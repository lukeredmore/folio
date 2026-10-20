import Foundation

extension DocumentLineDiff {
    static func extractEdits(from oldLines: [String], to newLines: [String]) -> [LineEdit] {
        let matches = computeLCSMatches(oldLines: oldLines, newLines: newLines)
        var allPairs: [(Int, Int)] = [(-1, -1)]
        allPairs.append(contentsOf: matches)
        allPairs.append((oldLines.count, newLines.count))

        var edits: [LineEdit] = []
        for idx in 0..<(allPairs.count - 1) {
            let (b0, t0) = allPairs[idx]
            let (b1, t1) = allPairs[idx + 1]
            let baseStart = b0 + 1
            let baseEnd = b1
            let targetStart = t0 + 1
            let targetEnd = t1
            if baseStart < baseEnd || targetStart < targetEnd {
                edits.append(LineEdit(
                    baseRange: baseStart..<baseEnd,
                    replacement: Array(newLines[targetStart..<targetEnd])
                ))
            }
        }
        return edits
    }

    public static func computeDiff(from oldText: String, to newText: String) -> DocumentLineDiffResult {
        let oldLines = splitLines(oldText)
        let newLines = splitLines(newText)
        let matches = computeLCSMatches(oldLines: oldLines, newLines: newLines)

        var allPairs: [(Int, Int)] = [(-1, -1)]
        allPairs.append(contentsOf: matches)
        allPairs.append((oldLines.count, newLines.count))

        var addedCount = 0
        var removedCount = 0
        var changedLineNumbers = Set<Int>()
        var hunks: [ExternalUpdateDiffHunk] = []

        for idx in 0..<(allPairs.count - 1) {
            let (b0, t0) = allPairs[idx]
            let (b1, t1) = allPairs[idx + 1]
            let oldRange = (b0 + 1)..<b1
            let newRange = (t0 + 1)..<t1
            if !oldRange.isEmpty || !newRange.isEmpty {
                let removed = Array(oldLines[oldRange])
                let added = Array(newLines[newRange])
                removedCount += removed.count
                addedCount += added.count
                for lineIdx in newRange {
                    changedLineNumbers.insert(lineIdx + 1)
                }
                if newRange.isEmpty && !newLines.isEmpty {
                    let anchorLine = min( max(1, t0 + 1), newLines.count)
                    changedLineNumbers.insert(anchorLine)
                }
                hunks.append(ExternalUpdateDiffHunk(
                    oldStartLine: max(1, oldRange.lowerBound + 1),
                    newStartLine: max(1, newRange.lowerBound + 1),
                    removedLines: removed,
                    addedLines: added
                ))
            }
        }

        // Compute UTF-16 character ranges for changedLineNumbers in newText
        var changedRanges: [NSRange] = []
        if !changedLineNumbers.isEmpty && !newText.isEmpty {
            let nsNew = newText as NSString
            var currentLocation = 0
            for (zeroIdx, line) in newLines.enumerated() {
                let lineLen = (line as NSString).length
                let fullLen = zeroIdx < newLines.count - 1 ? lineLen + 1 : lineLen
                if changedLineNumbers.contains(zeroIdx + 1) {
                    let safeLoc = min(currentLocation, nsNew.length)
                    let safeLen = max(0, min(fullLen, nsNew.length - safeLoc))
                    changedRanges.append(NSRange(location: safeLoc, length: safeLen))
                }
                currentLocation += fullLen
            }
        }

        return DocumentLineDiffResult(
            addedLinesCount: addedCount,
            removedLinesCount: removedCount,
            changedLineNumbers: changedLineNumbers,
            changedCharacterRanges: changedRanges,
            hunks: hunks
        )
    }

