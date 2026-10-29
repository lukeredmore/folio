import AppKit
import Foundation

enum LaTeXBlockStyleCache {

    static let styledPassAttributeKey = NSAttributedString.Key("FolioLaTeXStyledPass")
    static let sourceModePassAttributeKey = NSAttributedString.Key("FolioSourceCodeModePass")

    /// The inputs of a styling pass besides the text, the selection, and the document facts.
    /// A session is reused only for an equal config.
    struct StyleConfig: Equatable {
        let parameters: MarkdownStyleParameters
        let documentStyle: LaTeXDocumentStyle
    }

    struct CachedBlock {
        let range: NSRange
        let startLineNumber: Int
        let lineCount: Int
        let isActive: Bool
        let dimFactor: CGFloat
        let headings: [OutlineHeading]
        var decorations: [LineDecoration]
        /// The text that styling the block read, which can extend past `range`: a probe for a
        /// multi-line call reads ahead, and a blank block checks its neighbors.
        var context: NSRange?
        /// The group and font state before and after the block.
        var entryFlow = LaTeXFlowState()
        var exitFlow = LaTeXFlowState()

        var contextRange: NSRange { context.map { NSUnionRange($0, range) } ?? range }
    }

    struct StorageEntry {
        weak var storage: NSTextStorage?
        let config: StyleConfig
        let string: String
        let nsString: NSString
        let docMacros: [String: LaTeXMacroDefinition]
        let facts: DocumentFacts
        let blocksByStart: [Int: CachedBlock]
    }

    struct DiffWindow {
        let isSameString: Bool
        let commonPrefixLen: Int
        let suffixStartInNew: Int
        let charDelta: Int

        /// Where a location in the old text is in the new text, or nil inside the changed text.
        func newLocation(ofOld location: Int) -> Int? {
            if isSameString || location < commonPrefixLen { return location }
            return location >= suffixStartInNew - charDelta ? location + charDelta : nil
        }
    }

    /// The last session of each recently styled storage, so styling another storage, such as a
    /// print or reference copy, does not discard the editor's session.
    nonisolated(unsafe) private static var entries: [ObjectIdentifier: StorageEntry] = [:]
    private static let maxEntries = 4
    nonisolated(unsafe) static var activeBaseAttributes: [NSAttributedString.Key: Any] = [:]
    nonisolated(unsafe) static var pendingGlyphInvalidationRanges: [NSRange] = []
    /// Text read while styling the current block, beyond the block itself. See
    /// `CachedBlock.context`.
    nonisolated(unsafe) static var currentBlockContext: NSRange?

    /// Records that styling the current block read `range`.
    static func noteContext(_ range: NSRange) {
        currentBlockContext = currentBlockContext.map { NSUnionRange($0, range) } ?? range
    }

    static func invalidate() {
        entries.removeAll()
    }

    static func collapseInternalNewlines(in storage: NSTextStorage, nsString: NSString, range: NSRange) {
        let end = min(NSMaxRange(range), nsString.length) - 1
        guard range.location < end else { return }
        var idx = range.location
        while idx < end {
            if nsString.character(at: idx) == 0x0A {
                let nlRange = NSRange(location: idx, length: 1)
                storage.addAttributes(
                    [
                        MarkdownLiveStyler.softLineBreakAttributeKey: true,
                        MarkdownLiveStyler.collapsedTokenAttributeKey: true
                    ], range: nlRange)
            }
            idx += 1
        }
    }

    static func invalidateLayoutManagers(for storage: NSTextStorage, fullRange: NSRange) {
        guard fullRange.length > 0 else { return }
        for lm in storage.layoutManagers {
            lm.invalidateGlyphs(forCharacterRange: fullRange, changeInLength: 0, actualCharacterRange: nil)
            lm.invalidateLayout(forCharacterRange: fullRange, actualCharacterRange: nil)
        }
    }

    static func resetAttributes(in storage: NSTextStorage, range: NSRange) {
        guard range.length > 0, NSMaxRange(range) <= storage.length else { return }
        storage.setAttributes(activeBaseAttributes, range: range)
    }

    static func prepareIncrementalSession(
        for storage: NSTextStorage,
        config: StyleConfig,
        string: String,
        nsString: NSString,
        docIndex: LaTeXDocumentIndex,
        docMacros: [String: LaTeXMacroDefinition]
    ) -> (entry: StorageEntry, diff: DiffWindow)? {
        guard let entry = entries[ObjectIdentifier(storage)],
            entry.storage === storage,
            entry.config == config,
            entry.docMacros == docMacros
        else {
            return nil
        }

        if entry.string == string {
            let diff = DiffWindow(isSameString: true, commonPrefixLen: nsString.length, suffixStartInNew: 0, charDelta: 0)
            return entry.facts == DocumentFacts(docIndex) ? (entry, diff) : nil
        }

        let prevNS = entry.nsString
        let prevLen = prevNS.length
        let newLen = nsString.length
        let minLen = min(prevLen, newLen)

        var prefix = 0
        while prefix < minLen && prevNS.character(at: prefix) == nsString.character(at: prefix) {
            prefix += 1
        }

        var suffix = 0
        let maxSuffix = minLen - prefix
        while suffix < maxSuffix && prevNS.character(at: prevLen - 1 - suffix) == nsString.character(at: newLen - 1 - suffix) {
            suffix += 1
        }

        let diff = DiffWindow(isSameString: false, commonPrefixLen: prefix, suffixStartInNew: newLen - suffix, charDelta: newLen - prevLen)
        // A block reads labels, numbers, and citations from anywhere in the document.
        return entry.facts.moved(by: diff) == DocumentFacts(docIndex) ? (entry, diff) : nil
    }

