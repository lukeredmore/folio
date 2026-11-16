import AppKit
import Foundation

/// Pre-filtered and prefix-max indexed cmark AST projection read by the Markdown styler.
/// Lines are one-based; `forEachOverlappingBlock` and `forEachOverlappingLink` slice a region's
/// line window in $O(\log N + k)$ time without scanning the rest of the document.
struct MarkdownStyleAST: Equatable, Sendable {
    struct RelevantBlock: Equatable, Sendable {
        let kind: UInt32
        let startLine: Int
        let endLine: Int
    }

    let relevantBlocks: [RelevantBlock]
    let blockPrefixMaxEnd: [Int]
    let links: [CmarkAstInline]
    let linkPrefixMaxEnd: [Int]

    static let empty = MarkdownStyleAST(relevantBlocks: [], blockPrefixMaxEnd: [], links: [], linkPrefixMaxEnd: [])

    private init(
        relevantBlocks: [RelevantBlock],
        blockPrefixMaxEnd: [Int],
        links: [CmarkAstInline],
        linkPrefixMaxEnd: [Int]
    ) {
        self.relevantBlocks = relevantBlocks
        self.blockPrefixMaxEnd = blockPrefixMaxEnd
        self.links = links
        self.linkPrefixMaxEnd = linkPrefixMaxEnd
    }

    init(blocks: [CmarkAstBlock], inlines: [CmarkAstInline]) {
        var filteredBlocks: [RelevantBlock] = []
        filteredBlocks.reserveCapacity(blocks.count / 2)
        var blocksSorted = true
        var lastBlockStart = 0
        for block in blocks where block.startLine > 0 {
            let isIndentedCode = block.kind == 2 && (block.flags & 1) == 0 && block.endLine >= block.startLine
            let isHTMLBlock = block.kind == 7 && block.endLine >= block.startLine
            let isMultiLineParagraph = block.kind == 8 && block.endLine > block.startLine
            guard isIndentedCode || isHTMLBlock || isMultiLineParagraph else { continue }
            if block.startLine < lastBlockStart {
                blocksSorted = false
            }
            lastBlockStart = block.startLine
            filteredBlocks.append(
                RelevantBlock(kind: block.kind, startLine: block.startLine, endLine: block.endLine)
            )
        }
        if !blocksSorted {
            filteredBlocks.sort {
                $0.startLine != $1.startLine ? $0.startLine < $1.startLine : $0.endLine < $1.endLine
            }
        }
        var bPrefix: [Int] = []
        bPrefix.reserveCapacity(filteredBlocks.count)
        var runningBlockMax = 0
        for b in filteredBlocks {
            runningBlockMax = max(runningBlockMax, b.endLine)
            bPrefix.append(runningBlockMax)
        }

        var filteredLinks: [CmarkAstInline] = []
        filteredLinks.reserveCapacity(inlines.count / 2)
        var linksSorted = true
        var lastLinkStart = 0
        var lastLinkCol = 0
        for inl in inlines where (inl.kind == 5 || inl.kind == 6) && inl.startLine > 0 && inl.endLine >= inl.startLine {
            if inl.startLine < lastLinkStart || (inl.startLine == lastLinkStart && inl.startColumn < lastLinkCol) {
                linksSorted = false
            }
            lastLinkStart = inl.startLine
            lastLinkCol = inl.startColumn
            filteredLinks.append(inl)
        }
        if !linksSorted {
            filteredLinks.sort {
                if $0.startLine != $1.startLine { return $0.startLine < $1.startLine }
                return $0.startColumn < $1.startColumn
            }
        }
        var lPrefix: [Int] = []
        lPrefix.reserveCapacity(filteredLinks.count)
        var runningLinkMax = 0
        for l in filteredLinks {
            runningLinkMax = max(runningLinkMax, l.endLine)
            lPrefix.append(runningLinkMax)
        }

        self.relevantBlocks = filteredBlocks
        self.blockPrefixMaxEnd = bPrefix
        self.links = filteredLinks
        self.linkPrefixMaxEnd = lPrefix
    }

