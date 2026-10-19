import CryptoKit
import Foundation
import SwiftUI

// MARK: - Remote Target Kind & Spec

public enum RemoteMountTargetKind: String, Codable, CaseIterable, Sendable {
    case folder
    case file
}

/// Describes a mounted remote SSH/SFTP folder or file in the Folio workspace.
public struct RemoteMountSpec: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var host: String
    public var user: String?
    public var port: Int?
    public var remotePath: String
    public var targetKind: RemoteMountTargetKind
    public var identityFile: String?
    public var displayName: String?

    public init(
        id: UUID = UUID(),
        host: String,
        user: String? = nil,
        port: Int? = nil,
        remotePath: String,
        targetKind: RemoteMountTargetKind = .folder,
        identityFile: String? = nil,
        displayName: String? = nil
    ) {
        self.id = id
        self.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUser = user?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.user = (trimmedUser?.isEmpty == false) ? trimmedUser : nil
        self.port = port
        let normalizedPath = remotePath.trimmingCharacters(in: .whitespacesAndNewlines)
        self.remotePath = normalizedPath.isEmpty ? "~" : normalizedPath
        self.targetKind = targetKind
        let trimmedIdentity = identityFile?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.identityFile = (trimmedIdentity?.isEmpty == false) ? trimmedIdentity : nil
        let trimmedName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.displayName = (trimmedName?.isEmpty == false) ? trimmedName : nil
    }

    /// SSH destination formatted as `user@host` or `host`.
    public var sshDestination: String {
        if let user = user, !user.isEmpty {
            return "\(user)@\(host)"
        }
        return host
    }

    /// Short human-readable label for the sidebar root node.
    public var effectiveDisplayName: String {
        if let custom = displayName, !custom.isEmpty {
            return custom
        }
        let cleaned = remotePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let basename = (cleaned as NSString).lastPathComponent
        let label = basename.isEmpty ? remotePath : basename
        return "\(label) (\(host))"
    }

    /// Alias for `effectiveDisplayName`.
    public var label: String {
        effectiveDisplayName
    }

    /// Full connection string like `user@host:/path` or `ssh://user@host:2222/path`.
    public var connectionSpecString: String {
        if let port = port, port != 22 {
            return "ssh://\(sshDestination):\(port)\(remotePath.hasPrefix("/") ? "" : "/")\(remotePath)"
        }
        return "\(sshDestination):\(remotePath)"
    }

    /// Alias for `connectionSpecString`.
    public var connectionString: String {
        connectionSpecString
    }

    /// Parses connection strings of the forms:
    /// - `user@host:/path/to/folder`
    /// - `host:~/notes`
    /// - `ssh://user@host:2222/path/to/file.md`
    /// - `sftp://user@host/path`
    public static func parse(
        connectionString: String,
        targetKind: RemoteMountTargetKind? = nil,
        portOverride: Int? = nil,
        identityFile: String? = nil,
        identityFilePath: String? = nil,
        displayName: String? = nil
    ) throws -> RemoteMountSpec {
        let raw = connectionString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            throw RemoteWorkspaceError.invalidConnectionSpec("Connection string cannot be empty.")
        }

        var user: String?
        var host: String = ""
        var port: Int?
        var remotePath: String = "~"

        if raw.lowercased().hasPrefix("ssh://") || raw.lowercased().hasPrefix("sftp://") {
            guard let components = URLComponents(string: raw),
                  let parsedHost = components.host, !parsedHost.isEmpty else {
                throw RemoteWorkspaceError.invalidConnectionSpec("Invalid SSH/SFTP URL: \(raw)")
            }
            user = components.user
            host = parsedHost
            port = components.port
            let urlPath = components.path
            if urlPath.hasPrefix("/~/") {
                remotePath = "~/" + String(urlPath.dropFirst(3))
            } else if urlPath == "/~" {
                remotePath = "~"
            } else if !urlPath.isEmpty {
                remotePath = urlPath
            }
        } else {
            // Format: [user@]host:/path
            guard raw.contains(":") else {
                throw RemoteWorkspaceError.invalidConnectionSpec("Expected 'user@host:/path' or 'ssh://user@host/path' in '\(raw)'.")
            }
            let parts = raw.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let hostPart = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
            if parts.count > 1 {
                let pathPart = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !pathPart.isEmpty {
                    remotePath = pathPart
                }
            }
            if let atIdx = hostPart.firstIndex(of: "@") {
                let u = String(hostPart[..<atIdx])
                let h = String(hostPart[hostPart.index(after: atIdx)...])
                user = u.isEmpty ? nil : u
                host = h
            } else {
                host = hostPart
            }
        }

        guard !host.isEmpty, !host.contains(" ") else {
            throw RemoteWorkspaceError.invalidConnectionSpec("Invalid remote host in '\(raw)'.")
        }

        let inferredKind: RemoteMountTargetKind
        if let explicit = targetKind {
            inferredKind = explicit
        } else {
            let ext = (remotePath as NSString).pathExtension.lowercased()
            if ["md", "markdown", "mdown", "mkd", "txt", "textbundle"].contains(ext) {
                inferredKind = .file
            } else {
                inferredKind = .folder
            }
        }

        let effectivePort = portOverride ?? port ?? 22
        let effectiveIdentity = identityFilePath ?? identityFile

        return RemoteMountSpec(
            host: host,
            user: user,
            port: effectivePort,
            remotePath: remotePath,
            targetKind: inferredKind,
            identityFile: effectiveIdentity,
            displayName: displayName
        )
    }
}