    /// Adjusts an existing UTF-16 selection range from `oldText` into `newText` so the user's cursor stays
    /// anchored at the same logical text position even when multiple disjoint edits occur above and below it,
    /// while guaranteeing UTF-16 surrogate pairs (emojis, math symbols) are never split.
    public static func adjustedSelection(
        for oldSelection: NSRange,
        inOldText oldText: String,
        toNewText newText: String
    ) -> NSRange {
        let oldNS = oldText as NSString
        let newNS = newText as NSString
        let oldLen = oldNS.length
        let newLen = newNS.length

        guard oldLen > 0, newLen > 0 else {
            return NSRange(location: 0, length: 0)
        }

        let clampedOldLoc = max(0, min(oldLen, oldSelection.location))
        var prefixLen = 0
        let minLen = min(oldLen, newLen)
        while prefixLen < minLen && oldNS.character(at: prefixLen) == newNS.character(at: prefixLen) {
            prefixLen += 1
        }

        var suffixLen = 0
        while suffixLen < (oldLen - prefixLen)
            && suffixLen < (newLen - prefixLen)
            && oldNS.character(at: oldLen - 1 - suffixLen) == newNS.character(at: newLen - 1 - suffixLen) {
            suffixLen += 1
        }

        let oldChangedEnd = oldLen - suffixLen
        let delta = newLen - oldLen

        let rawNewLoc: Int
        if clampedOldLoc <= prefixLen {
            rawNewLoc = clampedOldLoc
        } else if clampedOldLoc >= oldChangedEnd {
            rawNewLoc = max(prefixLen, min(newLen, clampedOldLoc + delta))
        } else {
            // Cursor is between the first and last changed character (e.g. an unchanged middle section
            // when edits occurred at both the top and bottom of the document). Use line-level LCS matching
            // to shift the cursor by the exact cumulative UTF-16 delta of edits above it.
            let oldLines = splitLines(oldText)
            let newLines = splitLines(newText)
            let matches = computeLCSMatches(oldLines: oldLines, newLines: newLines)

            var oldLineStarts: [Int] = []
            oldLineStarts.reserveCapacity(oldLines.count)
            var offset = 0
            for (i, line) in oldLines.enumerated() {
                oldLineStarts.append(offset)
                offset += (line as NSString).length + (i < oldLines.count - 1 ? 1 : 0)
            }

            var newLineStarts: [Int] = []
            newLineStarts.reserveCapacity(newLines.count)
            offset = 0
            for (i, line) in newLines.enumerated() {
                newLineStarts.append(offset)
                offset += (line as NSString).length + (i < newLines.count - 1 ? 1 : 0)
            }

            var targetOldLine = 0
            for i in 0..<oldLines.count {
                if clampedOldLoc >= oldLineStarts[i] {
                    targetOldLine = i
                } else {
                    break
                }
            }
            let intraLineOffset = clampedOldLoc - oldLineStarts[targetOldLine]

            var matchedNewLineMap: [Int: Int] = [:]
            matchedNewLineMap.reserveCapacity(matches.count)
            for (oIdx, nIdx) in matches {
                matchedNewLineMap[oIdx] = nIdx
            }

            if let exactNewLine = matchedNewLineMap[targetOldLine] {
                let maxIntra = (newLines[exactNewLine] as NSString).length
                rawNewLoc = min(newLen, newLineStarts[exactNewLine] + min(intraLineOffset, maxIntra))
            } else {
                var precedingPair: (Int, Int)? = nil
                for pair in matches where pair.0 < targetOldLine {
                    precedingPair = pair
                }
                if let (prevOld, prevNew) = precedingPair {
                    let oldAnchor = oldLineStarts[prevOld] + (oldLines[prevOld] as NSString).length
                    let newAnchor = newLineStarts[prevNew] + (newLines[prevNew] as NSString).length
                    let localDelta = newAnchor - oldAnchor
                    rawNewLoc = max(0, min(newLen, clampedOldLoc + localDelta))
                } else {
                    rawNewLoc = min(newLen, clampedOldLoc)
                }
            }
        }

        let safeNewLoc = clampOutOfSurrogateSplit(rawNewLoc, in: newNS)
        let rawEndLoc = max(safeNewLoc, min(newLen, safeNewLoc + max(0, oldSelection.length)))
        let safeEndLoc = clampOutOfSurrogateSplit(rawEndLoc, in: newNS)
        return NSRange(location: safeNewLoc, length: max(0, safeEndLoc - safeNewLoc))
    }

    static func clampOutOfSurrogateSplit(_ index: Int, in nsString: NSString) -> Int {
        let len = nsString.length
        let clamped = max(0, min(len, index))
        guard clamped > 0 && clamped < len else { return clamped }
        let unit = nsString.character(at: clamped)
        let prevUnit = nsString.character(at: clamped - 1)
        if UTF16.isTrailSurrogate(unit) && UTF16.isLeadSurrogate(prevUnit) {
            return clamped - 1
        }
        return clamped
    }
}