    func forEachOverlappingBlock(in window: ClosedRange<Int>, _ body: (RelevantBlock) -> Void) {
        guard !relevantBlocks.isEmpty else { return }
        var low = 0
        var high = blockPrefixMaxEnd.count
        while low < high {
            let mid = (low + high) >> 1
            if blockPrefixMaxEnd[mid] < window.lowerBound {
                low = mid + 1
            } else {
                high = mid
            }
        }
        var idx = low
        while idx < relevantBlocks.count && relevantBlocks[idx].startLine <= window.upperBound {
            let b = relevantBlocks[idx]
            if b.endLine >= window.lowerBound {
                body(b)
            }
            idx += 1
        }
    }

    func forEachOverlappingLink(in window: ClosedRange<Int>, _ body: (CmarkAstInline) -> Void) {
        guard !links.isEmpty else { return }
        var low = 0
        var high = linkPrefixMaxEnd.count
        while low < high {
            let mid = (low + high) >> 1
            if linkPrefixMaxEnd[mid] < window.lowerBound {
                low = mid + 1
            } else {
                high = mid
            }
        }
        var idx = low
        while idx < links.count && links[idx].startLine <= window.upperBound {
            let l = links[idx]
            if l.endLine >= window.lowerBound {
                body(l)
            }
            idx += 1
        }
    }
}

/// A whitespace-only line that the line loop reached outside a code fence. The line is styled on
/// its own and leaves no block state behind, so styling can restart on the line after it.
struct MarkdownStyleCheckpoint: Equatable {
    let lineRange: NSRange
    let lineNumber: Int
}

/// Decorations grouped by the phase that emits them. Within a phase they are in document order;
/// a full pass returns the phases one after another.
struct MarkdownDecorationPhases: Equatable {
    var lines: [LineDecoration] = []
    var deferredInline: [LineDecoration] = []
    var links: [LineDecoration] = []

    var all: [LineDecoration] { lines + deferredInline + links }
}

/// One Markdown styling pass. A full pass styles every line once. An incremental pass styles line
/// regions that start after a checkpoint, slicing only the AST items overlapping that line window.
final class MarkdownStylePass {
    typealias Styler = MarkdownLiveStyler

    /// State that the line loop carries from one line to the next.
    struct BlockState {
        var inCodeFence = false
        var fenceChar: Character = "`"
        var fenceLength = 3
        var fenceLanguage = ""
        var fenceContainer = MarkdownLiveStyler.CodeFenceContainer()
        var previousListTextIndent: CGFloat?
    }

    let storage: NSTextStorage
    let string: String
    let nsString: NSString
    let fullLength: Int
    let parameters: MarkdownStyleParameters
    let selectedRange: NSRange
    let activeLineRange: NSRange
    let effectiveBaseSize: CGFloat
    let effectiveContainerWidth: CGFloat
    let baseFont: NSFont
    let baseColor: NSColor
    let baseAttributes: [NSAttributedString.Key: Any]
    let ast: MarkdownStyleAST
    let indentedCodeBlockLines: Set<Int>
    let multiLineParagraphLines: Set<Int>
    let paragraphStartLineByLine: [Int: Int]
    let regionParagraphBlocks: [MarkdownStyleAST.RelevantBlock]
    let astLinksByLine: [Int: [CmarkAstInline]]
    let astLinkLinesSorted: [Int]
    /// Line count of each CommonMark HTML block in this region, by its one-based first line.
    let htmlBlockLineCounts: [Int: Int]

    var headings: [OutlineHeading] = []
    var decorations = MarkdownDecorationPhases()
    var checkpoints: [MarkdownStyleCheckpoint] = []
    var lineRecords: [Int: MarkdownLiveStyler.LineRecord] = [:]
    var proseLineKinds: [Int: MarkdownLiveStyler.ProseLineKind] = [:]
    var proseContentPrefixBytes: [Int: Int] = [:]
    var deferredProseInline: [MarkdownLiveStyler.DeferredInlineStyle] = []
    var tableStyledLines: Set<Int> = []
    var tableLinkDecorationsByLine: [Int: [LineDecoration]] = [:]
    var state = BlockState()

    var theme: EditorTheme { parameters.theme }
    var typography: EditorTypographySettings { parameters.typography }
    var focusMode: Bool { parameters.focusMode }
    var prettyMode: Bool { parameters.prettyMode }
    var baseDirectoryURL: URL? { parameters.baseDirectoryURL }