// MARK: - Remote Connection Health & Sync State

public enum RemoteConnectionState: Equatable, Sendable {
    case connected
    case syncing(detail: String)
    case reconnecting(attempt: Int, lastError: String, nextRetryAt: Date)
    case error(message: String)

    public var isHealthy: Bool {
        switch self {
        case .connected, .syncing:
            return true
        case .reconnecting, .error:
            return false
        }
    }

    public var errorMessage: String? {
        switch self {
        case .connected, .syncing:
            return nil
        case .reconnecting(_, let lastError, _):
            return lastError
        case .error(let message):
            return message
        }
    }

    public var statusSummary: String {
        switch self {
        case .connected:
            return "Synced"
        case .syncing(let detail):
            return detail.isEmpty ? "Syncing…" : detail
        case .reconnecting(let attempt, let lastError, _):
            return "Connection interrupted (\(lastError)) — auto-reconnecting (#\(attempt))…"
        case .error(let message):
            return message
        }
    }

    public var shortBadgeText: String {
        switch self {
        case .connected:
            return "Synced"
        case .syncing:
            return "Syncing"
        case .reconnecting(let attempt, _, _):
            return "Retry #\(attempt)"
        case .error:
            return "Offline"
        }
    }
}

public enum RemoteFileSyncStatus: Equatable, Hashable, Sendable {
    case synced
    case syncing
    case pendingUpload
    case conflictResolved
    case error(String)
}

public enum RemoteWorkspaceError: LocalizedError, Equatable, Sendable {
    case invalidConnectionSpec(String)
    case connectionFailed(host: String, details: String)
    case remotePathNotFound(path: String)
    case transportTimeout(host: String)
    case permissionDenied(path: String)

    public var errorDescription: String? {
        switch self {
        case .invalidConnectionSpec(let msg):
            return msg
        case .connectionFailed(let host, let details):
            return "Cannot reach \(host): \(details)"
        case .remotePathNotFound(let path):
            return "Remote path not found: \(path)"
        case .transportTimeout(let host):
            return "Connection to \(host) timed out"
        case .permissionDenied(let path):
            return "Permission denied for \(path)"
        }
    }
}

// MARK: - Remote File Snapshot & Transport Protocol

public struct RemoteFileEntry: Equatable, Sendable {
    /// Relative path inside the mounted folder (or the filename itself when `targetKind == .file`).
    public let relativePath: String
    public let modificationTimestamp: TimeInterval
    public let content: String

