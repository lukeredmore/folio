import AppKit
import Foundation

enum LaTeXBlockStyleCache {

    static let styledPassAttributeKey = NSAttributedString.Key("FolioLaTeXStyledPass")
    static let sourceModePassAttributeKey = NSAttributedString.Key("FolioSourceCodeModePass")

    struct StyleConfig: Equatable {
        let theme: EditorTheme
        let typography: EditorTypographySettings
        let documentStyle: LaTeXDocumentStyle
        let textAlignment: NSTextAlignment
        let sourceCodeMode: Bool
        let prettyMode: Bool
        let focusMode: Bool
        let effectiveContainerWidth: CGFloat
        let baseDirectoryURL: URL?
    }

    struct CachedBlock {
        let range: NSRange
        let startLineNumber: Int
        let lineCount: Int
        let isActive: Bool
        let dimFactor: CGFloat
        let headings: [OutlineHeading]
        let decorations: [LineDecoration]
    }

    struct StorageEntry {
        weak var storage: NSTextStorage?
        let config: StyleConfig
        let string: String
        let nsString: NSString
        let docIndex: LaTeXDocumentIndex
        let docMacros: [String: LaTeXMacroDefinition]
        let blocksByStart: [Int: CachedBlock]
    }

    struct DiffWindow {
        let isSameString: Bool
        let commonPrefixLen: Int
        let suffixStartInNew: Int
        let charDelta: Int
        let numberingUnchanged: Bool
    }

    nonisolated(unsafe) private static var lastEntry: StorageEntry?
    nonisolated(unsafe) static var activeBaseAttributes: [NSAttributedString.Key: Any] = [:]
    nonisolated(unsafe) static var pendingGlyphInvalidationRanges: [NSRange] = []

    static func invalidate() {
        lastEntry = nil
    }

