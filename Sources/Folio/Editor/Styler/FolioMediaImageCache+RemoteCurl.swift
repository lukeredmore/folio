import AppKit
import Foundation

extension FolioMediaImageCache {

    /// User-configurable `curl` command prefix used to fetch remote `http://` and `https://` media.
    /// Defaults to `"curl"`, allowing users to include auth cookies, headers, or flags
    /// (e.g. `curl -b "session=..."` or `curl -H "Authorization: Bearer ..."`).
    public var curlCommandPrefix: String {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _curlCommandPrefix
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = trimmed.isEmpty ? Self.defaultCurlCommandPrefix : trimmed
            var didChange = false
            lock.lock()
            if _curlCommandPrefix != normalized {
                _curlCommandPrefix = normalized
                failedRemoteURLs.removeAll()
                imageCache = imageCache.filter { !$0.key.hasPrefix("remote:") }
                animatedFramesCache = animatedFramesCache.filter { !$0.key.hasPrefix("remote:") }
                remoteVideoFileURLs.removeAll()
                didChange = true
            }
            lock.unlock()
            if didChange {
                postImageDidLoadNotification()
            }
        }
    }

    /// Clears cached remote images and failed remote URL state so subsequent renders re-fetch.
    public func clearRemoteCache() {
        lock.lock()
        failedRemoteURLs.removeAll()
        imageCache = imageCache.filter { !$0.key.hasPrefix("remote:") }
        animatedFramesCache = animatedFramesCache.filter { !$0.key.hasPrefix("remote:") }
        remoteVideoFileURLs.removeAll()
        lock.unlock()
        postImageDidLoadNotification()
    }

    private func postImageDidLoadNotification() {
        if Thread.isMainThread {
            NotificationCenter.default.post(name: Self.imageDidLoadNotification, object: nil)
        } else {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: Self.imageDidLoadNotification, object: nil)
            }
        }
    }

    /// Waits for all in-flight remote image and local video thumbnail fetches to finish (useful for deterministic tests).
    @discardableResult
    public func waitUntilRemoteFetchesIdle(timeout: TimeInterval = 15.0) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            lock.lock()
            let empty = inFlightRemoteURLs.isEmpty && inFlightLocalVideoKeys.isEmpty
            lock.unlock()
            if empty {
                return true
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        lock.lock()
        let empty = inFlightRemoteURLs.isEmpty && inFlightLocalVideoKeys.isEmpty
        lock.unlock()
        return empty
    }

    public static func remoteCacheKey(for url: URL) -> String {
        "remote:\(url.absoluteString)"
    }

    /// Resolves a raw Markdown/HTML image source string into an `http://`, `https://`, `sftp://`, `scp://`, or `ssh://` `URL`.
    public static func resolveRemoteURL(from rawSource: String) -> URL? {
        let trimmed =
            rawSource
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "&amp;", with: "&")
        let lower = trimmed.lowercased()
        let isSupportedRemoteScheme =
            lower.hasPrefix("http://")
            || lower.hasPrefix("https://")
            || lower.hasPrefix("sftp://")
            || lower.hasPrefix("scp://")
            || lower.hasPrefix("ssh://")
        guard isSupportedRemoteScheme else {
            return nil
        }
        if let url = URL(string: trimmed), url.host != nil {
            return url
        }
        if let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
            let url = URL(string: encoded),
            url.host != nil
        {
            return url
        }
        return nil
    }

    /// Builds the shell command executed by `/bin/sh -c` for fetching `url` using `commandPrefix`
    /// and optional SSH credentials (`--key` and `-u`) from `sshAuth`.
    public static func buildCurlShellCommand(
        for url: URL,
        commandPrefix: String,
        sshAuth: FolioMediaSSHAuthConfig = .disabled
    ) -> String {
        var normalizedPrefix =
            commandPrefix
            .replacingOccurrences(of: "\\\r\n", with: " ")
            .replacingOccurrences(of: "\\\n", with: " ")
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while normalizedPrefix.hasSuffix("\\") {
            normalizedPrefix.removeLast()
            normalizedPrefix = normalizedPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if normalizedPrefix.isEmpty {
            normalizedPrefix = defaultCurlCommandPrefix
        } else if normalizedPrefix.hasPrefix("-") {
            normalizedPrefix = "curl \(normalizedPrefix)"
        }
        normalizedPrefix = stripChromeCopyAsCurlLeadingURL(from: normalizedPrefix)

        let sshFlags = buildSSHAuthCurlFlags(
            for: url,
            normalizedPrefix: normalizedPrefix,
            sshAuth: sshAuth
        )
        let escapedURL = "'" + url.absoluteString.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "\(normalizedPrefix)\(sshFlags) -sS -L --fail --max-time 30 \(escapedURL)"
    }

    private static let chromeCopyAsCurlLeadingURLRegex = try! NSRegularExpression(
        pattern: #"^(curl(?:\.exe)?)\s+(?:'https?://[^']+'|"https?://[^"]+"|https?://\S+)\s*(.*)$"#,
        options: [.caseInsensitive]
    )

    /// If a user pasted a full browser "Copy as cURL" snippet (`curl 'https://example.com/...' -H ...`),
    /// strips the positional URL right after `curl` so only the requested image URL is fetched.
    private static func stripChromeCopyAsCurlLeadingURL(from prefix: String) -> String {
        guard
            let match = chromeCopyAsCurlLeadingURLRegex.firstMatch(
                in: prefix,
                options: [],
                range: NSRange(prefix.startIndex..., in: prefix)
            ),
            let cmdRange = Range(match.range(at: 1), in: prefix),
            let restRange = Range(match.range(at: 2), in: prefix)
        else {
            return prefix
        }
        let cmd = String(prefix[cmdRange])
        let rest = String(prefix[restRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        return rest.isEmpty ? cmd : "\(cmd) \(rest)"
    }

    func triggerRemoteFetchIfNeeded(url: URL, cacheKey: String) {
        lock.lock()
        if inFlightRemoteURLs.contains(cacheKey)
            || failedRemoteURLs.contains(cacheKey)
            || imageCache[cacheKey] != nil
        {
            lock.unlock()
            return
        }
        inFlightRemoteURLs.insert(cacheKey)
        let prefix = _curlCommandPrefix
        let sshAuth = _sshAuthConfig
        lock.unlock()

        remoteFetchQueue.async { [weak self] in
            guard let self = self else { return }
            let data = Self.executeCurlFetch(url: url, commandPrefix: prefix, sshAuth: sshAuth)
            let loadedImage = data.flatMap { self.decodeRemoteImageData($0, url: url) }

            self.lock.lock()
            self.inFlightRemoteURLs.remove(cacheKey)
            let currentConfigMatches = (self._curlCommandPrefix == prefix && self._sshAuthConfig == sshAuth)
            if let img = loadedImage {
                self.failedRemoteURLs.remove(cacheKey)
                self.imageCache[cacheKey] = img
            } else if currentConfigMatches {
                self.failedRemoteURLs.insert(cacheKey)
            }
            self.lock.unlock()

            if loadedImage != nil {
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: Self.imageDidLoadNotification, object: url)
                }
            }
        }
    }

    func decodeRemoteImageData(_ data: Data, url: URL) -> NSImage? {
        guard !data.isEmpty else { return nil }
        let cacheKey = Self.remoteCacheKey(for: url)
        let isSVGExtension = url.pathExtension.lowercased() == "svg"
        let headData = data.prefix(1024)
        let headString =
            String(data: headData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        let looksLikeSVG = isSVGExtension || headString.contains("<svg")
        if looksLikeSVG, let svgStr = String(data: data, encoding: .utf8) {
            if let img = svgImage(for: svgStr).image {
                return img
            }
        }
        if Self.isVideoURL(url.absoluteString) || Self.looksLikeVideoData(data) {
            if let videoThumb = cacheAndDecodeRemoteVideo(data, url: url, cacheKey: cacheKey) {
                return videoThumb
            }
        }
        if let animated = Self.decodeAnimatedFrames(from: data), let firstFrame = animated.frames.first {
            lock.lock()
            animatedFramesCache[cacheKey] = animated
            lock.unlock()
            return firstFrame
        }
        return NSImage(data: data)
    }

    static func runProcessDrainingPipes(
        _ process: Process
    ) -> (terminationStatus: Int32, stdout: Data, stderr: Data)? {
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return nil
        }

        final class PipeCapture: @unchecked Sendable {
            var stdout = Data()
            var stderr = Data()
        }
        let capture = PipeCapture()
        let group = DispatchGroup()

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            capture.stdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            capture.stderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        group.wait()
        process.waitUntilExit()
        return (process.terminationStatus, capture.stdout, capture.stderr)
    }

    static func executeCurlFetch(
        url: URL,
        commandPrefix: String,
        sshAuth: FolioMediaSSHAuthConfig = .disabled
    ) -> Data? {
        let shellCommand = buildCurlShellCommand(
            for: url,
            commandPrefix: commandPrefix,
            sshAuth: sshAuth
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", shellCommand]

        if let result = runProcessDrainingPipes(process),
            result.terminationStatus == 0,
            !result.stdout.isEmpty
        {
            return result.stdout
        }

        if isSSHFamilyURL(url) {
            return executeSSHFallbackFetch(url: url, sshAuth: sshAuth)
        }
        return nil
    }
}