    public var contentHash: String {
        let digest = SHA256.hash(data: Data(content.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public init(relativePath: String, modificationTimestamp: TimeInterval, content: String) {
        self.relativePath = relativePath
        self.modificationTimestamp = modificationTimestamp
        self.content = content
    }
}

/// Pluggable transport abstraction for remote file & folder synchronization.
/// Production uses `SSHRemoteTransport` (multiplexed non-interactive OpenSSH),
/// while unit tests can inject deterministic or fault-injecting mock transports.
public protocol RemoteFileTransport: Sendable {
    func fetchSnapshot(for mount: RemoteMountSpec) async throws -> [RemoteFileEntry]
    func pushFile(content: String, relativePath: String, for mount: RemoteMountSpec) async throws -> TimeInterval
    func deleteFile(relativePath: String, for mount: RemoteMountSpec) async throws
}

// MARK: - Multiplexed OpenSSH Transport

public struct SSHRemoteTransport: RemoteFileTransport {
    public let connectTimeoutSeconds: Int

    public init(connectTimeoutSeconds: Int = 6) {
        self.connectTimeoutSeconds = connectTimeoutSeconds
    }

    private func controlSocketPath(for mount: RemoteMountSpec) -> String {
        let rawKey = "\(mount.sshDestination):\(mount.port ?? 22)"
        let hash = SHA256.hash(data: Data(rawKey.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return "/tmp/folio-ssh-\(hash).sock"
    }

    private func baseSSHArguments(for mount: RemoteMountSpec) -> [String] {
        let lowerHost = mount.host.lowercased()
        let isLoopback = lowerHost == "localhost" || lowerHost == "127.0.0.1" || lowerHost == "::1"
        var args: [String] = [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=\(connectTimeoutSeconds)",
            "-o", "ControlMaster=auto",
            "-o", "ControlPersist=120",
            "-o", "ControlPath=\(controlSocketPath(for: mount))",
            "-o", "ServerAliveInterval=5",
            "-o", "ServerAliveCountMax=2"
        ]
        if isLoopback {
            args.append(contentsOf: [
                "-o", "StrictHostKeyChecking=no",
                "-o", "UserKnownHostsFile=/dev/null",
                "-o", "LogLevel=ERROR"
            ])
        } else {
            args.append(contentsOf: [
                "-o", "StrictHostKeyChecking=accept-new"
            ])
        }
        if let port = mount.port, port > 0 {
            args.append(contentsOf: ["-p", "\(port)"])
        }
        if let identity = mount.identityFile, !identity.isEmpty {
            let expanded = (identity as NSString).expandingTildeInPath
            args.append(contentsOf: ["-i", expanded])
        }
        args.append(mount.sshDestination)
        return args
    }

    /// Escapes a path for safe single-quoted POSIX shell usage, while allowing leading `~` expansion.
    public static func shellEscapePath(_ path: String) -> String {
        if path == "~" {
            return "\"$HOME\""
        }
        if path.hasPrefix("~/") {
            let rest = String(path.dropFirst(2))
            let escapedRest = rest.replacingOccurrences(of: "'", with: "'\\''")
            return "\"$HOME\"/'\(escapedRest)'"
        }
        let escaped = path.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }

    public func fetchSnapshot(for mount: RemoteMountSpec) async throws -> [RemoteFileEntry] {
        let escapedTarget = Self.shellEscapePath(mount.remotePath)

        let remoteScript: String
        switch mount.targetKind {
        case .file:
            remoteScript = """
            TARGET=\(escapedTarget)
            if [ ! -f "$TARGET" ]; then
                echo "__FOLIO_ERR_NOT_FOUND__" >&2
                exit 44
            fi
            BASENAME=$(basename "$TARGET")
            MTIME=$(date -r "$TARGET" +%s 2>/dev/null || stat -c %Y "$TARGET" 2>/dev/null || stat -f %m "$TARGET" 2>/dev/null || echo 0)
            printf "===FOLIO_FILE===\\t%s\\t%s\\n" "$BASENAME" "$MTIME"
            base64 < "$TARGET" | tr -d '\\r\\n'
            printf "\\n===FOLIO_END===\\n"
            """
        case .folder:
            remoteScript = """
            TARGET=\(escapedTarget)
            if [ ! -d "$TARGET" ]; then
                echo "__FOLIO_ERR_NOT_FOUND__" >&2
                exit 44
            fi
            cd "$TARGET" || exit 44
            find . -maxdepth 4 \\( -name .git -o -name node_modules -o -name target -o -name .build -o -name DerivedData -o -name dist -o -name build \\) -prune -o -type f \\( -iname '*.md' -o -iname '*.markdown' -o -iname '*.mdown' -o -iname '*.mkd' -o -iname '*.txt' \\) -print | while IFS= read -r f; do
                REL="${f#./}"
                MTIME=$(date -r "$f" +%s 2>/dev/null || stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo 0)
                printf "===FOLIO_FILE===\\t%s\\t%s\\n" "$REL" "$MTIME"
                base64 < "$f" | tr -d '\\r\\n'
                printf "\\n===FOLIO_END===\\n"
            done
            """
        }

        let (stdout, stderr, status) = try await runSSHScript(for: mount, script: remoteScript)
        guard status == 0 else {
            throw mapSSHError(mount: mount, status: status, stderr: stderr)
        }

        return Self.parseSnapshotOutput(stdout)
    }

    public static func parseSnapshotOutput(_ output: String) -> [RemoteFileEntry] {
        var entries: [RemoteFileEntry] = []
        let lines = output.components(separatedBy: "\n")
        var idx = 0
        while idx < lines.count {
            let line = lines[idx]
            if line.hasPrefix("===FOLIO_FILE===\t") {
                let parts = line.components(separatedBy: "\t")
                guard parts.count >= 3 else {
                    idx += 1
                    continue
                }
                let relPath = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                let mtime = TimeInterval(parts[2].trimmingCharacters(in: .whitespacesAndNewlines)) ?? Date().timeIntervalSince1970
                idx += 1
                var b64Chunks: [String] = []
                while idx < lines.count && lines[idx] != "===FOLIO_END===" {
                    b64Chunks.append(lines[idx].trimmingCharacters(in: .whitespacesAndNewlines))
                    idx += 1
                }
                let joinedB64 = b64Chunks.joined()
                let decodedData = Data(base64Encoded: joinedB64) ?? Data()
                let text = String(data: decodedData, encoding: .utf8) ?? ""
                if !relPath.isEmpty {
                    entries.append(RemoteFileEntry(
                        relativePath: relPath,
                        modificationTimestamp: mtime,
                        content: text
                    ))
                }
            }
            idx += 1
        }
        return entries
    }

    public func pushFile(content: String, relativePath: String, for mount: RemoteMountSpec) async throws -> TimeInterval {
        let targetFileExpr: String
        switch mount.targetKind {
        case .file:
            targetFileExpr = Self.shellEscapePath(mount.remotePath)
        case .folder:
            let cleanRel = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let combined = (mount.remotePath as NSString).appendingPathComponent(cleanRel)
            targetFileExpr = Self.shellEscapePath(combined)
        }

        let b64Payload = Data(content.utf8).base64EncodedString()
        let remoteScript = """
        TARGET=\(targetFileExpr)
        DIR=$(dirname "$TARGET")
        mkdir -p "$DIR" || exit 45
        TMP="$TARGET.folio_tmp.$$"
        base64 -d > "$TMP" << '__FOLIO_B64_EOF__'
        \(b64Payload)
        __FOLIO_B64_EOF__
        if [ $? -ne 0 ]; then
            base64 -D > "$TMP" << '__FOLIO_B64_EOF__'
        \(b64Payload)
        __FOLIO_B64_EOF__
        fi
        mv -f "$TMP" "$TARGET" || exit 45
        MTIME=$(date -r "$TARGET" +%s 2>/dev/null || stat -c %Y "$TARGET" 2>/dev/null || stat -f %m "$TARGET" 2>/dev/null || date +%s)
        printf "%s\\n" "$MTIME"
        """

        let (stdout, stderr, status) = try await runSSHScript(for: mount, script: remoteScript)
        guard status == 0 else {
            throw mapSSHError(mount: mount, status: status, stderr: stderr)
        }
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return TimeInterval(trimmed) ?? Date().timeIntervalSince1970
    }

    public func deleteFile(relativePath: String, for mount: RemoteMountSpec) async throws {
        let targetFileExpr: String
        switch mount.targetKind {
        case .file:
            targetFileExpr = Self.shellEscapePath(mount.remotePath)
        case .folder:
            let cleanRel = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let combined = (mount.remotePath as NSString).appendingPathComponent(cleanRel)
            targetFileExpr = Self.shellEscapePath(combined)
        }

        let remoteScript = "rm -f \(targetFileExpr)"
        let (_, stderr, status) = try await runSSHScript(for: mount, script: remoteScript)
        guard status == 0 else {
            throw mapSSHError(mount: mount, status: status, stderr: stderr)
        }
    }

    private func mapSSHError(mount: RemoteMountSpec, status: Int32, stderr: String) -> RemoteWorkspaceError {
        let cleanErr = stderr
            .replacingOccurrences(of: "__FOLIO_ERR_NOT_FOUND__", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if status == 44 || stderr.contains("__FOLIO_ERR_NOT_FOUND__") {
            return .remotePathNotFound(path: mount.remotePath)
        }
        if status == 45 || cleanErr.lowercased().contains("permission denied") {
            return .permissionDenied(path: mount.remotePath)
        }
        if cleanErr.lowercased().contains("timed out") || cleanErr.lowercased().contains("operation timed out") {
            return .transportTimeout(host: mount.host)
        }
        let fallback = cleanErr.isEmpty ? "SSH exited with code \(status)" : cleanErr
        return .connectionFailed(host: mount.host, details: fallback)
    }

    private func runSSHScript(
        for mount: RemoteMountSpec,
        script: String
    ) async throws -> (stdout: String, stderr: String, status: Int32) {
        let sshArgs = baseSSHArguments(for: mount) + ["sh", "-s"]
        return try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = sshArgs

            let stdinPipe = Pipe()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardInput = stdinPipe
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            try process.run()

            if let scriptData = script.data(using: .utf8) {
                stdinPipe.fileHandleForWriting.write(scriptData)
            }
            stdinPipe.fileHandleForWriting.closeFile()

            let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            return (
                stdout: String(data: outData, encoding: .utf8) ?? "",
                stderr: String(data: errData, encoding: .utf8) ?? "",
                status: process.terminationStatus
            )
        }.value
    }
}

// MARK: - Remote Workspace Sync Engine & Local Mirror Manager

public struct PendingRemoteWrite: Codable, Equatable, Sendable {
    public let mountID: UUID
    public let relativePath: String
    public let localFileURL: URL
    public let queuedAt: Date
}

@MainActor
public final class RemoteWorkspaceManager: ObservableObject {
    @Published public private(set) var mounts: [RemoteMountSpec] = []
    @Published public private(set) var connectionStates: [UUID: RemoteConnectionState] = [:]
    @Published public private(set) var fileSyncStatuses: [URL: RemoteFileSyncStatus] = [:]
    @Published public private(set) var pendingWriteQueue: [PendingRemoteWrite] = []

    /// Callback invoked whenever a remote mount's mirror directory or file content changes,
    /// allowing `EditorWorkspaceViewModel` to refresh the file tree and open editor buffer.
    public var onMirrorUpdated: ((UUID, [URL]) -> Void)?

    public let mirrorRootURL: URL
    public var transport: RemoteFileTransport

    /// Tracks the last-known remote SHA-256 hash per mirrored local file URL so we can distinguish
    /// remote changes from local dirty edits.
    private var lastSyncedContentHashes: [URL: String] = [:]
    private var retryCounts: [UUID: Int] = [:]
    nonisolated(unsafe) private var retryTasks: [UUID: Task<Void, Never>] = [:]
    nonisolated(unsafe) private var pollingTask: Task<Void, Never>?

    private let mountsDefaultsKey: String
    private let userDefaults: UserDefaults

    /// Backoff schedule in seconds: fast initial recovery (1s, 2s, 4s, 8s, capped at 15s).
    public var retryBackoffBaseSeconds: TimeInterval = 1.0

    public var baseRetryDelaySeconds: TimeInterval {
        get { retryBackoffBaseSeconds }
        set { retryBackoffBaseSeconds = newValue }
    }

    public init(
        transport: RemoteFileTransport = SSHRemoteTransport(),
        mirrorRootURL: URL? = nil,
        mirrorBaseDirectory: URL? = nil,
        userDefaults: UserDefaults = .standard,
        mountsDefaultsKey: String = "Folio.RemoteMounts.v1"
    ) {
        self.transport = transport
        self.userDefaults = userDefaults
        self.mountsDefaultsKey = mountsDefaultsKey

        if let customRoot = mirrorBaseDirectory ?? mirrorRootURL {
            self.mirrorRootURL = customRoot
        } else {
            let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.mirrorRootURL = cachesDir.appendingPathComponent("FolioRemoteMirrors", isDirectory: true)
        }

        try? FileManager.default.createDirectory(at: self.mirrorRootURL, withIntermediateDirectories: true)

        if let savedData = userDefaults.data(forKey: mountsDefaultsKey),
           let decoded = try? JSONDecoder().decode([RemoteMountSpec].self, from: savedData) {
            self.mounts = decoded
            for mount in decoded {
                let dir = localMirrorDirectory(for: mount)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                self.connectionStates[mount.id] = .syncing(detail: "Connecting to \(mount.host)…")
            }
        }
    }

    deinit {
        pollingTask?.cancel()
        for (_, task) in retryTasks {
            task.cancel()
        }
    }

    // MARK: - Mirror URL Resolution

    /// Returns the local mirror root directory on disk for a given `RemoteMountSpec`.
    public func localMirrorDirectory(for mount: RemoteMountSpec) -> URL {
        mirrorRootURL.appendingPathComponent(mount.id.uuidString, isDirectory: true)
    }

    /// Alias for `localMirrorDirectory(for:)`.
    public func mirrorRootURL(for mount: RemoteMountSpec) -> URL {
        localMirrorDirectory(for: mount)
    }

    /// Returns the local mirror URL for a specific relative path inside a mount.
    public func localFileURL(for relativePath: String, in mount: RemoteMountSpec) -> URL {
        let base = localMirrorDirectory(for: mount)
        let cleanRel = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return base.appendingPathComponent(cleanRel, isDirectory: false).standardizedFileURL
    }

    /// Resolves which `RemoteMountSpec` and relative path own a given local mirror `URL`, if any.
    public func resolveMount(for url: URL) -> (mount: RemoteMountSpec, relativePath: String)? {
        let stdPath = url.standardizedFileURL.path
        for mount in mounts {
            let rootPath = localMirrorDirectory(for: mount).standardizedFileURL.path
            if stdPath == rootPath {
                return (mount, "")
            }
            let prefix = rootPath.hasSuffix("/") ? rootPath : (rootPath + "/")
            if stdPath.hasPrefix(prefix) {
                let rel = String(stdPath.dropFirst(prefix.count))
                return (mount, rel)
            }
        }
        return nil
    }

    /// Returns the `RemoteMountSpec` owning a given local mirror `URL`, if any.
    public func mount(forLocalURL url: URL) -> RemoteMountSpec? {
        resolveMount(for: url)?.mount
    }

    /// Returns the live `RemoteFileSyncStatus` for a given local mirror `URL`.
    public func syncStatus(forLocalURL url: URL) -> RemoteFileSyncStatus {
        fileSyncStatuses[url.standardizedFileURL] ?? .synced
    }

    /// Returns a human-readable `user@host:/path/to/file` display string for a local mirror URL.
    public func remoteSSHDisplayPath(forLocalURL url: URL) -> String? {
        guard let resolved = resolveMount(for: url) else { return nil }
        if resolved.relativePath.isEmpty || resolved.mount.targetKind == .file {
            return resolved.mount.connectionSpecString
        }
        let base = resolved.mount.remotePath.hasSuffix("/")
            ? String(resolved.mount.remotePath.dropLast())
            : resolved.mount.remotePath
        return "\(resolved.mount.sshDestination):\(base)/\(resolved.relativePath)"
    }

    /// Returns true if the given URL belongs to any mounted remote workspace.
    public func isRemoteURL(_ url: URL) -> Bool {
        resolveMount(for: url) != nil
    }

    // MARK: - Adding & Removing Remote Mounts

    @discardableResult
    public func addMount(_ spec: RemoteMountSpec) async -> Bool {
        if let existingIdx = mounts.firstIndex(where: {
            $0.host == spec.host && $0.user == spec.user && $0.port == spec.port && $0.remotePath == spec.remotePath
        }) {
            let existing = mounts[existingIdx]
            return await syncMount(id: existing.id)
        }

        let dir = localMirrorDirectory(for: spec)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        mounts.append(spec)
        persistMounts()
        connectionStates[spec.id] = .syncing(detail: "Connecting to \(spec.host)…")

        return await syncMount(id: spec.id)
    }

    public func removeMount(id: UUID) {
        retryTasks[id]?.cancel()
        retryTasks.removeValue(forKey: id)
        retryCounts.removeValue(forKey: id)
        connectionStates.removeValue(forKey: id)
        pendingWriteQueue.removeAll(where: { $0.mountID == id })

        if let mount = mounts.first(where: { $0.id == id }) {
            let dir = localMirrorDirectory(for: mount)
            try? FileManager.default.removeItem(at: dir)
        }

        mounts.removeAll(where: { $0.id == id })
        persistMounts()
    }

    private func persistMounts() {
        if let encoded = try? JSONEncoder().encode(mounts) {
            userDefaults.set(encoded, forKey: mountsDefaultsKey)
        }
    }

    // MARK: - Background Polling & Auto-Reconnect

    public func startBackgroundSyncLoop(intervalSeconds: TimeInterval = 5.0) {
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                if let self = self {
                    await self.syncAllMounts()
                }
                try? await Task.sleep(nanoseconds: UInt64(max(0.2, intervalSeconds) * 1_000_000_000))
            }
        }
    }

    public func stopBackgroundSyncLoop() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    public func syncAllMounts(isBackground: Bool = true) async {
        for mount in mounts {
            _ = await syncMount(id: mount.id, isManualRetry: !isBackground, isBackground: isBackground)
        }
    }

    /// Synchronizes a single mount:
    /// 1. Flushes any queued local writes for this mount first so offline/optimistic saves are never overwritten.
    /// 2. Fetches the latest remote snapshot.
    /// 3. Updates local mirror files on disk and notifies the workspace view model.
    /// 4. If an error occurs, transitions into `.reconnecting` and schedules an automatic self-healing retry.
    @discardableResult
    public func syncMount(id: UUID, isManualRetry: Bool = false, isBackground: Bool = true) async -> Bool {
        guard let mount = mounts.first(where: { $0.id == id }) else { return false }

        if isManualRetry || !isBackground {
            retryTasks[id]?.cancel()
            retryTasks.removeValue(forKey: id)
            connectionStates[id] = .syncing(detail: "Reconnecting to \(mount.host)…")
        } else if connectionStates[id] == nil {
            connectionStates[id] = .syncing(detail: "Syncing \(mount.effectiveDisplayName)…")
        }

        do {
            // Step 1: Flush pending optimistic writes for this mount before pulling remote state
            try await flushPendingWrites(for: mount)

            // Step 2: Fetch remote snapshot
            let entries = try await transport.fetchSnapshot(for: mount)

            // Step 3: Reconcile local mirror directory
            let updatedURLs = reconcileLocalMirror(for: mount, with: entries)

            // Step 4: Clear any previous error/retry state — connection is healthy!
            retryTasks[id]?.cancel()
            retryTasks.removeValue(forKey: id)
            retryCounts[id] = 0
            connectionStates[id] = .connected

            onMirrorUpdated?(mount.id, updatedURLs)
            return true
        } catch {
            handleTransportFailure(for: mount, error: error)
            return false
        }
    }

    // MARK: - Optimistic Local Write + Background Push

    /// Writes `content` to the local mirror immediately (0 ms latency) and pushes it to the remote host.
    /// If the connection is currently offline or fails, the write is queued in `pendingWriteQueue` and
    /// pushed automatically as soon as connectivity recovers.
    public func saveRemoteFile(at url: URL, content: String) async {
        guard let resolved = resolveMount(for: url) else { return }
        let mount = resolved.mount
        var relativePath = resolved.relativePath
        if relativePath.isEmpty, mount.targetKind == .file {
            relativePath = (mount.remotePath as NSString).lastPathComponent
        }

        // 1. Ensure parent directories exist in local mirror and write immediately
        let parentDir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        try? content.write(to: url, atomically: true, encoding: .utf8)

        let stdURL = url.standardizedFileURL
        fileSyncStatuses[stdURL] = .syncing

        // 2. Enqueue or update pending write
        pendingWriteQueue.removeAll(where: { $0.localFileURL == stdURL })
        pendingWriteQueue.append(PendingRemoteWrite(
            mountID: mount.id,
            relativePath: relativePath,
            localFileURL: stdURL,
            queuedAt: Date()
        ))

        // 3. Attempt immediate push via transport
        do {
            let mtime = try await transport.pushFile(content: content, relativePath: relativePath, for: mount)
            try? FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: mtime)],
                ofItemAtPath: stdURL.path
            )
            let newHash = SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
            lastSyncedContentHashes[stdURL] = newHash
            pendingWriteQueue.removeAll(where: { $0.localFileURL == stdURL })
            fileSyncStatuses[stdURL] = .synced

            // Mark connection healthy if it was previously reconnecting
            retryTasks[mount.id]?.cancel()
            retryTasks.removeValue(forKey: mount.id)
            retryCounts[mount.id] = 0
            connectionStates[mount.id] = .connected
            onMirrorUpdated?(mount.id, [stdURL])
        } catch {
            fileSyncStatuses[stdURL] = .pendingUpload
            handleTransportFailure(for: mount, error: error)
        }
    }