    init(
        storage: NSTextStorage,
        string: String? = nil,
        nsString: NSString? = nil,
        parameters: MarkdownStyleParameters,
        selectedRange: NSRange,
        ast: MarkdownStyleAST,
        lineWindow: ClosedRange<Int>? = nil
    ) {
        self.storage = storage
        self.parameters = parameters
        self.selectedRange = selectedRange
        self.ast = ast
        let resolvedString = string ?? storage.string
        let resolvedNS = nsString ?? (resolvedString as NSString)
        self.string = resolvedString
        self.nsString = resolvedNS
        fullLength = resolvedNS.length
        activeLineRange = resolvedNS.lineRange(for: NSRange(location: min(selectedRange.location, fullLength), length: 0))

        let theme = parameters.theme
        let typography = parameters.typography
        let sourceCodeMode = parameters.sourceCodeMode
        effectiveBaseSize = theme.baseFontSize * typography.fontSizeScale
        effectiveContainerWidth = parameters.containerWidth > 200 ? parameters.containerWidth : typography.maxColumnWidth

        let baseParagraph = NSMutableParagraphStyle()
        baseParagraph.lineHeightMultiple = typography.lineHeightMultiple
        baseParagraph.lineSpacing = typography.lineSpacing
        baseParagraph.paragraphSpacing = max(4.0, typography.paragraphSpacing * 0.65)
        if !sourceCodeMode { baseParagraph.tailIndent = effectiveContainerWidth }

        baseFont = sourceCodeMode ? theme.codeFont(size: effectiveBaseSize) : theme.bodyFont(size: effectiveBaseSize)
        baseColor = theme.textNSColor
        var attributes: [NSAttributedString.Key: Any] = [
            .font: baseFont,
            .foregroundColor: baseColor,
            .paragraphStyle: baseParagraph,
            .kern: sourceCodeMode ? 0.0 : typography.characterSpacing
        ]
        if sourceCodeMode {
            attributes[LaTeXBlockStyleCache.sourceModePassAttributeKey] = true
        }
        baseAttributes = attributes

        let window = lineWindow ?? (1...Int.max)
        var indentedLines = Set<Int>()
        var paragraphLines = Set<Int>()
        var paragraphStarts: [Int: Int] = [:]
        var paragraphBlocks: [MarkdownStyleAST.RelevantBlock] = []
        var htmlBlocks: [Int: Int] = [:]

        ast.forEachOverlappingBlock(in: window) { block in
            let clampedStart = max(block.startLine, window.lowerBound)
            let clampedEnd = min(block.endLine, window.upperBound)
            switch block.kind {
            case 2:
                if clampedStart <= clampedEnd {
                    indentedLines.formUnion(clampedStart...clampedEnd)
                }
            case 7:
                htmlBlocks[block.startLine] = block.endLine - block.startLine + 1
            case 8:
                if clampedStart <= clampedEnd {
                    for ln in clampedStart...clampedEnd {
                        paragraphLines.insert(ln)
                        if ln > block.startLine {
                            paragraphStarts[ln] = block.startLine
                        }
                    }
                }
                paragraphBlocks.append(block)
            default:
                break
            }
        }
        indentedCodeBlockLines = indentedLines
        multiLineParagraphLines = paragraphLines
        paragraphStartLineByLine = paragraphStarts
        regionParagraphBlocks = paragraphBlocks
        htmlBlockLineCounts = htmlBlocks

        var linksByLine: [Int: [CmarkAstInline]] = [:]
        var orderedLinkLines: [Int] = []
        ast.forEachOverlappingLink(in: window) { inl in
            if linksByLine[inl.startLine] == nil {
                orderedLinkLines.append(inl.startLine)
            }
            linksByLine[inl.startLine, default: []].append(inl)
        }
        astLinksByLine = linksByLine
        astLinkLinesSorted = orderedLinkLines
    }

    var analysis: MarkdownDocumentAnalysis {
        MarkdownDocumentAnalysis(headings: headings, decorations: decorations.all)
    }

