import AppKit
import Foundation

extension EditorWorkspaceViewModel {

    func performDiskWrite(_ content: String, to url: URL) {
        perfCounters.autosaveWriteCount += 1
        let span = EditorPerfPhase.autosaveWrite.begin()
        defer { span.end() }
        do {
            recentSelfWrites.record(content)
            lastSavedDiskContent = content
            let utf8Data = Data(content.utf8)
            if FileManager.default.fileExists(atPath: url.path) {
                try utf8Data.write(to: url)
            } else {
                try utf8Data.write(to: url, options: .atomic)
            }
            lastAutoSavedAt = Date()
            isDirty = false

            if currentFileURL?.standardizedFileURL == url.standardizedFileURL {
                if !selectionComments.isEmpty {
                    saveCompanionCommentsToDisk(for: url)
                }
                let newInode = Self.fileInode(for: url)
                if watchedFileInode == 0 || newInode != watchedFileInode {
                    watchFileDescriptorOnly(url)
                }
            }

            if remoteWorkspaceManager.isRemoteURL(url) {
                enqueueRemoteUpload(content, to: url)
            }
        } catch {
            NSSound.beep()
        }
    }
}
