import AppKit
import Foundation

/// The cmark AST data that the Markdown styler reads. Lines are one-based.
struct MarkdownStyleAST: Equatable {
    let blocks: [CmarkAstBlock]
    let inlines: [CmarkAstInline]

    static var empty: MarkdownStyleAST { MarkdownStyleAST(blocks: [], inlines: []) }
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
/// regions that start after a checkpoint, with the same code and a fresh block state.
final class MarkdownStylePass {
    private typealias Styler = MarkdownLiveStyler

    /// State that the line loop carries from one line to the next.
    private struct BlockState {
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
    private let indentedCodeBlockLines: Set<Int>
    private let multiLineParagraphLines: Set<Int>
    private let astLinksByLine: [Int: [CmarkAstInline]]
    /// Line count of each CommonMark HTML block, by its one-based first line.
    private let htmlBlockLineCounts: [Int: Int]

    private(set) var headings: [OutlineHeading] = []
    private(set) var decorations = MarkdownDecorationPhases()
    private(set) var checkpoints: [MarkdownStyleCheckpoint] = []
    private var lineRecords: [Int: MarkdownLiveStyler.LineRecord] = [:]
    private var proseLineKinds: [Int: MarkdownLiveStyler.ProseLineKind] = [:]
    private var deferredProseInline: [MarkdownLiveStyler.DeferredInlineStyle] = []
    private var state = BlockState()

    private var theme: EditorTheme { parameters.theme }
    private var typography: EditorTypographySettings { parameters.typography }
    private var focusMode: Bool { parameters.focusMode }
    private var prettyMode: Bool { parameters.prettyMode }
    private var baseDirectoryURL: URL? { parameters.baseDirectoryURL }

    init(storage: NSTextStorage, parameters: MarkdownStyleParameters, selectedRange: NSRange, ast: MarkdownStyleAST) {
        self.storage = storage
        self.parameters = parameters
        self.selectedRange = selectedRange
        self.ast = ast
        string = storage.string
        nsString = string as NSString
        fullLength = nsString.length
        activeLineRange = nsString.lineRange(for: NSRange(location: min(selectedRange.location, fullLength), length: 0))

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

        var indentedLines = Set<Int>()
        for block in ast.blocks where block.kind == 2 && (block.flags & 1) == 0 && block.startLine > 0 && block.endLine >= block.startLine {
            indentedLines.formUnion(block.startLine...block.endLine)
        }
        indentedCodeBlockLines = indentedLines
        var linksByLine: [Int: [CmarkAstInline]] = [:]
        for inl in ast.inlines where (inl.kind == 5 || inl.kind == 6) && inl.endLine >= inl.startLine && inl.startLine > 0 {
            linksByLine[inl.startLine, default: []].append(inl)
        }
        astLinksByLine = linksByLine
        var paragraphLines = Set<Int>()
        for block in ast.blocks where block.kind == 8 && block.startLine > 0 && block.endLine > block.startLine {
            paragraphLines.formUnion(block.startLine...block.endLine)
        }
        multiLineParagraphLines = paragraphLines
        var htmlBlocks: [Int: Int] = [:]
        for block in ast.blocks where block.kind == 7 && block.startLine > 0 && block.endLine >= block.startLine {
            htmlBlocks[block.startLine] = block.endLine - block.startLine + 1
        }
        htmlBlockLineCounts = htmlBlocks
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
        Styler.applySoftLineBreaks(to: storage, blocks: ast.blocks, lineRecords: lineRecords, proseLineKinds: proseLineKinds)
        Styler.applyDeferredProseInlineStyles(
            in: storage, string: string, fullLength: fullLength, deferredProseInline: deferredProseInline,
            lineRecords: lineRecords, theme: theme, prettyMode: prettyMode,
            baseDirectoryURL: baseDirectoryURL, decorations: &decorations.deferredInline
        )
        Styler.applyAstResolvedLinks(
            in: storage, nsString: nsString, fullLength: fullLength, astLinksByLine: astLinksByLine,
            lineRecords: lineRecords, theme: theme, prettyMode: prettyMode,
            baseDirectoryURL: baseDirectoryURL, decorations: &decorations.links
        )
        Styler.applyProseAlignment(parameters.textAlignment, to: storage, lineRecords: lineRecords, proseLineKinds: proseLineKinds)
    }

