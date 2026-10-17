import AppKit
import Foundation

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
    case horizontalRule
    case tableRow(
        isHeader: Bool,
        isSeparator: Bool,
        isFirstRow: Bool,
        isLastRow: Bool,
        bodyRowIndex: Int,
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
    private static let italicRegex = try! NSRegularExpression(pattern: #"(?<![\*_])(\*|_)(?=\S)([^\*_\n]+?)(?<=\S)\1(?![\*_])"#)
    private static let strikeRegex = try! NSRegularExpression(pattern: #"(~~)(?=\S)(.+?)(?<=\S)(~~)"#)
    private static let highlightRegex = try! NSRegularExpression(pattern: #"(==)(?=\S)(.+?)(?<=\S)(==)"#)
    // CommonMark-compliant inline code regex: matches exact backtick run length (e.g. `` ` `` or `code`) without splitting multi-backticks
    private static let inlineCodeRegex = try! NSRegularExpression(pattern: #"(?<!`)(`+)(?!`)((?:(?!\1)[^\n])+?)(?<!`)\1(?!`)"#)
    private static let inlineMathRegex = try! NSRegularExpression(pattern: #"(?<!\$)(\$)(?!\$)([^\$\n]+?)(?<!\$)(\$)(?!\$)"#)
    private static let linkRegex = try! NSRegularExpression(pattern: #"(!?\[)([^\]]+)(\]\()([^\)]+)(\))"#)

    private static let latexCommandRegex = try! NSRegularExpression(pattern: #"\\[a-zA-Z]+|\\[^a-zA-Z\s]"#)
    private static let latexBracesRegex = try! NSRegularExpression(pattern: #"[\{\}\^_]"#)

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
        var currentFenceLanguage = ""
        var lineNumber = 1
        var index = 0

        while index < fullLength {
            let lineRange = nsString.lineRange(for: NSRange(location: index, length: 0))
            let contentRange = strippedLineContentRange(nsString: nsString, lineRange: lineRange)
            let lineText = nsString.substring(with: contentRange)
            let isActiveLine = isLineActive(lineRange: lineRange, activeLineRange: activeLineRange, selectedRange: selectedRange)
            let dimFactor: CGFloat = (focusMode && !isActiveLine) ? 0.30 : 1.0

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
                    currentFenceLanguage = lang.lowercased()
                    decorations.append(LineDecoration(lineRange: lineRange, kind: .codeFenceStart(language: lang)))
                } else {
                    inCodeFence = false
                    currentFenceLanguage = ""
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

            // 2. Check Display Math Block ($$ ... $$) as a cohesive unit
            if trimmedLine.hasPrefix("$$") {
                var mathLines: [(lineRange: NSRange, contentRange: NSRange, text: String, isActive: Bool)] = []
                mathLines.append((lineRange, contentRange, lineText, isActiveLine))

                var scanIndex = NSMaxRange(lineRange)
                var scanLineCount = 1
                // Single-line $$ ... $$ (e.g. $$ E = mc^2 $$)
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
                        // Cursor is inside the math block: show editable syntax-highlighted LaTeX source
                        let mathMono = theme.codeFont(size: theme.baseFontSize * 0.92)
                        let mathPara = NSMutableParagraphStyle()
                        mathPara.lineSpacing = 3.5
                        mathPara.paragraphSpacing = 2.0
                        mathPara.firstLineHeadIndent = 14.0
                        mathPara.headIndent = 14.0
                        storage.addAttributes([
                            .font: mathMono,
                            .foregroundColor: theme.textNSColor,
                            .paragraphStyle: mathPara
                        ], range: mLine.lineRange)

                        if t.hasPrefix("$$") {
                            storage.addAttribute(.foregroundColor, value: theme.linkNSColor.withAlphaComponent(0.9), range: mLine.contentRange)
                        } else {
                            highlightLaTeXSource(in: storage, range: mLine.contentRange, theme: theme, dimFactor: 1.0)
                        }
                    } else {
                        // Cursor is outside the math block: hide raw LaTeX text and let HybridMarkdownTextView draw the 2D equation
                        let mathPara = NSMutableParagraphStyle()
                        mathPara.alignment = .center
                        mathPara.lineSpacing = 4.0
                        mathPara.paragraphSpacing = 4.0
                        storage.addAttributes([
                            .font: theme.bodyFont(size: theme.baseFontSize),
                            .foregroundColor: NSColor.clear,
                            .paragraphStyle: mathPara
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
                    dimFactor: dimFactor,
                    decorations: &decorations
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
                    dimFactor: dimFactor,
                    decorations: &decorations
                )

                index = NSMaxRange(lineRange)
                lineNumber += 1
                continue
            }

            // 6. Check Table Block (contiguous | col | col | lines)
            if tableRowRegex.firstMatch(in: string, options: [], range: contentRange) != nil {
                var tableRows: [(lineRange: NSRange, contentRange: NSRange, isActive: Bool, isSeparator: Bool)] = []
                var scanIndex = index
                var scanLines = 0

                while scanIndex < fullLength {
                    let nextLR = nsString.lineRange(for: NSRange(location: scanIndex, length: 0))
                    let nextCR = strippedLineContentRange(nsString: nsString, lineRange: nextLR)
                    guard nextCR.length > 0,
                          tableRowRegex.firstMatch(in: string, options: [], range: nextCR) != nil else {
                        break
                    }
                    let nextActive = isLineActive(lineRange: nextLR, activeLineRange: activeLineRange, selectedRange: selectedRange)
                    let nextSep = tableSepRegex.firstMatch(in: string, options: [], range: nextCR) != nil
                    tableRows.append((nextLR, nextCR, nextActive, nextSep))
                    scanIndex = NSMaxRange(nextLR)
                    scanLines += 1
                }

                styleTableBlock(
                    rows: tableRows,
                    in: storage,
                    string: string,
                    nsString: nsString,
                    theme: theme,
                    focusMode: focusMode,
                    decorations: &decorations
                )

                index = scanIndex
                lineNumber += scanLines
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
                    dimFactor: dimFactor,
                    decorations: &decorations
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
                    dimFactor: dimFactor,
                    decorations: &decorations
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
                dimFactor: dimFactor,
                decorations: &decorations
            )

            index = NSMaxRange(lineRange)
            lineNumber += 1
        }

        storage.endEditing()
        return MarkdownDocumentAnalysis(headings: headings, decorations: decorations)
    }

    // MARK: - Helpers for Line Ranges
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

    // MARK: - Table Block Layout & Column Alignment
    private struct ParsedTableCell {
        let leadingDelimiterRange: NSRange // pipe + leading spaces before cell content
        let contentRange: NSRange          // trimmed cell text
        let trailingSpacesRange: NSRange   // trailing spaces before the next pipe
    }

    private struct ParsedTableRow {
        let cells: [ParsedTableCell]
        let closingPipeRange: NSRange
    }

    private static func parseTableRowCells(nsString: NSString, contentRange: NSRange) -> ParsedTableRow? {
        var pipeLocations: [Int] = []
        let endLoc = NSMaxRange(contentRange)
        var idx = contentRange.location
        while idx < endLoc {
            let ch = nsString.character(at: idx)
            if ch == 0x5C { // backslash escape
                idx += 2
                continue
            }
            if ch == 0x7C { // '|'
                pipeLocations.append(idx)
            }
            idx += 1
        }

        guard pipeLocations.count >= 2 else { return nil }

        var cells: [ParsedTableCell] = []
        for i in 0..<(pipeLocations.count - 1) {
            let pipePos = pipeLocations[i]
            let nextPipePos = pipeLocations[i + 1]

            // Trim spaces between pipePos+1 and nextPipePos
            var contentStart = pipePos + 1
            while contentStart < nextPipePos {
                let c = nsString.character(at: contentStart)
                if c == 32 || c == 9 { contentStart += 1 } else { break }
            }

            var contentEnd = nextPipePos
            while contentEnd > contentStart {
                let c = nsString.character(at: contentEnd - 1)
                if c == 32 || c == 9 { contentEnd -= 1 } else { break }
            }

            let leadingRange = NSRange(location: pipePos, length: contentStart - pipePos)
            let cellRange = NSRange(location: contentStart, length: contentEnd - contentStart)
            let trailingRange = NSRange(location: contentEnd, length: nextPipePos - contentEnd)
            cells.append(ParsedTableCell(
                leadingDelimiterRange: leadingRange,
                contentRange: cellRange,
                trailingSpacesRange: trailingRange
            ))
        }

        let lastPipe = pipeLocations.last!
        let closingRange = NSRange(location: lastPipe, length: endLoc - lastPipe)
        return ParsedTableRow(cells: cells, closingPipeRange: closingRange)
    }

    private static func styleTableBlock(
        rows: [(lineRange: NSRange, contentRange: NSRange, isActive: Bool, isSeparator: Bool)],
        in storage: NSTextStorage,
        string: String,
        nsString: NSString,
        theme: EditorTheme,
        focusMode: Bool,
        decorations: inout [LineDecoration]
    ) {
        guard !rows.isEmpty else { return }

        let parsedRows: [ParsedTableRow?] = rows.map { parseTableRowCells(nsString: nsString, contentRange: $0.contentRange) }
        let numCols = parsedRows.compactMap({ $0?.cells.count }).max() ?? 1

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

        for (rIdx, row) in rows.enumerated() {
            let dimFactor: CGFloat = (focusMode && !row.isActive) ? 0.30 : 1.0
            let isHeader = (rIdx == 0)

            if row.isSeparator {
                if row.isActive {
                    let activePara = NSMutableParagraphStyle()
                    activePara.lineSpacing = 2.0
                    activePara.paragraphSpacing = 0.0
                    storage.addAttributes([
                        .font: theme.codeFont(size: theme.baseFontSize * 0.88),
                        .foregroundColor: theme.markdownTokenNSColor.withAlphaComponent(0.9 * dimFactor),
                        .paragraphStyle: activePara
                    ], range: row.lineRange)
                } else {
                    // Collapse separator row on inactive line into a clean hairline
                    let collapsedPara = NSMutableParagraphStyle()
                    collapsedPara.minimumLineHeight = 2.0
                    collapsedPara.maximumLineHeight = 2.0
                    collapsedPara.lineSpacing = 0.0
                    collapsedPara.paragraphSpacing = 0.0
                    storage.addAttributes([
                        .font: NSFont.systemFont(ofSize: 0.5),
                        .foregroundColor: NSColor.clear,
                        .paragraphStyle: collapsedPara
                    ], range: row.lineRange)
                }
                continue
            }

            let cellFont: NSFont
            if row.isActive {
                cellFont = theme.codeFont(size: theme.baseFontSize * 0.90)
            } else {
                cellFont = theme.bodyFont(size: theme.baseFontSize * 0.93, bold: isHeader)
            }

            let rowPara = NSMutableParagraphStyle()
            rowPara.lineSpacing = 0.0
            rowPara.paragraphSpacing = 0.0
            rowPara.minimumLineHeight = 26.0

            storage.addAttributes([
                .font: cellFont,
                .foregroundColor: (isHeader ? theme.headingNSColor : theme.textNSColor).withAlphaComponent(dimFactor),
                .paragraphStyle: rowPara
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
                        decorations: &decorations
                    )
                    let cellAttr = storage.attributedSubstring(from: cell.contentRange)
                    measuredWidths[rIdx][cIdx] = ceil(cellAttr.size().width)
                }
            }

            if row.isActive {
                // Highlight pipe delimiters in muted token color when editing the row
                for cell in parsed.cells {
                    let pipeRange = NSRange(location: cell.leadingDelimiterRange.location, length: 1)
                    storage.addAttribute(.foregroundColor, value: theme.markdownTokenNSColor.withAlphaComponent(0.85), range: pipeRange)
                }
                storage.addAttribute(.foregroundColor, value: theme.markdownTokenNSColor.withAlphaComponent(0.85), range: parsed.closingPipeRange)
            }
        }

        // Compute column widths and column start X coordinates
        let cellHorizontalPadding: CGFloat = 16.0
        var colWidths: [CGFloat] = (0..<numCols).map { cIdx in
            let maxCellW = (0..<rows.count).map({ measuredWidths[$0][cIdx] }).max() ?? 40.0
            return max(72.0, maxCellW + cellHorizontalPadding * 2.0)
        }

        let minTableWidth = min(640.0, theme.maxWriteWidth * 0.88)
        let naturalSum = colWidths.reduce(0, +)
        if naturalSum < minTableWidth && naturalSum > 0 {
            let scale = minTableWidth / naturalSum
            colWidths = colWidths.map { floor($0 * scale) }
        }

        var colStartX: [CGFloat] = Array(repeating: 0, count: numCols)
        var runningX: CGFloat = 0
        for cIdx in 0..<numCols {
            colStartX[cIdx] = runningX
            runningX += colWidths[cIdx]
        }
        let totalTableWidth = runningX
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
                    tableWidth: totalTableWidth,
                    columnDividers: columnDividerX
                )
            ))

            guard !row.isActive, !row.isSeparator, let parsed = parsedRows[rIdx] else { continue }

            let tinyFont = NSFont.systemFont(ofSize: 0.01)

            // Hide closing pipe
            storage.addAttributes([
                .font: tinyFont,
                .foregroundColor: NSColor.clear,
                .kern: 0.0
            ], range: parsed.closingPipeRange)

            var currentCursorX: CGFloat = 0.0

            for (cIdx, cell) in parsed.cells.enumerated() where cIdx < numCols {
                // Hide leading delimiter (pipe + spaces) and trailing spaces
                storage.addAttributes([
                    .font: tinyFont,
                    .foregroundColor: NSColor.clear,
                    .kern: 0.0
                ], range: cell.leadingDelimiterRange)

                if cell.trailingSpacesRange.length > 0 {
                    storage.addAttributes([
                        .font: tinyFont,
                        .foregroundColor: NSColor.clear,
                        .kern: 0.0
                    ], range: cell.trailingSpacesRange)
                }

                let cellW = measuredWidths[rIdx][cIdx]
                let colW = colWidths[cIdx]
                let alignOffset: CGFloat
                switch alignments[cIdx] {
                case .left:
                    alignOffset = cellHorizontalPadding
                case .center:
                    alignOffset = max(cellHorizontalPadding, floor((colW - cellW) * 0.5))
                case .right:
                    alignOffset = max(cellHorizontalPadding, colW - cellW - cellHorizontalPadding)
                }

                let targetCellStartX = colStartX[cIdx] + alignOffset
                let deltaKern = max(2.0, targetCellStartX - currentCursorX)

                // Apply deltaKern to the pipe character at the start of this cell's leadingDelimiterRange
                let pipeCharRange = NSRange(location: cell.leadingDelimiterRange.location, length: 1)
                storage.addAttribute(.kern, value: deltaKern, range: pipeCharRange)

                currentCursorX = targetCellStartX + cellW
            }
        }
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
        decorations: inout [LineDecoration]
    ) {
        guard range.length > 0 else { return }
        let nsString = string as NSString
        let fontSize = baseFont.pointSize

        // Track inline code and inline math ranges first so bold/italic/etc. never style inside code or math!
        var protectedRanges: [NSRange] = []

        // 1. Inline Code (`code` or `` ` ``)
        inlineCodeRegex.enumerateMatches(in: string, options: [], range: range) { match, _, _ in
            guard let match = match else { return }
            let fullMatchRange = match.range(at: 0)
            protectedRanges.append(fullMatchRange)

            var openRange = match.range(at: 1)
            var innerRange = match.range(at: 2)
            var closeRange = NSRange(location: NSMaxRange(innerRange), length: openRange.length)

            // CommonMark rule: if code span has a leading AND trailing space (e.g. `` ` ``), strip one space from each end
            if innerRange.length >= 2 {
                let firstChar = nsString.character(at: innerRange.location)
                let lastChar = nsString.character(at: NSMaxRange(innerRange) - 1)
                if firstChar == 32 && lastChar == 32 {
                    openRange.length += 1
                    innerRange.location += 1
                    innerRange.length -= 2
                    closeRange.location -= 1
                    closeRange.length += 1
                }
            }

            storage.addAttributes([
                .font: theme.codeFont(size: fontSize * 0.88),
                .foregroundColor: theme.inlineCodeNSColor.withAlphaComponent(dimFactor),
                .backgroundColor: theme.codeBackgroundNSColor.withAlphaComponent(dimFactor)
            ], range: innerRange)
            styleSyntaxToken(in: storage, range: openRange, isActiveLine: isActiveLine, theme: theme, dimFactor: dimFactor)
            styleSyntaxToken(in: storage, range: closeRange, isActiveLine: isActiveLine, theme: theme, dimFactor: dimFactor)
        }

        // 2. Inline Math ($E = mc^2$)
        inlineMathRegex.enumerateMatches(in: string, options: [], range: range) { match, _, _ in
            guard let match = match else { return }
            let fullMatchRange = match.range(at: 0)
            if protectedRanges.contains(where: { NSIntersectionRange($0, fullMatchRange).length > 0 }) {
                return
            }
            protectedRanges.append(fullMatchRange)

            let openRange = match.range(at: 1)
            let innerRange = match.range(at: 2)
            let closeRange = match.range(at: 3)
            let latexStr = nsString.substring(with: innerRange)

            if isActiveLine {
                // On the active line, show editable LaTeX source with syntax coloring
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
                // On inactive lines, reserve the exact pixel width of the 2D rendered math formula and let HybridMarkdownTextView draw it
                let mathNode = LaTeXMathRenderer.parse(latexStr)
                let mathBox = LaTeXMathRenderer.layout(node: mathNode, baseFontSize: fontSize, isDisplayStyle: false)
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

        // Helper to skip matches that overlap inline code or inline math
        let isProtected: (NSRange) -> Bool = { r in
            protectedRanges.contains { NSIntersectionRange($0, r).length > 0 }
        }

        // 3. Bold (**text** or __text__)
        boldRegex.enumerateMatches(in: string, options: [], range: range) { match, _, _ in
            guard let match = match, !isProtected(match.range) else { return }
            let openRange = match.range(at: 1)
            let innerRange = match.range(at: 2)
            let closeRange = NSRange(location: NSMaxRange(innerRange), length: openRange.length)

            let boldFont = NSFontManager.shared.convert(baseFont, toHaveTrait: .boldFontMask)
            storage.addAttribute(.font, value: boldFont, range: innerRange)
            styleSyntaxToken(in: storage, range: openRange, isActiveLine: isActiveLine, theme: theme, dimFactor: dimFactor)
            styleSyntaxToken(in: storage, range: closeRange, isActiveLine: isActiveLine, theme: theme, dimFactor: dimFactor)
        }

        // 4. Italic (*text* or _text_)
        italicRegex.enumerateMatches(in: string, options: [], range: range) { match, _, _ in
            guard let match = match, !isProtected(match.range) else { return }
            let openRange = match.range(at: 1)
            let innerRange = match.range(at: 2)
            let closeRange = NSRange(location: NSMaxRange(innerRange), length: openRange.length)

            let italicFont = NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
            storage.addAttribute(.font, value: italicFont, range: innerRange)
            styleSyntaxToken(in: storage, range: openRange, isActiveLine: isActiveLine, theme: theme, dimFactor: dimFactor)
            styleSyntaxToken(in: storage, range: closeRange, isActiveLine: isActiveLine, theme: theme, dimFactor: dimFactor)
        }

        // 5. Strikethrough (~~text~~)
        strikeRegex.enumerateMatches(in: string, options: [], range: range) { match, _, _ in
            guard let match = match, !isProtected(match.range) else { return }
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

        // 6. Highlight (==text==)
        highlightRegex.enumerateMatches(in: string, options: [], range: range) { match, _, _ in
            guard let match = match, !isProtected(match.range) else { return }
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

        // 7. Links ([label](url))
        linkRegex.enumerateMatches(in: string, options: [], range: range) { match, _, _ in
            guard let match = match, !isProtected(match.range) else { return }
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
            storage.addAttributes([
                .foregroundColor: theme.markdownTokenNSColor.withAlphaComponent(0.85 * dimFactor),
                .font: theme.codeFont(size: max(11.0, theme.baseFontSize * 0.85))
            ], range: range)
        } else {
            // Collapse syntax token to near-zero width without negative kerning distortion
            storage.addAttributes([
                .foregroundColor: NSColor.clear,
                .font: NSFont.systemFont(ofSize: 0.01),
                .kern: 0.0
            ], range: range)
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
