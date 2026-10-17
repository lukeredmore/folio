import AppKit
import Foundation

public enum BlockDecorationKind: Equatable {
    case headingUnderline(level: Int)
    case blockquote(nestLevel: Int)
    case codeFenceStart(language: String)
    case codeFenceBody
    case codeFenceEnd
    case mathBlockStart
    case mathBlockBody
    case mathBlockEnd
    case horizontalRule
    case tableHeaderRow
    case tableSeparatorRow
    case tableBodyRow(rowIndex: Int)
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

    private static let headingRegex = try! NSRegularExpression(pattern: #"^(#{1,6})(\s+)(.+)$"#)
    private static let blockquoteRegex = try! NSRegularExpression(pattern: #"^(\s*>+\s*)(.*)$"#)
    private static let taskListRegex = try! NSRegularExpression(pattern: #"^(\s*[-*+]\s+)(\[[ xX]\])(\s+)(.*)$"#)
    private static let unorderedListRegex = try! NSRegularExpression(pattern: #"^(\s*[-*+]\s+)(.+)$"#)
    private static let orderedListRegex = try! NSRegularExpression(pattern: #"^(\s*\d+\.\s+)(.+)$"#)
    private static let hrRegex = try! NSRegularExpression(pattern: #"^\s*(?:-\s*-\s*-[- ]*|\*\s*\*\s*\*[* ]*|_\s*_\s*_[_ ]*)\s*$"#)
    private static let tableRowRegex = try! NSRegularExpression(pattern: #"^\s*\|(.+)\|\s*$"#)
    private static let tableSepRegex = try! NSRegularExpression(pattern: #"^\s*\|[\s:|-]+\|\s*$"#)

    // Inline regexes
    private static let boldRegex = try! NSRegularExpression(pattern: #"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#)
    private static let italicRegex = try! NSRegularExpression(pattern: #"(?<![\*_])(\*|_)(?=\S)([^\*_]+?)(?<=\S)\1(?![\*_])"#)
    private static let strikeRegex = try! NSRegularExpression(pattern: #"(~~)(?=\S)(.+?)(?<=\S)(~~)"#)
    private static let highlightRegex = try! NSRegularExpression(pattern: #"(==)(?=\S)(.+?)(?<=\S)(==)"#)
    private static let inlineCodeRegex = try! NSRegularExpression(pattern: #"(`+)([^`\n]+?)\1"#)
    private static let inlineMathRegex = try! NSRegularExpression(pattern: #"(\$)(?!\$)([^\$\n]+?)(\$)"#)
    private static let linkRegex = try! NSRegularExpression(pattern: #"(!?\[)([^\]]+)(\]\()([^\)]+)(\))"#)

    private static let codeKeywordsRegex = try! NSRegularExpression(
        pattern: #"\b(func|let|var|struct|class|enum|protocol|extension|import|return|if|else|switch|case|default|for|while|in|guard|try|catch|throw|throws|async|await|public|private|internal|static|final|override|init|self|super|true|false|nil|null|const|function|export|from|def|lambda|None|True|False|fn|mut|impl|pub|use|match)\b"#
    )
    private static let codeStringsRegex = try! NSRegularExpression(pattern: #""[^"\n]*""#)
    private static let codeCommentsRegex = try! NSRegularExpression(pattern: #"//.*$|#.*$"#)

    @discardableResult
    public static func applyStyles(
        to storage: NSTextStorage,
        theme: EditorTheme,
        sourceCodeMode: Bool,
        focusMode: Bool,
        selectedRange: NSRange
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

        // Base paragraph style
        let baseParagraph = NSMutableParagraphStyle()
        baseParagraph.lineSpacing = 4.5
        baseParagraph.paragraphSpacing = 8.0
        if theme == .classic || theme == .modernist {
            baseParagraph.alignment = .justified
        }

        let baseFont = sourceCodeMode ? theme.codeFont(size: theme.baseFontSize) : theme.bodyFont(size: theme.baseFontSize)
        let baseColor = theme.textNSColor

        storage.setAttributes([
            .font: baseFont,
            .foregroundColor: baseColor,
            .paragraphStyle: baseParagraph
        ], range: fullRange)

        var headings: [OutlineHeading] = []
        var decorations: [LineDecoration] = []

        var inCodeFence = false
        var inMathBlock = false
        var lineNumber = 1
        var index = 0

        while index < fullLength {
            let lineRange = nsString.lineRange(for: NSRange(location: index, length: 0))
            var contentRange = lineRange
            // Strip trailing newline from contentRange for regex matching
            while contentRange.length > 0 {
                let lastChar = nsString.character(at: contentRange.location + contentRange.length - 1)
                if lastChar == 10 || lastChar == 13 {
                    contentRange.length -= 1
                } else {
                    break
                }
            }

            let lineText = nsString.substring(with: contentRange)
            let isActiveLine = NSIntersectionRange(lineRange, activeLineRange).length > 0 ||
                (selectedRange.location == lineRange.location + lineRange.length && lineRange.location == activeLineRange.location)

            let dimFactor: CGFloat = (focusMode && !isActiveLine) ? 0.30 : 1.0

            if sourceCodeMode {
                // In Source Code Mode (Cmd+/), keep monospace font and highlight raw tokens subtly
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
                        value: NSFont.monospacedSystemFont(ofSize: theme.baseFontSize, weight: .bold),
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

            // 1. Check Code Fence (```)
            let trimmedLine = lineText.trimmingCharacters(in: .whitespaces)
            if trimmedLine.hasPrefix("```") {
                let codeMono = theme.codeFont(size: theme.baseFontSize * 0.88)
                storage.addAttribute(.font, value: codeMono, range: contentRange)
                storage.addAttribute(
                    .foregroundColor,
                    value: theme.markdownTokenNSColor.withAlphaComponent(isActiveLine ? 0.9 : 0.45 * dimFactor),
                    range: contentRange
                )
                if !inCodeFence {
                    inCodeFence = true
                    let lang = String(trimmedLine.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    decorations.append(LineDecoration(lineRange: lineRange, kind: .codeFenceStart(language: lang)))
                } else {
                    inCodeFence = false
                    decorations.append(LineDecoration(lineRange: lineRange, kind: .codeFenceEnd))
                }
                index = NSMaxRange(lineRange)
                lineNumber += 1
                continue
            }

            if inCodeFence {
                decorations.append(LineDecoration(lineRange: lineRange, kind: .codeFenceBody))
                let codeMono = theme.codeFont(size: theme.baseFontSize * 0.90)
                let codePara = NSMutableParagraphStyle()
                codePara.lineSpacing = 3.0
                codePara.paragraphSpacing = 1.5
                codePara.firstLineHeadIndent = 14.0
                codePara.headIndent = 14.0

                storage.addAttributes([
                    .font: codeMono,
                    .foregroundColor: theme.textNSColor.withAlphaComponent(dimFactor),
                    .paragraphStyle: codePara
                ], range: lineRange)

                highlightCodeLine(in: storage, range: contentRange, theme: theme, dimFactor: dimFactor)
                index = NSMaxRange(lineRange)
                lineNumber += 1
                continue
            }

            // 2. Check Math Block ($$)
            if trimmedLine.hasPrefix("$$") {
                let mathMono = theme.codeFont(size: theme.baseFontSize * 0.92)
                storage.addAttribute(.font, value: mathMono, range: contentRange)
                storage.addAttribute(
                    .foregroundColor,
                    value: theme.linkNSColor.withAlphaComponent(isActiveLine ? 0.95 : 0.45 * dimFactor),
                    range: contentRange
                )
                if !inMathBlock {
                    inMathBlock = true
                    decorations.append(LineDecoration(lineRange: lineRange, kind: .mathBlockStart))
                } else {
                    inMathBlock = false
                    decorations.append(LineDecoration(lineRange: lineRange, kind: .mathBlockEnd))
                }
                index = NSMaxRange(lineRange)
                lineNumber += 1
                continue
            }

            if inMathBlock {
                decorations.append(LineDecoration(lineRange: lineRange, kind: .mathBlockBody))
                let mathPara = NSMutableParagraphStyle()
                mathPara.alignment = .center
                mathPara.lineSpacing = 4.0
                mathPara.paragraphSpacing = 4.0
                let mathFont = NSFont(name: "Times New Roman Italic", size: theme.baseFontSize * 1.15)
                    ?? theme.bodyFont(size: theme.baseFontSize * 1.15, italic: true)
                storage.addAttributes([
                    .font: mathFont,
                    .foregroundColor: theme.headingNSColor.withAlphaComponent(dimFactor),
                    .paragraphStyle: mathPara
                ], range: lineRange)
                index = NSMaxRange(lineRange)
                lineNumber += 1
                continue
            }

            // 3. Check Horizontal Rule (--- / ***)
            if contentRange.length >= 3,
               hrRegex.firstMatch(in: string, options: [], range: contentRange) != nil {
                decorations.append(LineDecoration(lineRange: lineRange, kind: .horizontalRule))
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

            // 4. Check Heading (# .. ######)
            if let match = headingRegex.firstMatch(in: string, options: [], range: contentRange) {
                let hashesRange = match.range(at: 1)
                let spaceRange = match.range(at: 2)
                let titleRange = match.range(at: 3)
                let level = min(6, max(1, hashesRange.length))
                let titleText = nsString.substring(with: titleRange)

                headings.append(OutlineHeading(
                    level: level,
                    title: titleText,
                    characterLocation: contentRange.location,
                    lineNumber: lineNumber
                ))

                let hFont = theme.headingFont(level: level)
                let hPara = NSMutableParagraphStyle()
                hPara.paragraphSpacingBefore = level == 1 ? 14.0 : (level == 2 ? 11.0 : 8.0)
                hPara.paragraphSpacing = level <= 2 ? 10.0 : 6.0
                if (theme == .classic && level <= 3) || (theme == .modernist && level == 1) {
                    hPara.alignment = .center
                }

                storage.addAttributes([
                    .font: hFont,
                    .foregroundColor: theme.headingNSColor.withAlphaComponent(dimFactor),
                    .paragraphStyle: hPara
                ], range: lineRange)

                let prefixRange = NSRange(location: hashesRange.location, length: hashesRange.length + spaceRange.length)
                styleSyntaxToken(
                    in: storage,
                    range: prefixRange,
                    isActiveLine: isActiveLine,
                    theme: theme,
                    dimFactor: dimFactor
                )

                if level <= 2 {
                    decorations.append(LineDecoration(lineRange: lineRange, kind: .headingUnderline(level: level)))
                }

                styleInlineMarkdown(
                    in: storage,
                    string: string,
                    range: titleRange,
                    baseFont: hFont,
                    isActiveLine: isActiveLine,
                    theme: theme,
                    dimFactor: dimFactor
                )

                index = NSMaxRange(lineRange)
                lineNumber += 1
                continue
            }

            // 5. Check Blockquote (> ...)
            if let match = blockquoteRegex.firstMatch(in: string, options: [], range: contentRange) {
                let markerRange = match.range(at: 1)
                let bodyRange = match.range(at: 2)
                let markerText = nsString.substring(with: markerRange)
                let nestLevel = max(1, markerText.filter { $0 == ">" }.count)

                decorations.append(LineDecoration(lineRange: lineRange, kind: .blockquote(nestLevel: nestLevel)))

                let bqPara = NSMutableParagraphStyle()
                bqPara.firstLineHeadIndent = CGFloat(nestLevel) * 16.0
                bqPara.headIndent = CGFloat(nestLevel) * 16.0
                bqPara.lineSpacing = 4.5
                bqPara.paragraphSpacing = 6.0

                let bqFont = theme.bodyFont(size: theme.baseFontSize, italic: theme == .parchment || theme == .editorial)
                storage.addAttributes([
                    .font: bqFont,
                    .foregroundColor: theme.blockquoteTextNSColor.withAlphaComponent(dimFactor),
                    .paragraphStyle: bqPara
                ], range: lineRange)

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
                    range: bodyRange,
                    baseFont: bqFont,
                    isActiveLine: isActiveLine,
                    theme: theme,
                    dimFactor: dimFactor
                )

                index = NSMaxRange(lineRange)
                lineNumber += 1
                continue
            }

            // 6. Check Table Row (| col | col |)
            if tableRowRegex.firstMatch(in: string, options: [], range: contentRange) != nil {
                let isSeparator = tableSepRegex.firstMatch(in: string, options: [], range: contentRange) != nil
                if isSeparator {
                    decorations.append(LineDecoration(lineRange: lineRange, kind: .tableSeparatorRow))
                    styleSyntaxToken(
                        in: storage,
                        range: contentRange,
                        isActiveLine: isActiveLine,
                        theme: theme,
                        dimFactor: dimFactor
                    )
                } else {
                    let isHeader: Bool
                    if let lastDec = decorations.last,
                       case .tableHeaderRow = lastDec.kind {
                        isHeader = false
                    } else if let lastDec = decorations.last,
                              case .tableSeparatorRow = lastDec.kind {
                        isHeader = false
                    } else if let lastDec = decorations.last,
                              case .tableBodyRow = lastDec.kind {
                        isHeader = false
                    } else {
                        isHeader = true
                    }

                    if isHeader {
                        decorations.append(LineDecoration(lineRange: lineRange, kind: .tableHeaderRow))
                    } else {
                        let prevRowIdx: Int
                        if let lastDec = decorations.last, case let .tableBodyRow(idx) = lastDec.kind {
                            prevRowIdx = idx + 1
                        } else {
                            prevRowIdx = 0
                        }
                        decorations.append(LineDecoration(lineRange: lineRange, kind: .tableBodyRow(rowIndex: prevRowIdx)))
                    }

                    let tableFont = NSFont.monospacedSystemFont(
                        ofSize: theme.baseFontSize * 0.92,
                        weight: isHeader ? .semibold : .regular
                    )
                    let tablePara = NSMutableParagraphStyle()
                    tablePara.lineSpacing = 5.0
                    tablePara.paragraphSpacing = 3.0
                    tablePara.firstLineHeadIndent = 8.0
                    tablePara.headIndent = 8.0

                    storage.addAttributes([
                        .font: tableFont,
                        .foregroundColor: (isHeader ? theme.headingNSColor : theme.textNSColor).withAlphaComponent(dimFactor),
                        .paragraphStyle: tablePara
                    ], range: lineRange)

                    styleInlineMarkdown(
                        in: storage,
                        string: string,
                        range: contentRange,
                        baseFont: tableFont,
                        isActiveLine: isActiveLine,
                        theme: theme,
                        dimFactor: dimFactor
                    )
                }

                index = NSMaxRange(lineRange)
                lineNumber += 1
                continue
            }

            // 7. Check Task List (- [ ] / - [x])
            if let match = taskListRegex.firstMatch(in: string, options: [], range: contentRange) {
                let bulletRange = match.range(at: 1)
                let boxRange = match.range(at: 2)
                let textRange = match.range(at: 4)
                let boxStr = nsString.substring(with: boxRange).lowercased()
                let isChecked = boxStr == "[x]"

                let listPara = NSMutableParagraphStyle()
                listPara.firstLineHeadIndent = 10.0
                listPara.headIndent = 28.0
                listPara.lineSpacing = 4.5
                listPara.paragraphSpacing = 4.0
                storage.addAttribute(.paragraphStyle, value: listPara, range: lineRange)

                styleSyntaxToken(
                    in: storage,
                    range: bulletRange,
                    isActiveLine: isActiveLine,
                    theme: theme,
                    dimFactor: dimFactor
                )

                storage.addAttributes([
                    .font: NSFont.monospacedSystemFont(ofSize: theme.baseFontSize * 0.92, weight: .bold),
                    .foregroundColor: (isChecked ? theme.linkNSColor : theme.secondaryTextNSColor).withAlphaComponent(dimFactor)
                ], range: boxRange)

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
                    dimFactor: dimFactor
                )

                index = NSMaxRange(lineRange)
                lineNumber += 1
                continue
            }

            // 8. Check Unordered / Ordered Lists
            if let match = unorderedListRegex.firstMatch(in: string, options: [], range: contentRange) ??
                orderedListRegex.firstMatch(in: string, options: [], range: contentRange) {
                let markerRange = match.range(at: 1)
                let bodyRange = match.range(at: 2)

                let listPara = NSMutableParagraphStyle()
                listPara.firstLineHeadIndent = 8.0
                listPara.headIndent = 24.0
                listPara.lineSpacing = 4.5
                listPara.paragraphSpacing = 4.0
                storage.addAttribute(.paragraphStyle, value: listPara, range: lineRange)

                storage.addAttributes([
                    .font: theme.bodyFont(size: theme.baseFontSize, bold: true),
                    .foregroundColor: theme.linkNSColor.withAlphaComponent(dimFactor)
                ], range: markerRange)

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
                    dimFactor: dimFactor
                )

                index = NSMaxRange(lineRange)
                lineNumber += 1
                continue
            }

            // Default paragraph line
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
                dimFactor: dimFactor
            )

            index = NSMaxRange(lineRange)
            lineNumber += 1
        }

        storage.endEditing()
        return MarkdownDocumentAnalysis(headings: headings, decorations: decorations)
    }

    private static func styleInlineMarkdown(
        in storage: NSTextStorage,
        string: String,
        range: NSRange,
        baseFont: NSFont,
        isActiveLine: Bool,
        theme: EditorTheme,
        dimFactor: CGFloat
    ) {
        guard range.length > 0 else { return }
        let fontSize = baseFont.pointSize

        // Bold (**text** or __text__)
        boldRegex.enumerateMatches(in: string, options: [], range: range) { match, _, _ in
            guard let match = match else { return }
            let openRange = match.range(at: 1)
            let innerRange = match.range(at: 2)
            let closeRange = NSRange(location: NSMaxRange(innerRange), length: openRange.length)

            let boldFont = NSFontManager.shared.convert(baseFont, toHaveTrait: .boldFontMask)
            storage.addAttribute(.font, value: boldFont, range: innerRange)
            styleSyntaxToken(in: storage, range: openRange, isActiveLine: isActiveLine, theme: theme, dimFactor: dimFactor)
            styleSyntaxToken(in: storage, range: closeRange, isActiveLine: isActiveLine, theme: theme, dimFactor: dimFactor)
        }

        // Italic (*text* or _text_)
        italicRegex.enumerateMatches(in: string, options: [], range: range) { match, _, _ in
            guard let match = match else { return }
            let openRange = match.range(at: 1)
            let innerRange = match.range(at: 2)
            let closeRange = NSRange(location: NSMaxRange(innerRange), length: openRange.length)

            let italicFont = NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
            storage.addAttribute(.font, value: italicFont, range: innerRange)
            styleSyntaxToken(in: storage, range: openRange, isActiveLine: isActiveLine, theme: theme, dimFactor: dimFactor)
            styleSyntaxToken(in: storage, range: closeRange, isActiveLine: isActiveLine, theme: theme, dimFactor: dimFactor)
        }

        // Strikethrough (~~text~~)
        strikeRegex.enumerateMatches(in: string, options: [], range: range) { match, _, _ in
            guard let match = match else { return }
            let openRange = match.range(at: 1)
            let innerRange = match.range(at: 2)
            let closeRange = match.range(at: 3)

            storage.addAttributes([
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                .foregroundColor: theme.secondaryTextNSColor.withAlphaComponent(dimFactor)
            ], range: innerRange)
            styleSyntaxToken(in: storage, range: openRange, isActiveLine: isActiveLine, theme: theme, dimFactor: dimFactor)
            styleSyntaxToken(in: storage, range: closeRange, isActiveLine: isActiveLine, theme: theme, dimFactor: dimFactor)
        }

        // Highlight (==text==)
        highlightRegex.enumerateMatches(in: string, options: [], range: range) { match, _, _ in
            guard let match = match else { return }
            let openRange = match.range(at: 1)
            let innerRange = match.range(at: 2)
            let closeRange = match.range(at: 3)

            let highlightBg = theme.isDark
                ? NSColor(srgbRed: 0.55, green: 0.45, blue: 0.12, alpha: 0.55 * dimFactor)
                : NSColor(srgbRed: 1.0, green: 0.93, blue: 0.45, alpha: 0.65 * dimFactor)
            storage.addAttribute(.backgroundColor, value: highlightBg, range: innerRange)
            styleSyntaxToken(in: storage, range: openRange, isActiveLine: isActiveLine, theme: theme, dimFactor: dimFactor)
            styleSyntaxToken(in: storage, range: closeRange, isActiveLine: isActiveLine, theme: theme, dimFactor: dimFactor)
        }

        // Inline Code (`code`)
        inlineCodeRegex.enumerateMatches(in: string, options: [], range: range) { match, _, _ in
            guard let match = match else { return }
            let openRange = match.range(at: 1)
            let innerRange = match.range(at: 2)
            let closeRange = NSRange(location: NSMaxRange(innerRange), length: openRange.length)

            storage.addAttributes([
                .font: theme.codeFont(size: fontSize * 0.88),
                .foregroundColor: theme.inlineCodeNSColor.withAlphaComponent(dimFactor),
                .backgroundColor: theme.codeBackgroundNSColor.withAlphaComponent(dimFactor)
            ], range: innerRange)
            styleSyntaxToken(in: storage, range: openRange, isActiveLine: isActiveLine, theme: theme, dimFactor: dimFactor)
            styleSyntaxToken(in: storage, range: closeRange, isActiveLine: isActiveLine, theme: theme, dimFactor: dimFactor)
        }

        // Inline Math ($E = mc^2$)
        inlineMathRegex.enumerateMatches(in: string, options: [], range: range) { match, _, _ in
            guard let match = match else { return }
            let openRange = match.range(at: 1)
            let innerRange = match.range(at: 2)
            let closeRange = match.range(at: 3)

            let mathFont = NSFont(name: "Times New Roman Italic", size: fontSize * 1.05)
                ?? theme.bodyFont(size: fontSize * 1.05, italic: true)
            storage.addAttributes([
                .font: mathFont,
                .foregroundColor: theme.linkNSColor.withAlphaComponent(dimFactor)
            ], range: innerRange)
            styleSyntaxToken(in: storage, range: openRange, isActiveLine: isActiveLine, theme: theme, dimFactor: dimFactor)
            styleSyntaxToken(in: storage, range: closeRange, isActiveLine: isActiveLine, theme: theme, dimFactor: dimFactor)
        }

        // Links ([label](url))
        linkRegex.enumerateMatches(in: string, options: [], range: range) { match, _, _ in
            guard let match = match else { return }
            let openBracket = match.range(at: 1)
            let labelRange = match.range(at: 2)
            let midRange = match.range(at: 3)
            let urlRange = match.range(at: 4)
            let closeParen = match.range(at: 5)

            storage.addAttributes([
                .foregroundColor: theme.linkNSColor.withAlphaComponent(dimFactor),
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ], range: labelRange)

            let trailingSyntaxRange = NSRange(
                location: midRange.location,
                length: midRange.length + urlRange.length + closeParen.length
            )
            styleSyntaxToken(in: storage, range: openBracket, isActiveLine: isActiveLine, theme: theme, dimFactor: dimFactor)
            styleSyntaxToken(in: storage, range: trailingSyntaxRange, isActiveLine: isActiveLine, theme: theme, dimFactor: dimFactor)
        }
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
            // Reveal Markdown syntax token on the active line where the cursor sits
            storage.addAttributes([
                .foregroundColor: theme.markdownTokenNSColor.withAlphaComponent(0.85 * dimFactor),
                .font: theme.codeFont(size: max(11.0, theme.baseFontSize * 0.85))
            ], range: range)
        } else {
            // Collapse syntax token on inactive lines for seamless live preview
            storage.addAttributes([
                .foregroundColor: NSColor.clear,
                .font: NSFont.systemFont(ofSize: 0.1),
                .kern: -2.0
            ], range: range)
        }
    }

    private static func highlightCodeLine(
        in storage: NSTextStorage,
        range: NSRange,
        theme: EditorTheme,
        dimFactor: CGFloat
    ) {
        guard range.length > 0 else { return }
        let string = storage.string

        let keywordColor = theme.isDark
            ? NSColor(srgbRed: 0.78, green: 0.56, blue: 0.89, alpha: dimFactor)
            : NSColor(srgbRed: 0.65, green: 0.11, blue: 0.36, alpha: dimFactor)
        let stringColor = theme.isDark
            ? NSColor(srgbRed: 0.60, green: 0.78, blue: 0.48, alpha: dimFactor)
            : NSColor(srgbRed: 0.09, green: 0.31, blue: 0.58, alpha: dimFactor)
        let commentColor = theme.secondaryTextNSColor.withAlphaComponent(0.75 * dimFactor)

        codeKeywordsRegex.enumerateMatches(in: string, options: [], range: range) { match, _, _ in
            if let r = match?.range {
                storage.addAttribute(.foregroundColor, value: keywordColor, range: r)
            }
        }
        codeStringsRegex.enumerateMatches(in: string, options: [], range: range) { match, _, _ in
            if let r = match?.range {
                storage.addAttribute(.foregroundColor, value: stringColor, range: r)
            }
        }
        codeCommentsRegex.enumerateMatches(in: string, options: [], range: range) { match, _, _ in
            if let r = match?.range {
                storage.addAttribute(.foregroundColor, value: commentColor, range: r)
            }
        }
    }
}