    private func flushPendingWrites(for mount: RemoteMountSpec) async throws {
        let itemsForMount = pendingWriteQueue.filter { $0.mountID == mount.id }
        guard !itemsForMount.isEmpty else { return }

        for item in itemsForMount {
            guard let localContent = try? String(contentsOf: item.localFileURL, encoding: .utf8) else {
                pendingWriteQueue.removeAll(where: { $0.localFileURL == item.localFileURL })
                continue
            }
            fileSyncStatuses[item.localFileURL] = .syncing
            do {
                let mtime = try await transport.pushFile(
                    content: localContent,
                    relativePath: item.relativePath,
                    for: mount
                )
                try? FileManager.default.setAttributes(
                    [.modificationDate: Date(timeIntervalSince1970: mtime)],
                    ofItemAtPath: item.localFileURL.path
                )
                let newHash = SHA256.hash(data: Data(localContent.utf8)).map { String(format: "%02x", $0) }.joined()
                lastSyncedContentHashes[item.localFileURL] = newHash
                pendingWriteQueue.removeAll(where: { $0.localFileURL == item.localFileURL })
                fileSyncStatuses[item.localFileURL] = .synced
            } catch {
                fileSyncStatuses[item.localFileURL] = .pendingUpload
                throw error
            }
        }
    }

