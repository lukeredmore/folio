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