    static func saveSession(
        for storage: NSTextStorage,
        config: StyleConfig,
        string: String,
        nsString: NSString,
        docIndex: LaTeXDocumentIndex,
        docMacros: [String: LaTeXMacroDefinition],
        blocks: [CachedBlock]
    ) {
        var map: [Int: CachedBlock] = [:]
        map.reserveCapacity(blocks.count)
        for b in blocks {
            map[b.range.location] = b
        }
        entries = entries.filter { $0.value.storage != nil }
        if entries.count >= maxEntries && entries[ObjectIdentifier(storage)] == nil {
            entries.removeAll()
        }
        entries[ObjectIdentifier(storage)] = StorageEntry(
            storage: storage,
            config: config,
            string: string,
            nsString: nsString,
            docMacros: docMacros,
            facts: DocumentFacts(docIndex),
            blocksByStart: map
        )
    }

    static func isBlockActive(range: NSRange, activeLineRange: NSRange, selectedRange: NSRange) -> Bool {
        if NSIntersectionRange(range, activeLineRange).length > 0 { return true }
        if selectedRange.length > 0, NSIntersectionRange(range, selectedRange).length > 0 { return true }
        // The active line decides, as the editor restyles only when it changes: a cursor at the
        // start of the line after a block does not activate the block.
        if selectedRange.location >= range.location && selectedRange.location <= NSMaxRange(range)
            && activeLineRange.location >= range.location && activeLineRange.location < NSMaxRange(range)
        {
            return true
        }
        return false
    }

    static func tryReuseBlock(
        at charIndex: Int,
        lineNumber: Int,
        in storage: NSTextStorage,
        fullLength: Int,
        activeLineRange: NSRange,
        selectedRange: NSRange,
        focusMode: Bool,
        session: (entry: StorageEntry, diff: DiffWindow)?,
        flow: inout LaTeXFlowState,
        headings: inout [OutlineHeading],
        decorations: inout [LineDecoration],
        recordedBlocks: inout [CachedBlock]
    ) -> (nextIndex: Int, lineDelta: Int)? {
        guard let (entry, diff) = session else { return nil }

        if diff.isSameString || charIndex < diff.commonPrefixLen {
            // The text before the block is unchanged; its entry flow state must match too.
            guard let prev = entry.blocksByStart[charIndex], prev.entryFlow == flow else { return nil }
            if !diff.isSameString && NSMaxRange(prev.contextRange) >= diff.commonPrefixLen {
                return nil
            }
            guard !prev.isActive else { return nil }
            let nowActive = isBlockActive(range: prev.range, activeLineRange: activeLineRange, selectedRange: selectedRange)
            guard !nowActive else { return nil }
            let newDim: CGFloat = focusMode ? 0.30 : 1.0
            guard prev.dimFactor == newDim, hasStyledMarker(in: storage, range: prev.range) else { return nil }

            var kept = prev
            // A reference before the edit can point at a label after it.
            kept.decorations = prev.decorations.map { shiftReferenceTarget($0, diff: diff) }
            headings.append(contentsOf: kept.headings)
            decorations.append(contentsOf: kept.decorations)
            recordedBlocks.append(kept)
            flow = prev.exitFlow
            EditorPerfScope.recorder?.increment(.latexBlockReused)
            return (NSMaxRange(prev.range), prev.lineCount)
        }

        if charIndex > diff.suffixStartInNew {
            let oldStart = charIndex - diff.charDelta
            guard let prev = entry.blocksByStart[oldStart], !prev.isActive, prev.entryFlow == flow,
                prev.contextRange.location + diff.charDelta > diff.suffixStartInNew
            else { return nil }
            let shiftedRange = NSRange(location: charIndex, length: prev.range.length)
            guard NSMaxRange(shiftedRange) <= fullLength else { return nil }
            let nowActive = isBlockActive(range: shiftedRange, activeLineRange: activeLineRange, selectedRange: selectedRange)
            guard !nowActive else { return nil }
            let newDim: CGFloat = focusMode ? 0.30 : 1.0
            guard prev.dimFactor == newDim, hasStyledMarker(in: storage, range: shiftedRange) else { return nil }

            let lineDelta = lineNumber - prev.startLineNumber
            let shiftedHeadings = prev.headings.map { h in
                OutlineHeading(
                    level: h.level,
                    title: h.title,
                    characterLocation: h.characterLocation + diff.charDelta,
                    lineNumber: h.lineNumber + lineDelta
                )
            }
            let shiftedDecorations = prev.decorations.map { dec in
                shiftDecoration(dec, by: diff.charDelta, editLocation: diff.commonPrefixLen)
            }
            let shiftedBlock = CachedBlock(
                range: shiftedRange,
                startLineNumber: lineNumber,
                lineCount: prev.lineCount,
                isActive: false,
                dimFactor: newDim,
                headings: shiftedHeadings,
                decorations: shiftedDecorations,
                context: prev.context.map { shiftRange($0, by: diff.charDelta) },
                entryFlow: prev.entryFlow,
                exitFlow: prev.exitFlow
            )
            headings.append(contentsOf: shiftedHeadings)
            decorations.append(contentsOf: shiftedDecorations)
            recordedBlocks.append(shiftedBlock)
            flow = prev.exitFlow
            EditorPerfScope.recorder?.increment(.latexBlockReused)
            return (NSMaxRange(shiftedRange), prev.lineCount)
        }

        return nil
    }

    private static func hasStyledMarker(in storage: NSTextStorage, range: NSRange) -> Bool {
        guard range.length > 0, NSMaxRange(range) <= storage.length else { return false }
        guard storage.attribute(styledPassAttributeKey, at: range.location, effectiveRange: nil) != nil else {
            return false
        }
        return storage.attribute(sourceModePassAttributeKey, at: range.location, effectiveRange: nil) == nil
    }
}