    /// Styles lines from the line that starts at `start` (one-based `lineNumber`) with a fresh
    /// block state, until a line starts at or after `end`. Returns where the loop stopped.
    @discardableResult
    func styleLines(from start: Int, lineNumber firstLine: Int, to end: Int) -> (index: Int, lineNumber: Int, inCodeFence: Bool) {
        state = BlockState()
        var index = start
        var lineNumber = firstLine
        while index < end {
            let step = styleStep(at: index, lineNumber: lineNumber)
            index = step.nextIndex
            lineNumber += step.lineDelta
        }
        return (index, lineNumber, state.inCodeFence)
    }

    /// Runs the passes that need every styled line: soft line breaks, deferred prose inline
    /// styles, AST-resolved links, and prose alignment. They only touch lines this pass styled.
    func finish() {
        applySoftLineBreaks()
        applyDeferredProseInlineStyles()
        applyAstResolvedLinks()
        applyProseAlignment()
    }

    private func styleStep(at index: Int, lineNumber: Int) -> (nextIndex: Int, lineDelta: Int) {
        let lineRange = nsString.lineRange(for: NSRange(location: index, length: 0))
        let contentRange = Styler.strippedLineContentRange(nsString: nsString, lineRange: lineRange)
        guard contentRange.length <= Styler.maxStyledLineLength else { return (NSMaxRange(lineRange), 1) }
        let lineText = nsString.substring(with: contentRange)
        let isActiveLine = Styler.isLineActive(lineRange: lineRange, activeLineRange: activeLineRange, selectedRange: selectedRange)
        let dimFactor: CGFloat = (focusMode && !isActiveLine) ? 0.30 : 1.0
        lineRecords[lineNumber] = (lineRange, contentRange, lineText, isActiveLine, dimFactor)
        let nextLine = (NSMaxRange(lineRange), 1)

        if parameters.sourceCodeMode {
            styleSourceCodeLine(
                lineText: lineText,
                contentRange: contentRange,
                lineNumber: lineNumber,
                dimFactor: dimFactor
            )
            return nextLine
        }

        let trimmedLine = lineText.trimmingCharacters(in: .whitespaces)
        if !state.inCodeFence && trimmedLine.isEmpty {
            checkpoints.append(MarkdownStyleCheckpoint(lineRange: lineRange, lineNumber: lineNumber))
        }

        // 1. Code Fence (``` or ~~~ with up to 3 leading spaces)
        if !state.inCodeFence, let fenceMatch = Styler.codeFenceOpenRegex.firstMatch(in: string, options: [], range: contentRange) {
            if let step = styleCodeFenceOpening(
                fenceMatch, lineRange: lineRange, contentRange: contentRange, lineText: lineText,
                isActiveLine: isActiveLine, dimFactor: dimFactor
            ) {
                return step
            }
        } else if state.inCodeFence {
            styleCodeFenceContinuation(
                lineRange: lineRange, contentRange: contentRange, lineText: lineText,
                isActiveLine: isActiveLine, dimFactor: dimFactor
            )
            return nextLine
        }

        // 1a. CommonMark Indented Code Block
        if indentedCodeBlockLines.contains(lineNumber) && (!trimmedLine.isEmpty || lineText.hasPrefix("    ") || lineText.hasPrefix("\t")) {
            state.previousListTextIndent = nil
            styleCodeFenceBodyLine(
                lineRange: lineRange, contentRange: contentRange, language: nil, dimFactor: dimFactor
            )
            return nextLine
        }

        // 1b. Blank line outside code fence
        if trimmedLine.isEmpty {
            state.previousListTextIndent = nil
            styleBlankLine(lineRange: lineRange, contentRange: contentRange, isActiveLine: isActiveLine)
            return nextLine
        }

        // 2. Display Math Block ($$ ... $$)
        if trimmedLine.hasPrefix("$$") {
            state.previousListTextIndent = nil
            return styleDisplayMathBlock(
                lineRange: lineRange, contentRange: contentRange, lineText: lineText,
                trimmedLine: trimmedLine, isActiveLine: isActiveLine
            )
        }

        // 2b. Standalone Raw <svg ...> ... </svg> Block
        let lowerTrimmedLine = trimmedLine.lowercased()
        if lowerTrimmedLine.hasPrefix("<svg") {
            state.previousListTextIndent = nil
            if let step = tryStyleRawSVGBlock(
                lineRange: lineRange, contentRange: contentRange, lineText: lineText,
                lowerTrimmedLine: lowerTrimmedLine, isActiveLine: isActiveLine
            ) {
                return step
            }
        }

        // 2c. CommonMark HTML block rendered in a web view
        if lowerTrimmedLine.hasPrefix("<"), let blockLineCount = htmlBlockLineCounts[lineNumber],
            let step = tryStyleHTMLBlock(lineRange: lineRange, endLineCount: blockLineCount)
        {
            state.previousListTextIndent = nil
            return step
        }

        // 3. Horizontal Rule (--- / *** / ___)
        if contentRange.length >= 3, Styler.hrRegex.firstMatch(in: string, options: [], range: contentRange) != nil {
            state.previousListTextIndent = nil
            styleHorizontalRuleLine(
                lineRange: lineRange, contentRange: contentRange, isActiveLine: isActiveLine, dimFactor: dimFactor
            )
            return nextLine
        }

        // 4. ATX Heading (# .. ######)
        if let match = Styler.headingRegex.firstMatch(in: string, options: [], range: contentRange),
            match.range(at: 3).location != NSNotFound || match.range(at: 2).length == contentRange.length - match.range(at: 1).length
        {
            state.previousListTextIndent = nil
            styleATXHeadingLine(
                match: match, lineRange: lineRange, contentRange: contentRange, lineNumber: lineNumber,
                isActiveLine: isActiveLine, dimFactor: dimFactor
            )
            return nextLine
        }

        // 5. Blockquote (> ...)
        if let match = Styler.blockquoteRegex.firstMatch(in: string, options: [], range: contentRange) {
            state.previousListTextIndent = nil
            styleBlockquoteLine(
                match: match, lineRange: lineRange, lineNumber: lineNumber,
                isActiveLine: isActiveLine, dimFactor: dimFactor
            )
            return nextLine
        }

        // 6. GFM Table Block
        if let step = tryStyleTableBlock(
            startIndex: index, lineNumber: lineNumber, contentRange: contentRange
        ) {
            state.previousListTextIndent = nil
            return step
        }

        // 7. Task List (- [ ] / - [x] / 1. [x])
        if let match = Styler.taskListRegex.firstMatch(in: string, options: [], range: contentRange) {
            state.previousListTextIndent = styleTaskListLine(
                match: match, lineRange: lineRange, lineNumber: lineNumber,
                isActiveLine: isActiveLine, dimFactor: dimFactor
            )
            return nextLine
        }

        // 8. Unordered / Ordered Lists
        if let match = Styler.unorderedListRegex.firstMatch(in: string, options: [], range: contentRange)
            ?? Styler.orderedListRegex.firstMatch(in: string, options: [], range: contentRange)
        {
            state.previousListTextIndent = styleStandardListLine(
                match: match, lineRange: lineRange, contentRange: contentRange,
                lineNumber: lineNumber, isActiveLine: isActiveLine, dimFactor: dimFactor
            )
            return nextLine
        }

        // 9. CommonMark Link Reference Definition ([label]: url "title") — checked BEFORE Setext
        //    underlines so `[ref]: /url` followed by `---` is not misparsed as an H2 heading.
        if state.previousListTextIndent == nil && proseLineKinds[lineNumber - 1] == nil,
            let refDefMatch = Styler.linkRefDefRegex.firstMatch(in: string, options: [], range: contentRange)
        {
            styleLinkReferenceDefinitionLine(
                refDefMatch: refDefMatch, isActiveLine: isActiveLine, dimFactor: dimFactor
            )
            return nextLine
        }

        // 10. Setext Heading
        if let nextIndex = tryStyleSetextHeadingBlock(
            lineRange: lineRange, contentRange: contentRange, trimmedLine: trimmedLine,
            lineNumber: lineNumber, isActiveLine: isActiveLine
        ) {
            state.previousListTextIndent = nil
            return (nextIndex, 2)
        }

        // 11. Default paragraph line (or indented list continuation line)
        styleDefaultParagraphOrListContinuationLine(
            lineRange: lineRange, contentRange: contentRange, lineNumber: lineNumber,
            isActiveLine: isActiveLine, dimFactor: dimFactor
        )
        return nextLine
    }
}
