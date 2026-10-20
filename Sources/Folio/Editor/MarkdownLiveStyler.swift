import AppKit
import Foundation

public final class MarkdownLiveStyler {

    public static let collapsedTokenAttributeKey = NSAttributedString.Key("FolioCollapsedSyntaxToken")
    public static let inlineCodeFontAttributeKey = NSAttributedString.Key("FolioInlineCodeFont")
    /// Marks a source newline inside an inactive paragraph that renders as a space (CommonMark soft line break).
    public static let softLineBreakAttributeKey = NSAttributedString.Key("FolioSoftLineBreak")

    static let headingRegex = try! NSRegularExpression(pattern: #"^( {0,3})(#{1,6})(?:([ \t]+)(.*?))?(?:(?<![ \t])[ \t]+#+[ \t]*)?$"#)
    static let setextH1Regex = try! NSRegularExpression(pattern: #"^ {0,3}=+[ \t]*$"#)
    static let setextH2Regex = try! NSRegularExpression(pattern: #"^ {0,3}-{2,}[ \t]*$"#)
    static let blockquoteRegex = try! NSRegularExpression(pattern: #"^(\s*>+[ \t]*)(.*)$"#)
    static let taskListRegex = try! NSRegularExpression(pattern: #"^([ \t]*)([-*+]|\d+[.)])([ \t]+)(\[[ xX]\])([ \t]+)(.*)$"#)
    static let unorderedListRegex = try! NSRegularExpression(pattern: #"^([ \t]*)([-*+])([ \t]+)(.+)$"#)
    static let orderedListRegex = try! NSRegularExpression(pattern: #"^([ \t]*)(\d+[.)])([ \t]+)(.+)$"#)
    static let hrRegex = try! NSRegularExpression(pattern: #"^ {0,3}(?:(?:-[ \t]*){3,}|(?:\*[ \t]*){3,}|(?:_[ \t]*){3,})$"#)
    static let codeFenceOpenRegex = try! NSRegularExpression(pattern: #"^ {0,3}(`{3,}|~{3,})([ \t]*[^`~\n]*)$"#)
    static let linkRefDefRegex = try! NSRegularExpression(pattern: #"^( {0,3}\[[^\]]+\]:)([ \t]*)(<?[^\s>]+>?)(?:([ \t]+)(["'(].*["')]))?[ \t]*$"#)

    // Inline regexes
    static let escapeRegex = try! NSRegularExpression(pattern: ##"\\([!\"#$%&'()*+,\-./:;<=>?@\[\\\]^_`{|}~])"##)
    static let htmlBrRegex = try! NSRegularExpression(pattern: #"<br\s*/?>"#, options: [.caseInsensitive])
    static let htmlImgTagRegex = try! NSRegularExpression(pattern: #"<img\b([^>]*?)/?>"#, options: [.caseInsensitive])
    static let htmlVideoTagRegex = try! NSRegularExpression(pattern: #"<video\b([^>]*?)(?:/>|>(.*?)</video\s*>)"#, options: [.caseInsensitive])
    static let htmlPairedTagRegex = try! NSRegularExpression(
        pattern: #"(<(kbd|u|ins|mark|sup|sub|b|strong|i|em|s|del|strike|code|summary)\b[^>]*>)(.*?)(</\2\s*>)"#,
        options: [.caseInsensitive]
    )
    static let htmlDetailsTagRegex = try! NSRegularExpression(pattern: #"</?details\b[^>]*>"#, options: [.caseInsensitive])
    static let htmlAttrRegex = try! NSRegularExpression(pattern: #"\b([a-zA-Z_-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+))"#)
    static let boldItalicRegex = try! NSRegularExpression(pattern: #"(?<!\*)\*\*\*(?!\*)(?=\S)((?:(?!\*\*\*)[\s\S])+?)(?<=\S)\*\*\*(?!\*)|(?<![\p{L}\p{N}_])___(?!_)(?=\S)((?:(?!___)[\s\S])+?)(?<=\S)___(?![\p{L}\p{N}_])"#)
    static let boldAsteriskRegex = try! NSRegularExpression(pattern: #"(?<!\*)\*\*(?!\*)(?=\S)((?:(?!\*\*)[\s\S])+?)(?<=\S)\*\*(?!\*)"#)
    static let boldUnderscoreRegex = try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}_])__(?!_)(?=\S)((?:(?!__)[\s\S])+?)(?<=\S)__(?![\p{L}\p{N}_])"#)
    static let italicAsteriskRegex = try! NSRegularExpression(pattern: #"(?<!\*)\*(?!\*)(?=\S)((?:[^\*]|\*\*(?=\S)[^\*]+?(?<=\S)\*\*)+?)(?<=\S)\*(?!\*)"#)
    static let italicUnderscoreRegex = try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}_])_(?!_)(?=\S)((?:[^_]|__(?=\S)[^_]+?(?<=\S)__|(?<=[\p{L}\p{N}])_(?=[\p{L}\p{N}]))+?)(?<=\S)_(?![\p{L}\p{N}_])"#)
    static let strikeRegex = try! NSRegularExpression(pattern: #"(?<!~)(~~)(?!~)(?=\S)((?:(?!~~)[\s\S])+?)(?<=\S)(~~)(?!~)"#)
    static let highlightRegex = try! NSRegularExpression(pattern: #"(?<!=)(==)(?!=)(?=\S)((?:(?!==)[\s\S])+?)(?<=\S)(==)(?!=)"#)
    static let inlineMathRegex = try! NSRegularExpression(pattern: #"(?<!\$)(\$)(?!\$)(?=\S)([^\$\n]+?)(?<=\S)(?<!\$)(\$)(?!\$)"#)
    static let autolinkRegex = try! NSRegularExpression(pattern: #"(<)((?:https?://|mailto:)[^>\s]+|[a-zA-Z0-9._%+\-]+@(?:[a-zA-Z0-9\-]+\.)+[a-zA-Z]{2,})(>)"#)
    static let multiSpaceRegex = try! NSRegularExpression(pattern: #"[ \t]{2,}"#)
    static let leadingSpaceRegex = try! NSRegularExpression(pattern: #"^[ \t]+"#, options: [.anchorsMatchLines])
    static let trailingSpaceRegex = try! NSRegularExpression(pattern: #"[ \t]+$"#, options: [.anchorsMatchLines])
    static let latexCommandRegex = try! NSRegularExpression(pattern: #"\\[a-zA-Z]+|\\[^a-zA-Z\s]"#)
    static let latexBracesRegex = try! NSRegularExpression(pattern: #"[\{\}\^_]"#)

    @discardableResult
    public static func applyStyles(
        to storage: NSTextStorage,
        theme: EditorTheme,
        typography: EditorTypographySettings? = nil,
        sourceCodeMode: Bool,
        focusMode: Bool,
        selectedRange: NSRange,
        containerWidth: CGFloat = 0,
        prettyMode: Bool = true,
        baseDirectoryURL: URL? = nil
    ) -> MarkdownDocumentAnalysis {
        let typography = typography ?? theme.typography
        let string = storage.string
        let nsString = string as NSString
        let fullLength = nsString.length
        guard fullLength > 0 else { return MarkdownDocumentAnalysis(headings: [], decorations: []) }

        let fullRange = NSRange(location: 0, length: fullLength)
        let activeLineRange = nsString.lineRange(for: NSRange(location: min(selectedRange.location, fullLength), length: 0))
        storage.beginEditing()

        let effectiveBaseSize = theme.baseFontSize * typography.fontSizeScale
        let effectiveContainerWidth = containerWidth > 200 ? containerWidth : typography.maxColumnWidth

        let baseParagraph = NSMutableParagraphStyle()
        baseParagraph.lineHeightMultiple = typography.lineHeightMultiple
        baseParagraph.lineSpacing = typography.lineSpacing
        baseParagraph.paragraphSpacing = max(4.0, typography.paragraphSpacing * 0.65)
        if !sourceCodeMode { baseParagraph.tailIndent = effectiveContainerWidth }

        let baseFont = sourceCodeMode ? theme.codeFont(size: effectiveBaseSize) : theme.bodyFont(size: effectiveBaseSize)
        let baseColor = theme.textNSColor
        storage.setAttributes([
            .font: baseFont,
            .foregroundColor: baseColor,
            .paragraphStyle: baseParagraph,
            .kern: sourceCodeMode ? 0.0 : typography.characterSpacing
        ], range: fullRange)

        var headings: [OutlineHeading] = []
        var decorations: [LineDecoration] = []

        let specAST = sourceCodeMode ? (blocks: [CmarkAstBlock](), inlines: [CmarkAstInline]()) : parseSpecAST(string)
        var indentedCodeBlockLines = Set<Int>()
        for block in specAST.blocks where block.kind == 2 && (block.flags & 1) == 0 && block.startLine > 0 && block.endLine >= block.startLine {
            indentedCodeBlockLines.formUnion(block.startLine...block.endLine)
        }
        var astLinksByLine: [Int: [CmarkAstInline]] = [:]
        for inl in specAST.inlines where (inl.kind == 5 || inl.kind == 6) && inl.endLine >= inl.startLine && inl.startLine > 0 {
            astLinksByLine[inl.startLine, default: []].append(inl)
        }
        var lineRecords: [Int: LineRecord] = [:]
        var proseLineKinds: [Int: ProseLineKind] = [:]
        var multiLineParagraphLines = Set<Int>()
        for block in specAST.blocks where block.kind == 8 && block.startLine > 0 && block.endLine > block.startLine {
            multiLineParagraphLines.formUnion(block.startLine...block.endLine)
        }
        var deferredProseInline: [DeferredInlineStyle] = []

        var inCodeFence = false
        var currentFenceChar: Character = "`"
        var currentFenceLength: Int = 3
        var currentFenceLanguage = ""
        var previousListTextIndent: CGFloat? = nil
        var lineNumber = 1
        var index = 0

        while index < fullLength {
            let lineRange = nsString.lineRange(for: NSRange(location: index, length: 0))
            let contentRange = strippedLineContentRange(nsString: nsString, lineRange: lineRange)
            let lineText = nsString.substring(with: contentRange)
            let isActiveLine = isLineActive(lineRange: lineRange, activeLineRange: activeLineRange, selectedRange: selectedRange)
            let dimFactor: CGFloat = (focusMode && !isActiveLine) ? 0.30 : 1.0
            lineRecords[lineNumber] = (lineRange, contentRange, lineText, isActiveLine, dimFactor)

            if sourceCodeMode {
                styleSourceCodeLine(in: storage, lineText: lineText, contentRange: contentRange, lineNumber: lineNumber, effectiveBaseSize: effectiveBaseSize, baseColor: baseColor, theme: theme, dimFactor: dimFactor, headings: &headings)
                index = NSMaxRange(lineRange); lineNumber += 1; continue
            }

            let trimmedLine = lineText.trimmingCharacters(in: .whitespaces)

            // 1. Code Fence (``` or ~~~ with up to 3 leading spaces)
            if !inCodeFence, let fenceMatch = codeFenceOpenRegex.firstMatch(in: string, options: [], range: contentRange) {
                let markerStr = nsString.substring(with: fenceMatch.range(at: 1))
                let infoStr = nsString.substring(with: fenceMatch.range(at: 2)).trimmingCharacters(in: .whitespaces)
                let fenceChar = markerStr.first ?? "`"
                if !(fenceChar == "`" && infoStr.contains("`")) {
                    let lang = infoStr.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
                    let lowerLang = lang.lowercased()
                    if prettyMode && (lowerLang == "mermaid" || lowerLang == "svg"),
                       let step = tryStyleDiagramCodeFence(in: storage, nsString: nsString, fullLength: fullLength, lineRange: lineRange, contentRange: contentRange, lineText: lineText, isActiveLine: isActiveLine, activeLineRange: activeLineRange, selectedRange: selectedRange, fenceChar: fenceChar, openFenceLen: markerStr.count, lowerLang: lowerLang, theme: theme, typography: typography, effectiveBaseSize: effectiveBaseSize, effectiveContainerWidth: effectiveContainerWidth, focusMode: focusMode, decorations: &decorations) {
                        previousListTextIndent = nil; index = step.nextIndex; lineNumber += step.lineDelta; continue
                    }
                    inCodeFence = true; currentFenceChar = fenceChar
                    currentFenceLength = markerStr.count; currentFenceLanguage = lowerLang; previousListTextIndent = nil
                    styleCodeFenceDelimiterLine(in: storage, lineRange: lineRange, isClosing: false, isActiveLine: isActiveLine, theme: theme, typography: typography, effectiveBaseSize: effectiveBaseSize, effectiveContainerWidth: effectiveContainerWidth, dimFactor: dimFactor)
                    decorations.append(LineDecoration(lineRange: lineRange, kind: .codeFenceStart(language: lang)))
                    index = NSMaxRange(lineRange); lineNumber += 1; continue
                }
            } else if inCodeFence {
                let leadingSpaces = lineText.prefix(while: { $0 == " " }).count
                let afterLeading = String(lineText.dropFirst(leadingSpaces))
                let fenceRun = afterLeading.prefix(while: { $0 == currentFenceChar })
                let restAfterFence = afterLeading.dropFirst(fenceRun.count).trimmingCharacters(in: .whitespaces)
                if leadingSpaces <= 3 && fenceRun.count >= currentFenceLength && restAfterFence.isEmpty {
                    inCodeFence = false; currentFenceLanguage = ""
                    styleCodeFenceDelimiterLine(in: storage, lineRange: lineRange, isClosing: true, isActiveLine: isActiveLine, theme: theme, typography: typography, effectiveBaseSize: effectiveBaseSize, effectiveContainerWidth: effectiveContainerWidth, dimFactor: dimFactor)
                    decorations.append(LineDecoration(lineRange: lineRange, kind: .codeFenceEnd))
                } else {
                    styleCodeFenceBodyLine(in: storage, lineRange: lineRange, contentRange: contentRange, language: currentFenceLanguage, theme: theme, effectiveBaseSize: effectiveBaseSize, effectiveContainerWidth: effectiveContainerWidth, dimFactor: dimFactor, decorations: &decorations)
                }
                index = NSMaxRange(lineRange); lineNumber += 1; continue
            }

            // 1a. CommonMark Indented Code Block
            if indentedCodeBlockLines.contains(lineNumber) && (!trimmedLine.isEmpty || lineText.hasPrefix("    ") || lineText.hasPrefix("\t")) {
                previousListTextIndent = nil
                styleCodeFenceBodyLine(in: storage, lineRange: lineRange, contentRange: contentRange, language: nil, theme: theme, effectiveBaseSize: effectiveBaseSize, effectiveContainerWidth: effectiveContainerWidth, dimFactor: dimFactor, decorations: &decorations)
                index = NSMaxRange(lineRange); lineNumber += 1; continue
            }

            // 1b. Blank line outside code fence
            if trimmedLine.isEmpty {
                previousListTextIndent = nil
                styleBlankLine(in: storage, lineRange: lineRange, contentRange: contentRange, isActiveLine: isActiveLine, effectiveBaseSize: effectiveBaseSize, effectiveContainerWidth: effectiveContainerWidth)
                index = NSMaxRange(lineRange); lineNumber += 1; continue
            }

            // 2. Display Math Block ($$ ... $$)
            if trimmedLine.hasPrefix("$$") {
                previousListTextIndent = nil
                let step = styleDisplayMathBlock(in: storage, nsString: nsString, fullLength: fullLength, lineRange: lineRange, contentRange: contentRange, lineText: lineText, trimmedLine: trimmedLine, isActiveLine: isActiveLine, activeLineRange: activeLineRange, selectedRange: selectedRange, theme: theme, effectiveBaseSize: effectiveBaseSize, effectiveContainerWidth: effectiveContainerWidth, focusMode: focusMode, decorations: &decorations)
                index = step.nextIndex; lineNumber += step.lineDelta; continue
            }

            // 2b. Standalone Raw <svg ...> ... </svg> Block
            let lowerTrimmedLine = trimmedLine.lowercased()
            if lowerTrimmedLine.hasPrefix("<svg") {
                previousListTextIndent = nil
                if let step = tryStyleRawSVGBlock(in: storage, nsString: nsString, fullLength: fullLength, lineRange: lineRange, contentRange: contentRange, lineText: lineText, lowerTrimmedLine: lowerTrimmedLine, isActiveLine: isActiveLine, activeLineRange: activeLineRange, selectedRange: selectedRange, theme: theme, typography: typography, effectiveBaseSize: effectiveBaseSize, effectiveContainerWidth: effectiveContainerWidth, focusMode: focusMode, prettyMode: prettyMode, decorations: &decorations) {
                    index = step.nextIndex; lineNumber += step.lineDelta; continue
                }
            }

            // 3. Horizontal Rule (--- / *** / ___)
            if contentRange.length >= 3, hrRegex.firstMatch(in: string, options: [], range: contentRange) != nil {
                previousListTextIndent = nil
                styleHorizontalRuleLine(in: storage, lineRange: lineRange, contentRange: contentRange, isActiveLine: isActiveLine, theme: theme, typography: typography, effectiveContainerWidth: effectiveContainerWidth, dimFactor: dimFactor, decorations: &decorations)
                index = NSMaxRange(lineRange); lineNumber += 1; continue
            }

            // 4. ATX Heading (# .. ######)
            if let match = headingRegex.firstMatch(in: string, options: [], range: contentRange),
               match.range(at: 3).location != NSNotFound || match.range(at: 2).length == contentRange.length - match.range(at: 1).length {
                previousListTextIndent = nil
                styleATXHeadingLine(in: storage, string: string, nsString: nsString, match: match, lineRange: lineRange, contentRange: contentRange, lineNumber: lineNumber, isActiveLine: isActiveLine, theme: theme, typography: typography, effectiveContainerWidth: effectiveContainerWidth, dimFactor: dimFactor, prettyMode: prettyMode, baseDirectoryURL: baseDirectoryURL, headings: &headings, decorations: &decorations)
                index = NSMaxRange(lineRange); lineNumber += 1; continue
            }

            // 5. Blockquote (> ...)
            if let match = blockquoteRegex.firstMatch(in: string, options: [], range: contentRange) {
                previousListTextIndent = nil
                styleBlockquoteLine(in: storage, string: string, nsString: nsString, match: match, lineRange: lineRange, lineNumber: lineNumber, isActiveLine: isActiveLine, theme: theme, typography: typography, effectiveBaseSize: effectiveBaseSize, effectiveContainerWidth: effectiveContainerWidth, dimFactor: dimFactor, prettyMode: prettyMode, baseDirectoryURL: baseDirectoryURL, multiLineParagraphLines: multiLineParagraphLines, proseLineKinds: &proseLineKinds, deferredProseInline: &deferredProseInline, decorations: &decorations)
                index = NSMaxRange(lineRange); lineNumber += 1; continue
            }

            // 6. GFM Table Block
            if let step = tryStyleTableBlock(in: storage, string: string, nsString: nsString, fullLength: fullLength, startIndex: index, contentRange: contentRange, activeLineRange: activeLineRange, selectedRange: selectedRange, theme: theme, typography: typography, effectiveContainerWidth: effectiveContainerWidth, focusMode: focusMode, prettyMode: prettyMode, baseDirectoryURL: baseDirectoryURL, decorations: &decorations) {
                previousListTextIndent = nil; index = step.nextIndex; lineNumber += step.lineDelta; continue
            }

            // 7. Task List (- [ ] / - [x] / 1. [x])
            if let match = taskListRegex.firstMatch(in: string, options: [], range: contentRange) {
                previousListTextIndent = styleTaskListLine(in: storage, string: string, nsString: nsString, match: match, lineRange: lineRange, lineNumber: lineNumber, isActiveLine: isActiveLine, baseFont: baseFont, baseColor: baseColor, theme: theme, typography: typography, effectiveBaseSize: effectiveBaseSize, effectiveContainerWidth: effectiveContainerWidth, dimFactor: dimFactor, prettyMode: prettyMode, baseDirectoryURL: baseDirectoryURL, multiLineParagraphLines: multiLineParagraphLines, proseLineKinds: &proseLineKinds, deferredProseInline: &deferredProseInline, decorations: &decorations)
                index = NSMaxRange(lineRange); lineNumber += 1; continue
            }

            // 8. Unordered / Ordered Lists
            if let match = unorderedListRegex.firstMatch(in: string, options: [], range: contentRange) ??
                orderedListRegex.firstMatch(in: string, options: [], range: contentRange) {
                previousListTextIndent = styleStandardListLine(in: storage, string: string, nsString: nsString, match: match, lineRange: lineRange, contentRange: contentRange, lineNumber: lineNumber, isActiveLine: isActiveLine, baseFont: baseFont, baseColor: baseColor, theme: theme, typography: typography, effectiveBaseSize: effectiveBaseSize, effectiveContainerWidth: effectiveContainerWidth, dimFactor: dimFactor, prettyMode: prettyMode, baseDirectoryURL: baseDirectoryURL, multiLineParagraphLines: multiLineParagraphLines, proseLineKinds: &proseLineKinds, deferredProseInline: &deferredProseInline, decorations: &decorations)
                index = NSMaxRange(lineRange); lineNumber += 1; continue
            }

            // 9. Setext Heading
            if let nextIdx = tryStyleSetextHeadingBlock(in: storage, string: string, nsString: nsString, fullLength: fullLength, lineRange: lineRange, contentRange: contentRange, trimmedLine: trimmedLine, lineNumber: lineNumber, isActiveLine: isActiveLine, activeLineRange: activeLineRange, selectedRange: selectedRange, theme: theme, typography: typography, effectiveContainerWidth: effectiveContainerWidth, focusMode: focusMode, prettyMode: prettyMode, baseDirectoryURL: baseDirectoryURL, headings: &headings, decorations: &decorations) {
                previousListTextIndent = nil; index = nextIdx; lineNumber += 2; continue
            }

            // 10b. CommonMark Link Reference Definition ([label]: url "title")
            if previousListTextIndent == nil,
               let refDefMatch = linkRefDefRegex.firstMatch(in: string, options: [], range: contentRange) {
                styleLinkReferenceDefinitionLine(in: storage, refDefMatch: refDefMatch, contentRange: contentRange, isActiveLine: isActiveLine, theme: theme, effectiveBaseSize: effectiveBaseSize, dimFactor: dimFactor)
                index = NSMaxRange(lineRange); lineNumber += 1; continue
            }

            // Default paragraph line (or indented list continuation line)
            styleDefaultParagraphOrListContinuationLine(in: storage, string: string, nsString: nsString, lineRange: lineRange, contentRange: contentRange, lineNumber: lineNumber, isActiveLine: isActiveLine, baseFont: baseFont, baseColor: baseColor, theme: theme, typography: typography, effectiveContainerWidth: effectiveContainerWidth, dimFactor: dimFactor, prettyMode: prettyMode, baseDirectoryURL: baseDirectoryURL, multiLineParagraphLines: multiLineParagraphLines, previousListTextIndent: &previousListTextIndent, proseLineKinds: &proseLineKinds, deferredProseInline: &deferredProseInline, decorations: &decorations)
            index = NSMaxRange(lineRange); lineNumber += 1
        }

        applySoftLineBreaks(to: storage, blocks: specAST.blocks, lineRecords: lineRecords, proseLineKinds: proseLineKinds)
        applyDeferredProseInlineStyles(
            in: storage, string: string, fullLength: fullLength, deferredProseInline: deferredProseInline,
            lineRecords: lineRecords, theme: theme, prettyMode: prettyMode,
            baseDirectoryURL: baseDirectoryURL, decorations: &decorations
        )
        applyAstResolvedLinks(
            in: storage, nsString: nsString, fullLength: fullLength, astLinksByLine: astLinksByLine,
            lineRecords: lineRecords, theme: theme, prettyMode: prettyMode,
            baseDirectoryURL: baseDirectoryURL, decorations: &decorations
        )

        storage.endEditing()
        return MarkdownDocumentAnalysis(headings: headings, decorations: decorations)
    }
}
