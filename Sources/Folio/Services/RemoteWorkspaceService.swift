import CryptoKit
import Foundation
import SwiftUI

// MARK: - Remote Workspace Sync Engine & Local Mirror Manager

public struct PendingRemoteWrite: Codable, Equatable, Sendable {
    public let mountID: UUID
    public let relativePath: String
    public let localFileURL: URL
    public let queuedAt: Date
}

@MainActor
public final class RemoteWorkspaceManager: ObservableObject {
    @Published public var mounts: [RemoteMountSpec] = []
    @Published public var connectionStates: [UUID: RemoteConnectionState] = [:]
    @Published public var fileSyncStatuses: [URL: RemoteFileSyncStatus] = [:]
    @Published public var pendingWriteQueue: [PendingRemoteWrite] = []

    /// Observers called when a remote mount's mirror directory or file content changes.
    /// Each open document window registers one, so every tab can refresh its tree and buffer.
    private var mirrorUpdateObservers: [ObjectIdentifier: (owner: WeakOwner, handler: (UUID, [URL]) -> Void)] = [:]

    struct WeakOwner { weak var object: AnyObject? }

    /// Registers `handler` for mirror updates until `owner` is deallocated.
    public func observeMirrorUpdates(owner: AnyObject, _ handler: @escaping (UUID, [URL]) -> Void) {
        mirrorUpdateObservers[ObjectIdentifier(owner)] = (WeakOwner(object: owner), handler)
    }

    func notifyMirrorUpdated(_ mountID: UUID, _ urls: [URL]) {
        mirrorUpdateObservers = mirrorUpdateObservers.filter { $0.value.owner.object != nil }
        for observer in mirrorUpdateObservers.values {
            observer.handler(mountID, urls)
        }
    }

    public let mirrorRootURL: URL
    public var transport: RemoteFileTransport

    /// Tracks the last-known remote SHA-256 hash per mirrored local file URL so we can distinguish
    /// remote changes from local dirty edits.
    var lastSyncedContentHashes: [URL: String] = [:]
    var retryCounts: [UUID: Int] = [:]
    nonisolated(unsafe) var retryTasks: [UUID: Task<Void, Never>] = [:]
    nonisolated(unsafe) var pollingTask: Task<Void, Never>?

    let mountsDefaultsKey: String
    public let userDefaults: UserDefaults

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

    func persistMounts() {
        if let encoded = try? JSONEncoder().encode(mounts) {
            userDefaults.set(encoded, forKey: mountsDefaultsKey)
        }
    }
}
