import AppKit
import Foundation
import FolioEngineFFI

public struct CmarkAstBlock: Equatable {
    public let kind: UInt32
    public let startLine: Int
    public let startColumn: Int
    public let endLine: Int
    public let endColumn: Int
    public let level: Int
    public let flags: UInt32
    public let info: String
}

public struct CmarkAstInline: Equatable {
    public let kind: UInt32
    public let startLine: Int
    public let startColumn: Int
    public let endLine: Int
    public let endColumn: Int
    public let url: String
    public let literal: String
}

public enum TableColumnAlignment: Equatable {
    case left
    case center
    case right
}

public enum BlockDecorationKind: Equatable {
    case headingUnderline(level: Int)
    case blockquote(nestLevel: Int)
    case codeFenceStart(language: String)
    case codeFenceBody
    case codeFenceEnd
    case mathBlockStart(isActive: Bool)
    case mathBlockBody(isActive: Bool)
    case mathBlockEnd(isActive: Bool)
    case mathBlockRendered(latex: String, fullBlockRange: NSRange, dimFactor: CGFloat)
    case inlineMathRendered(latex: String, range: NSRange, fontSize: CGFloat, dimFactor: CGFloat)
    case inlineCode(range: NSRange, fontSize: CGFloat, dimFactor: CGFloat)
    case horizontalRule
    case tableRow(
        isHeader: Bool,
        isSeparator: Bool,
        isFirstRow: Bool,
        isLastRow: Bool,
        bodyRowIndex: Int,
        tableOffsetX: CGFloat,
        tableWidth: CGFloat,
        columnDividers: [CGFloat]
    )
}

public struct LineDecoration {
    public let lineRange: NSRange
    public let kind: BlockDecorationKind
}

public struct MarkdownDocumentAnalysis {
    public let headings: [OutlineHeading]
    public let decorations: [LineDecoration]
}

public final class MarkdownLiveStyler {

    public static let collapsedTokenAttributeKey = NSAttributedString.Key("FolioCollapsedSyntaxToken")
    public static let inlineCodeFontAttributeKey = NSAttributedString.Key("FolioInlineCodeFont")

    /// Renders Markdown to specification-compliant HTML using the upstream `cmark-gfm` parser in `folio_engine`.
    /// Pass `nil` for `extensions` to enable the default GitHub Flavored Markdown extensions
    /// (`table`, `strikethrough`, `autolink`, `tagfilter`, `tasklist`), or pass a custom list (e.g. `[]` for pure CommonMark).
    public static func renderHTML(_ markdown: String, extensions: [String]? = nil) -> String {
        return markdown.withCString { mdPtr in
            let htmlPtr: UnsafeMutablePointer<CChar>?
            if let extensions = extensions {
                let joined = extensions.joined(separator: " ")
                htmlPtr = joined.withCString { extPtr in
                    ot_engine_render_markdown_html(mdPtr, extPtr)
                }
            } else {
                htmlPtr = ot_engine_render_markdown_html(mdPtr, nil)
            }
            guard let validPtr = htmlPtr else { return "" }
            defer { ot_engine_free_string(validPtr) }
            return String(cString: validPtr)
        }
    }

    /// Parses Markdown into a CommonMark 0.31.2 + GFM 0.29.0 AST via `cmark-gfm` in `folio_engine`.
    public static func parseSpecAST(_ markdown: String) -> (blocks: [CmarkAstBlock], inlines: [CmarkAstInline]) {
        return markdown.withCString { mdPtr in
            guard let resPtr = ot_engine_parse_markdown_ast(mdPtr) else {
                return ([], [])
            }
            defer { ot_engine_free_markdown_ast(resPtr) }
            let res = resPtr.pointee

            var blocks: [CmarkAstBlock] = []
            if res.block_count > 0, let blocksBase = res.blocks {
                blocks.reserveCapacity(res.block_count)
                for i in 0..<res.block_count {
                    let b = blocksBase[i]
                    let info = b.info != nil ? String(cString: b.info) : ""
                    blocks.append(CmarkAstBlock(
                        kind: b.kind,
                        startLine: Int(b.start_line),
                        startColumn: Int(b.start_column),
                        endLine: Int(b.end_line),
                        endColumn: Int(b.end_column),
                        level: Int(b.level),
                        flags: b.flags,
                        info: info
                    ))
                }
            }

            var inlines: [CmarkAstInline] = []
            if res.inline_count > 0, let inlinesBase = res.inlines {
                inlines.reserveCapacity(res.inline_count)
                for i in 0..<res.inline_count {
                    let inl = inlinesBase[i]
                    let url = inl.url != nil ? String(cString: inl.url) : ""
                    let literal = inl.literal != nil ? String(cString: inl.literal) : ""
                    inlines.append(CmarkAstInline(
                        kind: inl.kind,
                        startLine: Int(inl.start_line),
                        startColumn: Int(inl.start_column),
                        endLine: Int(inl.end_line),
                        endColumn: Int(inl.end_column),
                        url: url,
                        literal: literal
                    ))
                }
            }

            return (blocks, inlines)
        }
    }

