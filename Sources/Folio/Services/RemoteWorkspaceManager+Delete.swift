import Foundation

extension RemoteWorkspaceManager {
    /// Deletes a mirrored remote file on the host, then removes the local mirror and its sync state.
    public func deleteRemoteFile(at url: URL) async throws {
        guard let resolved = resolveMount(for: url) else { return }
        var relativePath = resolved.relativePath
        if relativePath.isEmpty, resolved.mount.targetKind == .file {
            relativePath = (resolved.mount.remotePath as NSString).lastPathComponent
        }
        let stdURL = url.standardizedFileURL
        pendingWriteQueue.removeAll(where: { $0.localFileURL == stdURL })
        try await transport.deleteFile(relativePath: relativePath, for: resolved.mount)
        try? FileManager.default.removeItem(at: stdURL)
        fileSyncStatuses.removeValue(forKey: stdURL)
        lastSyncedContentHashes.removeValue(forKey: stdURL)
    }
}