    private func styleStep(at index: Int, lineNumber: Int) -> (nextIndex: Int, lineDelta: Int) {
        let lineRange = nsString.lineRange(for: NSRange(location: index, length: 0))
        let contentRange = Styler.strippedLineContentRange(nsString: nsString, lineRange: lineRange)
        // A line without a record is skipped by the passes in `finish()` as well.
        guard contentRange.length <= Styler.maxStyledLineLength else { return (NSMaxRange(lineRange), 1) }
        let lineText = nsString.substring(with: contentRange)
        let isActiveLine = Styler.isLineActive(lineRange: lineRange, activeLineRange: activeLineRange, selectedRange: selectedRange)
        let dimFactor: CGFloat = (focusMode && !isActiveLine) ? 0.30 : 1.0
        lineRecords[lineNumber] = (lineRange, contentRange, lineText, isActiveLine, dimFactor)
        let nextLine = (NSMaxRange(lineRange), 1)

        if parameters.sourceCodeMode {
            Styler.styleSourceCodeLine(
                in: storage, lineText: lineText, contentRange: contentRange, lineNumber: lineNumber,
                effectiveBaseSize: effectiveBaseSize, baseColor: baseColor, theme: theme,
                dimFactor: dimFactor, headings: &headings
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
            Styler.styleCodeFenceBodyLine(
                in: storage, lineRange: lineRange, contentRange: contentRange, language: nil, theme: theme,
                effectiveBaseSize: effectiveBaseSize, effectiveContainerWidth: effectiveContainerWidth,
                dimFactor: dimFactor, decorations: &decorations.lines
            )
            return nextLine
        }

        // 1b. Blank line outside code fence
        if trimmedLine.isEmpty {
            state.previousListTextIndent = nil
            Styler.styleBlankLine(
                in: storage, lineRange: lineRange, contentRange: contentRange, isActiveLine: isActiveLine,
                effectiveBaseSize: effectiveBaseSize, effectiveContainerWidth: effectiveContainerWidth
            )
            return nextLine
        }

        // 2. Display Math Block ($$ ... $$)
        if trimmedLine.hasPrefix("$$") {
            state.previousListTextIndent = nil
            return Styler.styleDisplayMathBlock(
                in: storage, nsString: nsString, fullLength: fullLength, lineRange: lineRange,
                contentRange: contentRange, lineText: lineText, trimmedLine: trimmedLine,
                isActiveLine: isActiveLine, activeLineRange: activeLineRange, selectedRange: selectedRange,
                theme: theme, effectiveBaseSize: effectiveBaseSize, effectiveContainerWidth: effectiveContainerWidth,
                focusMode: focusMode, decorations: &decorations.lines
            )
        }

        // 2b. Standalone Raw <svg ...> ... </svg> Block
        let lowerTrimmedLine = trimmedLine.lowercased()
        if lowerTrimmedLine.hasPrefix("<svg") {
            state.previousListTextIndent = nil
            if let step = Styler.tryStyleRawSVGBlock(
                in: storage, nsString: nsString, fullLength: fullLength, lineRange: lineRange,
                contentRange: contentRange, lineText: lineText, lowerTrimmedLine: lowerTrimmedLine,
                isActiveLine: isActiveLine, activeLineRange: activeLineRange, selectedRange: selectedRange,
                theme: theme, typography: typography, effectiveBaseSize: effectiveBaseSize,
                effectiveContainerWidth: effectiveContainerWidth, focusMode: focusMode, prettyMode: prettyMode,
                decorations: &decorations.lines
            ) {
                return step
            }
        }

        // 2c. CommonMark HTML block rendered in a web view
        if lowerTrimmedLine.hasPrefix("<"), let blockLineCount = htmlBlockLineCounts[lineNumber],
            let step = Styler.tryStyleHTMLBlock(
                in: storage, nsString: nsString, lineRange: lineRange, endLineCount: blockLineCount,
                activeLineRange: activeLineRange, selectedRange: selectedRange, theme: theme,
                typography: typography, effectiveBaseSize: effectiveBaseSize,
                effectiveContainerWidth: effectiveContainerWidth, focusMode: focusMode, prettyMode: prettyMode,
                decorations: &decorations.lines
            )
        {
            state.previousListTextIndent = nil
            return step
        }

        // 3. Horizontal Rule (--- / *** / ___)
        if contentRange.length >= 3, Styler.hrRegex.firstMatch(in: string, options: [], range: contentRange) != nil {
            state.previousListTextIndent = nil
            Styler.styleHorizontalRuleLine(
                in: storage, lineRange: lineRange, contentRange: contentRange, isActiveLine: isActiveLine,
                theme: theme, typography: typography, effectiveContainerWidth: effectiveContainerWidth,
                dimFactor: dimFactor, decorations: &decorations.lines
            )
            return nextLine
        }

        // 4. ATX Heading (# .. ######)
        if let match = Styler.headingRegex.firstMatch(in: string, options: [], range: contentRange),
            match.range(at: 3).location != NSNotFound || match.range(at: 2).length == contentRange.length - match.range(at: 1).length
        {
            state.previousListTextIndent = nil
            Styler.styleATXHeadingLine(
                in: storage, string: string, nsString: nsString, match: match, lineRange: lineRange,
                contentRange: contentRange, lineNumber: lineNumber, isActiveLine: isActiveLine, theme: theme,
                typography: typography, effectiveContainerWidth: effectiveContainerWidth, dimFactor: dimFactor,
                prettyMode: prettyMode, baseDirectoryURL: baseDirectoryURL, headings: &headings,
                decorations: &decorations.lines
            )
            return nextLine
        }

        // 5. Blockquote (> ...)
        if let match = Styler.blockquoteRegex.firstMatch(in: string, options: [], range: contentRange) {
            state.previousListTextIndent = nil
            Styler.styleBlockquoteLine(
                in: storage, string: string, nsString: nsString, match: match, lineRange: lineRange,
                lineNumber: lineNumber, isActiveLine: isActiveLine, theme: theme, typography: typography,
                effectiveBaseSize: effectiveBaseSize, effectiveContainerWidth: effectiveContainerWidth,
                dimFactor: dimFactor, prettyMode: prettyMode, baseDirectoryURL: baseDirectoryURL,
                multiLineParagraphLines: multiLineParagraphLines, proseLineKinds: &proseLineKinds,
                deferredProseInline: &deferredProseInline, decorations: &decorations.lines
            )
            return nextLine
        }

        // 6. GFM Table Block
        if let step = Styler.tryStyleTableBlock(
            in: storage, string: string, nsString: nsString, fullLength: fullLength, startIndex: index,
            contentRange: contentRange, activeLineRange: activeLineRange, selectedRange: selectedRange,
            theme: theme, typography: typography, effectiveContainerWidth: effectiveContainerWidth,
            focusMode: focusMode, prettyMode: prettyMode, baseDirectoryURL: baseDirectoryURL,
            decorations: &decorations.lines
        ) {
            state.previousListTextIndent = nil
            return step
        }

        // 7. Task List (- [ ] / - [x] / 1. [x])
        if let match = Styler.taskListRegex.firstMatch(in: string, options: [], range: contentRange) {
            state.previousListTextIndent = Styler.styleTaskListLine(
                in: storage, string: string, nsString: nsString, match: match, lineRange: lineRange,
                lineNumber: lineNumber, isActiveLine: isActiveLine, baseFont: baseFont, baseColor: baseColor,
                theme: theme, typography: typography, effectiveBaseSize: effectiveBaseSize,
                effectiveContainerWidth: effectiveContainerWidth, dimFactor: dimFactor, prettyMode: prettyMode,
                baseDirectoryURL: baseDirectoryURL, multiLineParagraphLines: multiLineParagraphLines,
                proseLineKinds: &proseLineKinds, deferredProseInline: &deferredProseInline,
                decorations: &decorations.lines
            )
            return nextLine
        }

        // 8. Unordered / Ordered Lists
        if let match = Styler.unorderedListRegex.firstMatch(in: string, options: [], range: contentRange)
            ?? Styler.orderedListRegex.firstMatch(in: string, options: [], range: contentRange)
        {
            state.previousListTextIndent = Styler.styleStandardListLine(
                in: storage, string: string, nsString: nsString, match: match, lineRange: lineRange,
                contentRange: contentRange, lineNumber: lineNumber, isActiveLine: isActiveLine,
                baseFont: baseFont, baseColor: baseColor, theme: theme, typography: typography,
                effectiveBaseSize: effectiveBaseSize, effectiveContainerWidth: effectiveContainerWidth,
                dimFactor: dimFactor, prettyMode: prettyMode, baseDirectoryURL: baseDirectoryURL,
                multiLineParagraphLines: multiLineParagraphLines, proseLineKinds: &proseLineKinds,
                deferredProseInline: &deferredProseInline, decorations: &decorations.lines
            )
            return nextLine
        }

        // 9. Setext Heading
        if let nextIndex = Styler.tryStyleSetextHeadingBlock(
            in: storage, string: string, nsString: nsString, fullLength: fullLength, lineRange: lineRange,
            contentRange: contentRange, trimmedLine: trimmedLine, lineNumber: lineNumber,
            isActiveLine: isActiveLine, activeLineRange: activeLineRange, selectedRange: selectedRange,
            theme: theme, typography: typography, effectiveContainerWidth: effectiveContainerWidth,
            focusMode: focusMode, prettyMode: prettyMode, baseDirectoryURL: baseDirectoryURL,
            headings: &headings, decorations: &decorations.lines
        ) {
            state.previousListTextIndent = nil
            return (nextIndex, 2)
        }

        // 10b. CommonMark Link Reference Definition ([label]: url "title")
        if state.previousListTextIndent == nil,
            let refDefMatch = Styler.linkRefDefRegex.firstMatch(in: string, options: [], range: contentRange)
        {
            Styler.styleLinkReferenceDefinitionLine(
                in: storage, refDefMatch: refDefMatch, contentRange: contentRange, isActiveLine: isActiveLine,
                theme: theme, effectiveBaseSize: effectiveBaseSize, dimFactor: dimFactor
            )
            return nextLine
        }

        // Default paragraph line (or indented list continuation line)
        Styler.styleDefaultParagraphOrListContinuationLine(
            in: storage, string: string, nsString: nsString, lineRange: lineRange, contentRange: contentRange,
            lineNumber: lineNumber, isActiveLine: isActiveLine, baseFont: baseFont, baseColor: baseColor,
            theme: theme, typography: typography, effectiveContainerWidth: effectiveContainerWidth,
            dimFactor: dimFactor, prettyMode: prettyMode, baseDirectoryURL: baseDirectoryURL,
            multiLineParagraphLines: multiLineParagraphLines, previousListTextIndent: &state.previousListTextIndent,
            proseLineKinds: &proseLineKinds, deferredProseInline: &deferredProseInline,
            decorations: &decorations.lines
        )
        return nextLine
    }

    /// Opens a fenced code block, or styles a whole Mermaid or SVG diagram fence. Returns nil
    /// when the line is not a fence opener after all (a backtick fence with a backtick info
    /// string), so the caller tries the other line kinds.
    private func styleCodeFenceOpening(
        _ fenceMatch: NSTextCheckingResult,
        lineRange: NSRange,
        contentRange: NSRange,
        lineText: String,
        isActiveLine: Bool,
        dimFactor: CGFloat
    ) -> (nextIndex: Int, lineDelta: Int)? {
        let markerStr = nsString.substring(with: fenceMatch.range(at: 1))
        let infoStr = nsString.substring(with: fenceMatch.range(at: 2)).trimmingCharacters(in: .whitespaces)
        let fenceChar = markerStr.first ?? "`"
        guard !(fenceChar == "`" && infoStr.contains("`")) else { return nil }
        let lang = infoStr.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
        let lowerLang = lang.lowercased()
        if prettyMode && (lowerLang == "mermaid" || lowerLang == "svg"),
            let step = Styler.tryStyleDiagramCodeFence(
                in: storage, nsString: nsString, fullLength: fullLength, lineRange: lineRange,
                contentRange: contentRange, lineText: lineText, isActiveLine: isActiveLine,
                activeLineRange: activeLineRange, selectedRange: selectedRange, fenceChar: fenceChar,
                openFenceLen: markerStr.count, lowerLang: lowerLang, theme: theme, typography: typography,
                effectiveBaseSize: effectiveBaseSize, effectiveContainerWidth: effectiveContainerWidth,
                focusMode: focusMode, decorations: &decorations.lines
            )
        {
            state.previousListTextIndent = nil
            return step
        }
        state.inCodeFence = true
        state.fenceChar = fenceChar
        state.fenceContainer = MarkdownLiveStyler.CodeFenceContainer(
            strippedSpaces: lineText.prefix(while: { $0 == " " }).count,
            indent: state.previousListTextIndent ?? 0
        )
        state.fenceLength = markerStr.count
        state.fenceLanguage = lowerLang
        state.previousListTextIndent = nil
        Styler.styleCodeFenceDelimiterLine(
            in: storage, lineRange: lineRange, contentRange: contentRange, container: state.fenceContainer,
            isClosing: false, isActiveLine: isActiveLine, theme: theme, typography: typography,
            effectiveBaseSize: effectiveBaseSize, effectiveContainerWidth: effectiveContainerWidth,
            dimFactor: dimFactor
        )
        decorations.lines.append(LineDecoration(lineRange: lineRange, kind: .codeFenceStart(language: lang)))
        return (NSMaxRange(lineRange), 1)
    }

    /// Styles a line inside an open fenced code block: its closing fence or a body line.
    private func styleCodeFenceContinuation(
        lineRange: NSRange,
        contentRange: NSRange,
        lineText: String,
        isActiveLine: Bool,
        dimFactor: CGFloat
    ) {
        let leadingSpaces = lineText.prefix(while: { $0 == " " }).count
        let afterLeading = String(lineText.dropFirst(leadingSpaces))
        let fenceRun = afterLeading.prefix(while: { $0 == state.fenceChar })
        let restAfterFence = afterLeading.dropFirst(fenceRun.count).trimmingCharacters(in: .whitespaces)
        let container = state.fenceContainer
        if leadingSpaces <= 3 + container.strippedSpaces && fenceRun.count >= state.fenceLength && restAfterFence.isEmpty {
            state.inCodeFence = false
            state.fenceLanguage = ""
            Styler.styleCodeFenceDelimiterLine(
                in: storage, lineRange: lineRange, contentRange: contentRange, container: container,
                isClosing: true, isActiveLine: isActiveLine, theme: theme, typography: typography,
                effectiveBaseSize: effectiveBaseSize, effectiveContainerWidth: effectiveContainerWidth,
                dimFactor: dimFactor
            )
            decorations.lines.append(LineDecoration(lineRange: lineRange, kind: .codeFenceEnd))
        } else {
            Styler.styleCodeFenceBodyLine(
                in: storage, lineRange: lineRange, contentRange: contentRange, container: container,
                language: state.fenceLanguage, theme: theme, effectiveBaseSize: effectiveBaseSize,
                effectiveContainerWidth: effectiveContainerWidth, dimFactor: dimFactor,
                decorations: &decorations.lines
            )
        }
    }
}
