import AppKit
import Combine
import Foundation
import SwiftUI

extension EditorWorkspaceViewModel {

    // MARK: - Infinite Undo & Redo Engine

    func undoTimelineKey(for url: URL?) -> String {
        if let url {
            return url.standardizedFileURL.path
        }
        return "__UNTITLED_SCRATCHPAD__"
    }

    public var currentUndoStack: [DocumentUndoEntry] {
        perFileUndoTimelines[undoTimelineKey(for: currentFileURL)]?.undoStack ?? []
    }

    public var currentRedoStack: [DocumentUndoEntry] {
        perFileUndoTimelines[undoTimelineKey(for: currentFileURL)]?.redoStack ?? []
    }

    public var undoActionTitle: String {
        if let last = currentUndoStack.last {
            return "Undo \(last.summary)"
        }
        return "Undo"
    }

    public var redoActionTitle: String {
        if let last = currentRedoStack.last {
            return "Redo \(last.summary)"
        }
        return "Redo"
    }

    public func undoTimeline(for url: URL?) -> DocumentUndoTimeline {
        perFileUndoTimelines[undoTimelineKey(for: url)] ?? DocumentUndoTimeline()
    }

    func refreshUndoRedoAvailability() {
        let timeline = perFileUndoTimelines[undoTimelineKey(for: currentFileURL)] ?? DocumentUndoTimeline()
        if canUndo != timeline.canUndo {
            canUndo = timeline.canUndo
        }
        if canRedo != timeline.canRedo {
            canRedo = timeline.canRedo
        }
    }

    static let maxPersistedUndoEntriesPerFile = 100

    func persistUndoTimelines() {
        guard !isRestoringState else { return }
        var boundedTimelines: [String: DocumentUndoTimeline] = [:]
        boundedTimelines.reserveCapacity(perFileUndoTimelines.count)
        for (key, timeline) in perFileUndoTimelines {
            let undoSlice = timeline.undoStack.suffix(Self.maxPersistedUndoEntriesPerFile)
            let redoSlice = timeline.redoStack.suffix(Self.maxPersistedUndoEntriesPerFile)
            boundedTimelines[key] = DocumentUndoTimeline(
                undoStack: Array(undoSlice),
                redoStack: Array(redoSlice)
            )
        }
        if let encoded = try? JSONEncoder().encode(boundedTimelines) {
            userDefaults.set(encoded, forKey: Self.undoTimelinesDefaultsKey)
        }
    }

    public func breakUndoCoalescing() {
        canCoalesceLiveTyping = false
    }

    public func withUndoMetadata<T>(
        origin: UndoEntryOrigin,
        summary: String? = nil,
        _ block: () -> T
    ) -> T {
        breakUndoCoalescing()
        let prevOrigin = pendingEditOrigin
        let prevSummary = pendingEditSummary
        pendingEditOrigin = origin
        pendingEditSummary = summary ?? origin.rawValue
        defer {
            pendingEditOrigin = prevOrigin
            pendingEditSummary = prevSummary
            breakUndoCoalescing()
        }
        return block()
    }

    func recordUndoStep(
        from previousText: String,
        to newText: String,
        previousSelection: NSRange,
        newSelection: NSRange,
        origin: UndoEntryOrigin,
        summary: String? = nil,
        allowCoalescing: Bool = false
    ) {
        guard previousText != newText else { return }
        let key = undoTimelineKey(for: currentFileURL)
        var timeline = perFileUndoTimelines[key] ?? DocumentUndoTimeline()
        let now = Date()

        let prevNS = previousText as NSString
        let newNS = newText as NSString
        let deltaLen = newNS.length - prevNS.length
        let isSingleCharAlphanumeric: Bool = {
            guard deltaLen == 1,
                  previousSelection.length == 0,
                  newSelection.length == 0 else { return false }
            // Determine the UTF-16 index of the newly inserted character (either via cursor advance or diff prefix)
            var insertLoc = newSelection.location - 1
            if insertLoc < 0 || insertLoc >= newNS.length || newSelection.location != previousSelection.location + 1 {
                var prefix = 0
                let limit = prevNS.length
                while prefix < limit && prevNS.character(at: prefix) == newNS.character(at: prefix) {
                    prefix += 1
                }
                insertLoc = prefix
            }
            guard insertLoc >= 0 && insertLoc < newNS.length else { return false }
            let insertedStr = newNS.substring(with: NSRange(location: insertLoc, length: 1))
            guard let scalar = insertedStr.unicodeScalars.first, insertedStr.unicodeScalars.count == 1 else {
                return false
            }
            if CharacterSet.whitespacesAndNewlines.contains(scalar) || CharacterSet.punctuationCharacters.contains(scalar) {
                return false
            }
            return true
        }()

        if allowCoalescing,
           origin == .userTyping,
           isSingleCharAlphanumeric,
           var lastEntry = timeline.undoStack.last,
           lastEntry.origin == .userTyping,
           lastEntry.newText == previousText,
           lastEntry.newSelectedLocation == previousSelection.location,
           lastEntry.newSelectedLength == 0,
           now.timeIntervalSince(lastEntry.timestamp) < 0.65 {
            lastEntry.newText = newText
            lastEntry.newSelectedLocation = max(0, newSelection.location)
            lastEntry.newSelectedLength = max(0, newSelection.length)
            lastEntry.timestamp = now
            timeline.undoStack[timeline.undoStack.count - 1] = lastEntry
            timeline.redoStack.removeAll()
        } else {
            let entry = DocumentUndoEntry(
                previousText: previousText,
                newText: newText,
                previousSelectedRange: previousSelection,
                newSelectedRange: newSelection,
                timestamp: now,
                origin: origin,
                summary: summary
            )
            timeline.undoStack.append(entry)
            timeline.redoStack.removeAll()
            canCoalesceLiveTyping = (origin == .userTyping && isSingleCharAlphanumeric)
        }

        perFileUndoTimelines[key] = timeline
        refreshUndoRedoAvailability()
        persistUndoTimelines()
    }

