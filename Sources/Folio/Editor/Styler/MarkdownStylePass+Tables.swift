import AppKit
import Foundation

extension MarkdownStylePass {

    // MARK: - Table Block Layout & Column Alignment

    func tryStyleTableBlock(
        startIndex: Int,
        lineNumber: Int,
        contentRange: NSRange
    ) -> (nextIndex: Int, lineDelta: Int)? {
        guard Styler.isTableCandidateLine(nsString: nsString, contentRange: contentRange) else { return nil }
        var tableRows: [(lineRange: NSRange, contentRange: NSRange, isActive: Bool, isSeparator: Bool)] = []
        var scanIndex = startIndex
        var scanLines = 0
        while scanIndex < fullLength {
            let nextLR = nsString.lineRange(for: NSRange(location: scanIndex, length: 0))
            let nextCR = Styler.strippedLineContentRange(nsString: nsString, lineRange: nextLR)
            guard nextCR.length > 0, Styler.isTableCandidateLine(nsString: nsString, contentRange: nextCR) else { break }
            let nextActive = Styler.isLineActive(lineRange: nextLR, activeLineRange: activeLineRange, selectedRange: selectedRange)
            let nextSep = Styler.isTableSeparatorRow(nsString: nsString, contentRange: nextCR)
            tableRows.append((nextLR, nextCR, nextActive, nextSep))
            scanIndex = NSMaxRange(nextLR)
            scanLines += 1
        }
        let hasValidTableStructure =
            tableRows.count >= 2 && tableRows.contains(where: { $0.isSeparator })
            || (tableRows.count == 1 && nsString.substring(with: tableRows[0].contentRange).trimmingCharacters(in: .whitespaces).hasPrefix("|"))
        guard hasValidTableStructure else { return nil }

        for (rIdx, row) in tableRows.enumerated() {
            let rowLine = lineNumber + rIdx
            let rowDim: CGFloat = (focusMode && !row.isActive) ? 0.30 : 1.0
            let rowText = nsString.substring(with: row.contentRange)
            lineRecords[rowLine] = (row.lineRange, row.contentRange, rowText, row.isActive, rowDim)
            tableStyledLines.insert(rowLine)
        }

        styleTableBlock(rows: tableRows, startLineNumber: lineNumber)
        return (scanIndex, scanLines)
    }

