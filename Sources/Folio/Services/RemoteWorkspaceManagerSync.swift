import CryptoKit
import Foundation
import SwiftUI

extension RemoteWorkspaceManager {
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

    func flushPendingWrites(for mount: RemoteMountSpec) async throws {
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

    func reconcileLocalMirror(for mount: RemoteMountSpec, with entries: [RemoteFileEntry]) -> [URL] {
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

    func handleTransportFailure(for mount: RemoteMountSpec, error: Error) {
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