    private static let headingRegex = try! NSRegularExpression(pattern: #"^( {0,3})(#{1,6})(?:([ \t]+)(.*?))?(?:(?<![ \t])[ \t]+#+[ \t]*)?$"#)
    private static let setextH1Regex = try! NSRegularExpression(pattern: #"^ {0,3}=+[ \t]*$"#)
    private static let setextH2Regex = try! NSRegularExpression(pattern: #"^ {0,3}-{2,}[ \t]*$"#)
    private static let blockquoteRegex = try! NSRegularExpression(pattern: #"^(\s*>+[ \t]*)(.*)$"#)
    private static let taskListRegex = try! NSRegularExpression(pattern: #"^([ \t]*)([-*+]|\d+[.)])([ \t]+)(\[[ xX]\])([ \t]+)(.*)$"#)
    private static let unorderedListRegex = try! NSRegularExpression(pattern: #"^([ \t]*)([-*+])([ \t]+)(.+)$"#)
    private static let orderedListRegex = try! NSRegularExpression(pattern: #"^([ \t]*)(\d+[.)])([ \t]+)(.+)$"#)
    private static let hrRegex = try! NSRegularExpression(pattern: #"^ {0,3}(?:(?:-[ \t]*){3,}|(?:\*[ \t]*){3,}|(?:_[ \t]*){3,})$"#)
    private static let codeFenceOpenRegex = try! NSRegularExpression(pattern: #"^ {0,3}(`{3,}|~{3,})([ \t]*[^`~\n]*)$"#)
    private static let linkRefDefRegex = try! NSRegularExpression(pattern: #"^( {0,3}\[[^\]]+\]:)([ \t]*)(<?[^\s>]+>?)(?:([ \t]+)(["'(].*["')]))?[ \t]*$"#)

    // Inline regexes
    private static let escapeRegex = try! NSRegularExpression(pattern: ##"\\([!\"#$%&'()*+,\-./:;<=>?@\[\\\]^_`{|}~])"##)
    private static let htmlBrRegex = try! NSRegularExpression(pattern: #"<br\s*/?>"#, options: [.caseInsensitive])
    private static let boldItalicRegex = try! NSRegularExpression(pattern: #"(?<!\*)\*\*\*(?!\*)(?=\S)((?:(?!\*\*\*)[^\n])+?)(?<=\S)\*\*\*(?!\*)|(?<![\p{L}\p{N}_])___(?!_)(?=\S)((?:(?!___)[^\n])+?)(?<=\S)___(?![\p{L}\p{N}_])"#)
    private static let boldAsteriskRegex = try! NSRegularExpression(pattern: #"(?<!\*)\*\*(?!\*)(?=\S)((?:(?!\*\*)[^\n])+?)(?<=\S)\*\*(?!\*)"#)
    private static let boldUnderscoreRegex = try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}_])__(?!_)(?=\S)((?:(?!__)[^\n])+?)(?<=\S)__(?![\p{L}\p{N}_])"#)
    private static let italicAsteriskRegex = try! NSRegularExpression(pattern: #"(?<!\*)\*(?!\*)(?=\S)((?:[^\*\n]|\*\*(?=\S)[^\*\n]+?(?<=\S)\*\*)+?)(?<=\S)\*(?!\*)"#)
    private static let italicUnderscoreRegex = try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}_])_(?!_)(?=\S)((?:[^_\n]|__(?=\S)[^_\n]+?(?<=\S)__|(?<=[\p{L}\p{N}])_(?=[\p{L}\p{N}]))+?)(?<=\S)_(?![\p{L}\p{N}_])"#)
    private static let strikeRegex = try! NSRegularExpression(pattern: #"(?<!~)(~~)(?!~)(?=\S)((?:(?!~~)[^\n])+?)(?<=\S)(~~)(?!~)"#)
    private static let highlightRegex = try! NSRegularExpression(pattern: #"(?<!=)(==)(?!=)(?=\S)((?:(?!==)[^\n])+?)(?<=\S)(==)(?!=)"#)
    private static let inlineMathRegex = try! NSRegularExpression(pattern: #"(?<!\$)(\$)(?!\$)(?=\S)([^\$\n]+?)(?<=\S)(?<!\$)(\$)(?!\$)"#)
    private static let autolinkRegex = try! NSRegularExpression(pattern: #"(<)((?:https?://|mailto:)[^>\s]+|[a-zA-Z0-9._%+\-]+@(?:[a-zA-Z0-9\-]+\.)+[a-zA-Z]{2,})(>)"#)
    private static let multiSpaceRegex = try! NSRegularExpression(pattern: #"[ \t]{2,}"#)
    private static let leadingSpaceRegex = try! NSRegularExpression(pattern: #"^[ \t]+"#)
    private static let trailingSpaceRegex = try! NSRegularExpression(pattern: #"[ \t]+$"#)

    private static let latexCommandRegex = try! NSRegularExpression(pattern: #"\\[a-zA-Z]+|\\[^a-zA-Z\s]"#)
    private static let latexBracesRegex = try! NSRegularExpression(pattern: #"[\{\}\^_]"#)

    @discardableResult
    public static func applyStyles(
        to storage: NSTextStorage,
        theme: EditorTheme,
        typography: EditorTypographySettings = .default,
        sourceCodeMode: Bool,
        focusMode: Bool,
        selectedRange: NSRange,
        containerWidth: CGFloat = 0
    ) -> MarkdownDocumentAnalysis {
        let string = storage.string
        let nsString = string as NSString
        let fullLength = nsString.length
        guard fullLength > 0 else {
            return MarkdownDocumentAnalysis(headings: [], decorations: [])
        }

        let fullRange = NSRange(location: 0, length: fullLength)
        let activeLineRange = nsString.lineRange(for: NSRange(location: min(selectedRange.location, fullLength), length: 0))

        storage.beginEditing()

        let effectiveBaseSize = theme.baseFontSize * typography.fontSizeScale
        let effectiveContainerWidth = containerWidth > 200 ? containerWidth : typography.maxColumnWidth

        // Base paragraph style
        let baseParagraph = NSMutableParagraphStyle()
        baseParagraph.lineHeightMultiple = typography.lineHeightMultiple
        baseParagraph.lineSpacing = typography.lineSpacing
        baseParagraph.paragraphSpacing = max(4.0, typography.paragraphSpacing * 0.65)
        if !sourceCodeMode {
            baseParagraph.tailIndent = effectiveContainerWidth
        }

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

        // Parse CommonMark 0.31.2 + GFM 0.29.0 AST via cmark-gfm for indented code blocks,
        // resolved reference links ([text][ref], [text][], [text]), and GFM extended autolinks.
        let specAST = sourceCodeMode ? (blocks: [CmarkAstBlock](), inlines: [CmarkAstInline]()) : parseSpecAST(string)
        var indentedCodeBlockLines = Set<Int>()
        for block in specAST.blocks where block.kind == 2 && (block.flags & 1) == 0 {
            if block.startLine > 0 && block.endLine >= block.startLine {
                for ln in block.startLine...block.endLine {
                    indentedCodeBlockLines.insert(ln)
                }
            }
        }
        var astLinksByLine: [Int: [CmarkAstInline]] = [:]
        for inl in specAST.inlines where (inl.kind == 5 || inl.kind == 6) && inl.startLine == inl.endLine && inl.startLine > 0 {
            astLinksByLine[inl.startLine, default: []].append(inl)
        }
        var lineRecords: [Int: (lineRange: NSRange, contentRange: NSRange, lineText: String, isActive: Bool, dimFactor: CGFloat)] = [:]

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
                if lineText.hasPrefix("#") {
                    let trimmed = lineText.prefix(while: { $0 == "#" })
                    let level = min(6, max(1, trimmed.count))
                    let title = String(lineText.dropFirst(level)).trimmingCharacters(in: .whitespaces)
                    if !title.isEmpty {
                        headings.append(OutlineHeading(
                            level: level,
                            title: title,
                            characterLocation: contentRange.location,
                            lineNumber: lineNumber
                        ))
                    }
                    storage.addAttribute(
                        .foregroundColor,
                        value: theme.headingNSColor.withAlphaComponent(dimFactor),
                        range: contentRange
                    )
                    storage.addAttribute(
                        .font,
                        value: NSFont.monospacedSystemFont(ofSize: effectiveBaseSize, weight: .bold),
                        range: contentRange
                    )
                } else if dimFactor < 1.0 {
                    storage.addAttribute(
                        .foregroundColor,
                        value: baseColor.withAlphaComponent(dimFactor),
                        range: contentRange
                    )
                }
                index = NSMaxRange(lineRange)
                lineNumber += 1
                continue
            }

            let trimmedLine = lineText.trimmingCharacters(in: .whitespaces)

            // 1. Check Code Fence (``` or ~~~ with up to 3 leading spaces)
            if !inCodeFence, let fenceMatch = codeFenceOpenRegex.firstMatch(in: string, options: [], range: contentRange) {
                let markerStr = nsString.substring(with: fenceMatch.range(at: 1))
                let infoStr = nsString.substring(with: fenceMatch.range(at: 2)).trimmingCharacters(in: .whitespaces)
                let fenceChar = markerStr.first ?? "`"
                if !(fenceChar == "`" && infoStr.contains("`")) {
                    inCodeFence = true
                    currentFenceChar = fenceChar
                    currentFenceLength = markerStr.count
                    let lang = infoStr.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
                    currentFenceLanguage = lang.lowercased()
                    previousListTextIndent = nil

                    let codeMono = theme.codeFont(size: effectiveBaseSize * 0.88)
                    let fenceRowHeight: CGFloat = 23.0
                    let fencePara = NSMutableParagraphStyle()
                    fencePara.lineSpacing = 0.0
                    fencePara.paragraphSpacingBefore = 0.0
                    fencePara.paragraphSpacing = 0.0
                    fencePara.firstLineHeadIndent = 14.0
                    fencePara.headIndent = 14.0
                    fencePara.minimumLineHeight = fenceRowHeight
                    fencePara.maximumLineHeight = fenceRowHeight
                    fencePara.tailIndent = effectiveContainerWidth

                    storage.addAttributes([
                        .font: codeMono,
                        .foregroundColor: theme.markdownTokenNSColor.withAlphaComponent(isActiveLine ? 0.9 : 0.45 * dimFactor),
                        .paragraphStyle: fencePara,
                        .baselineOffset: 0.0,
                        .kern: 0.0
                    ], range: lineRange)

                    decorations.append(LineDecoration(lineRange: lineRange, kind: .codeFenceStart(language: lang)))
                    index = NSMaxRange(lineRange)
                    lineNumber += 1
                    continue
                }
            } else if inCodeFence {
                let leadingSpaces = lineText.prefix(while: { $0 == " " }).count
                let afterLeading = String(lineText.dropFirst(leadingSpaces))
                let fenceRun = afterLeading.prefix(while: { $0 == currentFenceChar })
                let restAfterFence = afterLeading.dropFirst(fenceRun.count).trimmingCharacters(in: .whitespaces)
                if leadingSpaces <= 3 && fenceRun.count >= currentFenceLength && restAfterFence.isEmpty {
                    inCodeFence = false
                    currentFenceLanguage = ""
                    let codeMono = theme.codeFont(size: effectiveBaseSize * 0.88)
                    let fenceRowHeight: CGFloat = 23.0
                    let fencePara = NSMutableParagraphStyle()
                    fencePara.lineSpacing = 0.0
                    fencePara.paragraphSpacingBefore = 0.0
                    fencePara.paragraphSpacing = max(4.0, typography.paragraphSpacing * 0.55)
                    fencePara.firstLineHeadIndent = 14.0
                    fencePara.headIndent = 14.0
                    fencePara.minimumLineHeight = fenceRowHeight
                    fencePara.maximumLineHeight = fenceRowHeight
                    fencePara.tailIndent = effectiveContainerWidth

                    storage.addAttributes([
                        .font: codeMono,
                        .foregroundColor: theme.markdownTokenNSColor.withAlphaComponent(isActiveLine ? 0.9 : 0.45 * dimFactor),
                        .paragraphStyle: fencePara,
                        .baselineOffset: 0.0,
                        .kern: 0.0
                    ], range: lineRange)

                    decorations.append(LineDecoration(lineRange: lineRange, kind: .codeFenceEnd))
                    index = NSMaxRange(lineRange)
                    lineNumber += 1
                    continue
                }

                decorations.append(LineDecoration(lineRange: lineRange, kind: .codeFenceBody))
                let codeMono = theme.codeFont(size: effectiveBaseSize * 0.90)
                let bodyRowHeight: CGFloat = 22.0
                let codePara = NSMutableParagraphStyle()
                codePara.lineSpacing = 0.0
                codePara.paragraphSpacingBefore = 0.0
                codePara.paragraphSpacing = 0.0
                codePara.firstLineHeadIndent = 14.0
                codePara.headIndent = 14.0
                codePara.minimumLineHeight = bodyRowHeight
                codePara.maximumLineHeight = bodyRowHeight
                codePara.tailIndent = effectiveContainerWidth

                storage.addAttributes([
                    .font: codeMono,
                    .foregroundColor: theme.textNSColor.withAlphaComponent(dimFactor),
                    .paragraphStyle: codePara,
                    .baselineOffset: 0.0,
                    .kern: 0.0
                ], range: lineRange)

                highlightCodeLine(
                    in: storage,
                    range: contentRange,
                    language: currentFenceLanguage,
                    theme: theme,
                    dimFactor: dimFactor
                )
                index = NSMaxRange(lineRange)
                lineNumber += 1
                continue
            }

            // 1a. CommonMark Indented Code Block (4+ leading spaces / tab outside lists/paragraphs as determined by cmark-gfm AST)
            if indentedCodeBlockLines.contains(lineNumber) && (!trimmedLine.isEmpty || lineText.hasPrefix("    ") || lineText.hasPrefix("\t")) {
                previousListTextIndent = nil
                decorations.append(LineDecoration(lineRange: lineRange, kind: .codeFenceBody))
                let codeMono = theme.codeFont(size: effectiveBaseSize * 0.90)
                let bodyRowHeight: CGFloat = 22.0
                let codePara = NSMutableParagraphStyle()
                codePara.lineSpacing = 0.0
                codePara.paragraphSpacingBefore = 0.0
                codePara.paragraphSpacing = 0.0
                codePara.firstLineHeadIndent = 14.0
                codePara.headIndent = 14.0
                codePara.minimumLineHeight = bodyRowHeight
                codePara.maximumLineHeight = bodyRowHeight
                codePara.tailIndent = effectiveContainerWidth

                storage.addAttributes([
                    .font: codeMono,
                    .foregroundColor: theme.textNSColor.withAlphaComponent(dimFactor),
                    .paragraphStyle: codePara,
                    .baselineOffset: 0.0,
                    .kern: 0.0
                ], range: lineRange)

                index = NSMaxRange(lineRange)
                lineNumber += 1
                continue
            }

            // 1b. Blank line outside code fence: use compact height so paragraph breaks don't double-space
            if trimmedLine.isEmpty {
                previousListTextIndent = nil
                let blankPara = NSMutableParagraphStyle()
                let blankH = round(effectiveBaseSize * (isActiveLine ? 1.15 : 0.55))
                blankPara.minimumLineHeight = blankH
                blankPara.maximumLineHeight = blankH
                blankPara.lineSpacing = 0.0
                blankPara.paragraphSpacing = 0.0
                blankPara.paragraphSpacingBefore = 0.0
                blankPara.tailIndent = effectiveContainerWidth
                storage.addAttributes([
                    .paragraphStyle: blankPara,
                    .kern: 0.0
                ], range: lineRange)
                if !isActiveLine && contentRange.length > 0 {
                    collapseWhitespaceRange(in: storage, range: contentRange)
                }
                index = NSMaxRange(lineRange)
                lineNumber += 1
                continue
            }

            // 2. Check Display Math Block ($$ ... $$) as a cohesive unit
            if trimmedLine.hasPrefix("$$") {
                previousListTextIndent = nil
                var mathLines: [(lineRange: NSRange, contentRange: NSRange, text: String, isActive: Bool)] = []
                mathLines.append((lineRange, contentRange, lineText, isActiveLine))

                var scanIndex = NSMaxRange(lineRange)
                var scanLineCount = 1
                let isSingleLineMath = trimmedLine.count > 4 && trimmedLine.hasSuffix("$$")

                if !isSingleLineMath {
                    while scanIndex < fullLength {
                        let nextLR = nsString.lineRange(for: NSRange(location: scanIndex, length: 0))
                        let nextCR = strippedLineContentRange(nsString: nsString, lineRange: nextLR)
                        let nextText = nsString.substring(with: nextCR)
                        let nextActive = isLineActive(lineRange: nextLR, activeLineRange: activeLineRange, selectedRange: selectedRange)
                        mathLines.append((nextLR, nextCR, nextText, nextActive))
                        scanIndex = NSMaxRange(nextLR)
                        scanLineCount += 1
                        if nextText.trimmingCharacters(in: .whitespaces).hasPrefix("$$") {
                            break
                        }
                    }
                }

                let isMathBlockActive = mathLines.contains(where: { $0.isActive }) ||
                    NSIntersectionRange(
                        NSRange(location: lineRange.location, length: scanIndex - lineRange.location),
                        selectedRange
                    ).length > 0
                let blockDim: CGFloat = (focusMode && !isMathBlockActive) ? 0.30 : 1.0
                let fullBlockRange = NSRange(location: lineRange.location, length: scanIndex - lineRange.location)

                var latexParts: [String] = []
                for (idx, mLine) in mathLines.enumerated() {
                    let t = mLine.text.trimmingCharacters(in: .whitespaces)
                    if isSingleLineMath {
                        let inner = String(t.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces)
                        latexParts.append(inner)
                        decorations.append(LineDecoration(lineRange: mLine.lineRange, kind: .mathBlockBody(isActive: isMathBlockActive)))
                    } else if idx == 0 {
                        let afterFence = String(t.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                        if !afterFence.isEmpty { latexParts.append(afterFence) }
                        decorations.append(LineDecoration(lineRange: mLine.lineRange, kind: .mathBlockStart(isActive: isMathBlockActive)))
                    } else if idx == mathLines.count - 1 && t.hasPrefix("$$") {
                        decorations.append(LineDecoration(lineRange: mLine.lineRange, kind: .mathBlockEnd(isActive: isMathBlockActive)))
                    } else {
                        latexParts.append(mLine.text)
                        decorations.append(LineDecoration(lineRange: mLine.lineRange, kind: .mathBlockBody(isActive: isMathBlockActive)))
                    }

                    if isMathBlockActive {
                        let mathMono = theme.codeFont(size: effectiveBaseSize * 0.92)
                        let mathPara = NSMutableParagraphStyle()
                        mathPara.lineSpacing = 3.5
                        mathPara.paragraphSpacing = 2.0
                        mathPara.firstLineHeadIndent = 14.0
                        mathPara.headIndent = 14.0
                        mathPara.tailIndent = effectiveContainerWidth
                        storage.addAttributes([
                            .font: mathMono,
                            .foregroundColor: theme.textNSColor,
                            .paragraphStyle: mathPara,
                            .kern: 0.0
                        ], range: mLine.lineRange)

                        if t.hasPrefix("$$") {
                            storage.addAttribute(.foregroundColor, value: theme.linkNSColor.withAlphaComponent(0.9), range: mLine.contentRange)
                        } else {
                            highlightLaTeXSource(in: storage, range: mLine.contentRange, theme: theme, dimFactor: 1.0)
                        }
                    } else {
                        let mathPara = NSMutableParagraphStyle()
                        mathPara.alignment = .center
                        mathPara.lineSpacing = 4.0
                        mathPara.paragraphSpacing = 4.0
                        mathPara.tailIndent = effectiveContainerWidth
                        storage.addAttributes([
                            .font: theme.bodyFont(size: effectiveBaseSize),
                            .foregroundColor: NSColor.clear,
                            .paragraphStyle: mathPara,
                            .kern: 0.0
                        ], range: mLine.lineRange)
                    }
                }

                let combinedLatex = latexParts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                if !isMathBlockActive && !combinedLatex.isEmpty {
                    decorations.append(LineDecoration(
                        lineRange: fullBlockRange,
                        kind: .mathBlockRendered(latex: combinedLatex, fullBlockRange: fullBlockRange, dimFactor: blockDim)
                    ))
                }

                index = scanIndex
                lineNumber += scanLineCount
                continue
            }

            // 3. Check Horizontal Rule (--- / *** / ___)
            if contentRange.length >= 3,
               hrRegex.firstMatch(in: string, options: [], range: contentRange) != nil {
                previousListTextIndent = nil
                decorations.append(LineDecoration(lineRange: lineRange, kind: .horizontalRule))
                let hrPara = NSMutableParagraphStyle()
                hrPara.minimumLineHeight = 28.0
                hrPara.maximumLineHeight = 28.0
                hrPara.paragraphSpacingBefore = 6.0 * typography.headingSpacingScale
                hrPara.paragraphSpacing = 6.0 * typography.headingSpacingScale
                hrPara.tailIndent = effectiveContainerWidth
                storage.addAttribute(.paragraphStyle, value: hrPara, range: lineRange)
                styleSyntaxToken(
                    in: storage,
                    range: contentRange,
                    isActiveLine: isActiveLine,
                    theme: theme,
                    dimFactor: dimFactor
                )
                index = NSMaxRange(lineRange)
                lineNumber += 1
                continue
            }

            // 4. Check ATX Heading (# .. ###### with 0-3 leading spaces and optional closing #)
            if let match = headingRegex.firstMatch(in: string, options: [], range: contentRange),
               match.range(at: 3).location != NSNotFound || match.range(at: 2).length == contentRange.length - match.range(at: 1).length {
                previousListTextIndent = nil
                let leadingRange = match.range(at: 1)
                let hashesRange = match.range(at: 2)
                let spaceRange = match.range(at: 3)
                let titleRange = match.range(at: 4)
                let level = min(6, max(1, hashesRange.length))
                let titleText = titleRange.location != NSNotFound ? nsString.substring(with: titleRange) : ""

                if !titleText.isEmpty {
                    headings.append(OutlineHeading(
                        level: level,
                        title: titleText,
                        characterLocation: contentRange.location,
                        lineNumber: lineNumber
                    ))
                }

                let hFont = theme.headingFont(level: level, scale: typography.fontSizeScale)
                let hScale = typography.headingSpacingScale
                let hPara = NSMutableParagraphStyle()
                hPara.lineHeightMultiple = max(1.10, typography.lineHeightMultiple * 0.90)
                hPara.lineSpacing = max(1.5, typography.lineSpacing * 0.5)
                hPara.tailIndent = effectiveContainerWidth
                switch level {
                case 1:
                    hPara.paragraphSpacingBefore = 12.0 * hScale
                    hPara.paragraphSpacing = (typography.showHeadingUnderlines ? 14.0 : 8.0) * hScale
                case 2:
                    hPara.paragraphSpacingBefore = 10.0 * hScale
                    hPara.paragraphSpacing = (typography.showHeadingUnderlines ? 12.0 : 7.0) * hScale
                case 3:
                    hPara.paragraphSpacingBefore = 8.0 * hScale
                    hPara.paragraphSpacing = 6.0 * hScale
                default:
                    hPara.paragraphSpacingBefore = 6.0 * hScale
                    hPara.paragraphSpacing = 4.0 * hScale
                }

                storage.addAttributes([
                    .font: hFont,
                    .foregroundColor: theme.headingNSColor.withAlphaComponent(dimFactor),
                    .paragraphStyle: hPara,
                    .kern: typography.headingCharacterSpacing
                ], range: lineRange)

                let prefixEnd = spaceRange.location != NSNotFound ? NSMaxRange(spaceRange) : NSMaxRange(hashesRange)
                let prefixRange = NSRange(location: leadingRange.location, length: prefixEnd - leadingRange.location)
                styleSyntaxToken(
                    in: storage,
                    range: prefixRange,
                    isActiveLine: isActiveLine,
                    theme: theme,
                    dimFactor: dimFactor
                )

                // Collapse optional closing # sequence (e.g. `## Heading ##`)
                if titleRange.location != NSNotFound {
                    let suffixStart = NSMaxRange(titleRange)
                    let suffixLen = NSMaxRange(contentRange) - suffixStart
                    if suffixLen > 0 {
                        styleSyntaxToken(
                            in: storage,
                            range: NSRange(location: suffixStart, length: suffixLen),
                            isActiveLine: isActiveLine,
                            theme: theme,
                            dimFactor: dimFactor
                        )
                    }
                }

                if level <= 2 && typography.showHeadingUnderlines {
                    decorations.append(LineDecoration(lineRange: lineRange, kind: .headingUnderline(level: level)))
                }

                if titleRange.location != NSNotFound && titleRange.length > 0 {
                    styleInlineMarkdown(
                        in: storage,
                        string: string,
                        range: titleRange,
                        baseFont: hFont,
                        isActiveLine: isActiveLine,
                        theme: theme,
                        dimFactor: dimFactor,
                        normalizeWhitespace: !isActiveLine,
                        decorations: &decorations
                    )
                }

                index = NSMaxRange(lineRange)
                lineNumber += 1
                continue
            }

            // 5. Check Blockquote (> ...)
            if let match = blockquoteRegex.firstMatch(in: string, options: [], range: contentRange) {
                previousListTextIndent = nil
                let markerRange = match.range(at: 1)
                let bodyRange = match.range(at: 2)
                let markerText = nsString.substring(with: markerRange)
                let nestLevel = max(1, markerText.filter { $0 == ">" }.count)

                decorations.append(LineDecoration(lineRange: lineRange, kind: .blockquote(nestLevel: nestLevel)))

                let bqPara = NSMutableParagraphStyle()
                bqPara.firstLineHeadIndent = CGFloat(nestLevel) * 16.0
                bqPara.headIndent = CGFloat(nestLevel) * 16.0
                bqPara.lineHeightMultiple = typography.lineHeightMultiple
                bqPara.lineSpacing = max(1.0, typography.lineSpacing * 0.75)
                bqPara.paragraphSpacing = max(3.0, typography.paragraphSpacing * 0.45)
                bqPara.tailIndent = effectiveContainerWidth

                var bqFont = theme.bodyFont(size: effectiveBaseSize, italic: theme == .parchment || theme == .editorial)
                var bqColor = theme.blockquoteTextNSColor.withAlphaComponent(dimFactor)
                var inlineRange = bodyRange

                // Support ATX headings nested inside blockquotes (e.g. `> ### Note`)
                if bodyRange.length > 0,
                   let innerHeading = headingRegex.firstMatch(in: string, options: [], range: bodyRange),
                   innerHeading.range(at: 3).location != NSNotFound {
                    let hLevel = min(6, max(1, innerHeading.range(at: 2).length))
                    bqFont = theme.headingFont(level: hLevel, scale: typography.fontSizeScale)
                    bqColor = theme.headingNSColor.withAlphaComponent(dimFactor)
                    let innerPrefixEnd = NSMaxRange(innerHeading.range(at: 3))
                    let innerPrefixRange = NSRange(location: bodyRange.location, length: innerPrefixEnd - bodyRange.location)
                    inlineRange = innerHeading.range(at: 4)
                    storage.addAttributes([
                        .font: bqFont,
                        .foregroundColor: bqColor,
                        .paragraphStyle: bqPara,
                        .kern: typography.headingCharacterSpacing
                    ], range: lineRange)
                    styleSyntaxToken(in: storage, range: innerPrefixRange, isActiveLine: isActiveLine, theme: theme, dimFactor: dimFactor)
                } else {
                    storage.addAttributes([
                        .font: bqFont,
                        .foregroundColor: bqColor,
                        .paragraphStyle: bqPara,
                        .kern: typography.characterSpacing
                    ], range: lineRange)
                }

                styleSyntaxToken(
                    in: storage,
                    range: markerRange,
                    isActiveLine: isActiveLine,
                    theme: theme,
                    dimFactor: dimFactor
                )

                styleInlineMarkdown(
                    in: storage,
                    string: string,
                    range: inlineRange,
                    baseFont: bqFont,
                    isActiveLine: isActiveLine,
                    theme: theme,
                    dimFactor: dimFactor,
                    normalizeWhitespace: !isActiveLine,
                    decorations: &decorations
                )

                index = NSMaxRange(lineRange)
                lineNumber += 1
                continue
            }

            // 6. Check GFM Table Block (contiguous pipe-delimited rows)
            if isTableCandidateLine(nsString: nsString, contentRange: contentRange) {
                var tableRows: [(lineRange: NSRange, contentRange: NSRange, isActive: Bool, isSeparator: Bool)] = []
                var scanIndex = index
                var scanLines = 0

                while scanIndex < fullLength {
                    let nextLR = nsString.lineRange(for: NSRange(location: scanIndex, length: 0))
                    let nextCR = strippedLineContentRange(nsString: nsString, lineRange: nextLR)
                    guard nextCR.length > 0,
                          isTableCandidateLine(nsString: nsString, contentRange: nextCR) else {
                        break
                    }
                    let nextActive = isLineActive(lineRange: nextLR, activeLineRange: activeLineRange, selectedRange: selectedRange)
                    let nextSep = isTableSeparatorRow(nsString: nsString, contentRange: nextCR)
                    tableRows.append((nextLR, nextCR, nextActive, nextSep))
                    scanIndex = NSMaxRange(nextLR)
                    scanLines += 1
                }

                let hasValidTableStructure = tableRows.count >= 2 && tableRows.contains(where: { $0.isSeparator })
                    || (tableRows.count == 1 && nsString.substring(with: tableRows[0].contentRange).trimmingCharacters(in: .whitespaces).hasPrefix("|"))

                if hasValidTableStructure {
                    previousListTextIndent = nil
                    styleTableBlock(
                        rows: tableRows,
                        in: storage,
                        string: string,
                        nsString: nsString,
                        theme: theme,
                        typography: typography,
                        containerWidth: effectiveContainerWidth,
                        focusMode: focusMode,
                        decorations: &decorations
                    )

                    index = scanIndex
                    lineNumber += scanLines
                    continue
                }
            }

            // 7. Check Task List (- [ ] / - [x] / 1. [x])
            if let match = taskListRegex.firstMatch(in: string, options: [], range: contentRange) {
                let leadingWSRange = match.range(at: 1)
                let markerRange = match.range(at: 2)
                let spaceAfterMarkerRange = match.range(at: 3)
                let boxRange = match.range(at: 4)
                let spaceAfterBoxRange = match.range(at: 5)
                let textRange = match.range(at: 6)
                let boxStr = nsString.substring(with: boxRange).lowercased()
                let isChecked = boxStr == "[x]"

                let indentCols = indentationColumnCount(nsString: nsString, range: leadingWSRange)
                let nestLevel = indentCols / 2
                let baseIndent: CGFloat = 10.0 + CGFloat(nestLevel) * 18.0
                let textIndent: CGFloat = baseIndent + 26.0
                previousListTextIndent = textIndent

                let listPara = NSMutableParagraphStyle()
                listPara.firstLineHeadIndent = isActiveLine ? 0.0 : baseIndent
                listPara.headIndent = textIndent
                listPara.lineHeightMultiple = typography.lineHeightMultiple
                listPara.lineSpacing = max(1.0, typography.lineSpacing * 0.70)
                listPara.paragraphSpacing = max(2.5, typography.paragraphSpacing * 0.35)
                listPara.tailIndent = effectiveContainerWidth
                storage.addAttribute(.paragraphStyle, value: listPara, range: lineRange)

                let bulletPrefixRange = NSRange(
                    location: leadingWSRange.location,
                    length: NSMaxRange(spaceAfterMarkerRange) - leadingWSRange.location
                )
                styleSyntaxToken(
                    in: storage,
                    range: bulletPrefixRange,
                    isActiveLine: isActiveLine,
                    theme: theme,
                    dimFactor: dimFactor
                )

                let boxFont = NSFont.monospacedSystemFont(ofSize: effectiveBaseSize * 0.92, weight: .bold)
                storage.addAttributes([
                    .font: boxFont,
                    .foregroundColor: (isChecked ? theme.linkNSColor : theme.secondaryTextNSColor).withAlphaComponent(dimFactor),
                    .kern: 0.0
                ], range: boxRange)

                if !isActiveLine && spaceAfterBoxRange.length > 0 {
                    let boxW = (nsString.substring(with: boxRange) as NSString).size(withAttributes: [.font: boxFont]).width
                    let desiredGap = max(4.0, (textIndent - baseIndent) - boxW)
                    collapseWhitespaceRange(in: storage, range: spaceAfterBoxRange)
                    storage.addAttribute(.kern, value: desiredGap, range: NSRange(location: spaceAfterBoxRange.location, length: 1))
                } else {
                    _ = markerRange
                }

                if isChecked {
                    storage.addAttributes([
                        .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                        .foregroundColor: theme.secondaryTextNSColor.withAlphaComponent(0.75 * dimFactor)
                    ], range: textRange)
                } else if dimFactor < 1.0 {
                    storage.addAttribute(.foregroundColor, value: baseColor.withAlphaComponent(dimFactor), range: textRange)
                }

                styleInlineMarkdown(
                    in: storage,
                    string: string,
                    range: textRange,
                    baseFont: baseFont,
                    isActiveLine: isActiveLine,
                    theme: theme,
                    dimFactor: dimFactor,
                    normalizeWhitespace: !isActiveLine,
                    decorations: &decorations
                )

                index = NSMaxRange(lineRange)
                lineNumber += 1
                continue
            }

            // 8. Check Unordered / Ordered Lists
            if let match = unorderedListRegex.firstMatch(in: string, options: [], range: contentRange) ??
                orderedListRegex.firstMatch(in: string, options: [], range: contentRange) {
                let leadingWSRange = match.range(at: 1)
                let markerSymbolRange = match.range(at: 2)
                let postMarkerWSRange = match.range(at: 3)
                let bodyRange = match.range(at: 4)

                let indentCols = indentationColumnCount(nsString: nsString, range: leadingWSRange)
                let nestLevel = indentCols / 2
                let isOrdered = orderedListRegex.firstMatch(in: string, options: [], range: contentRange) != nil
                let baseIndent: CGFloat = 10.0 + CGFloat(nestLevel) * 18.0
                let markerAdvance: CGFloat = isOrdered ? 22.0 : 16.0
                let textIndent: CGFloat = baseIndent + markerAdvance
                previousListTextIndent = textIndent

                let listPara = NSMutableParagraphStyle()
                listPara.firstLineHeadIndent = isActiveLine ? 0.0 : baseIndent
                listPara.headIndent = textIndent
                listPara.lineHeightMultiple = typography.lineHeightMultiple
                listPara.lineSpacing = max(1.0, typography.lineSpacing * 0.70)
                listPara.paragraphSpacing = max(2.5, typography.paragraphSpacing * 0.35)
                listPara.tailIndent = effectiveContainerWidth
                storage.addAttribute(.paragraphStyle, value: listPara, range: lineRange)

                let markerFont = theme.bodyFont(size: effectiveBaseSize, bold: true)
                storage.addAttributes([
                    .font: markerFont,
                    .foregroundColor: theme.linkNSColor.withAlphaComponent(dimFactor),
                    .kern: 0.0
                ], range: markerSymbolRange)

                if !isActiveLine {
                    if leadingWSRange.length > 0 {
                        collapseWhitespaceRange(in: storage, range: leadingWSRange)
                    }
                    if postMarkerWSRange.length > 0 {
                        let markerStr = nsString.substring(with: markerSymbolRange) as NSString
                        let markerW = markerStr.size(withAttributes: [.font: markerFont]).width
                        let desiredGap = max(4.0, markerAdvance - markerW)
                        collapseWhitespaceRange(in: storage, range: postMarkerWSRange)
                        storage.addAttribute(.kern, value: desiredGap, range: NSRange(location: postMarkerWSRange.location, length: 1))
                    }
                } else {
                    storage.addAttributes([
                        .font: markerFont,
                        .foregroundColor: theme.linkNSColor.withAlphaComponent(dimFactor)
                    ], range: NSRange(location: leadingWSRange.location, length: NSMaxRange(postMarkerWSRange) - leadingWSRange.location))
                }

                if dimFactor < 1.0 {
                    storage.addAttribute(.foregroundColor, value: baseColor.withAlphaComponent(dimFactor), range: bodyRange)
                }

                styleInlineMarkdown(
                    in: storage,
                    string: string,
                    range: bodyRange,
                    baseFont: baseFont,
                    isActiveLine: isActiveLine,
                    theme: theme,
                    dimFactor: dimFactor,
                    normalizeWhitespace: !isActiveLine,
                    decorations: &decorations
                )

                index = NSMaxRange(lineRange)
                lineNumber += 1
                continue
            }

            // 9. Check Setext Heading (current paragraph line followed immediately by `===` or `---` underline)
            let nextLineStart = NSMaxRange(lineRange)
            if nextLineStart < fullLength {
                let nextLR = nsString.lineRange(for: NSRange(location: nextLineStart, length: 0))
                let nextCR = strippedLineContentRange(nsString: nsString, lineRange: nextLR)
                if nextCR.length > 0 {
                    let isSetextH1 = setextH1Regex.firstMatch(in: string, options: [], range: nextCR) != nil
                    let isSetextH2 = !isSetextH1 && setextH2Regex.firstMatch(in: string, options: [], range: nextCR) != nil
                    if isSetextH1 || isSetextH2 {
                        previousListTextIndent = nil
                        let level = isSetextH1 ? 1 : 2
                        let nextActive = isLineActive(lineRange: nextLR, activeLineRange: activeLineRange, selectedRange: selectedRange)
                        let combinedActive = isActiveLine || nextActive
                        let setextDim: CGFloat = (focusMode && !combinedActive) ? 0.30 : 1.0

                        let titleText = trimmedLine
                        if !titleText.isEmpty {
                            headings.append(OutlineHeading(
                                level: level,
                                title: titleText,
                                characterLocation: contentRange.location,
                                lineNumber: lineNumber
                            ))
                        }

                        let hFont = theme.headingFont(level: level, scale: typography.fontSizeScale)
                        let hScale = typography.headingSpacingScale
                        let hPara = NSMutableParagraphStyle()
                        hPara.lineHeightMultiple = max(1.10, typography.lineHeightMultiple * 0.90)
                        hPara.lineSpacing = max(1.5, typography.lineSpacing * 0.5)
                        hPara.paragraphSpacingBefore = (level == 1 ? 12.0 : 10.0) * hScale
                        hPara.paragraphSpacing = (typography.showHeadingUnderlines ? (level == 1 ? 14.0 : 12.0) : 8.0) * hScale
                        hPara.tailIndent = effectiveContainerWidth

                        storage.addAttributes([
                            .font: hFont,
                            .foregroundColor: theme.headingNSColor.withAlphaComponent(setextDim),
                            .paragraphStyle: hPara,
                            .kern: typography.headingCharacterSpacing
                        ], range: lineRange)

                        if typography.showHeadingUnderlines {
                            decorations.append(LineDecoration(lineRange: lineRange, kind: .headingUnderline(level: level)))
                        }

                        styleInlineMarkdown(
                            in: storage,
                            string: string,
                            range: contentRange,
                            baseFont: hFont,
                            isActiveLine: combinedActive,
                            theme: theme,
                            dimFactor: setextDim,
                            normalizeWhitespace: !combinedActive,
                            decorations: &decorations
                        )

                        // Style or collapse the Setext underline row
                        let underlinePara = NSMutableParagraphStyle()
                        underlinePara.lineSpacing = 0.0
                        underlinePara.paragraphSpacing = 0.0
                        underlinePara.paragraphSpacingBefore = 0.0
                        underlinePara.minimumLineHeight = combinedActive ? 20.0 : 1.0
                        underlinePara.maximumLineHeight = combinedActive ? 20.0 : 1.0
                        underlinePara.tailIndent = effectiveContainerWidth
                        storage.addAttribute(.paragraphStyle, value: underlinePara, range: nextLR)
                        styleSyntaxToken(in: storage, range: nextCR, isActiveLine: combinedActive, theme: theme, dimFactor: setextDim)

                        index = NSMaxRange(nextLR)
                        lineNumber += 2
                        continue
                    }
                }
            }

            // 10b. CommonMark Link Reference Definition ([label]: url "title")
            if previousListTextIndent == nil,
               let refDefMatch = linkRefDefRegex.firstMatch(in: string, options: [], range: contentRange) {
                let labelRange = refDefMatch.range(at: 1)
                let destRange = refDefMatch.range(at: 2)
                let prefixLen = (labelRange.location - contentRange.location) + labelRange.length + 2 // includes `]:`
                let prefixRange = NSRange(location: contentRange.location, length: min(contentRange.length, prefixLen))

                storage.addAttributes([
                    .font: theme.codeFont(size: max(11.0, effectiveBaseSize * 0.86)),
                    .foregroundColor: theme.markdownTokenNSColor.withAlphaComponent((isActiveLine ? 0.90 : 0.65) * dimFactor)
                ], range: prefixRange)
                storage.addAttributes([
                    .font: theme.codeFont(size: max(11.0, effectiveBaseSize * 0.86)),
                    .foregroundColor: theme.linkNSColor.withAlphaComponent((isActiveLine ? 0.95 : 0.75) * dimFactor),
                    .underlineStyle: NSUnderlineStyle.single.rawValue
                ], range: destRange)

                index = NSMaxRange(lineRange)
                lineNumber += 1
                continue
            }

            // Default paragraph line (or indented list continuation line)
            if let listIndent = previousListTextIndent,
               let leadMatch = leadingSpaceRegex.firstMatch(in: string, options: [], range: contentRange),
               indentationColumnCount(nsString: nsString, range: leadMatch.range) >= 2 {
                let contPara = NSMutableParagraphStyle()
                contPara.firstLineHeadIndent = isActiveLine ? 0.0 : listIndent
                contPara.headIndent = listIndent
                contPara.lineHeightMultiple = typography.lineHeightMultiple
                contPara.lineSpacing = max(1.0, typography.lineSpacing * 0.70)
                contPara.paragraphSpacing = max(2.5, typography.paragraphSpacing * 0.35)
                contPara.tailIndent = effectiveContainerWidth
                storage.addAttribute(.paragraphStyle, value: contPara, range: lineRange)
            } else {
                previousListTextIndent = nil
            }

            if dimFactor < 1.0 {
                storage.addAttribute(.foregroundColor, value: baseColor.withAlphaComponent(dimFactor), range: contentRange)
            }

            styleInlineMarkdown(
                in: storage,
                string: string,
                range: contentRange,
                baseFont: baseFont,
                isActiveLine: isActiveLine,
                theme: theme,
                dimFactor: dimFactor,
                normalizeWhitespace: !isActiveLine,
                decorations: &decorations
            )

            index = NSMaxRange(lineRange)
            lineNumber += 1
        }

        // Apply cmark-gfm AST-resolved reference links ([text][ref], [text][], [text])
        // and GFM extended autolinks (www.example.com, https://...)
        if !astLinksByLine.isEmpty {
            for (ln, links) in astLinksByLine {
                guard let rec = lineRecords[ln] else { continue }
                let utf8 = rec.lineText.utf8
                for link in links {
                    let startByte = max(0, link.startColumn - 1)
                    let endByte = min(utf8.count, link.endColumn)
                    guard endByte > startByte,
                          let startIdx = utf8.index(utf8.startIndex, offsetBy: startByte, limitedBy: utf8.endIndex),
                          let endIdx = utf8.index(utf8.startIndex, offsetBy: endByte, limitedBy: utf8.endIndex) else {
                        continue
                    }
                    let localNSRange = NSRange(startIdx..<endIdx, in: rec.lineText)
                    let docRange = NSRange(location: rec.contentRange.location + localNSRange.location, length: localNSRange.length)
                    guard NSMaxRange(docRange) <= fullLength, docRange.length > 0 else { continue }

                    let spanText = String(rec.lineText[startIdx..<endIdx])
                    if spanText.hasPrefix("[") || spanText.hasPrefix("![") {
                        let isImg = spanText.hasPrefix("![")
                        let openLen = isImg ? 2 : 1
                        let spanNS = spanText as NSString
                        var scan = openLen
                        var depth = 1
                        var closeBracketOffset: Int? = nil
                        while scan < spanNS.length {
                            let c = spanNS.character(at: scan)
                            if c == 0x5C { // backslash escape
                                scan += 2
                                continue
                            } else if c == 0x5B {
                                depth += 1
                            } else if c == 0x5D {
                                depth -= 1
                                if depth == 0 {
                                    closeBracketOffset = scan
                                    break
                                }
                            }
                            scan += 1
                        }
                        guard let closeBracket = closeBracketOffset, closeBracket >= openLen else { continue }
                        // Inline `[label](url)` links were already styled by scanMarkdownLinks
                        if closeBracket + 1 < spanNS.length && spanNS.character(at: closeBracket + 1) == 0x28 {
                            continue
                        }
                        let openSyntaxRange = NSRange(location: docRange.location, length: openLen)
                        let labelRange = NSRange(location: docRange.location + openLen, length: closeBracket - openLen)
                        let trailingSyntaxRange = NSRange(
                            location: docRange.location + closeBracket,
                            length: docRange.length - closeBracket
                        )
                        applyAttributesToVisibleCharacters(
                            in: storage,
                            range: labelRange,
                            attributes: [
                                .foregroundColor: theme.linkNSColor.withAlphaComponent(rec.dimFactor),
                                .underlineStyle: NSUnderlineStyle.single.rawValue
                            ]
                        )
                        styleSyntaxToken(in: storage, range: openSyntaxRange, isActiveLine: rec.isActive, theme: theme, dimFactor: rec.dimFactor)
                        styleSyntaxToken(in: storage, range: trailingSyntaxRange, isActiveLine: rec.isActive, theme: theme, dimFactor: rec.dimFactor)
                    } else if !spanText.hasPrefix("<") {
                        // GFM extended bare autolink (e.g. www.example.com, https://example.com)
                        applyAttributesToVisibleCharacters(
                            in: storage,
                            range: docRange,
                            attributes: [
                                .foregroundColor: theme.linkNSColor.withAlphaComponent(rec.dimFactor),
                                .underlineStyle: NSUnderlineStyle.single.rawValue
                            ]
                        )
                    }
                }
            }
        }

        storage.endEditing()
        return MarkdownDocumentAnalysis(headings: headings, decorations: decorations)
    }

    // MARK: - Helpers for Line Ranges & Indentation
    private static func strippedLineContentRange(nsString: NSString, lineRange: NSRange) -> NSRange {
        var contentRange = lineRange
        while contentRange.length > 0 {
            let lastChar = nsString.character(at: contentRange.location + contentRange.length - 1)
            if lastChar == 10 || lastChar == 13 {
                contentRange.length -= 1
            } else {
                break
            }
        }
        return contentRange
    }

    private static func isLineActive(lineRange: NSRange, activeLineRange: NSRange, selectedRange: NSRange) -> Bool {
        return NSIntersectionRange(lineRange, activeLineRange).length > 0 ||
            (selectedRange.location == lineRange.location + lineRange.length && lineRange.location == activeLineRange.location)
    }

    private static func indentationColumnCount(nsString: NSString, range: NSRange) -> Int {
        var cols = 0
        let end = NSMaxRange(range)
        var i = range.location
        while i < end {
            let ch = nsString.character(at: i)
            if ch == 9 { // tab
                cols += 4 - (cols % 4)
            } else if ch == 32 {
                cols += 1
            }
            i += 1
        }
        return cols
    }

    // MARK: - Table Block Layout & Column Alignment
    private struct ParsedTableCell {
        let leadingDelimiterRange: NSRange // pipe (if any) + leading spaces before cell content
        let contentRange: NSRange          // trimmed cell text
        let trailingSpacesRange: NSRange   // trailing spaces before the next pipe
    }

    private struct ParsedTableRow {
        let cells: [ParsedTableCell]
        let closingPipeRange: NSRange
    }

    /// Scans `contentRange` for unescaped, unprotected `|` pipe locations (ignoring pipes inside `` `code` `` or `$math$`).
    private static func scanUnprotectedTablePipes(nsString: NSString, contentRange: NSRange) -> [Int] {
        var pipes: [Int] = []
        let endLoc = NSMaxRange(contentRange)
        var idx = contentRange.location
        var failedTickLengths = Set<Int>()
        var noClosingDollar = false

        while idx < endLoc {
            let ch = nsString.character(at: idx)
            if ch == 0x5C { // '\' escape
                idx += 2
                continue
            }
            if ch == 0x60 { // '`' inline code span
                var tickCount = 0
                while idx + tickCount < endLoc && nsString.character(at: idx + tickCount) == 0x60 {
                    tickCount += 1
                }
                if failedTickLengths.contains(tickCount) {
                    idx += tickCount
                    continue
                }
                var searchIdx = idx + tickCount
                var foundClose = false
                while searchIdx < endLoc {
                    if nsString.character(at: searchIdx) == 0x60 {
                        var closeTicks = 0
                        while searchIdx + closeTicks < endLoc && nsString.character(at: searchIdx + closeTicks) == 0x60 {
                            closeTicks += 1
                        }
                        if closeTicks == tickCount {
                            idx = searchIdx + closeTicks
                            foundClose = true
                            break
                        }
                        searchIdx += closeTicks
                    } else {
                        searchIdx += 1
                    }
                }
                if !foundClose {
                    failedTickLengths.insert(tickCount)
                    idx += tickCount
                }
                continue
            }
            if ch == 0x24 && !noClosingDollar { // '$' inline math span
                if idx + 1 < endLoc && nsString.character(at: idx + 1) != 0x24 {
                    var searchIdx = idx + 1
                    var foundClose = false
                    while searchIdx < endLoc {
                        let mCh = nsString.character(at: searchIdx)
                        if mCh == 0x5C {
                            searchIdx += 2
                            continue
                        }
                        if mCh == 0x24 {
                            idx = searchIdx + 1
                            foundClose = true
                            break
                        }
                        searchIdx += 1
                    }
                    if !foundClose {
                        noClosingDollar = true
                        idx += 1
                    }
                    continue
                }
            }
            if ch == 0x7C { // '|'
                pipes.append(idx)
            }
            idx += 1
        }
        return pipes
    }

    private static func isTableCandidateLine(nsString: NSString, contentRange: NSRange) -> Bool {
        guard contentRange.length > 0 else { return false }
        let pipes = scanUnprotectedTablePipes(nsString: nsString, contentRange: contentRange)
        return !pipes.isEmpty
    }

    private static func isTableSeparatorRow(nsString: NSString, contentRange: NSRange) -> Bool {
        guard let parsed = parseTableRowCells(nsString: nsString, contentRange: contentRange),
              !parsed.cells.isEmpty else {
            return false
        }
        for cell in parsed.cells {
            let text = nsString.substring(with: cell.contentRange).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return false }
            var slice = text[...]
            if slice.first == ":" { slice = slice.dropFirst() }
            if slice.last == ":" { slice = slice.dropLast() }
            if slice.isEmpty || !slice.allSatisfy({ $0 == "-" }) {
                return false
            }
        }
        return true
    }

    private static func parseTableRowCells(nsString: NSString, contentRange: NSRange) -> ParsedTableRow? {
        let pipeLocations = scanUnprotectedTablePipes(nsString: nsString, contentRange: contentRange)
        guard !pipeLocations.isEmpty else { return nil }

        let endLoc = NSMaxRange(contentRange)
        var firstNonWS = contentRange.location
        while firstNonWS < endLoc {
            let c = nsString.character(at: firstNonWS)
            if c == 32 || c == 9 { firstNonWS += 1 } else { break }
        }
        var lastNonWS = endLoc
        while lastNonWS > firstNonWS {
            let c = nsString.character(at: lastNonWS - 1)
            if c == 32 || c == 9 { lastNonWS -= 1 } else { break }
        }

        let hasLeadingPipe = (pipeLocations.first == firstNonWS)
        let hasTrailingPipe = (pipeLocations.last == lastNonWS - 1)

        // Build virtual boundary positions
        var boundaries: [Int] = []
        if !hasLeadingPipe {
            boundaries.append(firstNonWS - 1) // virtual pipe before first char
        }
        boundaries.append(contentsOf: pipeLocations)
        if !hasTrailingPipe {
            boundaries.append(lastNonWS) // virtual pipe at end
        }

        guard boundaries.count >= 2 else { return nil }

        var cells: [ParsedTableCell] = []
        for i in 0..<(boundaries.count - 1) {
            let pipePos = boundaries[i]
            let nextPipePos = boundaries[i + 1]

            let rawCellStart = max(contentRange.location, pipePos + 1)
            var contentStart = rawCellStart
            while contentStart < nextPipePos {
                let c = nsString.character(at: contentStart)
                if c == 32 || c == 9 { contentStart += 1 } else { break }
            }

            var contentEnd = nextPipePos
            while contentEnd > contentStart {
                let c = nsString.character(at: contentEnd - 1)
                if c == 32 || c == 9 { contentEnd -= 1 } else { break }
            }

            let startLoc = (i == 0) ? contentRange.location : pipePos
            let leadingRange = NSRange(location: startLoc, length: max(0, contentStart - startLoc))
            let cellRange = NSRange(location: contentStart, length: max(0, contentEnd - contentStart))
            let trailingRange = NSRange(location: contentEnd, length: max(0, nextPipePos - contentEnd))
            cells.append(ParsedTableCell(
                leadingDelimiterRange: leadingRange,
                contentRange: cellRange,
                trailingSpacesRange: trailingRange
            ))
        }

        let closingRange: NSRange
        if hasTrailingPipe, let lastPipe = pipeLocations.last {
            closingRange = NSRange(location: lastPipe, length: endLoc - lastPipe)
        } else {
            closingRange = NSRange(location: lastNonWS, length: endLoc - lastNonWS)
        }
        return ParsedTableRow(cells: cells, closingPipeRange: closingRange)
    }

    private static func styleTableBlock(
        rows: [(lineRange: NSRange, contentRange: NSRange, isActive: Bool, isSeparator: Bool)],
        in storage: NSTextStorage,
        string: String,
        nsString: NSString,
        theme: EditorTheme,
        typography: EditorTypographySettings,
        containerWidth: CGFloat,
        focusMode: Bool,
        decorations: inout [LineDecoration]
    ) {
        guard !rows.isEmpty else { return }

        let effectiveBaseSize = theme.baseFontSize * typography.fontSizeScale
        let parsedRows: [ParsedTableRow?] = rows.map { parseTableRowCells(nsString: nsString, contentRange: $0.contentRange) }
        let numCols = max(1, parsedRows.compactMap({ $0?.cells.count }).max() ?? 1)

        // Extract column alignments from separator row if present
        var alignments = Array(repeating: TableColumnAlignment.left, count: numCols)
        for (rIdx, row) in rows.enumerated() where row.isSeparator {
            if let parsed = parsedRows[rIdx] {
                for (cIdx, cell) in parsed.cells.enumerated() where cIdx < numCols {
                    let spec = nsString.substring(with: cell.contentRange).trimmingCharacters(in: .whitespaces)
                    if spec.hasPrefix(":") && spec.hasSuffix(":") {
                        alignments[cIdx] = .center
                    } else if spec.hasSuffix(":") {
                        alignments[cIdx] = .right
                    } else {
                        alignments[cIdx] = .left
                    }
                }
            }
        }

        // First pass: style text & inline Markdown inside each row and measure natural cell widths
        var measuredWidths: [[CGFloat]] = Array(repeating: Array(repeating: 0, count: numCols), count: rows.count)
        var maxActiveRowWidth: CGFloat = 0
        var inlineTableDecorations: [LineDecoration] = []

        for (rIdx, row) in rows.enumerated() {
            let dimFactor: CGFloat = (focusMode && !row.isActive) ? 0.30 : 1.0
            let isHeader = (rIdx == 0)

            if row.isSeparator {
                if row.isActive {
                    let activeMono = theme.codeFont(size: effectiveBaseSize * 0.88)
                    let activeRowHeight: CGFloat = 26.0
                    let activePara = NSMutableParagraphStyle()
                    activePara.lineSpacing = 0.0
                    activePara.paragraphSpacing = 0.0
                    activePara.minimumLineHeight = activeRowHeight
                    activePara.maximumLineHeight = activeRowHeight
                    activePara.lineBreakMode = .byClipping
                    activePara.tailIndent = 0.0
                    let naturalH = activeMono.ascender + abs(activeMono.descender)
                    let shift = max(0.0, floor((activeRowHeight - naturalH) * 0.5))
                    storage.addAttributes([
                        .font: activeMono,
                        .foregroundColor: theme.markdownTokenNSColor.withAlphaComponent(0.9 * dimFactor),
                        .paragraphStyle: activePara,
                        .baselineOffset: shift,
                        .kern: 0.0
                    ], range: row.lineRange)
                    let activeW = ceil(storage.attributedSubstring(from: row.contentRange).size().width) + 28.0
                    maxActiveRowWidth = max(maxActiveRowWidth, activeW)
                } else {
                    // Collapse separator row on inactive line into a clean hairline
                    let collapsedPara = NSMutableParagraphStyle()
                    collapsedPara.minimumLineHeight = 2.0
                    collapsedPara.maximumLineHeight = 2.0
                    collapsedPara.lineSpacing = 0.0
                    collapsedPara.paragraphSpacing = 0.0
                    collapsedPara.lineBreakMode = .byClipping
                    collapsedPara.tailIndent = 0.0
                    storage.addAttributes([
                        .font: NSFont.systemFont(ofSize: 0.001),
                        .foregroundColor: NSColor.clear,
                        .paragraphStyle: collapsedPara,
                        .baselineOffset: 0.0,
                        .kern: 0.0,
                        collapsedTokenAttributeKey: true
                    ], range: row.lineRange)
                }
                continue
            }

            let cellFont: NSFont
            if row.isActive {
                cellFont = theme.codeFont(size: effectiveBaseSize * 0.90)
            } else {
                cellFont = theme.bodyFont(size: effectiveBaseSize * 0.93, bold: isHeader)
            }

            let rowHeight: CGFloat = 32.0
            let rowPara = NSMutableParagraphStyle()
            rowPara.lineSpacing = 0.0
            rowPara.paragraphSpacing = (rIdx == rows.count - 1) ? max(4.0, typography.paragraphSpacing * 0.55) : 0.0
            rowPara.minimumLineHeight = rowHeight
            rowPara.maximumLineHeight = rowHeight
            rowPara.lineBreakMode = .byClipping
            rowPara.tailIndent = 0.0

            let naturalFontHeight = cellFont.ascender + abs(cellFont.descender)
            let baselineShift = max(0.0, floor((rowHeight - naturalFontHeight) * 0.5))

            storage.addAttributes([
                .font: cellFont,
                .foregroundColor: (isHeader ? theme.headingNSColor : theme.textNSColor).withAlphaComponent(dimFactor),
                .paragraphStyle: rowPara,
                .baselineOffset: baselineShift,
                .kern: 0.0
            ], range: row.lineRange)

            guard let parsed = parsedRows[rIdx] else { continue }

            for (cIdx, cell) in parsed.cells.enumerated() where cIdx < numCols {
                if cell.contentRange.length > 0 {
                    styleInlineMarkdown(
                        in: storage,
                        string: string,
                        range: cell.contentRange,
                        baseFont: cellFont,
                        isActiveLine: row.isActive,
                        theme: theme,
                        dimFactor: dimFactor,
                        normalizeWhitespace: !row.isActive,
                        decorations: &inlineTableDecorations
                    )
                    let cellAttr = storage.attributedSubstring(from: cell.contentRange)
                    measuredWidths[rIdx][cIdx] = ceil(cellAttr.size().width) + 4.0
                }
            }

            if row.isActive {
                // Highlight pipe delimiters in muted token color when editing the row
                for cell in parsed.cells where cell.leadingDelimiterRange.length > 0 {
                    let firstChar = nsString.character(at: cell.leadingDelimiterRange.location)
                    if firstChar == 0x7C {
                        let pipeRange = NSRange(location: cell.leadingDelimiterRange.location, length: 1)
                        storage.addAttribute(.foregroundColor, value: theme.markdownTokenNSColor.withAlphaComponent(0.85), range: pipeRange)
                    }
                }
                if parsed.closingPipeRange.length > 0 {
                    storage.addAttribute(.foregroundColor, value: theme.markdownTokenNSColor.withAlphaComponent(0.85), range: parsed.closingPipeRange)
                }
                let activeW = ceil(storage.attributedSubstring(from: row.contentRange).size().width) + 28.0
                maxActiveRowWidth = max(maxActiveRowWidth, activeW)
            }
        }

        // Compute column widths and column start X coordinates.
        // IMPORTANT: Never shrink columns below their natural content width! Wide tables extend beyond containerWidth and scroll horizontally.
        let cellHorizontalPadding: CGFloat = 16.0
        var colWidths: [CGFloat] = (0..<numCols).map { cIdx in
            let maxCellW = (0..<rows.count).map({ measuredWidths[$0][cIdx] }).max() ?? 40.0
            return max(64.0, maxCellW + cellHorizontalPadding * 2.0)
        }

        let naturalSum = colWidths.reduce(0, +)
        if naturalSum > 0 && naturalSum < containerWidth {
            let extra = containerWidth - naturalSum
            let perCol = floor(extra / CGFloat(numCols))
            colWidths = colWidths.map { $0 + perCol }
            let expandedSum = colWidths.reduce(0, +)
            if numCols > 0 && expandedSum < containerWidth {
                colWidths[numCols - 1] += (containerWidth - expandedSum)
            }
        }

        var colStartX: [CGFloat] = Array(repeating: 0, count: numCols)
        var runningX: CGFloat = 0
        for cIdx in 0..<numCols {
            colStartX[cIdx] = runningX
            runningX += colWidths[cIdx]
        }
        let totalTableWidth = max(runningX, maxActiveRowWidth)
        let tableOffsetX: CGFloat = 0.0
        let columnDividerX = Array(colStartX.dropFirst())

        // Second pass: apply exact .kern alignment to inactive non-separator rows and emit decorations
        var bodyCounter = 0
        for (rIdx, row) in rows.enumerated() {
            let isHeader = (rIdx == 0)
            let isFirst = (rIdx == 0)
            let isLast = (rIdx == rows.count - 1)
            let currentBodyIdx = (!isHeader && !row.isSeparator) ? bodyCounter : 0
            if !isHeader && !row.isSeparator {
                bodyCounter += 1
            }

            decorations.append(LineDecoration(
                lineRange: row.lineRange,
                kind: .tableRow(
                    isHeader: isHeader,
                    isSeparator: row.isSeparator,
                    isFirstRow: isFirst,
                    isLastRow: isLast,
                    bodyRowIndex: currentBodyIdx,
                    tableOffsetX: tableOffsetX,
                    tableWidth: totalTableWidth,
                    columnDividers: columnDividerX
                )
            ))

            guard !row.isActive, !row.isSeparator, let parsed = parsedRows[rIdx] else { continue }

            // Hide closing pipe
            if parsed.closingPipeRange.length > 0 {
                collapseWhitespaceRange(in: storage, range: parsed.closingPipeRange)
            }

            var currentCursorX: CGFloat = 0.0

            for (cIdx, cell) in parsed.cells.enumerated() where cIdx < numCols {
                // Hide leading delimiter (pipe + spaces) and trailing spaces
                if cell.leadingDelimiterRange.length > 0 {
                    collapseWhitespaceRange(in: storage, range: cell.leadingDelimiterRange)
                }

                if cell.trailingSpacesRange.length > 0 {
                    collapseWhitespaceRange(in: storage, range: cell.trailingSpacesRange)
                }

                let actualCellW = cell.contentRange.length > 0
                    ? ceil(storage.attributedSubstring(from: cell.contentRange).size().width)
                    : 0.0
                let colW = colWidths[cIdx]
                let alignOffset: CGFloat
                switch alignments[cIdx] {
                case .left:
                    alignOffset = cellHorizontalPadding
                case .center:
                    alignOffset = max(cellHorizontalPadding, floor((colW - actualCellW) * 0.5))
                case .right:
                    alignOffset = max(cellHorizontalPadding, colW - actualCellW - cellHorizontalPadding)
                }

                let targetCellStartX = tableOffsetX + colStartX[cIdx] + alignOffset
                let deltaKern = max(1.0, targetCellStartX - currentCursorX)

                if cell.leadingDelimiterRange.length > 0 {
                    let anchorRange = NSRange(location: cell.leadingDelimiterRange.location, length: 1)
                    storage.addAttribute(.kern, value: deltaKern, range: anchorRange)
                    currentCursorX = targetCellStartX + actualCellW
                } else if cell.contentRange.length > 0 {
                    let firstLineIndent = max(0.0, targetCellStartX)
                    if let existingPara = storage.attribute(.paragraphStyle, at: row.lineRange.location, effectiveRange: nil) as? NSParagraphStyle,
                       let mutablePara = existingPara.mutableCopy() as? NSMutableParagraphStyle {
                        mutablePara.firstLineHeadIndent = firstLineIndent
                        mutablePara.headIndent = firstLineIndent
                        storage.addAttribute(.paragraphStyle, value: mutablePara, range: row.lineRange)
                    }
                    currentCursorX = targetCellStartX + actualCellW
                }
            }
        }

        // Append inline decorations (inline code pills, inline math) after tableRow backgrounds so they render on top
        decorations.append(contentsOf: inlineTableDecorations)
    }

    // MARK: - Inline Markdown Styling
    private static func styleInlineMarkdown(
        in storage: NSTextStorage,
        string: String,
        range: NSRange,
        baseFont: NSFont,
        isActiveLine: Bool,
        theme: EditorTheme,
        dimFactor: CGFloat,
        normalizeWhitespace: Bool = false,
        decorations: inout [LineDecoration]
    ) {
        guard range.length > 0 else { return }
        let nsString = string as NSString
        let fontSize = baseFont.pointSize

        // Ranges inside inline code or inline math are completely opaque to other inline syntax
        var codeAndMathRanges: [NSRange] = []
        // Ranges of escaped characters or link URL destinations `(url)` cannot act as emphasis delimiters
        var protectedDelimiterRanges: [NSRange] = []

        let isInCodeOrMath: (NSRange) -> Bool = { r in
            codeAndMathRanges.contains { NSIntersectionRange($0, r).length > 0 }
        }
        let isDelimiterProtected: (NSRange) -> Bool = { r in
            isInCodeOrMath(r) || protectedDelimiterRanges.contains { NSIntersectionRange($0, r).length > 0 }
        }

        // 1. Inline Code (`code` or `` ` ``) - highest precedence in CommonMark (even `\` inside code is literal)
        for codeSpan in scanInlineCodeSpans(nsString: nsString, range: range) {
            let fullMatchRange = codeSpan.fullRange
            codeAndMathRanges.append(fullMatchRange)

            var openRange = codeSpan.openRange
            var innerRange = codeSpan.innerRange
            var closeRange = codeSpan.closeRange

            // CommonMark rule: if code span has a leading AND trailing space (and is not all spaces), strip one space from each end
            if innerRange.length >= 2 {
                let firstChar = nsString.character(at: innerRange.location)
                let lastChar = nsString.character(at: NSMaxRange(innerRange) - 1)
                let innerSub = nsString.substring(with: innerRange)
                if firstChar == 32 && lastChar == 32 && innerSub.contains(where: { $0 != " " }) {
                    openRange.length += 1
                    innerRange.location += 1
                    innerRange.length -= 2
                    closeRange.location -= 1
                    closeRange.length += 1
                }
            }

            let codeFontSize = fontSize * 0.88
            let codeFont = theme.codeFont(size: codeFontSize)
            storage.addAttributes([
                .font: codeFont,
                .foregroundColor: theme.inlineCodeNSColor.withAlphaComponent(dimFactor),
                inlineCodeFontAttributeKey: true
            ], range: innerRange)
            decorations.append(LineDecoration(
                lineRange: innerRange,
                kind: .inlineCode(range: innerRange, fontSize: codeFontSize, dimFactor: dimFactor)
            ))
            styleSyntaxToken(in: storage, range: openRange, isActiveLine: isActiveLine, theme: theme, dimFactor: dimFactor)
            styleSyntaxToken(in: storage, range: closeRange, isActiveLine: isActiveLine, theme: theme, dimFactor: dimFactor)
        }

        // 2. Inline Math ($E = mc^2$)
        inlineMathRegex.enumerateMatches(in: string, options: [], range: range) { match, _, _ in
            guard let match = match else { return }
            let fullMatchRange = match.range(at: 0)
            if isInCodeOrMath(fullMatchRange) {
                return
            }
            codeAndMathRanges.append(fullMatchRange)

            let openRange = match.range(at: 1)
            let innerRange = match.range(at: 2)
            let closeRange = match.range(at: 3)
            let latexStr = nsString.substring(with: innerRange)

            if isActiveLine {
                let mathMono = theme.codeFont(size: fontSize * 0.90)
                storage.addAttributes([
                    .font: mathMono,
                    .foregroundColor: theme.textNSColor.withAlphaComponent(dimFactor),
                    .backgroundColor: theme.codeBackgroundNSColor.withAlphaComponent(0.55 * dimFactor)
                ], range: innerRange)
                highlightLaTeXSource(in: storage, range: innerRange, theme: theme, dimFactor: dimFactor)
                styleSyntaxToken(in: storage, range: openRange, isActiveLine: true, theme: theme, dimFactor: dimFactor)
                styleSyntaxToken(in: storage, range: closeRange, isActiveLine: true, theme: theme, dimFactor: dimFactor)
            } else {
                let mathBox = LaTeXMathRenderer.layoutLatex(latexStr, baseFontSize: fontSize, isDisplayStyle: false)
                let targetWidth = max(12.0, mathBox.width + 6.0)

                let tinyFont = NSFont.monospacedSystemFont(ofSize: 2.0, weight: .regular)
                let rawSubstr = nsString.substring(with: fullMatchRange) as NSString
                let baseW = rawSubstr.size(withAttributes: [.font: tinyFont]).width
                let perCharKern = (targetWidth - baseW) / CGFloat(max(1, fullMatchRange.length))

                storage.addAttributes([
                    .font: tinyFont,
                    .foregroundColor: NSColor.clear,
                    .kern: perCharKern
                ], range: fullMatchRange)

                decorations.append(LineDecoration(
                    lineRange: fullMatchRange,
                    kind: .inlineMathRendered(
                        latex: latexStr,
                        range: fullMatchRange,
                        fontSize: fontSize,
                        dimFactor: dimFactor
                    )
                ))
            }
        }

        // 3. Backslash escapes (\*, \_, \|, \[, etc.) outside inline code/math
        escapeRegex.enumerateMatches(in: string, options: [], range: range) { match, _, _ in
            guard let match = match, !isInCodeOrMath(match.range) else { return }
            let slashRange = NSRange(location: match.range.location, length: 1)
            let escapedCharRange = match.range(at: 1)
            protectedDelimiterRanges.append(match.range)
            styleSyntaxToken(in: storage, range: slashRange, isActiveLine: isActiveLine, theme: theme, dimFactor: dimFactor)
            _ = escapedCharRange
        }

        // 4. HTML <br/> tags outside inline code/math
        htmlBrRegex.enumerateMatches(in: string, options: [], range: range) { match, _, _ in
            guard let match = match, !isInCodeOrMath(match.range) else { return }
            protectedDelimiterRanges.append(match.range)
            styleSyntaxToken(in: storage, range: match.range, isActiveLine: isActiveLine, theme: theme, dimFactor: dimFactor)
            if !isActiveLine && match.range.length > 0 {
                storage.addAttribute(.kern, value: 6.0, range: NSRange(location: match.range.location, length: 1))
            }
        }

        // 5. Links ([label](url)) and Images (![alt](url)) — scanned with code-span & balanced-paren awareness
        let linkMatches = scanMarkdownLinks(nsString: nsString, range: range, isDelimiterProtected: isDelimiterProtected)
        for link in linkMatches {
            protectedDelimiterRanges.append(link.openSyntaxRange)
            protectedDelimiterRanges.append(link.trailingSyntaxRange)

            applyAttributesToVisibleCharacters(
                in: storage,
                range: link.labelRange,
                attributes: [
                    .foregroundColor: theme.linkNSColor.withAlphaComponent(dimFactor),
                    .underlineStyle: NSUnderlineStyle.single.rawValue
                ]
            )
            styleSyntaxToken(in: storage, range: link.openSyntaxRange, isActiveLine: isActiveLine, theme: theme, dimFactor: dimFactor)
            styleSyntaxToken(in: storage, range: link.trailingSyntaxRange, isActiveLine: isActiveLine, theme: theme, dimFactor: dimFactor)
        }

        // 5b. Autolinks (<https://...> or <user@example.com>)
        autolinkRegex.enumerateMatches(in: string, options: [], range: range) { match, _, _ in
            guard let match = match, !isDelimiterProtected(match.range) else { return }
            let openAngle = match.range(at: 1)
            let urlRange = match.range(at: 2)
            let closeAngle = match.range(at: 3)
            protectedDelimiterRanges.append(match.range)

            applyAttributesToVisibleCharacters(
                in: storage,
                range: urlRange,
                attributes: [
                    .foregroundColor: theme.linkNSColor.withAlphaComponent(dimFactor),
                    .underlineStyle: NSUnderlineStyle.single.rawValue
                ]
            )
            styleSyntaxToken(in: storage, range: openAngle, isActiveLine: isActiveLine, theme: theme, dimFactor: dimFactor)
            styleSyntaxToken(in: storage, range: closeAngle, isActiveLine: isActiveLine, theme: theme, dimFactor: dimFactor)
        }

        // 6. Bold + Italic (***text*** or ___text___)
        boldItalicRegex.enumerateMatches(in: string, options: [], range: range) { match, _, _ in
            guard let match = match else { return }
            let innerRange = match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range(at: 2)
            guard innerRange.location != NSNotFound else { return }
            let openRange = NSRange(location: match.range.location, length: 3)
            let closeRange = NSRange(location: NSMaxRange(innerRange), length: 3)
            guard !isDelimiterProtected(openRange), !isDelimiterProtected(closeRange) else { return }

            protectedDelimiterRanges.append(openRange)
            protectedDelimiterRanges.append(closeRange)
            applyFontTraitToVisibleCharacters(in: storage, range: innerRange, trait: [.boldFontMask, .italicFontMask], fallbackFont: baseFont)
            styleSyntaxToken(in: storage, range: openRange, isActiveLine: isActiveLine, theme: theme, dimFactor: dimFactor)
            styleSyntaxToken(in: storage, range: closeRange, isActiveLine: isActiveLine, theme: theme, dimFactor: dimFactor)
        }

        // 7. Bold (**text** or __text__)
        for regex in [boldAsteriskRegex, boldUnderscoreRegex] {
            regex.enumerateMatches(in: string, options: [], range: range) { match, _, _ in
                guard let match = match else { return }
                let innerRange = match.range(at: 1)
                let openRange = NSRange(location: match.range.location, length: 2)
                let closeRange = NSRange(location: NSMaxRange(innerRange), length: 2)
                guard !isDelimiterProtected(openRange), !isDelimiterProtected(closeRange) else { return }

                protectedDelimiterRanges.append(openRange)
                protectedDelimiterRanges.append(closeRange)
                applyFontTraitToVisibleCharacters(in: storage, range: innerRange, trait: .boldFontMask, fallbackFont: baseFont)
                styleSyntaxToken(in: storage, range: openRange, isActiveLine: isActiveLine, theme: theme, dimFactor: dimFactor)
                styleSyntaxToken(in: storage, range: closeRange, isActiveLine: isActiveLine, theme: theme, dimFactor: dimFactor)
            }
        }

        // 8. Italic (*text* or _text_)
        for regex in [italicAsteriskRegex, italicUnderscoreRegex] {
            regex.enumerateMatches(in: string, options: [], range: range) { match, _, _ in
                guard let match = match else { return }
                let innerRange = match.range(at: 1)
                let openRange = NSRange(location: match.range.location, length: 1)
                let closeRange = NSRange(location: NSMaxRange(innerRange), length: 1)
                guard !isDelimiterProtected(openRange), !isDelimiterProtected(closeRange) else { return }

                protectedDelimiterRanges.append(openRange)
                protectedDelimiterRanges.append(closeRange)
                applyFontTraitToVisibleCharacters(in: storage, range: innerRange, trait: .italicFontMask, fallbackFont: baseFont)
                styleSyntaxToken(in: storage, range: openRange, isActiveLine: isActiveLine, theme: theme, dimFactor: dimFactor)
                styleSyntaxToken(in: storage, range: closeRange, isActiveLine: isActiveLine, theme: theme, dimFactor: dimFactor)
            }
        }

        // 9. Strikethrough (~~text~~)
        strikeRegex.enumerateMatches(in: string, options: [], range: range) { match, _, _ in
            guard let match = match else { return }
            let openRange = match.range(at: 1)
            let innerRange = match.range(at: 2)
            let closeRange = match.range(at: 3)
            guard !isDelimiterProtected(openRange), !isDelimiterProtected(closeRange) else { return }

            protectedDelimiterRanges.append(openRange)
            protectedDelimiterRanges.append(closeRange)
            applyAttributesToVisibleCharacters(
                in: storage,
                range: innerRange,
                attributes: [
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    .foregroundColor: theme.secondaryTextNSColor.withAlphaComponent(dimFactor)
                ]
            )
            styleSyntaxToken(in: storage, range: openRange, isActiveLine: isActiveLine, theme: theme, dimFactor: dimFactor)
            styleSyntaxToken(in: storage, range: closeRange, isActiveLine: isActiveLine, theme: theme, dimFactor: dimFactor)
        }

        // 10. Highlight (==text==)
        highlightRegex.enumerateMatches(in: string, options: [], range: range) { match, _, _ in
            guard let match = match else { return }
            let openRange = match.range(at: 1)
            let innerRange = match.range(at: 2)
            let closeRange = match.range(at: 3)
            guard !isDelimiterProtected(openRange), !isDelimiterProtected(closeRange) else { return }

            protectedDelimiterRanges.append(openRange)
            protectedDelimiterRanges.append(closeRange)
            let highlightBg = theme.isDark
                ? NSColor(srgbRed: 0.55, green: 0.45, blue: 0.12, alpha: 0.55 * dimFactor)
                : NSColor(srgbRed: 1.0, green: 0.93, blue: 0.45, alpha: 0.65 * dimFactor)
            applyAttributesToVisibleCharacters(
                in: storage,
                range: innerRange,
                attributes: [.backgroundColor: highlightBg]
            )
            styleSyntaxToken(in: storage, range: openRange, isActiveLine: isActiveLine, theme: theme, dimFactor: dimFactor)
            styleSyntaxToken(in: storage, range: closeRange, isActiveLine: isActiveLine, theme: theme, dimFactor: dimFactor)
        }

        // 11. CommonMark Whitespace Normalization on inactive lines (outside inline code & math)
        if normalizeWhitespace && !isActiveLine {
            normalizeProseWhitespace(
                in: storage,
                string: string,
                range: range,
                isInCodeOrMath: isInCodeOrMath
            )
        }
    }

    private struct ScannedInlineCodeSpan {
        let fullRange: NSRange
        let openRange: NSRange
        let innerRange: NSRange
        let closeRange: NSRange
    }

    /// Linear-time $O(N)$ CommonMark inline code span scanner.
    /// Collects contiguous backtick runs in a single pass and pairs matching run lengths without quadratic rescanning.
    private static func scanInlineCodeSpans(nsString: NSString, range: NSRange) -> [ScannedInlineCodeSpan] {
        let end = NSMaxRange(range)
        var runs: [(location: Int, length: Int)] = []
        var runsByLength: [Int: [Int]] = [:]

        var idx = range.location
        while idx < end {
            let ch = nsString.character(at: idx)
            if ch == 0x0A { // '\n' - inline code in single-line styler does not cross line breaks
                idx += 1
                continue
            }
            if ch == 0x60 { // '`'
                let start = idx
                while idx < end && nsString.character(at: idx) == 0x60 {
                    idx += 1
                }
                let len = idx - start
                let runIdx = runs.count
                runs.append((location: start, length: len))
                runsByLength[len, default: []].append(runIdx)
            } else {
                idx += 1
            }
        }

        guard runs.count >= 2 else { return [] }

        var results: [ScannedInlineCodeSpan] = []
        var cursorByLength: [Int: Int] = [:]
        var i = 0
        while i < runs.count {
            let openRun = runs[i]
            guard let candidates = runsByLength[openRun.length] else {
                i += 1
                continue
            }
            var cursor = cursorByLength[openRun.length] ?? 0
            while cursor < candidates.count && candidates[cursor] <= i {
                cursor += 1
            }
            cursorByLength[openRun.length] = cursor

            if cursor < candidates.count {
                let closeRunIdx = candidates[cursor]
                let closeRun = runs[closeRunIdx]
                let openEnd = openRun.location + openRun.length
                let innerLen = closeRun.location - openEnd
                if innerLen > 0 {
                    let fullRange = NSRange(location: openRun.location, length: (closeRun.location + closeRun.length) - openRun.location)
                    let openRange = NSRange(location: openRun.location, length: openRun.length)
                    let innerRange = NSRange(location: openEnd, length: innerLen)
                    let closeRange = NSRange(location: closeRun.location, length: closeRun.length)
                    results.append(ScannedInlineCodeSpan(
                        fullRange: fullRange,
                        openRange: openRange,
                        innerRange: innerRange,
                        closeRange: closeRange
                    ))
                    cursorByLength[openRun.length] = cursor + 1
                    i = closeRunIdx + 1
                    continue
                }
            }
            i += 1
        }

        return results
    }

    private struct ScannedMarkdownLink {
        let openSyntaxRange: NSRange      // `[` or `![`
        let labelRange: NSRange           // `label`
        let trailingSyntaxRange: NSRange  // `](url)`
    }

    /// Linear-time $O(N)$ Markdown link & image scanner (`[label](url)` and `![alt](url)`).
    /// Precomputes balanced parentheses in one pass and uses an explicit bracket stack to avoid $O(N^2)$ rescanning on unmatched `[` or `](`.
    private static func scanMarkdownLinks(
        nsString: NSString,
        range: NSRange,
        isDelimiterProtected: (NSRange) -> Bool
    ) -> [ScannedMarkdownLink] {
        let end = NSMaxRange(range)
        guard range.length >= 4 else { return [] }

        // Pass 1: Precompute matching ')' for every '(' in O(N) time using a stack
        var matchingCloseParen: [Int: Int] = [:]
        var parenStack: [Int] = []
        var pIdx = range.location
        while pIdx < end {
            let ch = nsString.character(at: pIdx)
            if ch == 0x5C { // '\' escape
                pIdx += 2
                continue
            }
            if ch == 0x28 { // '('
                if !isDelimiterProtected(NSRange(location: pIdx, length: 1)) {
                    parenStack.append(pIdx)
                }
            } else if ch == 0x29 { // ')'
                if !isDelimiterProtected(NSRange(location: pIdx, length: 1)),
                   let openParen = parenStack.popLast() {
                    matchingCloseParen[openParen] = pIdx
                }
            }
            pIdx += 1
        }

        // Pass 2: Single linear scan with an open-bracket stack
        struct OpenBracketEntry {
            let openStart: Int
            let bracketPos: Int
            let isImage: Bool
        }

        var results: [ScannedMarkdownLink] = []
        var openStack: [OpenBracketEntry] = []
        var idx = range.location

        while idx < end {
            let ch = nsString.character(at: idx)
            if ch == 0x21 && idx + 1 < end && nsString.character(at: idx + 1) == 0x5B { // `![`
                let openSyntaxRange = NSRange(location: idx, length: 2)
                if !isDelimiterProtected(openSyntaxRange) {
                    openStack.append(OpenBracketEntry(openStart: idx, bracketPos: idx + 1, isImage: true))
                    idx += 2
                    continue
                }
            } else if ch == 0x5B { // `[`
                let openSyntaxRange = NSRange(location: idx, length: 1)
                if !isDelimiterProtected(openSyntaxRange) {
                    openStack.append(OpenBracketEntry(openStart: idx, bracketPos: idx, isImage: false))
                    idx += 1
                    continue
                }
            } else if ch == 0x5D { // `]`
                let closeRange = NSRange(location: idx, length: 1)
                if !isDelimiterProtected(closeRange), let open = openStack.popLast() {
                    if idx + 1 < end,
                       nsString.character(at: idx + 1) == 0x28,
                       !isDelimiterProtected(NSRange(location: idx, length: 2)),
                       let closeParen = matchingCloseParen[idx + 1] {
                        let labelRange = NSRange(location: open.bracketPos + 1, length: idx - (open.bracketPos + 1))
                        if labelRange.length > 0 || open.isImage {
                            let openSyntaxRange = NSRange(location: open.openStart, length: open.isImage ? 2 : 1)
                            let trailingRange = NSRange(location: idx, length: (closeParen + 1) - idx)
                            results.append(ScannedMarkdownLink(
                                openSyntaxRange: openSyntaxRange,
                                labelRange: labelRange,
                                trailingSyntaxRange: trailingRange
                            ))
                            openStack.removeAll(keepingCapacity: true)
                            idx = closeParen + 1
                            continue
                        }
                    }
                }
            }
            idx += 1
        }

        return results
    }

    private static func applyFontTraitToVisibleCharacters(
        in storage: NSTextStorage,
        range: NSRange,
        trait: NSFontTraitMask,
        fallbackFont: NSFont
    ) {
        guard range.length > 0 else { return }
        storage.enumerateAttributes(in: range, options: []) { attrs, subrange, _ in
            if attrs[collapsedTokenAttributeKey] != nil {
                return
            }
            let currentFont = (attrs[.font] as? NSFont) ?? fallbackFont
            let converted = NSFontManager.shared.convert(currentFont, toHaveTrait: trait)
            storage.addAttribute(.font, value: converted, range: subrange)
        }
    }

    private static func applyAttributesToVisibleCharacters(
        in storage: NSTextStorage,
        range: NSRange,
        attributes: [NSAttributedString.Key: Any]
    ) {
        guard range.length > 0 else { return }
        storage.enumerateAttributes(in: range, options: []) { attrs, subrange, _ in
            if attrs[collapsedTokenAttributeKey] != nil {
                return
            }
            storage.addAttributes(attributes, range: subrange)
        }
    }

    private static func normalizeProseWhitespace(
        in storage: NSTextStorage,
        string: String,
        range: NSRange,
        isInCodeOrMath: (NSRange) -> Bool
    ) {
        guard range.length > 0 else { return }

        // 1. Collapse leading spaces/tabs on the range
        if let leadMatch = leadingSpaceRegex.firstMatch(in: string, options: [], range: range),
           !isInCodeOrMath(leadMatch.range) {
            collapseWhitespaceRange(in: storage, range: leadMatch.range)
        }

        // 2. Collapse trailing spaces/tabs on the range
        if let trailMatch = trailingSpaceRegex.firstMatch(in: string, options: [], range: range),
           !isInCodeOrMath(trailMatch.range) {
            collapseWhitespaceRange(in: storage, range: trailMatch.range)
        }

        // 3. Collapse extra spaces in runs of 2+ internal spaces/tabs (preserving the first space)
        multiSpaceRegex.enumerateMatches(in: string, options: [], range: range) { match, _, _ in
            guard let match = match, match.range.length >= 2, !isInCodeOrMath(match.range) else { return }
            if storage.attribute(collapsedTokenAttributeKey, at: match.range.location, effectiveRange: nil) != nil {
                return
            }
            let extraRange = NSRange(location: match.range.location + 1, length: match.range.length - 1)
            collapseWhitespaceRange(in: storage, range: extraRange)
        }
    }

    private static func collapseWhitespaceRange(
        in storage: NSTextStorage,
        range: NSRange
    ) {
        guard range.length > 0 else { return }
        storage.addAttributes([
            .foregroundColor: NSColor.clear,
            .backgroundColor: NSColor.clear,
            .font: NSFont.systemFont(ofSize: 0.001),
            .kern: 0.0,
            .underlineStyle: 0,
            .strikethroughStyle: 0,
            collapsedTokenAttributeKey: true
        ], range: range)
    }

    private static func styleSyntaxToken(
        in storage: NSTextStorage,
        range: NSRange,
        isActiveLine: Bool,
        theme: EditorTheme,
        dimFactor: CGFloat
    ) {
        guard range.length > 0 else { return }
        if isActiveLine {
            storage.addAttributes([
                .foregroundColor: theme.markdownTokenNSColor.withAlphaComponent(0.85 * dimFactor),
                .font: theme.codeFont(size: max(11.0, theme.baseFontSize * 0.85))
            ], range: range)
        } else {
            collapseWhitespaceRange(in: storage, range: range)
        }
    }

    private static func highlightLaTeXSource(
        in storage: NSTextStorage,
        range: NSRange,
        theme: EditorTheme,
        dimFactor: CGFloat
    ) {
        guard range.length > 0 else { return }
        let string = storage.string
        latexCommandRegex.enumerateMatches(in: string, options: [], range: range) { match, _, _ in
            if let r = match?.range {
                storage.addAttribute(.foregroundColor, value: theme.linkNSColor.withAlphaComponent(dimFactor), range: r)
            }
        }
        latexBracesRegex.enumerateMatches(in: string, options: [], range: range) { match, _, _ in
            if let r = match?.range {
                storage.addAttribute(.foregroundColor, value: theme.inlineCodeNSColor.withAlphaComponent(dimFactor), range: r)
            }
        }
    }

    // MARK: - Language-Aware Code Fence Syntax Highlighter
    private struct LanguageSyntaxProfile {
        let keywords: NSRegularExpression?
        let typesAndBuiltins: NSRegularExpression?
        let attributesOrMacros: NSRegularExpression?
        let comments: NSRegularExpression?
        let strings: NSRegularExpression
        let numbers: NSRegularExpression
        let functions: NSRegularExpression
        let keywordColorLight: NSColor
        let keywordColorDark: NSColor
    }

    private static let sharedStringsRegex = try! NSRegularExpression(pattern: #""(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`"#)
    private static let sharedNumbersRegex = try! NSRegularExpression(pattern: #"\b(?:0x[0-9a-fA-F]+|\d+(?:\.\d+)?)\b"#)
    private static let sharedFunctionsRegex = try! NSRegularExpression(pattern: #"\b([a-zA-Z_][a-zA-Z0-9_]*)\s*(?=\()"#)

    private static func syntaxProfile(for rawLanguage: String) -> LanguageSyntaxProfile? {
        let lang = rawLanguage.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lang.isEmpty else { return nil }

        switch lang {
        case "swift":
            return LanguageSyntaxProfile(
                keywords: try? NSRegularExpression(pattern: #"\b(func|let|var|struct|class|enum|protocol|extension|import|return|if|else|switch|case|default|for|while|in|guard|try|catch|throw|throws|async|await|public|private|internal|fileprivate|open|static|final|override|mutating|init|deinit|self|super|true|false|nil|where|some|any|typealias|inout|defer|repeat)\b"#),
                typesAndBuiltins: try? NSRegularExpression(pattern: #"\b([A-Z][a-zA-Z0-9_]*)\b"#),
                attributesOrMacros: try? NSRegularExpression(pattern: #"@[a-zA-Z_][a-zA-Z0-9_]*|#[a-zA-Z_][a-zA-Z0-9_]*"#),
                comments: try? NSRegularExpression(pattern: #"//.*$|/\*.*?\*/"#),
                strings: sharedStringsRegex,
                numbers: sharedNumbersRegex,
                functions: sharedFunctionsRegex,
                keywordColorLight: NSColor(srgbRed: 0.68, green: 0.09, blue: 0.54, alpha: 1.0),
                keywordColorDark: NSColor(srgbRed: 0.99, green: 0.37, blue: 0.64, alpha: 1.0)
            )

        case "python", "py":
            return LanguageSyntaxProfile(
                keywords: try? NSRegularExpression(pattern: #"\b(def|class|return|if|elif|else|for|while|in|import|from|as|with|try|except|finally|raise|pass|break|continue|lambda|yield|async|await|global|nonlocal|assert|del|is|not|and|or|True|False|None|self|cls)\b"#),
                typesAndBuiltins: try? NSRegularExpression(pattern: #"\b(int|str|float|bool|list|dict|set|tuple|bytes|object|type|print|len|range|enumerate|zip|map|filter|sorted|super|isinstance|getattr|setattr|open)\b"#),
                attributesOrMacros: try? NSRegularExpression(pattern: #"@[a-zA-Z_][a-zA-Z0-9_\.]*"#),
                comments: try? NSRegularExpression(pattern: #"#.*$"#),
                strings: sharedStringsRegex,
                numbers: sharedNumbersRegex,
                functions: sharedFunctionsRegex,
                keywordColorLight: NSColor(srgbRed: 0.05, green: 0.38, blue: 0.68, alpha: 1.0),
                keywordColorDark: NSColor(srgbRed: 0.38, green: 0.72, blue: 0.98, alpha: 1.0)
            )

        case "javascript", "js", "jsx", "typescript", "ts", "tsx":
            return LanguageSyntaxProfile(
                keywords: try? NSRegularExpression(pattern: #"\b(const|let|var|function|return|if|else|switch|case|default|for|while|do|of|in|import|export|from|default|class|extends|new|this|super|try|catch|finally|throw|async|await|typeof|instanceof|void|delete|yield|interface|type|implements|readonly|public|private|protected|true|false|null|undefined)\b"#),
                typesAndBuiltins: try? NSRegularExpression(pattern: #"\b(Promise|Array|Object|String|Number|Boolean|Map|Set|WeakMap|WeakSet|Date|RegExp|Error|Math|JSON|console|window|document|globalThis|number|string|boolean|any|unknown|never|Record|Partial)\b"#),
                attributesOrMacros: try? NSRegularExpression(pattern: #"@[a-zA-Z_][a-zA-Z0-9_]*"#),
                comments: try? NSRegularExpression(pattern: #"//.*$|/\*.*?\*/"#),
                strings: sharedStringsRegex,
                numbers: sharedNumbersRegex,
                functions: sharedFunctionsRegex,
                keywordColorLight: NSColor(srgbRed: 0.56, green: 0.24, blue: 0.78, alpha: 1.0),
                keywordColorDark: NSColor(srgbRed: 0.78, green: 0.56, blue: 0.98, alpha: 1.0)
            )

        case "rust", "rs":
            return LanguageSyntaxProfile(
                keywords: try? NSRegularExpression(pattern: #"\b(fn|let|mut|const|static|struct|enum|trait|impl|pub|crate|mod|use|as|where|for|in|while|loop|if|else|match|return|break|continue|async|await|move|ref|type|unsafe|extern|dyn|self|Self|super|true|false)\b"#),
                typesAndBuiltins: try? NSRegularExpression(pattern: #"\b(u8|u16|u32|u64|u128|usize|i8|i16|i32|i64|i128|isize|f32|f64|bool|char|str|String|Vec|Option|Result|Some|None|Ok|Err|Box|Rc|Arc|Cow|HashMap|HashSet)\b"#),
                attributesOrMacros: try? NSRegularExpression(pattern: #"#!?\[[^\]]*\]|\b[a-zA-Z_][a-zA-Z0-9_]*!"#),
                comments: try? NSRegularExpression(pattern: #"//.*$|/\*.*?\*/"#),
                strings: sharedStringsRegex,
                numbers: sharedNumbersRegex,
                functions: sharedFunctionsRegex,
                keywordColorLight: NSColor(srgbRed: 0.75, green: 0.28, blue: 0.08, alpha: 1.0),
                keywordColorDark: NSColor(srgbRed: 0.96, green: 0.58, blue: 0.34, alpha: 1.0)
            )

        case "go", "golang":
            return LanguageSyntaxProfile(
                keywords: try? NSRegularExpression(pattern: #"\b(func|package|import|var|const|type|struct|interface|map|chan|go|defer|return|if|else|switch|case|default|select|for|range|break|continue|fallthrough|goto|true|false|nil|iota)\b"#),
                typesAndBuiltins: try? NSRegularExpression(pattern: #"\b(int|int8|int16|int32|int64|uint|uint8|uint16|uint32|uint64|uintptr|float32|float64|complex64|complex128|byte|rune|string|bool|error|any|make|len|cap|new|append|copy|close|delete|panic|recover|print|println)\b"#),
                attributesOrMacros: nil,
                comments: try? NSRegularExpression(pattern: #"//.*$|/\*.*?\*/"#),
                strings: sharedStringsRegex,
                numbers: sharedNumbersRegex,
                functions: sharedFunctionsRegex,
                keywordColorLight: NSColor(srgbRed: 0.0, green: 0.48, blue: 0.62, alpha: 1.0),
                keywordColorDark: NSColor(srgbRed: 0.28, green: 0.82, blue: 0.92, alpha: 1.0)
            )

        case "c", "cpp", "c++", "h", "hpp", "objc", "objective-c":
            return LanguageSyntaxProfile(
                keywords: try? NSRegularExpression(pattern: #"\b(if|else|switch|case|default|for|while|do|return|break|continue|goto|struct|class|union|enum|typedef|using|namespace|template|typename|public|private|protected|virtual|override|final|static|extern|const|constexpr|volatile|inline|sizeof|new|delete|try|catch|throw|nullptr|NULL|true|false)\b"#),
                typesAndBuiltins: try? NSRegularExpression(pattern: #"\b(void|int|long|short|char|float|double|bool|unsigned|signed|size_t|uint8_t|uint16_t|uint32_t|uint64_t|int32_t|int64_t|std|string|vector|map|set|shared_ptr|unique_ptr)\b"#),
                attributesOrMacros: try? NSRegularExpression(pattern: #"^\s*#\s*[a-zA-Z_]+"#),
                comments: try? NSRegularExpression(pattern: #"//.*$|/\*.*?\*/"#),
                strings: sharedStringsRegex,
                numbers: sharedNumbersRegex,
                functions: sharedFunctionsRegex,
                keywordColorLight: NSColor(srgbRed: 0.58, green: 0.12, blue: 0.45, alpha: 1.0),
                keywordColorDark: NSColor(srgbRed: 0.88, green: 0.48, blue: 0.75, alpha: 1.0)
            )

        case "json", "jsonc", "yaml", "yml", "toml":
            return LanguageSyntaxProfile(
                keywords: try? NSRegularExpression(pattern: #"\b(true|false|null|yes|no|on|off)\b"#),
                typesAndBuiltins: nil,
                attributesOrMacros: try? NSRegularExpression(pattern: #""[^"\n]*"\s*(?=:)|^\s*[a-zA-Z0-9_-]+\s*(?=:)"#),
                comments: lang == "json" ? nil : (try? NSRegularExpression(pattern: #"#.*$|//.*$"#)),
                strings: sharedStringsRegex,
                numbers: sharedNumbersRegex,
                functions: sharedFunctionsRegex,
                keywordColorLight: NSColor(srgbRed: 0.12, green: 0.48, blue: 0.34, alpha: 1.0),
                keywordColorDark: NSColor(srgbRed: 0.42, green: 0.85, blue: 0.65, alpha: 1.0)
            )

        case "bash", "sh", "zsh", "shell":
            return LanguageSyntaxProfile(
                keywords: try? NSRegularExpression(pattern: #"\b(if|then|else|elif|fi|for|while|until|do|done|in|case|esac|function|return|exit|export|local|readonly|set|unset|shift|source)\b"#),
                typesAndBuiltins: try? NSRegularExpression(pattern: #"\b(echo|printf|cd|pwd|ls|cp|mv|rm|mkdir|cat|grep|sed|awk|find|xargs|curl|git|swift|npm|npx|python3|brew|chmod|chown)\b"#),
                attributesOrMacros: try? NSRegularExpression(pattern: #"\$[a-zA-Z0-9_@*#?-]+|\$\{[^\}]+\}"#),
                comments: try? NSRegularExpression(pattern: #"#.*$"#),
                strings: sharedStringsRegex,
                numbers: sharedNumbersRegex,
                functions: sharedFunctionsRegex,
                keywordColorLight: NSColor(srgbRed: 0.16, green: 0.46, blue: 0.22, alpha: 1.0),
                keywordColorDark: NSColor(srgbRed: 0.48, green: 0.86, blue: 0.54, alpha: 1.0)
            )

        case "html", "xml", "svg", "css", "scss":
            return LanguageSyntaxProfile(
                keywords: try? NSRegularExpression(pattern: #"</?[a-zA-Z0-9_-]+|/?>|@[a-zA-Z_-]+"#),
                typesAndBuiltins: try? NSRegularExpression(pattern: #"\b[a-zA-Z-]+(?=\s*=|\s*:)"#),
                attributesOrMacros: try? NSRegularExpression(pattern: #"#[0-9a-fA-F]{3,8}\b|\.[a-zA-Z_-][a-zA-Z0-9_-]*"#),
                comments: try? NSRegularExpression(pattern: #"<!--.*?-->|/\*.*?\*/"#),
                strings: sharedStringsRegex,
                numbers: sharedNumbersRegex,
                functions: sharedFunctionsRegex,
                keywordColorLight: NSColor(srgbRed: 0.72, green: 0.14, blue: 0.26, alpha: 1.0),
                keywordColorDark: NSColor(srgbRed: 0.95, green: 0.45, blue: 0.55, alpha: 1.0)
            )

        case "sql":
            return LanguageSyntaxProfile(
                keywords: try? NSRegularExpression(pattern: #"(?i)\b(SELECT|FROM|WHERE|INSERT|INTO|VALUES|UPDATE|SET|DELETE|CREATE|TABLE|DROP|ALTER|INDEX|VIEW|JOIN|INNER|LEFT|RIGHT|FULL|ON|AS|AND|OR|NOT|NULL|IS|IN|EXISTS|BETWEEN|LIKE|ORDER|BY|GROUP|HAVING|LIMIT|OFFSET|UNION|ALL|DISTINCT|PRIMARY|KEY|FOREIGN|REFERENCES|DEFAULT|BEGIN|COMMIT|ROLLBACK)\b"#),
                typesAndBuiltins: try? NSRegularExpression(pattern: #"(?i)\b(INT|INTEGER|BIGINT|TEXT|VARCHAR|BOOLEAN|DATE|TIMESTAMP|FLOAT|DOUBLE|DECIMAL|UUID|JSONB|COUNT|SUM|AVG|MIN|MAX|COALESCE|NOW)\b"#),
                attributesOrMacros: nil,
                comments: try? NSRegularExpression(pattern: #"--.*$|/\*.*?\*/"#),
                strings: sharedStringsRegex,
                numbers: sharedNumbersRegex,
                functions: sharedFunctionsRegex,
                keywordColorLight: NSColor(srgbRed: 0.10, green: 0.36, blue: 0.72, alpha: 1.0),
                keywordColorDark: NSColor(srgbRed: 0.44, green: 0.72, blue: 0.98, alpha: 1.0)
            )

        default:
            // Unknown/custom language tag: provide lightweight generic highlighting
            return LanguageSyntaxProfile(
                keywords: try? NSRegularExpression(pattern: #"\b(if|else|for|while|return|function|class|import|true|false|null)\b"#),
                typesAndBuiltins: nil,
                attributesOrMacros: nil,
                comments: try? NSRegularExpression(pattern: #"//.*$|#.*$"#),
                strings: sharedStringsRegex,
                numbers: sharedNumbersRegex,
                functions: sharedFunctionsRegex,
                keywordColorLight: NSColor(srgbRed: 0.45, green: 0.25, blue: 0.65, alpha: 1.0),
                keywordColorDark: NSColor(srgbRed: 0.72, green: 0.55, blue: 0.88, alpha: 1.0)
            )
        }
    }

    private static func highlightCodeLine(
        in storage: NSTextStorage,
        range: NSRange,
        language: String,
        theme: EditorTheme,
        dimFactor: CGFloat
    ) {
        guard range.length > 0, let profile = syntaxProfile(for: language) else { return }
        let string = storage.string

        let keywordColor = (theme.isDark ? profile.keywordColorDark : profile.keywordColorLight).withAlphaComponent(dimFactor)
        let typeColor = (theme.isDark
            ? NSColor(srgbRed: 0.38, green: 0.84, blue: 0.78, alpha: dimFactor)
            : NSColor(srgbRed: 0.04, green: 0.45, blue: 0.48, alpha: dimFactor))
        let functionColor = (theme.isDark
            ? NSColor(srgbRed: 0.45, green: 0.72, blue: 0.96, alpha: dimFactor)
            : NSColor(srgbRed: 0.14, green: 0.36, blue: 0.74, alpha: dimFactor))
        let numberColor = (theme.isDark
            ? NSColor(srgbRed: 0.88, green: 0.68, blue: 0.38, alpha: dimFactor)
            : NSColor(srgbRed: 0.68, green: 0.36, blue: 0.04, alpha: dimFactor))
        let attrColor = (theme.isDark
            ? NSColor(srgbRed: 0.94, green: 0.62, blue: 0.42, alpha: dimFactor)
            : NSColor(srgbRed: 0.64, green: 0.28, blue: 0.12, alpha: dimFactor))
        let stringColor = (theme.isDark
            ? NSColor(srgbRed: 0.60, green: 0.82, blue: 0.50, alpha: dimFactor)
            : NSColor(srgbRed: 0.12, green: 0.46, blue: 0.18, alpha: dimFactor))
        let commentColor = theme.secondaryTextNSColor.withAlphaComponent(0.72 * dimFactor)

        // 1. Numbers
        profile.numbers.enumerateMatches(in: string, options: [], range: range) { match, _, _ in
            if let r = match?.range {
                storage.addAttribute(.foregroundColor, value: numberColor, range: r)
            }
        }

        // 2. Function calls/names
        profile.functions.enumerateMatches(in: string, options: [], range: range) { match, _, _ in
            if let r = match?.range(at: 1) {
                storage.addAttribute(.foregroundColor, value: functionColor, range: r)
            }
        }

        // 3. Types & Builtins
        profile.typesAndBuiltins?.enumerateMatches(in: string, options: [], range: range) { match, _, _ in
            if let r = match?.range {
                storage.addAttribute(.foregroundColor, value: typeColor, range: r)
            }
        }

        // 4. Keywords (override function/type matches if a keyword is followed by '(')
        profile.keywords?.enumerateMatches(in: string, options: [], range: range) { match, _, _ in
            if let r = match?.range {
                storage.addAttribute(.foregroundColor, value: keywordColor, range: r)
            }
        }

        // 5. Attributes / Decorators / Preprocessor / JSON keys
        profile.attributesOrMacros?.enumerateMatches(in: string, options: [], range: range) { match, _, _ in
            if let r = match?.range {
                storage.addAttribute(.foregroundColor, value: attrColor, range: r)
            }
        }

        // 6. Strings (override keywords inside string literals)
        profile.strings.enumerateMatches(in: string, options: [], range: range) { match, _, _ in
            if let r = match?.range {
                storage.addAttribute(.foregroundColor, value: stringColor, range: r)
            }
        }

        // 7. Comments (override everything inside a comment)
        profile.comments?.enumerateMatches(in: string, options: [], range: range) { match, _, _ in
            if let r = match?.range {
                storage.addAttribute(.foregroundColor, value: commentColor, range: r)
            }
        }
    }
}