    private func styleTableBlock(
        rows: [(lineRange: NSRange, contentRange: NSRange, isActive: Bool, isSeparator: Bool)],
        startLineNumber: Int
    ) {
        guard !rows.isEmpty else { return }

        let parsedRows: [Styler.ParsedTableRow?] = rows.map {
            Styler.parseTableRowCells(nsString: nsString, contentRange: $0.contentRange)
        }
        let numCols = max(1, parsedRows.compactMap({ $0?.cells.count }).max() ?? 1)

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

        var measuredWidths: [[CGFloat]] = Array(repeating: Array(repeating: 0, count: numCols), count: rows.count)
        var maxActiveRowWidth: CGFloat = 0
        var inlineTableDecorations: [LineDecoration] = []
        var tableColumns: Styler.LineUTF8ColumnCache?

        for (rIdx, row) in rows.enumerated() {
            let rowLine = startLineNumber + rIdx
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
                    let naturalHeight = activeMono.ascender + abs(activeMono.descender)
                    let shift = max(0.0, floor((activeRowHeight - naturalHeight) * 0.5))
                    storage.addAttributes(
                        [
                            .font: activeMono,
                            .foregroundColor: theme.markdownTokenNSColor.withAlphaComponent(0.9 * dimFactor),
                            .paragraphStyle: activePara,
                            .baselineOffset: shift,
                            .kern: 0.0
                        ], range: row.lineRange)
                    let activeWidth = ceil(storage.attributedSubstring(from: row.contentRange).size().width) + 28.0
                    maxActiveRowWidth = max(maxActiveRowWidth, activeWidth)
                } else {
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
                            Styler.collapsedTokenAttributeKey: true
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

            for (cIdx, cell) in parsed.cells.enumerated() where cIdx < numCols && cell.contentRange.length > 0 {
                Styler.styleInlineMarkdown(
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
            }

            if astLinksByLine[rowLine] != nil {
                if tableColumns == nil {
                    tableColumns = Styler.LineUTF8ColumnCache(lineRecords: lineRecords)
                }
                if var cols = tableColumns {
                    var rowLinkDecos: [LineDecoration] = []
                    applyAstLinks(onLine: rowLine, columns: &cols, decorations: &rowLinkDecos)
                    tableColumns = cols
                    if !rowLinkDecos.isEmpty {
                        tableLinkDecorationsByLine[rowLine] = rowLinkDecos
                    }
                }
            }

            for (cIdx, cell) in parsed.cells.enumerated() where cIdx < numCols && cell.contentRange.length > 0 {
                let cellAttr = storage.attributedSubstring(from: cell.contentRange)
                measuredWidths[rIdx][cIdx] = ceil(cellAttr.size().width) + 4.0
            }

            if row.isActive {
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
                let activeWidth = ceil(storage.attributedSubstring(from: row.contentRange).size().width) + 28.0
                maxActiveRowWidth = max(maxActiveRowWidth, activeWidth)
            }
        }

        let cellHorizontalPadding: CGFloat = 16.0
        var colWidths: [CGFloat] = (0..<numCols).map { cIdx in
            let maxCellWidth = (0..<rows.count).map({ measuredWidths[$0][cIdx] }).max() ?? 40.0
            return max(64.0, maxCellWidth + cellHorizontalPadding * 2.0)
        }

        let naturalSum = colWidths.reduce(0, +)
        if naturalSum > 0 && naturalSum < effectiveContainerWidth {
            let extra = effectiveContainerWidth - naturalSum
            let perCol = floor(extra / CGFloat(numCols))
            colWidths = colWidths.map { $0 + perCol }
            let expandedSum = colWidths.reduce(0, +)
            if numCols > 0 && expandedSum < effectiveContainerWidth {
                colWidths[numCols - 1] += (effectiveContainerWidth - expandedSum)
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

        var bodyCounter = 0
        for (rIdx, row) in rows.enumerated() {
            let isHeader = (rIdx == 0)
            let isFirst = (rIdx == 0)
            let isLast = (rIdx == rows.count - 1)
            let currentBodyIdx = (!isHeader && !row.isSeparator) ? bodyCounter : 0
            if !isHeader && !row.isSeparator {
                bodyCounter += 1
            }

            decorations.lines.append(
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

            if parsed.closingPipeRange.length > 0 {
                Styler.collapseWhitespaceRange(in: storage, range: parsed.closingPipeRange)
            }

            var currentCursorX: CGFloat = 0.0

            for (cIdx, cell) in parsed.cells.enumerated() where cIdx < numCols {
                if cell.leadingDelimiterRange.length > 0 {
                    Styler.collapseWhitespaceRange(in: storage, range: cell.leadingDelimiterRange)
                }

                if cell.trailingSpacesRange.length > 0 {
                    Styler.collapseWhitespaceRange(in: storage, range: cell.trailingSpacesRange)
                }

                let actualCellWidth =
                    cell.contentRange.length > 0
                    ? max(0.0, measuredWidths[rIdx][cIdx] - 4.0)
                    : 0.0
                let colWidth = colWidths[cIdx]
                let alignOffset: CGFloat
                switch alignments[cIdx] {
                case .left:
                    alignOffset = cellHorizontalPadding
                case .center:
                    alignOffset = max(cellHorizontalPadding, floor((colWidth - actualCellWidth) * 0.5))
                case .right:
                    alignOffset = max(cellHorizontalPadding, colWidth - actualCellWidth - cellHorizontalPadding)
                }

                let targetCellStartX = tableOffsetX + colStartX[cIdx] + alignOffset
                let deltaKern = max(1.0, targetCellStartX - currentCursorX)

                if cell.leadingDelimiterRange.length > 0 {
                    let anchorRange = NSRange(location: cell.leadingDelimiterRange.location, length: 1)
                    storage.addAttribute(.kern, value: deltaKern, range: anchorRange)
                    currentCursorX = targetCellStartX + actualCellWidth
                } else if cell.contentRange.length > 0 {
                    let firstLineIndent = max(0.0, targetCellStartX)
                    if let existingPara = storage.attribute(.paragraphStyle, at: row.lineRange.location, effectiveRange: nil) as? NSParagraphStyle,
                        let mutablePara = existingPara.mutableCopy() as? NSMutableParagraphStyle
                    {
                        mutablePara.firstLineHeadIndent = firstLineIndent
                        mutablePara.headIndent = firstLineIndent
                        storage.addAttribute(.paragraphStyle, value: mutablePara, range: row.lineRange)
                    }
                    currentCursorX = targetCellStartX + actualCellWidth
                }
            }
        }

        decorations.lines.append(contentsOf: inlineTableDecorations)
    }
}

extension MarkdownLiveStyler {

    // MARK: - Table Row Scanning & Parsing

    /// Scans `contentRange` for unescaped, unprotected `|` pipe locations (ignoring pipes inside `` `code` `` or `$math$`).
    static func scanUnprotectedTablePipes(nsString: NSString, contentRange: NSRange) -> [Int] {
        var pipes: [Int] = []
        let endLoc = NSMaxRange(contentRange)
        var idx = contentRange.location
        var failedTickLengths = Set<Int>()
        var noClosingDollar = false

        while idx < endLoc {
            let ch = nsString.character(at: idx)
            if ch == 0x5C {
                idx += 2
                continue
            }
            if ch == 0x60 {
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
            if ch == 0x24 && !noClosingDollar {
                if idx + 1 < endLoc && nsString.character(at: idx + 1) != 0x24 {
                    var searchIdx = idx + 1
                    var foundClose = false
                    while searchIdx < endLoc {
                        let mathChar = nsString.character(at: searchIdx)
                        if mathChar == 0x5C {
                            searchIdx += 2
                            continue
                        }
                        if mathChar == 0x24 {
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
            if ch == 0x7C {
                pipes.append(idx)
            }
            idx += 1
        }
        return pipes
    }

    static func isTableCandidateLine(nsString: NSString, contentRange: NSRange) -> Bool {
        guard contentRange.length > 0 else { return false }
        let pipes = scanUnprotectedTablePipes(nsString: nsString, contentRange: contentRange)
        return !pipes.isEmpty
    }

    static func isTableSeparatorRow(nsString: NSString, contentRange: NSRange) -> Bool {
        guard let parsed = parseTableRowCells(nsString: nsString, contentRange: contentRange),
            !parsed.cells.isEmpty
        else {
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

    static func parseTableRowCells(nsString: NSString, contentRange: NSRange) -> ParsedTableRow? {
        let pipeLocations = scanUnprotectedTablePipes(nsString: nsString, contentRange: contentRange)
        guard !pipeLocations.isEmpty else { return nil }

        let endLoc = NSMaxRange(contentRange)
        var firstNonWS = contentRange.location
        while firstNonWS < endLoc {
            let ch = nsString.character(at: firstNonWS)
            if ch == 32 || ch == 9 { firstNonWS += 1 } else { break }
        }
        var lastNonWS = endLoc
        while lastNonWS > firstNonWS {
            let ch = nsString.character(at: lastNonWS - 1)
            if ch == 32 || ch == 9 { lastNonWS -= 1 } else { break }
        }

        let hasLeadingPipe = (pipeLocations.first == firstNonWS)
        let hasTrailingPipe = (pipeLocations.last == lastNonWS - 1)

        var boundaries: [Int] = []
        if !hasLeadingPipe {
            boundaries.append(firstNonWS - 1)
        }
        boundaries.append(contentsOf: pipeLocations)
        if !hasTrailingPipe {
            boundaries.append(lastNonWS)
        }

        guard boundaries.count >= 2 else { return nil }

        var cells: [ParsedTableCell] = []
        for idx in 0..<(boundaries.count - 1) {
            let pipePos = boundaries[idx]
            let nextPipePos = boundaries[idx + 1]

            let rawCellStart = max(contentRange.location, pipePos + 1)
            var contentStart = rawCellStart
            while contentStart < nextPipePos {
                let ch = nsString.character(at: contentStart)
                if ch == 32 || ch == 9 { contentStart += 1 } else { break }
            }

            var contentEnd = nextPipePos
            while contentEnd > contentStart {
                let ch = nsString.character(at: contentEnd - 1)
                if ch == 32 || ch == 9 { contentEnd -= 1 } else { break }
            }

            let startLoc = (idx == 0) ? contentRange.location : pipePos
            let leadingRange = NSRange(location: startLoc, length: max(0, contentStart - startLoc))
            let cellRange = NSRange(location: contentStart, length: max(0, contentEnd - contentStart))
            let trailingRange = NSRange(location: contentEnd, length: max(0, nextPipePos - contentEnd))
            cells.append(
                ParsedTableCell(
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
}