    func updateTopUndoNewSelection(_ selection: NSRange) {
        let key = undoTimelineKey(for: currentFileURL)
        guard var timeline = perFileUndoTimelines[key],
              !timeline.undoStack.isEmpty else { return }
        var last = timeline.undoStack[timeline.undoStack.count - 1]
        if last.newText == markdownText {
            last.newSelectedLocation = max(0, selection.location)
            last.newSelectedLength = max(0, selection.length)
            timeline.undoStack[timeline.undoStack.count - 1] = last
            perFileUndoTimelines[key] = timeline
            persistUndoTimelines()
        }
    }

    public func undo() {
        let key = undoTimelineKey(for: currentFileURL)
        guard var timeline = perFileUndoTimelines[key],
              let entry = timeline.undoStack.popLast() else { return }
        timeline.redoStack.append(entry)
        perFileUndoTimelines[key] = timeline
        canCoalesceLiveTyping = false

        applyHistoricalTextState(
            entry.previousText,
            selectedRange: entry.previousSelectedRange
        )
        refreshUndoRedoAvailability()
        persistUndoTimelines()
    }

    public func redo() {
        let key = undoTimelineKey(for: currentFileURL)
        guard var timeline = perFileUndoTimelines[key],
              let entry = timeline.redoStack.popLast() else { return }
        timeline.undoStack.append(entry)
        perFileUndoTimelines[key] = timeline
        canCoalesceLiveTyping = false

        applyHistoricalTextState(
            entry.newText,
            selectedRange: entry.newSelectedRange
        )
        refreshUndoRedoAvailability()
        persistUndoTimelines()
    }

    func applyHistoricalTextState(_ targetText: String, selectedRange: NSRange) {
        let clampedLoc = max(0, min((targetText as NSString).length, selectedRange.location))
        let clampedLen = max(0, min((targetText as NSString).length - clampedLoc, selectedRange.length))
        let clampedRange = NSRange(location: clampedLoc, length: clampedLen)

        isApplyingInternalStateChange = true
        markdownText = targetText
        currentSelectedRange = clampedRange
        userDefaults.set(clampedRange.location, forKey: Self.selectedCursorLocationDefaultsKey)
        stats = DocumentStats.compute(for: targetText, selectedRange: clampedRange)

        if let tv = activeTextView {
            tv.applyProgrammaticDocumentText(targetText, selectedRange: clampedRange)
        } else {
            let analysis = MarkdownLiveStyler.applyStyles(
                to: NSTextStorage(string: targetText),
                theme: theme,
                typography: typography,
                sourceCodeMode: sourceCodeMode,
                focusMode: focusMode,
                selectedRange: clampedRange
            )
            headings = analysis.headings
        }

        if let url = currentFileURL, autoSaveEnabled, activeConflict == nil {
            performDiskWrite(targetText, to: url)
            isDirty = false
        } else if currentFileURL == nil {
            isDirty = !autoSaveEnabled
        } else {
            isDirty = (targetText != lastSavedDiskContent)
        }
        isApplyingInternalStateChange = false
        persistDocumentSessionState()
    }
}
