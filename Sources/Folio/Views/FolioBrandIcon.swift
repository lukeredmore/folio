import AppKit
import CoreGraphics
import CoreText
import SwiftUI

/// Renders the Folio app icon and wordmark.
public enum FolioBrandIcon {
    static func srgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1.0) -> NSColor {
        NSColor(srgbRed: r / 255.0, green: g / 255.0, blue: b / 255.0, alpha: a)
    }

    /// Determines whether the current process is running a local/Bazel/temporary development build
    /// rather than a stamped release build.
    public static func isRunningDevBuild(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        let resolvedPath = bundle.bundleURL.resolvingSymlinksInPath().path
        let rawPath = bundle.bundleURL.path
        let combinedPath = resolvedPath == rawPath ? rawPath : "\(rawPath):\(resolvedPath)"
        return isRunningDevBuild(
            bundlePath: combinedPath,
            infoDictionary: bundle.infoDictionary,
            environment: environment
        )
    }

    /// Pure helper for determining whether a bundle/environment represents a dev or Bazel build.
    public static func isRunningDevBuild(
        bundlePath: String,
        infoDictionary: [String: Any]?,
        environment: [String: String] = [:]
    ) -> Bool {
        if let override = environment["FOLIO_DEV_ICON"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            if ["1", "true", "yes"].contains(override) {
                return true
            }
            if ["0", "false", "no"].contains(override) {
                return false
            }
        }

        let bazelEnvKeys = [
            "BUILD_WORKSPACE_DIRECTORY",
            "BUILD_WORKING_DIRECTORY",
            "RUNFILES_DIR",
            "JAVA_RUNFILES",
            "TEST_TMPDIR",
            "TEST_SRCDIR",
        ]
        for key in bazelEnvKeys {
            if let value = environment[key], !value.isEmpty {
                return true
            }
        }

        let devPathMarkers = [
            "/bazel-out/",
            "/bazel-bin/",
            "/_bazel_",
            ".runfiles/",
            "/bazel_temp.",
            "/worktrees/",
        ]
        for marker in devPathMarkers {
            if bundlePath.contains(marker) {
                return true
            }
        }

        if let channel = (infoDictionary?["FolioBuildChannel"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        {
            if channel == "dev" || channel == "debug" {
                return true
            }
            if channel == "release" {
                return false
            }
        }

        if let commitSHA = (infoDictionary?["FolioCommitSHA"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        {
            if commitSHA.isEmpty || commitSHA == "dev" {
                return true
            }
        }

        return false
    }

    /// Creates a vector-rendered macOS app icon `NSImage` for the current runtime environment
    /// (automatically badged with `DEV` when running via Bazel or an unstamped dev build).
    public static func makeCurrentAppIconImage(
        pixelSize: Int = 512,
        isDark: Bool = false,
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> NSImage {
        makeAppIconImage(
            pixelSize: pixelSize,
            isDark: isDark,
            isDevBuild: isRunningDevBuild(bundle: bundle, environment: environment)
        )
    }

    /// Creates a vector-rendered macOS app icon `NSImage`.
    public static func makeAppIconImage(
        pixelSize: Int = 512,
        isDark: Bool = false,
        isDevBuild: Bool = false
    ) -> NSImage {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelSize,
            pixelsHigh: pixelSize,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        rep.size = NSSize(width: pixelSize, height: pixelSize)

        NSGraphicsContext.saveGraphicsState()
        if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.current = ctx
            drawSquircleIcon(
                in: ctx.cgContext,
                canvasSize: CGFloat(pixelSize),
                includeMacOSMargin: true,
                isDark: isDark,
                isDevBuild: isDevBuild
            )
        }
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: NSSize(width: pixelSize, height: pixelSize))
        image.addRepresentation(rep)
        return image
    }
}

/// SwiftUI view rendering the Folio icon alongside the wordmark.
public struct FolioBrandLockupView: View {
    public var iconSize: CGFloat
    public var wordmarkSize: CGFloat
    public var isDark: Bool

    public init(iconSize: CGFloat = 24, wordmarkSize: CGFloat = 16, isDark: Bool = false) {
        self.iconSize = iconSize
        self.wordmarkSize = wordmarkSize
        self.isDark = isDark
    }

    public var body: some View {
        HStack(spacing: round(iconSize * 0.34)) {
            Image(nsImage: FolioBrandIcon.makeAppIconImage(pixelSize: Int(max(64, iconSize * 4)), isDark: isDark))
                .resizable()
                .interpolation(.high)
                .frame(width: iconSize, height: iconSize)

            Text("Folio")
                .font(.custom("Charter", size: wordmarkSize).weight(.bold))
                .tracking(-wordmarkSize * 0.02)
        }
    }
}
