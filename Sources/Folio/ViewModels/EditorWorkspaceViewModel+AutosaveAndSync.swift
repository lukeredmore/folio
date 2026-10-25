import AppKit
import Combine
import Foundation
import SwiftUI

extension EditorWorkspaceViewModel {

    // MARK: - Autosave, External Updates & Conflict Resolution

    func autoSaveOrStageCurrentDocument() {
        if let url = currentFileURL {
            if autoSaveEnabled && activeConflict == nil {
                // Before overwriting disk, verify whether an external process modified the file since our last save
                if let currentDiskText = try? String(contentsOf: url, encoding: .utf8),
                   currentDiskText != lastSavedDiskContent,
                   !recentSelfWrites.contains(currentDiskText) {
                    let mergeResult = ThreeWayDocumentMerger.merge(
                        base: lastSavedDiskContent,
                        local: markdownText,
                        external: currentDiskText,
                        fileURL: url,
                        sourceDescription: remoteWorkspaceManager.isRemoteURL(url) ? "SSH Remote" : "Disk"
                    )
                    switch mergeResult {
                    case .clean(let mergedText, let wasAutoMerged):
                        if mergedText != markdownText {
                            let localBeforeMerge = markdownText
                            let diff = DocumentLineDiff.computeDiff(from: localBeforeMerge, to: mergedText)
                            let adjustedSel = DocumentLineDiff.adjustedSelection(
                                for: currentSelectedRange,
                                inOldText: localBeforeMerge,
                                toNewText: mergedText
                            )
                            recordUndoStep(
                                from: localBeforeMerge,
                                to: mergedText,
                                previousSelection: currentSelectedRange,
                                newSelection: adjustedSel,
                                origin: .externalUpdate,
                                summary: wasAutoMerged ? "Auto-merged external changes" : "External file update",
                                allowCoalescing: false
                            )
                            isApplyingInternalStateChange = true
                            markdownText = mergedText
                            currentSelectedRange = adjustedSel
                            if let tv = activeTextView {
                                tv.applyProgrammaticDocumentText(mergedText, selectedRange: adjustedSel)
                            }
                            isApplyingInternalStateChange = false
                            publishExternalUpdateVisualNotice(
                                fileURL: url,
                                previousText: localBeforeMerge,
                                updatedText: mergedText,
                                diff: diff,
                                wasAutoMerged: wasAutoMerged,
                                sourceDescription: remoteWorkspaceManager.isRemoteURL(url) ? "SSH Remote" : "Disk"
                            )
                        }
                        performDiskWrite(mergedText, to: url)
                        isDirty = false
                    case .conflict(let conflict):
                        activeConflict = conflict
                        isDirty = true
                    }
                    persistDocumentSessionState()
                    return
                }

                performDiskWrite(markdownText, to: url)
                isDirty = false
            } else {
                isDirty = (markdownText != lastSavedDiskContent)
            }
        } else {
            isDirty = !autoSaveEnabled
        }
        persistDocumentSessionState()
    }