    static func collapseInternalNewlines(in storage: NSTextStorage, nsString: NSString, range: NSRange) {
        let end = min(NSMaxRange(range), nsString.length) - 1
        guard range.location < end else { return }
        var idx = range.location
        while idx < end {
            if nsString.character(at: idx) == 0x0A {
                let nlRange = NSRange(location: idx, length: 1)
                storage.addAttributes([
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
        guard let entry = lastEntry,
              entry.storage === storage,
              entry.config == config,
              entry.docMacros == docMacros else {
            return nil
        }

        if entry.string == string {
            let diff = DiffWindow(
                isSameString: true,
                commonPrefixLen: nsString.length,
                suffixStartInNew: 0,
                charDelta: 0,
                numberingUnchanged: true
            )
            return (entry, diff)
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
        while suffix < maxSuffix &&
            prevNS.character(at: prevLen - 1 - suffix) == nsString.character(at: newLen - 1 - suffix) {
            suffix += 1
        }

        let delta = newLen - prevLen
        let prevIdx = entry.docIndex
        let numberingUnchanged =
            docIndex.lineSectionNumbers.count == prevIdx.lineSectionNumbers.count &&
            docIndex.blockTheoremHeaders.count == prevIdx.blockTheoremHeaders.count &&
            docIndex.blockEquationNumbers.count == prevIdx.blockEquationNumbers.count &&
            docIndex.labels.count == prevIdx.labels.count &&
            docIndex.bibEntries.count == prevIdx.bibEntries.count

        let diff = DiffWindow(
            isSameString: false,
            commonPrefixLen: prefix,
            suffixStartInNew: newLen - suffix,
            charDelta: delta,
            numberingUnchanged: numberingUnchanged
        )
        return (entry, diff)
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
        lastEntry = StorageEntry(
            storage: storage,
            config: config,
            string: string,
            nsString: nsString,
            docIndex: docIndex,
            docMacros: docMacros,
            blocksByStart: map
        )
    }

    static func isBlockActive(range: NSRange, activeLineRange: NSRange, selectedRange: NSRange) -> Bool {
        if NSIntersectionRange(range, activeLineRange).length > 0 { return true }
        if selectedRange.length > 0, NSIntersectionRange(range, selectedRange).length > 0 { return true }
        if selectedRange.location >= range.location && selectedRange.location <= NSMaxRange(range)
            && activeLineRange.location >= range.location && activeLineRange.location <= NSMaxRange(range) {
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
        headings: inout [OutlineHeading],
        decorations: inout [LineDecoration],
        recordedBlocks: inout [CachedBlock]
    ) -> (nextIndex: Int, lineDelta: Int)? {
        guard let (entry, diff) = session else { return nil }

        if diff.isSameString || charIndex < diff.commonPrefixLen {
            guard let prev = entry.blocksByStart[charIndex] else { return nil }
            if !diff.isSameString && NSMaxRange(prev.range) >= diff.commonPrefixLen {
                return nil
            }
            guard !prev.isActive else { return nil }
            let nowActive = isBlockActive(range: prev.range, activeLineRange: activeLineRange, selectedRange: selectedRange)
            guard !nowActive else { return nil }
            let newDim: CGFloat = focusMode ? 0.30 : 1.0
            guard prev.dimFactor == newDim, hasStyledMarker(in: storage, range: prev.range) else { return nil }

            headings.append(contentsOf: prev.headings)
            decorations.append(contentsOf: prev.decorations)
            recordedBlocks.append(prev)
            return (NSMaxRange(prev.range), prev.lineCount)
        }

        if charIndex > diff.suffixStartInNew && diff.numberingUnchanged {
            let oldStart = charIndex - diff.charDelta
            guard let prev = entry.blocksByStart[oldStart], !prev.isActive else { return nil }
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
                decorations: shiftedDecorations
            )
            headings.append(contentsOf: shiftedHeadings)
            decorations.append(contentsOf: shiftedDecorations)
            recordedBlocks.append(shiftedBlock)
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

    private static func shiftRange(_ r: NSRange, by delta: Int) -> NSRange {
        guard r.location != NSNotFound else { return r }
        return NSRange(location: r.location + delta, length: r.length)
    }

    private static func shiftDecoration(_ dec: LineDecoration, by delta: Int, editLocation: Int) -> LineDecoration {
        guard delta != 0 else { return dec }
        let newLineRange = shiftRange(dec.lineRange, by: delta)
        let newKind: BlockDecorationKind
        switch dec.kind {
        case .headingUnderline, .blockquote, .codeFenceStart, .codeFenceBody, .codeFenceEnd,
             .mathBlockStart, .mathBlockBody, .mathBlockEnd, .horizontalRule, .tableRow:
            newKind = dec.kind
        case let .mathBlockRendered(latex, fullBlockRange, dimFactor):
            newKind = .mathBlockRendered(latex: latex, fullBlockRange: shiftRange(fullBlockRange, by: delta), dimFactor: dimFactor)
        case let .mermaidBlockRendered(source, fullBlockRange, dimFactor):
            newKind = .mermaidBlockRendered(mermaidSource: source, fullBlockRange: shiftRange(fullBlockRange, by: delta), dimFactor: dimFactor)
        case let .svgBlockRendered(source, fullBlockRange, dimFactor):
            newKind = .svgBlockRendered(svgSource: source, fullBlockRange: shiftRange(fullBlockRange, by: delta), dimFactor: dimFactor)
        case let .imageRendered(url, alt, fullRange, ew, eh, baseDir, dimFactor):
            newKind = .imageRendered(url: url, alt: alt, fullRange: shiftRange(fullRange, by: delta), explicitWidth: ew, explicitHeight: eh, baseDirectoryURL: baseDir, dimFactor: dimFactor)
        case let .inlineMathRendered(latex, range, fontSize, dimFactor):
            newKind = .inlineMathRendered(latex: latex, range: shiftRange(range, by: delta), fontSize: fontSize, dimFactor: dimFactor)
        case let .inlineCode(range, fontSize, dimFactor):
            newKind = .inlineCode(range: shiftRange(range, by: delta), fontSize: fontSize, dimFactor: dimFactor)
        case let .kbdPill(range, fontSize, dimFactor):
            newKind = .kbdPill(range: shiftRange(range, by: delta), fontSize: fontSize, dimFactor: dimFactor)
        case let .listBullet(range, dimFactor):
            newKind = .listBullet(range: shiftRange(range, by: delta), dimFactor: dimFactor)
        case let .latexPreambleCard(title, subtitle, fullBlockRange, dimFactor):
            newKind = .latexPreambleCard(title: title, subtitle: subtitle, fullBlockRange: shiftRange(fullBlockRange, by: delta), dimFactor: dimFactor)
        case let .latexTheoremCard(header, isProof, showHeader, fullBlockRange, dimFactor):
            newKind = .latexTheoremCard(header: header, isProof: isProof, showHeader: showHeader, fullBlockRange: shiftRange(fullBlockRange, by: delta), dimFactor: dimFactor)
        case let .latexAbstractCard(showHeader, fullBlockRange, dimFactor):
            newKind = .latexAbstractCard(showHeader: showHeader, fullBlockRange: shiftRange(fullBlockRange, by: delta), dimFactor: dimFactor)
        case let .latexInputCard(path, resolvedURL, lineRange, dimFactor):
            newKind = .latexInputCard(path: path, resolvedURL: resolvedURL, lineRange: shiftRange(lineRange, by: delta), dimFactor: dimFactor)
        case let .latexEquationNumber(number, fullBlockRange, dimFactor):
            newKind = .latexEquationNumber(number: number, fullBlockRange: shiftRange(fullBlockRange, by: delta), dimFactor: dimFactor)
        case let .latexSectionBadge(number, level, lineRange, dimFactor):
            newKind = .latexSectionBadge(number: number, level: level, lineRange: shiftRange(lineRange, by: delta), dimFactor: dimFactor)
        case let .latexInlinePill(label, tooltip, targetLoc, targetURL, range, fontSize, isCitation, dimFactor):
            let shiftedTarget = targetLoc.map { $0 >= editLocation ? $0 + delta : $0 }
            newKind = .latexInlinePill(label: label, tooltip: tooltip, targetLocation: shiftedTarget, targetURL: targetURL, range: shiftRange(range, by: delta), fontSize: fontSize, isCitation: isCitation, dimFactor: dimFactor)
        case let .latexInlineText(text, font, range, dimFactor):
            newKind = .latexInlineText(text: text, font: font, range: shiftRange(range, by: delta), dimFactor: dimFactor)
        }
        return LineDecoration(lineRange: newLineRange, kind: newKind)
    }
}
