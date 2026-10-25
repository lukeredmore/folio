import AppKit
import AVFoundation
import Foundation

/// Shared cache and loader for local, data-URI, remote, SVG, and Mermaid-generated `NSImage` assets.
public final class FolioMediaImageCache: @unchecked Sendable {
    public static let shared = FolioMediaImageCache()
    public static let imageDidLoadNotification = Notification.Name("FolioMediaImageDidLoadNotification")
    public static let defaultCurlCommandPrefix = "curl"

    let lock = NSLock()
    var imageCache: [String: NSImage] = [:]
    var animatedFramesCache: [String: FolioAnimatedMediaFrames] = [:]
    var remoteVideoFileURLs: [String: URL] = [:]
    var svgStringCache: [String: String] = [:]
    var inFlightRemoteURLs: Set<String> = []
    var failedRemoteURLs: Set<String> = []
    var _curlCommandPrefix: String = FolioMediaImageCache.defaultCurlCommandPrefix
    var _sshAuthConfig: FolioMediaSSHAuthConfig = .disabled
    let remoteFetchQueue = DispatchQueue(
        label: "com.folio.media.remote-fetch",
        qos: .userInitiated,
        attributes: .concurrent
    )

    public init() {}

    public func mermaidImage(for source: String, isDark: Bool) -> (image: NSImage?, svg: String) {
        let key = "mermaid:\(isDark ? "dark" : "light"):\(source)"
        lock.lock()
        let cachedImg = imageCache[key]
        let cachedSVG = svgStringCache[key]
        lock.unlock()

        if let svg = cachedSVG, let img = cachedImg {
            return (img, svg)
        }

        let svg = MarkdownLiveStyler.renderMermaidSVG(source, isDark: isDark)
        let img = svg.data(using: .utf8)
            .flatMap { NSImage(data: $0) }
            .map { DiagramImageRenderer.rasterizeVectorImage($0) }
        lock.lock()
        svgStringCache[key] = svg
        if let img = img {
            imageCache[key] = img
        }
        lock.unlock()
        return (img, svg)
    }

    public func svgImage(for rawSVG: String) -> (image: NSImage?, svg: String) {
        let key = "svg:\(rawSVG)"
        lock.lock()
        let cachedImg = imageCache[key]
        let cachedSVG = svgStringCache[key]
        lock.unlock()

        if let svg = cachedSVG, let img = cachedImg {
            return (img, svg)
        }

        let normalized = MarkdownLiveStyler.normalizeSVG(rawSVG)
        let img = normalized.data(using: .utf8)
            .flatMap { NSImage(data: $0) }
            .map { DiagramImageRenderer.rasterizeVectorImage($0) }
        lock.lock()
        svgStringCache[key] = normalized
        if let img = img {
            imageCache[key] = img
        }
        lock.unlock()
        return (img, normalized)
    }

    public func displaySize(
        for rawSource: String,
        explicitWidth: CGFloat? = nil,
        explicitHeight: CGFloat? = nil,
        maxColumnWidth: CGFloat = 680.0,
        baseDirectoryURL: URL? = nil,
        isDark: Bool = false
    ) -> (size: NSSize, isLoaded: Bool) {
        if let img = image(for: rawSource, baseDirectoryURL: baseDirectoryURL, isDark: isDark),
           img.size.width > 0,
           img.size.height > 0 {
            let natW = img.size.width
            let natH = img.size.height
            let aspect = natH / max(1.0, natW)
            let targetW: CGFloat
            let targetH: CGFloat
            if let ew = explicitWidth, let eh = explicitHeight {
                targetW = ew
                targetH = eh
            } else if let ew = explicitWidth {
                targetW = ew
                targetH = round(ew * aspect)
            } else if let eh = explicitHeight {
                targetH = eh
                targetW = round(eh / max(0.01, aspect))
            } else {
                targetW = natW
                targetH = natH
            }
            let maxW = max(120.0, maxColumnWidth)
            let maxH: CGFloat = 420.0
            let scale = min(1.0, min(maxW / max(1.0, targetW), maxH / max(1.0, targetH)))
            return (NSSize(width: ceil(targetW * scale), height: ceil(targetH * scale)), true)
        }
        let fallbackW = min(max(120.0, maxColumnWidth), explicitWidth ?? 360.0)
        return (NSSize(width: fallbackW, height: 48.0), false)
    }