    // MARK: - Mirror Reconciliation

    private func reconcileLocalMirror(for mount: RemoteMountSpec, with entries: [RemoteFileEntry]) -> [URL] {
        let rootDir = localMirrorDirectory(for: mount).standardizedFileURL
        try? FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)

        var changedURLs: [URL] = []
        var validLocalURLs: Set<URL> = []
        let pendingURLs = Set(pendingWriteQueue.filter { $0.mountID == mount.id }.map { $0.localFileURL })

        for entry in entries {
            let fileURL = localFileURL(for: entry.relativePath, in: mount)
            validLocalURLs.insert(fileURL)

            // Do not overwrite a file that has an unpushed local write queued
            if pendingURLs.contains(fileURL) {
                continue
            }

            let existingDiskText = try? String(contentsOf: fileURL, encoding: .utf8)
            let remoteHash = entry.contentHash

            if existingDiskText != entry.content {
                let parentDir = fileURL.deletingLastPathComponent()
                try? FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
                try? entry.content.write(to: fileURL, atomically: true, encoding: .utf8)
                if entry.modificationTimestamp > 0 {
                    try? FileManager.default.setAttributes(
                        [.modificationDate: Date(timeIntervalSince1970: entry.modificationTimestamp)],
                        ofItemAtPath: fileURL.path
                    )
                }
                changedURLs.append(fileURL)
            }

            lastSyncedContentHashes[fileURL] = remoteHash
            fileSyncStatuses[fileURL] = .synced
        }

