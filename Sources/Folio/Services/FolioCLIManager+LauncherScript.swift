import Foundation

extension FolioCLIManager {

    /// Marks launchers generated from the unified script with bundle-ID isolation and `--wait` support.
    static let cliScriptMarker = "wait_for_sentinel"

    /// Generates an executable `folio` shell script stamped from the canonical `macos/FolioApp/folio` launcher.
    ///
    /// The script opens an app with `bundleIdentifier` and signals only running processes of the bundle ID
    /// that it opens. The queue file comes from that bundle ID unless `queueFilePath` is set.
    public static func generateCLIScript(
        fallbackAppBundlePath: String,
        queueFilePath: String? = nil,
        bundleIdentifier: String = FolioAppIdentity.current.bundleIdentifier
    ) -> String {
        var script = Self.canonicalCLILauncherScript
        script = replaceHeaderLine(
            "DEFAULT_QUEUE_FILE=''",
            with: "DEFAULT_QUEUE_FILE=\(shellSingleQuoted(queueFilePath ?? ""))",
            in: script
        )
        script = replaceHeaderLine(
            "DEFAULT_FALLBACK_APP='/Applications/Folio.app'",
            with: "DEFAULT_FALLBACK_APP=\(shellSingleQuoted(fallbackAppBundlePath))",
            in: script
        )
        script = replaceHeaderLine(
            "EXPECTED_BUNDLE_ID=\"\"",
            with: "EXPECTED_BUNDLE_ID=\"\(shellDoubleQuotedContent(bundleIdentifier))\"",
            in: script
        )
        return script
    }

    private static func replaceHeaderLine(_ target: String, with replacement: String, in script: String) -> String {
        guard let range = script.range(of: target) else {
            preconditionFailure("Missing header sentinel '\(target)' in canonical CLI launcher script")
        }
        var updated = script
        updated.replaceSubrange(range, with: replacement)
        return updated
    }

    private static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func shellDoubleQuotedContent(_ value: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(value.count)
        for char in value {
            switch char {
            case "\\", "\"", "$", "`":
                escaped.append("\\")
                escaped.append(char)
            default:
                escaped.append(char)
            }
        }
        return escaped
    }
}
