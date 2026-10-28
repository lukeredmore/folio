import AppKit
import Foundation

extension MarkdownLiveStyler {

    // MARK: - Table Block Layout & Column Alignment

    static func styleTableBlock(
        rows: [(lineRange: NSRange, contentRange: NSRange, isActive: Bool, isSeparator: Bool)],
        in storage: NSTextStorage,
        string: String,
        nsString: NSString,
        theme: EditorTheme,
        typography: EditorTypographySettings,
        containerWidth: CGFloat,
        focusMode: Bool,
        prettyMode: Bool = true,
        baseDirectoryURL: URL? = nil,
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
                    storage.addAttributes(
                        [
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
                    storage.addAttributes(
                        [
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

            storage.addAttributes(
                [
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
                        lineRange: row.lineRange,
                        baseFont: cellFont,
                        isActiveLine: row.isActive,
                        theme: theme,
                        dimFactor: dimFactor,
                        normalizeWhitespace: !row.isActive,
                        prettyMode: prettyMode,
                        baseDirectoryURL: baseDirectoryURL,
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

            decorations.append(
                LineDecoration(
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

                let actualCellW =
                    cell.contentRange.length > 0
                    ? max(0.0, measuredWidths[rIdx][cIdx] - 4.0)
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
                        let mutablePara = existingPara.mutableCopy() as? NSMutableParagraphStyle
                    {
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
}