        // Prune deleted remote files from local mirror (unless they have a pending upload)
        if let enumerator = FileManager.default.enumerator(
            at: rootDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let fileURL as URL in enumerator {
                let stdURL = fileURL.standardizedFileURL
                let isDir = (try? stdURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if !isDir && !validLocalURLs.contains(stdURL) && !pendingURLs.contains(stdURL) {
                    try? FileManager.default.removeItem(at: stdURL)
                    lastSyncedContentHashes.removeValue(forKey: stdURL)
                    fileSyncStatuses.removeValue(forKey: stdURL)
                    changedURLs.append(stdURL)
                }
            }
        }

        return changedURLs
    }

    // MARK: - Self-Healing Error & Auto-Reconnect Handling

    private func handleTransportFailure(for mount: RemoteMountSpec, error: Error) {
        let attempt = (retryCounts[mount.id] ?? 0) + 1
        retryCounts[mount.id] = attempt

        let delay = min(15.0, retryBackoffBaseSeconds * pow(2.0, Double(min(attempt - 1, 4))))
        let nextRetry = Date().addingTimeInterval(delay)
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription

        connectionStates[mount.id] = .reconnecting(
            attempt: attempt,
            lastError: message,
            nextRetryAt: nextRetry
        )

        retryTasks[mount.id]?.cancel()
        retryTasks[mount.id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0.05, delay) * 1_000_000_000))
            guard !Task.isCancelled, let self = self else { return }
            _ = await self.syncMount(id: mount.id)
        }
    }

    // MARK: - Aggregate Status Helpers for UI Banner

    /// Returns a list of mounts currently experiencing connection issues.
    public var unhealthyMounts: [(mount: RemoteMountSpec, state: RemoteConnectionState)] {
        mounts.compactMap { mount in
            guard let state = connectionStates[mount.id], !state.isHealthy else { return nil }
            return (mount, state)
        }
    }

    /// Retry all unhealthy mounts immediately.
    public func retryUnhealthyMountsNow() async {
        for (mount, _) in unhealthyMounts {
            _ = await syncMount(id: mount.id, isManualRetry: true)
        }
    }

    public func retryAllUnhealthyMounts() {
        Task { @MainActor in
            await retryUnhealthyMountsNow()
        }
    }
}
