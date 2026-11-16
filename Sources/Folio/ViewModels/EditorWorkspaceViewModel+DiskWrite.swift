import AppKit
import Foundation

extension EditorWorkspaceViewModel {

    func applyProgrammaticBufferState(
        _ newText: String,
        selectedRange: NSRange = NSRange(location: 0, length: 0),
        reconcileComments: Bool = true
    ) {
        let nsLen = (newText as NSString).length
        let clampedLoc = max(0, min(nsLen, selectedRange.location))
        let clampedLen = max(0, min(nsLen - clampedLoc, selectedRange.length))
        let clampedRange = NSRange(location: clampedLoc, length: clampedLen)
        let previousText = markdownText

        updateStatsWithoutRedundantPublish(for: newText, selectedRange: clampedRange)
        isApplyingInternalStateChange = true
        markdownText = newText
        currentSelectedRange = clampedRange
        if reconcileComments {
            reconcileSelectionComments(from: previousText, to: newText)
        }
        updateSelectionTooltipAnchor(for: clampedRange)
        if let tv = activeTextView {
            tv.applyProgrammaticDocumentText(newText, selectedRange: clampedRange)
        } else {
            let baseDir = currentFileURL?.deletingLastPathComponent() ?? workspaceFolderURL
            let analysis = MarkdownLiveStyler.applyStyles(
                to: NSTextStorage(string: newText),
                theme: theme,
                typography: typography,
                sourceCodeMode: sourceCodeMode,
                focusMode: focusMode,
                selectedRange: clampedRange,
                baseDirectoryURL: baseDir,
                fileURL: currentFileURL
            )
            headings = analysis.headings
        }
        isApplyingInternalStateChange = false
    }

    @discardableResult
    func performDiskWrite(_ content: String, to url: URL) -> Bool {
        perfCounters.autosaveWriteCount += 1
        let span = EditorPerfPhase.autosaveWrite.begin()
        defer { span.end() }
        do {
            let fm = FileManager.default
            if fm.fileExists(atPath: url.path), !fm.isWritableFile(atPath: url.path) {
                throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: url.path])
            }
            try Data(content.utf8).write(to: url, options: .atomic)
            recentSelfWrites.record(content)
            lastSavedDiskContent = content
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
            windowRegistry?.fileWasWritten(url, content: content, by: self)
            return true
        } catch {
            if currentFileURL?.standardizedFileURL == url.standardizedFileURL {
                isDirty = (markdownText != lastSavedDiskContent)
            }
            NSSound.beep()
            return false
        }
    }
}