    public func image(for rawSource: String, baseDirectoryURL: URL? = nil, isDark: Bool = false) -> NSImage? {
        let trimmed = rawSource.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // 1. Remote HTTP/HTTPS URL (canonical cache key independent of baseDirectoryURL / isDark)
        if let remoteURL = Self.resolveRemoteURL(from: trimmed) {
            let remoteKey = Self.remoteCacheKey(for: remoteURL)
            lock.lock()
            if let cached = imageCache[remoteKey] {
                lock.unlock()
                return cached
            }
            lock.unlock()
            triggerRemoteFetchIfNeeded(url: remoteURL, cacheKey: remoteKey)
            return nil
        }

        let cacheKey = "\(baseDirectoryURL?.path ?? "")|\(isDark ? "1" : "0")|\(trimmed)"
        lock.lock()
        if let cached = imageCache[cacheKey] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        // 2. Inline <svg ...> string
        if trimmed.lowercased().hasPrefix("<svg") {
            let (img, _) = svgImage(for: trimmed)
            if let img = img {
                storeImage(img, forKey: cacheKey)
            }
            return img
        }

        // 3. data: URI (e.g. data:image/svg+xml;utf8,<svg...> or data:image/png;base64,...)
        if trimmed.lowercased().hasPrefix("data:") {
            if let commaIdx = trimmed.firstIndex(of: ",") {
                let header = String(trimmed[..<commaIdx]).lowercased()
                let payload = String(trimmed[trimmed.index(after: commaIdx)...])
                if header.contains(";base64") {
                    if let data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters) {
                        if header.contains("image/svg"), let svgStr = String(data: data, encoding: .utf8) {
                            let (img, _) = svgImage(for: svgStr)
                            if let img = img { storeImage(img, forKey: cacheKey) }
                            return img
                        } else if let img = storeAndDecodeImageData(data, forKey: cacheKey) {
                            return img
                        }
                    }
                } else {
                    let decoded = payload.removingPercentEncoding ?? payload
                    if header.contains("image/svg") || decoded.lowercased().contains("<svg") {
                        let (img, _) = svgImage(for: decoded)
                        if let img = img { storeImage(img, forKey: cacheKey) }
                        return img
                    } else if let data = decoded.data(using: .utf8),
                              let img = storeAndDecodeImageData(data, forKey: cacheKey) {
                        return img
                    }
                }
            }
            return nil
        }

        // 4. Local file:// URL, ~/path, /absolute/path, or relative path
        if let fileURL = resolveLocalFileURL(from: trimmed, baseDirectoryURL: baseDirectoryURL),
           FileManager.default.fileExists(atPath: fileURL.path) {
            let ext = fileURL.pathExtension.lowercased()
            if ext == "svg",
               let rawSVG = try? String(contentsOf: fileURL, encoding: .utf8) {
                let (img, _) = svgImage(for: rawSVG)
                if let img = img {
                    storeImage(img, forKey: cacheKey)
                    return img
                }
            }
            if ["mp4", "mov", "m4v", "webm"].contains(ext) {
                if let img = Self.extractVideoThumbnail(from: fileURL) {
                    storeImage(img, forKey: cacheKey)
                    return img
                }
            }
            if let data = try? Data(contentsOf: fileURL),
               let img = storeAndDecodeImageData(data, forKey: cacheKey) {
                return img
            }
            if let img = NSImage(contentsOf: fileURL) {
                storeImage(img, forKey: cacheKey)
                return img
            }
        }

        return nil
    }

    func resolveLocalFileURL(from trimmed: String, baseDirectoryURL: URL?) -> URL? {
        if trimmed.lowercased().hasPrefix("file://"), let url = URL(string: trimmed) {
            return url
        }
        let unescaped = trimmed.removingPercentEncoding ?? trimmed
        if unescaped.hasPrefix("~/") {
            let expanded = (unescaped as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expanded)
        } else if unescaped.hasPrefix("/") {
            return URL(fileURLWithPath: unescaped)
        } else {
            let baseDir = baseDirectoryURL ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            return baseDir.appendingPathComponent(unescaped).standardizedFileURL
        }
    }

    func storeAndDecodeImageData(_ data: Data, forKey key: String) -> NSImage? {
        if let animated = Self.decodeAnimatedFrames(from: data), let first = animated.frames.first {
            lock.lock()
            animatedFramesCache[key] = animated
            imageCache[key] = first
            lock.unlock()
            return first
        }
        guard let img = NSImage(data: data) else { return nil }
        storeImage(img, forKey: key)
        return img
    }

    public static func isVideoURL(_ rawURL: String) -> Bool {
        let lower = rawURL.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let pathPart = lower.split(separator: "?").first.map(String.init) ?? lower
        return pathPart.hasSuffix(".mp4")
            || pathPart.hasSuffix(".mov")
            || pathPart.hasSuffix(".m4v")
            || pathPart.hasSuffix(".webm")
            || lower.hasPrefix("data:video/")
    }

    func storeImage(_ image: NSImage, forKey key: String) {
        lock.lock()
        imageCache[key] = image
        lock.unlock()
    }
}
