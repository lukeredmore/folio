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
        let currentMounts = mounts
        let manager = self
        await withTaskGroup(of: Void.self) { group in
            for mount in currentMounts {
                let mountID = mount.id
                group.addTask {
                    _ = await manager.syncMount(
                        id: mountID,
                        isManualRetry: !isBackground,
                        isBackground: isBackground
                    )
                }
            }
        }
    }

    /// Synchronizes a single mount:
    /// 1. Flushes any queued local writes for this mount first so offline/optimistic saves are never overwritten.
    /// 2. Lists each loaded directory of a folder mount, or fetches the target of a file mount.
    /// 3. Downloads changed files into the local mirror and notifies the workspace view model.
    /// 4. If an error occurs, transitions into `.reconnecting` and schedules an automatic self-healing retry.
    @discardableResult
    public func syncMount(id: UUID, isManualRetry: Bool = false, isBackground: Bool = true) async -> Bool {
        guard let mount = mounts.first(where: { $0.id == id }) else { return false }

        if let inFlight = inFlightMountSyncs[id] {
            return await inFlight.task.value
        }

        if isManualRetry || !isBackground {
            retryTasks[id]?.cancel()
            retryTasks.removeValue(forKey: id)
            connectionStates[id] = .syncing(detail: "Reconnecting to \(mount.host)…")
        } else if connectionStates[id] == nil {
            connectionStates[id] = .syncing(detail: "Syncing \(mount.effectiveDisplayName)…")
        }

        let syncToken = UUID()
        let task = Task { @MainActor [weak self] () -> Bool in
            guard let self else { return false }
            defer {
                if self.inFlightMountSyncs[id]?.token == syncToken {
                    self.inFlightMountSyncs.removeValue(forKey: id)
                }
            }
            guard let currentMount = self.mounts.first(where: { $0.id == id }) else { return false }
            do {
                try await self.flushPendingWrites(for: currentMount)

                let updatedURLs: [URL]
                switch currentMount.targetKind {
                case .folder:
                    updatedURLs = try await self.refreshFolderMount(
                        currentMount,
                        directories: self.loadedDirectories(for: currentMount.id),
                        refreshAllProbes: isManualRetry || !isBackground
                    )
                case .file:
                    updatedURLs = try await self.refreshFileMount(currentMount)
                }

                guard !Task.isCancelled, self.mounts.contains(where: { $0.id == id }) else { return false }

                self.retryTasks[id]?.cancel()
                self.retryTasks.removeValue(forKey: id)
                self.retryCounts[id] = 0
                self.connectionStates[id] = .connected

                self.notifyMirrorUpdated(currentMount.id, updatedURLs)
                return true
            } catch {
                guard !Task.isCancelled, self.mounts.contains(where: { $0.id == id }) else { return false }
                self.handleTransportFailure(for: currentMount, error: error)
                return false
            }
        }
        inFlightMountSyncs[id] = (syncToken, task)
        return await task.value
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

        let stdURL = url.standardizedFileURL
        nextPendingWriteRevision &+= 1
        let writeRevision = nextPendingWriteRevision
        latestWriteRevisions[stdURL] = writeRevision

        let parentDir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        try? content.write(to: url, atomically: true, encoding: .utf8)

        fileSyncStatuses[stdURL] = .syncing

        pendingWriteQueue.removeAll(where: { $0.localFileURL == stdURL && $0.revision < writeRevision })
        pendingWriteQueue.append(
            PendingRemoteWrite(
                mountID: mount.id,
                relativePath: relativePath,
                localFileURL: stdURL,
                queuedAt: Date(),
                revision: writeRevision
            ))

        do {
            let mtime = try await transport.pushFile(content: content, relativePath: relativePath, for: mount)
            let newHash = SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
            pendingWriteQueue.removeAll(where: { $0.localFileURL == stdURL && $0.revision <= writeRevision })

            let hasNewerRevision =
                (latestWriteRevisions[stdURL] ?? writeRevision) > writeRevision
                || pendingWriteQueue.contains(where: { $0.localFileURL == stdURL })
            if !hasNewerRevision {
                try? FileManager.default.setAttributes(
                    [.modificationDate: Date(timeIntervalSince1970: mtime)],
                    ofItemAtPath: stdURL.path
                )
                lastSyncedContentHashes[stdURL] = newHash
                fileSyncStatuses[stdURL] = .synced
            }

            retryTasks[mount.id]?.cancel()
            retryTasks.removeValue(forKey: mount.id)
            retryCounts[mount.id] = 0
            connectionStates[mount.id] = .connected
            notifyMirrorUpdated(mount.id, [stdURL])
        } catch {
            if pendingWriteQueue.contains(where: { $0.localFileURL == stdURL }) {
                fileSyncStatuses[stdURL] = .pendingUpload
            }
            handleTransportFailure(for: mount, error: error)
        }
    }

    func flushPendingWrites(for mount: RemoteMountSpec) async throws {
        let itemsForMount = pendingWriteQueue.filter { $0.mountID == mount.id }
        guard !itemsForMount.isEmpty else { return }

        for item in itemsForMount {
            guard pendingWriteQueue.contains(where: { $0.localFileURL == item.localFileURL && $0.revision >= item.revision }) else {
                continue
            }
            let snapshotRevision = max(item.revision, latestWriteRevisions[item.localFileURL] ?? item.revision)
            guard let localContent = try? String(contentsOf: item.localFileURL, encoding: .utf8) else {
                pendingWriteQueue.removeAll(where: { $0.localFileURL == item.localFileURL && $0.revision <= snapshotRevision })
                continue
            }
            fileSyncStatuses[item.localFileURL] = .syncing
            do {
                let mtime = try await transport.pushFile(
                    content: localContent,
                    relativePath: item.relativePath,
                    for: mount
                )
                let newHash = SHA256.hash(data: Data(localContent.utf8)).map { String(format: "%02x", $0) }.joined()
                pendingWriteQueue.removeAll(where: { $0.localFileURL == item.localFileURL && $0.revision <= snapshotRevision })

                let hasNewerRevision =
                    (latestWriteRevisions[item.localFileURL] ?? snapshotRevision) > snapshotRevision
                    || pendingWriteQueue.contains(where: { $0.localFileURL == item.localFileURL })
                if !hasNewerRevision {
                    try? FileManager.default.setAttributes(
                        [.modificationDate: Date(timeIntervalSince1970: mtime)],
                        ofItemAtPath: item.localFileURL.path
                    )
                    lastSyncedContentHashes[item.localFileURL] = newHash
                    fileSyncStatuses[item.localFileURL] = .synced
                }
            } catch {
                if pendingWriteQueue.contains(where: { $0.localFileURL == item.localFileURL }) {
                    fileSyncStatuses[item.localFileURL] = .pendingUpload
                }
                throw error
            }
        }
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