    func performDiskWrite(_ content: String, to url: URL) {
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

    func flushPendingAutoSaveBeforeSwitchingFile() {
        flushPendingAutoSave()
        guard let url = currentFileURL,
              activeConflict == nil,
              autoSaveEnabled,
              markdownText != lastSavedDiskContent else { return }
        performDiskWrite(markdownText, to: url)
    }

    /// Checks whether the currently open file on disk has been modified by an external process,
    /// and either auto-updates, 3-way auto-merges, or triggers conflict resolution.
    public func checkForExternalFileChanges(for targetURL: URL? = nil, sourceDescription: String? = nil) {
        guard let currentURL = targetURL ?? currentFileURL else { return }
        guard currentFileURL?.standardizedFileURL == currentURL.standardizedFileURL else { return }
        guard let diskContent = try? String(contentsOf: currentURL, encoding: .utf8) else { return }

        let currentInode = Self.fileInode(for: currentURL)
        if currentInode != 0 && currentInode != watchedFileInode {
            watchFileDescriptorOnly(currentURL)
        }

        // Ignore self-writes when no conflict is active and disk matches our buffer
        if activeConflict == nil,
           diskContent == markdownText,
           (diskContent == lastSavedDiskContent || recentSelfWrites.contains(diskContent)) {
            lastSavedDiskContent = diskContent
            return
        }

        // Also ignore asynchronous watcher echo from an older self-write that we already superseded
        if activeConflict == nil,
           diskContent != markdownText,
           recentSelfWrites.contains(diskContent),
           markdownText == lastSavedDiskContent {
            return
        }

        let effectiveSource = sourceDescription ?? (remoteWorkspaceManager.isRemoteURL(currentURL) ? "SSH Remote" : "Disk")
        handleExternalFileUpdate(diskContent: diskContent, for: currentURL, sourceDescription: effectiveSource)
    }

    public func handleExternalFileUpdate(
        diskContent: String,
        for url: URL,
        sourceDescription: String = "Disk"
    ) {
        guard currentFileURL?.standardizedFileURL == url.standardizedFileURL else { return }

        let baseText = lastSavedDiskContent
        let localText = markdownText

        let mergeResult = ThreeWayDocumentMerger.merge(
            base: baseText,
            local: localText,
            external: diskContent,
            fileURL: url,
            sourceDescription: sourceDescription
        )

        switch mergeResult {
        case .clean(let mergedText, let wasAutoMerged):
            activeConflict = nil
            showConflictResolverModal = false

            if mergedText != localText {
                let diff = DocumentLineDiff.computeDiff(from: localText, to: mergedText)
                let adjustedSel = DocumentLineDiff.adjustedSelection(
                    for: currentSelectedRange,
                    inOldText: localText,
                    toNewText: mergedText
                )

                recordUndoStep(
                    from: localText,
                    to: mergedText,
                    previousSelection: currentSelectedRange,
                    newSelection: adjustedSel,
                    origin: .externalUpdate,
                    summary: wasAutoMerged ? "Auto-merged external changes" : "External file update",
                    allowCoalescing: false
                )

                isApplyingInternalStateChange = true
                markdownText = mergedText
                currentSelectedRange = adjustedSel
                stats = DocumentStats.compute(for: mergedText, selectedRange: adjustedSel)
                if let tv = activeTextView {
                    tv.applyProgrammaticDocumentText(mergedText, selectedRange: adjustedSel)
                } else {
                    let analysis = MarkdownLiveStyler.applyStyles(
                        to: NSTextStorage(string: mergedText),
                        theme: theme,
                        typography: typography,
                        sourceCodeMode: sourceCodeMode,
                        focusMode: focusMode,
                        selectedRange: adjustedSel
                    )
                    headings = analysis.headings
                }
                isApplyingInternalStateChange = false

                publishExternalUpdateVisualNotice(
                    fileURL: url,
                    previousText: localText,
                    updatedText: mergedText,
                    diff: diff,
                    wasAutoMerged: wasAutoMerged,
                    sourceDescription: sourceDescription
                )
            }

            lastSavedDiskContent = mergedText
            isDirty = false
            if wasAutoMerged && mergedText != diskContent {
                performDiskWrite(mergedText, to: url)
            }
            persistDocumentSessionState()

        case .conflict(let conflict):
            activeConflict = conflict
            isDirty = true
            persistDocumentSessionState()
        }
    }

    func publishExternalUpdateVisualNotice(
        fileURL: URL,
        previousText: String,
        updatedText: String,
        diff: DocumentLineDiffResult,
        wasAutoMerged: Bool,
        sourceDescription: String
    ) {
        externalUpdateNotice = ExternalUpdateNotice(
            fileURL: fileURL,
            previousText: previousText,
            updatedText: updatedText,
            addedLinesCount: diff.addedLinesCount,
            removedLinesCount: diff.removedLinesCount,
            changedLineNumbers: diff.changedLineNumbers,
            changedCharacterRanges: diff.changedCharacterRanges,
            diffHunks: diff.hunks,
            wasAutoMerged: wasAutoMerged,
            sourceDescription: sourceDescription
        )
        externalUpdateHighlightRanges = diff.changedCharacterRanges

        externalHighlightClearTask?.cancel()
        externalHighlightClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled, let self = self else { return }
            self.externalUpdateHighlightRanges = []
        }
    }

    public func dismissExternalUpdateNotice() {
        externalHighlightClearTask?.cancel()
        externalUpdateNotice = nil
        externalUpdateHighlightRanges = []
        showExternalUpdateDiffModal = false
    }

    public func resolveConflict(using strategy: ConflictResolutionStrategy) {
        guard let conflict = activeConflict else { return }
        let resolved = conflict.resolvedText(using: strategy)
        applyResolvedConflictText(
            resolved,
            for: conflict,
            summary: "Resolved conflict (\(strategy.rawValue))"
        )
    }

    public func setConflictHunkResolution(_ strategy: ConflictResolutionStrategy, forHunkID hunkID: UUID) {
        activeConflict?.setResolution(strategy, forHunkID: hunkID)
    }

    public func applyInteractiveConflictResolution() {
        guard let conflict = activeConflict else { return }
        let resolved = conflict.resolvedText(using: nil)
        applyResolvedConflictText(
            resolved,
            for: conflict,
            summary: "Resolved conflict (Custom Merge)"
        )
    }

    func applyResolvedConflictText(
        _ resolved: String,
        for conflict: DocumentConflict,
        summary: String
    ) {
        let previousLocal = markdownText
        let baselineForUndo = (previousLocal != resolved) ? previousLocal : conflict.externalText
        let adjustedSel = DocumentLineDiff.adjustedSelection(
            for: currentSelectedRange,
            inOldText: previousLocal,
            toNewText: resolved
        )

        recordUndoStep(
            from: baselineForUndo,
            to: resolved,
            previousSelection: currentSelectedRange,
            newSelection: adjustedSel,
            origin: .conflictResolution,
            summary: summary,
            allowCoalescing: false
        )

        activeConflict = nil
        showConflictResolverModal = false

        isApplyingInternalStateChange = true
        markdownText = resolved
        currentSelectedRange = adjustedSel
        isDirty = false
        stats = DocumentStats.compute(for: resolved, selectedRange: adjustedSel)
        if let tv = activeTextView {
            tv.applyProgrammaticDocumentText(resolved, selectedRange: adjustedSel)
        } else {
            let analysis = MarkdownLiveStyler.applyStyles(
                to: NSTextStorage(string: resolved),
                theme: theme,
                typography: typography,
                sourceCodeMode: sourceCodeMode,
                focusMode: focusMode,
                selectedRange: adjustedSel
            )
            headings = analysis.headings
        }
        isApplyingInternalStateChange = false

        performDiskWrite(resolved, to: conflict.fileURL)
        let diff = DocumentLineDiff.computeDiff(from: baselineForUndo, to: resolved)
        externalUpdateHighlightRanges = diff.changedCharacterRanges
        persistDocumentSessionState()
    }
}
