import AppKit
import Foundation

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

    static func isTableCandidateLine(nsString: NSString, contentRange: NSRange) -> Bool {
        guard contentRange.length > 0 else { return false }
        let pipes = scanUnprotectedTablePipes(nsString: nsString, contentRange: contentRange)
        return !pipes.isEmpty
    }

    static func isTableSeparatorRow(nsString: NSString, contentRange: NSRange) -> Bool {
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

    static func parseTableRowCells(nsString: NSString, contentRange: NSRange) -> ParsedTableRow? {
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

    static func tryStyleTableBlock(
        in storage: NSTextStorage,
        string: String,
        nsString: NSString,
        fullLength: Int,
        startIndex: Int,
        contentRange: NSRange,
        activeLineRange: NSRange,
        selectedRange: NSRange,
        theme: EditorTheme,
        typography: EditorTypographySettings,
        effectiveContainerWidth: CGFloat,
        focusMode: Bool,
        prettyMode: Bool,
        baseDirectoryURL: URL?,
        decorations: inout [LineDecoration]
    ) -> (nextIndex: Int, lineDelta: Int)? {
        guard isTableCandidateLine(nsString: nsString, contentRange: contentRange) else { return nil }
        var tableRows: [(lineRange: NSRange, contentRange: NSRange, isActive: Bool, isSeparator: Bool)] = []
        var scanIndex = startIndex
        var scanLines = 0
        while scanIndex < fullLength {
            let nextLR = nsString.lineRange(for: NSRange(location: scanIndex, length: 0))
            let nextCR = strippedLineContentRange(nsString: nsString, lineRange: nextLR)
            guard nextCR.length > 0, isTableCandidateLine(nsString: nsString, contentRange: nextCR) else { break }
            let nextActive = isLineActive(lineRange: nextLR, activeLineRange: activeLineRange, selectedRange: selectedRange)
            let nextSep = isTableSeparatorRow(nsString: nsString, contentRange: nextCR)
            tableRows.append((nextLR, nextCR, nextActive, nextSep))
            scanIndex = NSMaxRange(nextLR)
            scanLines += 1
        }
        let hasValidTableStructure = tableRows.count >= 2 && tableRows.contains(where: { $0.isSeparator })
            || (tableRows.count == 1 && nsString.substring(with: tableRows[0].contentRange).trimmingCharacters(in: .whitespaces).hasPrefix("|"))
        guard hasValidTableStructure else { return nil }
        styleTableBlock(
            rows: tableRows, in: storage, string: string, nsString: nsString, theme: theme,
            typography: typography, containerWidth: effectiveContainerWidth, focusMode: focusMode,
            prettyMode: prettyMode, baseDirectoryURL: baseDirectoryURL, decorations: &decorations
        )
        return (scanIndex, scanLines)
    }
}
