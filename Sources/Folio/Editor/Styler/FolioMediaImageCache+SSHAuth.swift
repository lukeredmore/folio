import AppKit
import CryptoKit
import Foundation

/// Configuration for passing Remote Host Access SSH credentials (`--key` and `-u`) to `curl`
/// (and falling back to `/usr/bin/ssh` for `sftp://`, `scp://`, and `ssh://` media URLs when
/// the local `curl` binary lacks `libssh2`).
public struct FolioMediaSSHAuthConfig: Equatable, Sendable {
    public var isEnabled: Bool
    public var identityFile: String?
    public var user: String?
    public var mounts: [RemoteMountSpec]

    public static let disabled = FolioMediaSSHAuthConfig(
        isEnabled: false,
        identityFile: nil,
        user: nil,
        mounts: []
    )

    public init(
        isEnabled: Bool = false,
        identityFile: String? = nil,
        user: String? = nil,
        mounts: [RemoteMountSpec] = []
    ) {
        self.isEnabled = isEnabled
        let trimmedKey = identityFile?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.identityFile = (trimmedKey?.isEmpty == false) ? trimmedKey : nil
        let trimmedUser = user?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.user = (trimmedUser?.isEmpty == false) ? trimmedUser : nil
        self.mounts = mounts
    }
}

extension FolioMediaImageCache {

    /// Active SSH authentication configuration synchronized from `EditorWorkspaceViewModel` and `RemoteWorkspaceManager`.
    public var sshAuthConfig: FolioMediaSSHAuthConfig {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _sshAuthConfig
        }
        set {
            var didChange = false
            lock.lock()
            if _sshAuthConfig != newValue {
                _sshAuthConfig = newValue
                failedRemoteURLs.removeAll()
                imageCache = imageCache.filter { !$0.key.hasPrefix("remote:") }
                animatedFramesCache = animatedFramesCache.filter { !$0.key.hasPrefix("remote:") }
                remoteVideoFileURLs.removeAll()
                didChange = true
            }
            lock.unlock()
            if didChange {
                if Thread.isMainThread {
                    NotificationCenter.default.post(name: Self.imageDidLoadNotification, object: nil)
                } else {
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(name: Self.imageDidLoadNotification, object: nil)
                    }
                }
            }
        }
    }

    public static func isSSHFamilyURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "sftp" || scheme == "scp" || scheme == "ssh"
    }

    /// Resolves the effective SSH user, identity key file, port, and host for `url` using
    /// explicit overrides, a host-matched (or primary) `RemoteMountSpec`, or standard `~/.ssh` keys.
    public static func resolveSSHAuth(
        for url: URL,
        config: FolioMediaSSHAuthConfig
    ) -> (user: String?, identityFile: String?, port: Int?, host: String?) {
        let urlHost = url.host?.trimmingCharacters(in: .whitespacesAndNewlines)
        let matchedMount: RemoteMountSpec?
        if let urlHost, !urlHost.isEmpty {
            matchedMount =
                config.mounts.first(where: {
                    $0.host.caseInsensitiveCompare(urlHost) == .orderedSame
                }) ?? config.mounts.first
        } else {
            matchedMount = config.mounts.first
        }

        let urlUser = url.user?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedUser: String?
        if let urlUser, !urlUser.isEmpty {
            resolvedUser = urlUser
        } else if let explicitUser = config.user, !explicitUser.isEmpty {
            resolvedUser = explicitUser
        } else {
            resolvedUser = matchedMount?.user
        }

        let rawIdentity = config.identityFile ?? matchedMount?.identityFile ?? defaultSSHIdentityFilePath()
        let expandedIdentity = rawIdentity.map { ($0 as NSString).expandingTildeInPath }
        let resolvedPort = url.port ?? matchedMount?.port
        let resolvedHost = (urlHost?.isEmpty == false) ? urlHost : matchedMount?.host

        return (resolvedUser, expandedIdentity, resolvedPort, resolvedHost)
    }

    /// Builds the `curl` CLI flags (`-u '<user>:' --key '<identityFile>' [--pubkey '<pub>']`)
    /// when `sshAuth.isEnabled` is true.
    public static func buildSSHAuthCurlFlags(
        for url: URL,
        normalizedPrefix: String,
        sshAuth: FolioMediaSSHAuthConfig
    ) -> String {
        guard sshAuth.isEnabled else { return "" }
        let resolved = resolveSSHAuth(for: url, config: sshAuth)
        var flags: [String] = []

        let hasUserFlag =
            normalizedPrefix.contains(" -u ")
            || normalizedPrefix.hasSuffix(" -u")
            || normalizedPrefix.contains("--user")
        if !hasUserFlag, let user = resolved.user, !user.isEmpty {
            let escapedUser = user.replacingOccurrences(of: "'", with: "'\\''")
            flags.append("-u '\(escapedUser):'")
        }

        let hasKeyFlag = normalizedPrefix.contains("--key")
        if !hasKeyFlag, let keyPath = resolved.identityFile, !keyPath.isEmpty {
            let escapedKey = keyPath.replacingOccurrences(of: "'", with: "'\\''")
            flags.append("--key '\(escapedKey)'")
            let pubPath = keyPath + ".pub"
            if !normalizedPrefix.contains("--pubkey"),
                FileManager.default.fileExists(atPath: pubPath)
            {
                let escapedPub = pubPath.replacingOccurrences(of: "'", with: "'\\''")
                flags.append("--pubkey '\(escapedPub)'")
            }
        }

        return flags.isEmpty ? "" : " " + flags.joined(separator: " ")
    }

    public static func defaultSSHIdentityFilePath() -> String? {
        let sshDir = (NSHomeDirectory() as NSString).appendingPathComponent(".ssh")
        for candidate in ["id_ed25519", "id_rsa", "id_ecdsa"] {
            let fullPath = (sshDir as NSString).appendingPathComponent(candidate)
            if FileManager.default.fileExists(atPath: fullPath) {
                return fullPath
            }
        }
        return nil
    }

    /// Fallback for `sftp://`, `scp://`, and `ssh://` image URLs when the system `/usr/bin/curl`
    /// is compiled without `libssh2` (the default on macOS). Uses `/usr/bin/ssh` with the same
    /// multiplexed non-interactive OpenSSH parameters as `SSHRemoteTransport`.
    static func executeSSHFallbackFetch(
        url: URL,
        sshAuth: FolioMediaSSHAuthConfig
    ) -> Data? {
        let resolved = resolveSSHAuth(for: url, config: sshAuth)
        guard let host = resolved.host, !host.isEmpty else { return nil }

        let urlPath = url.path
        let remotePath: String
        if urlPath.hasPrefix("/~/") {
            remotePath = "~/" + String(urlPath.dropFirst(3))
        } else if urlPath == "/~" {
            remotePath = "~"
        } else if !urlPath.isEmpty {
            remotePath = urlPath
        } else {
            return nil
        }

        let spec = RemoteMountSpec(
            host: host,
            user: resolved.user,
            port: resolved.port,
            remotePath: remotePath,
            targetKind: .file,
            identityFile: resolved.identityFile
        )
        let transport = SSHRemoteTransport()
        let escapedTarget = SSHRemoteTransport.shellEscapePath(remotePath)
        let sshArgs = transport.baseSSHArguments(for: spec) + ["cat \(escapedTarget)"]

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = sshArgs

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return nil
        }

        let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        _ = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0, !outData.isEmpty else {
            return nil
        }
        return outData
    }
}
