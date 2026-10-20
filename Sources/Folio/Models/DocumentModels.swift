import Foundation
import FolioEngineFFI

public struct OutlineHeading: Identifiable, Equatable, Sendable {
    public let id: String
    public let level: Int
    public let title: String
    public let characterLocation: Int
    public let lineNumber: Int

    public init(level: Int, title: String, characterLocation: Int, lineNumber: Int) {
        self.id = "\(lineNumber)-\(characterLocation)-\(title)"
        self.level = level
        self.title = title
        self.characterLocation = characterLocation
        self.lineNumber = lineNumber
    }
}

public struct DocumentStats: Equatable, Sendable {
    public var words: Int = 0
    public var lines: Int = 0
    public var characters: Int = 0
    public var charactersWithoutSpaces: Int = 0
    public var selectedWords: Int = 0
    public var selectedCharacters: Int = 0

    public var readingTimeString: String {
        // Estimate reading time at ~225 words/minute
        let totalSeconds = max(0, Int((Double(words) / 225.0) * 60.0))
        if totalSeconds == 0 {
            return "0 sec"
        } else if totalSeconds < 60 {
            return "< 1 min"
        } else {
            let minutes = Int(ceil(Double(words) / 225.0))
            return "\(minutes) min"
        }
    }

    public static func compute(for text: String, selectedRange: NSRange? = nil) -> DocumentStats {
        let hasSel = (selectedRange != nil && (selectedRange?.length ?? 0) > 0)
        let selLoc = max(0, selectedRange?.location ?? 0)
        let selLen = max(0, selectedRange?.length ?? 0)

        let rawStats = text.withCString { cStr in
            ot_engine_compute_stats(cStr, hasSel, selLoc, selLen)
        }

        return DocumentStats(
            words: Int(rawStats.words),
            lines: Int(rawStats.lines),
            characters: Int(rawStats.characters),
            charactersWithoutSpaces: Int(rawStats.characters_without_spaces),
            selectedWords: Int(rawStats.selected_words),
            selectedCharacters: Int(rawStats.selected_characters)
        )
    }
}

public struct WorkspaceFileNode: Identifiable, Hashable, Sendable {
    public let url: URL
    public let name: String
    public let isDirectory: Bool
    public let modificationDate: Date
    public let creationDate: Date
    public var children: [WorkspaceFileNode]?
    public var remoteMountID: UUID?
    public var isRemoteRoot: Bool
    public var remoteConnectionString: String?
    public var syncStatus: RemoteFileSyncStatus?

    public init(
        url: URL,
        name: String,
        isDirectory: Bool,
        modificationDate: Date,
        creationDate: Date,
        children: [WorkspaceFileNode]?,
        remoteMountID: UUID? = nil,
        isRemoteRoot: Bool = false,
        remoteConnectionString: String? = nil,
        syncStatus: RemoteFileSyncStatus? = nil
    ) {
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.modificationDate = modificationDate
        self.creationDate = creationDate
        self.children = children
        self.remoteMountID = remoteMountID
        self.isRemoteRoot = isRemoteRoot
        self.remoteConnectionString = remoteConnectionString
        self.syncStatus = syncStatus
    }

    public var id: URL { url }

    public var isRemote: Bool { remoteMountID != nil }

    public var isMarkdownFile: Bool {
        let ext = url.pathExtension.lowercased()
        return ["md", "markdown", "mdown", "mkd", "txt", "textbundle"].contains(ext)
    }
}

public enum FileSortOrder: String, CaseIterable, Identifiable, Sendable {
    case name = "Name"
    case modificationDate = "Modification Date"
    case creationDate = "Creation Date"

    public var id: String { rawValue }
}

public struct WorkspaceSearchMatch: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let fileURL: URL
    public let fileName: String
    public let lineNumber: Int
    public let lineSnippet: String
    public let matchRangeInFile: NSRange
}

public struct EditorTypographySettings: Equatable, Hashable, Codable, Sendable {
    /// Multiplier applied to the theme's base font size (0.80 ... 1.50)
    public var fontSizeScale: CGFloat = 1.0
    /// Line height multiple applied to body and list paragraphs (1.0 ... 2.0)
    public var lineHeightMultiple: CGFloat = 1.24
    /// Extra line spacing (leading) in points between lines in a paragraph (0 ... 18)
    public var lineSpacing: CGFloat = 6.0
    /// Spacing in points after each body paragraph (2 ... 28)
    public var paragraphSpacing: CGFloat = 12.0
    /// Character spacing (kerning/tracking) in points for body text (-0.5 ... 2.5)
    public var characterSpacing: CGFloat = 0.15
    /// Character spacing (kerning/tracking) in points for headings (-0.5 ... 3.0)
    public var headingCharacterSpacing: CGFloat = 0.55
    /// Multiplier for spacing above and below headings (0.6 ... 2.0)
    public var headingSpacingScale: CGFloat = 1.15
    /// Vertical offset in points below heading descenders for H1/H2 underlines (2 ... 16)
    public var headingUnderlineOffset: CGFloat = 8.0
    /// Whether to draw horizontal underlines beneath H1 and H2 headings
    public var showHeadingUnderlines: Bool = true
    /// Maximum readable column width in points (560 ... 1280)
    public var maxColumnWidth: CGFloat = 860.0

    public init(
        fontSizeScale: CGFloat = 1.0,
        lineHeightMultiple: CGFloat = 1.24,
        lineSpacing: CGFloat = 6.0,
        paragraphSpacing: CGFloat = 12.0,
        characterSpacing: CGFloat = 0.15,
        headingCharacterSpacing: CGFloat = 0.55,
        headingSpacingScale: CGFloat = 1.15,
        headingUnderlineOffset: CGFloat = 8.0,
        showHeadingUnderlines: Bool = true,
        maxColumnWidth: CGFloat = 860.0
    ) {
        self.fontSizeScale = fontSizeScale
        self.lineHeightMultiple = lineHeightMultiple
        self.lineSpacing = lineSpacing
        self.paragraphSpacing = paragraphSpacing
        self.characterSpacing = characterSpacing
        self.headingCharacterSpacing = headingCharacterSpacing
        self.headingSpacingScale = headingSpacingScale
        self.headingUnderlineOffset = headingUnderlineOffset
        self.showHeadingUnderlines = showHeadingUnderlines
        self.maxColumnWidth = maxColumnWidth
    }

    public static let `default` = EditorTypographySettings()
}

// MARK: - Infinite Undo & Revision History Models

public enum UndoEntryOrigin: String, Codable, Equatable, Sendable {
    case userTyping = "Typing"
    case formattingAction = "Formatting"
    case findReplace = "Find & Replace"
    case externalUpdate = "External Update"
    case conflictResolution = "Conflict Resolution"
    case programmatic = "Edit"
}

public struct DocumentUndoEntry: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var previousText: String
    public var newText: String
    public var previousSelectedLocation: Int
    public var previousSelectedLength: Int
    public var newSelectedLocation: Int
    public var newSelectedLength: Int
    public var timestamp: Date
    public var origin: UndoEntryOrigin
    public var summary: String

    public init(
        id: UUID = UUID(),
        previousText: String,
        newText: String,
        previousSelectedRange: NSRange = NSRange(location: 0, length: 0),
        newSelectedRange: NSRange = NSRange(location: 0, length: 0),
        timestamp: Date = Date(),
        origin: UndoEntryOrigin = .userTyping,
        summary: String? = nil
    ) {
        self.id = id
        self.previousText = previousText
        self.newText = newText
        self.previousSelectedLocation = max(0, previousSelectedRange.location)
        self.previousSelectedLength = max(0, previousSelectedRange.length)
        self.newSelectedLocation = max(0, newSelectedRange.location)
        self.newSelectedLength = max(0, newSelectedRange.length)
        self.timestamp = timestamp
        self.origin = origin
        self.summary = summary ?? origin.rawValue
    }

    public var previousSelectedRange: NSRange {
        NSRange(location: previousSelectedLocation, length: previousSelectedLength)
    }

    public var newSelectedRange: NSRange {
        NSRange(location: newSelectedLocation, length: newSelectedLength)
    }
}

public struct DocumentUndoTimeline: Codable, Equatable, Sendable {
    public var undoStack: [DocumentUndoEntry] = []
    public var redoStack: [DocumentUndoEntry] = []

    public init(undoStack: [DocumentUndoEntry] = [], redoStack: [DocumentUndoEntry] = []) {
        self.undoStack = undoStack
        self.redoStack = redoStack
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
}

// MARK: - Line Diff & External File Update Models

public struct ExternalUpdateDiffHunk: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let oldStartLine: Int
    public let newStartLine: Int
    public let removedLines: [String]
    public let addedLines: [String]

    public init(
        id: UUID = UUID(),
        oldStartLine: Int,
        newStartLine: Int,
        removedLines: [String],
        addedLines: [String]
    ) {
        self.id = id
        self.oldStartLine = oldStartLine
        self.newStartLine = newStartLine
        self.removedLines = removedLines
        self.addedLines = addedLines
    }
}

public struct DocumentLineDiffResult: Equatable, Sendable {
    public let addedLinesCount: Int
    public let removedLinesCount: Int
    public let changedLineNumbers: Set<Int>
    public let changedCharacterRanges: [NSRange]
    public let hunks: [ExternalUpdateDiffHunk]
}

public enum DocumentLineDiff {
    struct LineEdit: Equatable, Sendable {
        let baseRange: Range<Int>
        let replacement: [String]
    }

    public static func splitLines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        return text.components(separatedBy: "\n")
    }

    /// Computes matched `(oldIndex, newIndex)` line pairs using LCS, with fast prefix/suffix trimming
    /// and Patience-style unique-line anchoring for large multi-hunk documents.
    static func computeLCSMatches(oldLines: [String], newLines: [String]) -> [(Int, Int)] {
        return computeLCSMatchesInSlice(
            oldLines: oldLines,
            oldRange: 0..<oldLines.count,
            newLines: newLines,
            newRange: 0..<newLines.count
        )
    }

    private static func computeLCSMatchesInSlice(
        oldLines: [String],
        oldRange: Range<Int>,
        newLines: [String],
        newRange: Range<Int>
    ) -> [(Int, Int)] {
        let m = oldRange.count
        let n = newRange.count
        if m == 0 || n == 0 { return [] }

        var prefixCount = 0
        while prefixCount < m && prefixCount < n
            && oldLines[oldRange.lowerBound + prefixCount] == newLines[newRange.lowerBound + prefixCount] {
            prefixCount += 1
        }

        var suffixCount = 0
        while suffixCount < (m - prefixCount)
            && suffixCount < (n - prefixCount)
            && oldLines[oldRange.upperBound - 1 - suffixCount] == newLines[newRange.upperBound - 1 - suffixCount] {
            suffixCount += 1
        }

        var matches: [(Int, Int)] = []
        matches.reserveCapacity(min(m, n))
        for i in 0..<prefixCount {
            matches.append((oldRange.lowerBound + i, newRange.lowerBound + i))
        }

        let midOldStart = oldRange.lowerBound + prefixCount
        let midOldEnd = oldRange.upperBound - suffixCount
        let midNewStart = newRange.lowerBound + prefixCount
        let midNewEnd = newRange.upperBound - suffixCount
        let midM = midOldEnd - midOldStart
        let midN = midNewEnd - midNewStart

        if midM > 0 && midN > 0 {
            if midM * midN <= 65_536 {
                var dp = Array(repeating: Array(repeating: 0, count: midN + 1), count: midM + 1)
                for i in stride(from: midM - 1, through: 0, by: -1) {
                    let oldLine = oldLines[midOldStart + i]
                    for j in stride(from: midN - 1, through: 0, by: -1) {
                        if oldLine == newLines[midNewStart + j] {
                            dp[i][j] = 1 + dp[i + 1][j + 1]
                        } else {
                            dp[i][j] = max(dp[i + 1][j], dp[i][j + 1])
                        }
                    }
                }
                var i = 0
                var j = 0
                while i < midM && j < midN {
                    if oldLines[midOldStart + i] == newLines[midNewStart + j] {
                        matches.append((midOldStart + i, midNewStart + j))
                        i += 1
                        j += 1
                    } else if dp[i + 1][j] >= dp[i][j + 1] {
                        i += 1
                    } else {
                        j += 1
                    }
                }
            } else {
                // Patience-style unique-line anchoring: find non-empty lines appearing exactly once in both slices
                var oldCounts: [String: Int] = [:]
                oldCounts.reserveCapacity(midM)
                for idx in midOldStart..<midOldEnd {
                    let line = oldLines[idx]
                    if !line.isEmpty {
                        oldCounts[line] = oldCounts[line] == nil ? idx : -1
                    }
                }
                var newCounts: [String: Int] = [:]
                newCounts.reserveCapacity(midN)
                for idx in midNewStart..<midNewEnd {
                    let line = newLines[idx]
                    if !line.isEmpty, let oldIdx = oldCounts[line], oldIdx >= 0 {
                        newCounts[line] = newCounts[line] == nil ? idx : -1
                    }
                }

                var uniquePairs: [(Int, Int)] = []
                for idx in midOldStart..<midOldEnd {
                    let line = oldLines[idx]
                    if let oldIdx = oldCounts[line], oldIdx >= 0,
                       let newIdx = newCounts[line], newIdx >= 0 {
                        uniquePairs.append((oldIdx, newIdx))
                    }
                }

                let anchors = longestIncreasingSubsequence(of: uniquePairs)
                if !anchors.isEmpty {
                    var prevOld = midOldStart
                    var prevNew = midNewStart
                    for (anchorOld, anchorNew) in anchors {
                        if anchorOld > prevOld && anchorNew > prevNew {
                            let subMatches = computeLCSMatchesInSlice(
                                oldLines: oldLines,
                                oldRange: prevOld..<anchorOld,
                                newLines: newLines,
                                newRange: prevNew..<anchorNew
                            )
                            matches.append(contentsOf: subMatches)
                        }
                        matches.append((anchorOld, anchorNew))
                        prevOld = anchorOld + 1
                        prevNew = anchorNew + 1
                    }
                    if prevOld < midOldEnd && prevNew < midNewEnd {
                        let tailMatches = computeLCSMatchesInSlice(
                            oldLines: oldLines,
                            oldRange: prevOld..<midOldEnd,
                            newLines: newLines,
                            newRange: prevNew..<midNewEnd
                        )
                        matches.append(contentsOf: tailMatches)
                    }
                } else {
                    // Fallback when no unique anchor lines exist in the middle slice
                    let oldMid = Array(oldLines[midOldStart..<midOldEnd])
                    let newMid = Array(newLines[midNewStart..<midNewEnd])
                    let diff = newMid.difference(from: oldMid)
                    var removedOld = Set<Int>()
                    var insertedNew = Set<Int>()
                    for change in diff {
                        switch change {
                        case .remove(let offset, _, _):
                            removedOld.insert(offset)
                        case .insert(let offset, _, _):
                            insertedNew.insert(offset)
                        }
                    }
                    let keptOld = (0..<midM).filter { !removedOld.contains($0) }
                    let keptNew = (0..<midN).filter { !insertedNew.contains($0) }
                    for (o, nw) in zip(keptOld, keptNew) {
                        matches.append((midOldStart + o, midNewStart + nw))
                    }
                }
            }
        }

        for k in 0..<suffixCount {
            matches.append((oldRange.upperBound - suffixCount + k, newRange.upperBound - suffixCount + k))
        }

        return matches
    }

    /// Computes the Longest Increasing Subsequence (by second element) of `(oldIdx, newIdx)` pairs in $O(K \log K)$.
    private static func longestIncreasingSubsequence(of pairs: [(Int, Int)]) -> [(Int, Int)] {
        guard !pairs.isEmpty else { return [] }
        var tails: [Int] = []
        var predecessors = Array(repeating: -1, count: pairs.count)

        for i in 0..<pairs.count {
            let targetNew = pairs[i].1
            var lo = 0
            var hi = tails.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if pairs[tails[mid]].1 < targetNew {
                    lo = mid + 1
                } else {
                    hi = mid
                }
            }
            if lo == tails.count {
                tails.append(i)
            } else {
                tails[lo] = i
            }
            if lo > 0 {
                predecessors[i] = tails[lo - 1]
            }
        }

        var result: [(Int, Int)] = []
        result.reserveCapacity(tails.count)
        var curr = tails.last ?? -1
        while curr >= 0 {
            result.append(pairs[curr])
            curr = predecessors[curr]
        }
        result.reverse()
        return result
    }

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

    private static func clampOutOfSurrogateSplit(_ index: Int, in nsString: NSString) -> Int {
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

public struct ExternalUpdateNotice: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let fileURL: URL
    public let previousText: String
    public let updatedText: String
    public let addedLinesCount: Int
    public let removedLinesCount: Int
    public let changedLineNumbers: Set<Int>
    public let changedCharacterRanges: [NSRange]
    public let diffHunks: [ExternalUpdateDiffHunk]
    public let wasAutoMerged: Bool
    public let sourceDescription: String
    public let timestamp: Date

    public init(
        id: UUID = UUID(),
        fileURL: URL,
        previousText: String,
        updatedText: String,
        addedLinesCount: Int,
        removedLinesCount: Int,
        changedLineNumbers: Set<Int>,
        changedCharacterRanges: [NSRange],
        diffHunks: [ExternalUpdateDiffHunk],
        wasAutoMerged: Bool = false,
        sourceDescription: String = "Disk",
        timestamp: Date = Date()
    ) {
        self.id = id
        self.fileURL = fileURL
        self.previousText = previousText
        self.updatedText = updatedText
        self.addedLinesCount = addedLinesCount
        self.removedLinesCount = removedLinesCount
        self.changedLineNumbers = changedLineNumbers
        self.changedCharacterRanges = changedCharacterRanges
        self.diffHunks = diffHunks
        self.wasAutoMerged = wasAutoMerged
        self.sourceDescription = sourceDescription
        self.timestamp = timestamp
    }

    public var wasThreeWayMerged: Bool { wasAutoMerged }
    public var addedLines: Int { addedLinesCount }
    public var removedLines: Int { removedLinesCount }
    public var hunks: [ExternalUpdateDiffHunk] { diffHunks }

    public var headlineText: String {
        if wasAutoMerged {
            return "Auto-merged external changes"
        }
        return "Updated externally"
    }

    public var summaryText: String {
        var parts: [String] = []
        if addedLinesCount > 0 {
            parts.append("+\(addedLinesCount)")
        }
        if removedLinesCount > 0 {
            parts.append("−\(removedLinesCount)")
        }
        if parts.isEmpty {
            return "\(max(1, changedLineNumbers.count)) line\(changedLineNumbers.count == 1 ? "" : "s") updated"
        }
        return "\(parts.joined(separator: " / ")) lines"
    }
}

// MARK: - 3-Way Document Merge & Conflict Resolution Engine

public enum ConflictResolutionStrategy: String, Codable, CaseIterable, Equatable, Sendable {
    case keepLocal = "Keep Local"
    case acceptExternal = "Accept External"
    case keepBoth = "Keep Both"

    public var title: String { rawValue }
}

public struct DocumentConflictHunk: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let index: Int
    public let baseStartLine: Int
    public let baseLines: [String]
    public let localLines: [String]
    public let externalLines: [String]
    public var selectedResolution: ConflictResolutionStrategy

    public var lineNumber: Int { baseStartLine }

    public var selectedStrategy: ConflictResolutionStrategy {
        get { selectedResolution }
        set { selectedResolution = newValue }
    }

    public init(
        id: UUID = UUID(),
        index: Int,
        baseStartLine: Int,
        baseLines: [String],
        localLines: [String],
        externalLines: [String],
        selectedResolution: ConflictResolutionStrategy = .keepLocal
    ) {
        self.id = id
        self.index = index
        self.baseStartLine = baseStartLine
        self.baseLines = baseLines
        self.localLines = localLines
        self.externalLines = externalLines
        self.selectedResolution = selectedResolution
    }

    public func resolvedLines(overrideStrategy: ConflictResolutionStrategy? = nil) -> [String] {
        let strategy = overrideStrategy ?? selectedResolution
        switch strategy {
        case .keepLocal:
            return localLines
        case .acceptExternal:
            return externalLines
        case .keepBoth:
            return localLines + externalLines
        }
    }
}

public enum DocumentMergeSegment: Equatable, Sendable {
    case clean([String])
    case conflict(DocumentConflictHunk)
}

public struct DocumentConflict: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let fileURL: URL
    public let baseText: String
    public let localText: String
    public let externalText: String
    public var segments: [DocumentMergeSegment]
    public let detectedAt: Date
    public let sourceDescription: String

    public init(
        id: UUID = UUID(),
        fileURL: URL,
        baseText: String,
        localText: String,
        externalText: String,
        segments: [DocumentMergeSegment],
        detectedAt: Date = Date(),
        sourceDescription: String = "Disk"
    ) {
        self.id = id
        self.fileURL = fileURL
        self.baseText = baseText
        self.localText = localText
        self.externalText = externalText
        self.segments = segments
        self.detectedAt = detectedAt
        self.sourceDescription = sourceDescription
    }

    public var hunks: [DocumentConflictHunk] {
        segments.compactMap { segment in
            if case let .conflict(hunk) = segment { return hunk }
            return nil
        }
    }

    public var conflictHunks: [DocumentConflictHunk] { hunks }

    public mutating func setResolution(_ strategy: ConflictResolutionStrategy, forHunkID hunkID: UUID) {
        for idx in segments.indices {
            if case var .conflict(hunk) = segments[idx], hunk.id == hunkID {
                hunk.selectedResolution = strategy
                segments[idx] = .conflict(hunk)
            }
        }
    }

    /// Reconstructs the full resolved document using `overrideStrategy` if provided, or each hunk's `selectedResolution` if `nil`.
    public func resolvedText(using overrideStrategy: ConflictResolutionStrategy? = nil) -> String {
        if let overrideStrategy {
            if segments.count == 1, case .conflict = segments[0] {
                switch overrideStrategy {
                case .keepLocal: return localText
                case .acceptExternal: return externalText
                case .keepBoth:
                    let sep = localText.hasSuffix("\n") || localText.isEmpty ? "" : "\n"
                    return localText + sep + externalText
                }
            }
        }

        var outputLines: [String] = []
        for segment in segments {
            switch segment {
            case .clean(let lines):
                outputLines.append(contentsOf: lines)
            case .conflict(let hunk):
                outputLines.append(contentsOf: hunk.resolvedLines(overrideStrategy: overrideStrategy))
            }
        }
        return outputLines.joined(separator: "\n")
    }

    /// Renders a standard Git-style conflict marker preview for inspection.
    public var conflictMarkersPreviewText: String {
        var outputLines: [String] = []
        for segment in segments {
            switch segment {
            case .clean(let lines):
                outputLines.append(contentsOf: lines)
            case .conflict(let hunk):
                outputLines.append("<<<<<<< Local (In Folio)")
                outputLines.append(contentsOf: hunk.localLines)
                outputLines.append("=======")
                outputLines.append(contentsOf: hunk.externalLines)
                outputLines.append(">>>>>>> External (\(sourceDescription))")
            }
        }
        return outputLines.joined(separator: "\n")
    }
}

public enum ThreeWayMergeResult: Equatable, Sendable {
    case clean(mergedText: String, wasAutoMerged: Bool)
    case conflict(DocumentConflict)
}

public enum ThreeWayDocumentMerger {
    /// Performs a line-level 3-way merge between `base` (last synced ancestor), `local` (current editor buffer),
    /// and `external` (newly changed file on disk or remote).
    public static func merge(
        base: String,
        local: String,
        external: String,
        fileURL: URL,
        sourceDescription: String = "Disk"
    ) -> ThreeWayMergeResult {
        if local == external {
            return .clean(mergedText: local, wasAutoMerged: false)
        }
        if local == base {
            return .clean(mergedText: external, wasAutoMerged: false)
        }
        if external == base {
            return .clean(mergedText: local, wasAutoMerged: false)
        }

        let baseLines = DocumentLineDiff.splitLines(base)
        let localLines = DocumentLineDiff.splitLines(local)
        let externalLines = DocumentLineDiff.splitLines(external)

        let localEdits = DocumentLineDiff.extractEdits(from: baseLines, to: localLines)
        let externalEdits = DocumentLineDiff.extractEdits(from: baseLines, to: externalLines)

        func editsOverlap(_ a: Range<Int>, _ b: Range<Int>) -> Bool {
            if a.isEmpty && b.isEmpty {
                return a.lowerBound == b.lowerBound
            }
            if a.isEmpty {
                return a.lowerBound >= b.lowerBound && a.lowerBound <= b.upperBound
            }
            if b.isEmpty {
                return b.lowerBound >= a.lowerBound && b.lowerBound <= a.upperBound
            }
            return a.overlaps(b)
        }

        func applyEdits(_ edits: [DocumentLineDiff.LineEdit], over span: Range<Int>) -> [String] {
            var result: [String] = []
            var cursor = span.lowerBound
            for edit in edits {
                if edit.baseRange.lowerBound > cursor {
                    result.append(contentsOf: baseLines[cursor..<edit.baseRange.lowerBound])
                }
                result.append(contentsOf: edit.replacement)
                cursor = edit.baseRange.upperBound
            }
            if cursor < span.upperBound {
                result.append(contentsOf: baseLines[cursor..<span.upperBound])
            }
            return result
        }

        var segments: [DocumentMergeSegment] = []
        var cleanBuffer: [String] = []
        var hunkCount = 0

        func flushCleanBuffer() {
            if !cleanBuffer.isEmpty {
                segments.append(.clean(cleanBuffer))
                cleanBuffer.removeAll(keepingCapacity: true)
            }
        }

        var baseCursor = 0
        var i = 0
        var j = 0

        while i < localEdits.count || j < externalEdits.count {
            if i < localEdits.count && (j >= externalEdits.count || (!editsOverlap(localEdits[i].baseRange, externalEdits[j].baseRange) && localEdits[i].baseRange.lowerBound < externalEdits[j].baseRange.lowerBound)) {
                let edit = localEdits[i]
                if edit.baseRange.lowerBound > baseCursor {
                    cleanBuffer.append(contentsOf: baseLines[baseCursor..<edit.baseRange.lowerBound])
                }
                cleanBuffer.append(contentsOf: edit.replacement)
                baseCursor = edit.baseRange.upperBound
                i += 1
            } else if j < externalEdits.count && (i >= localEdits.count || (!editsOverlap(localEdits[i].baseRange, externalEdits[j].baseRange) && externalEdits[j].baseRange.lowerBound < localEdits[i].baseRange.lowerBound)) {
                let edit = externalEdits[j]
                if edit.baseRange.lowerBound > baseCursor {
                    cleanBuffer.append(contentsOf: baseLines[baseCursor..<edit.baseRange.lowerBound])
                }
                cleanBuffer.append(contentsOf: edit.replacement)
                baseCursor = edit.baseRange.upperBound
                j += 1
            } else {
                // Overlapping local and external edits: expand cluster to include all transitively overlapping edits
                var groupLocal: [DocumentLineDiff.LineEdit] = [localEdits[i]]
                var groupExternal: [DocumentLineDiff.LineEdit] = [externalEdits[j]]
                var spanStart = min(localEdits[i].baseRange.lowerBound, externalEdits[j].baseRange.lowerBound)
                var spanEnd = max(localEdits[i].baseRange.upperBound, externalEdits[j].baseRange.upperBound)
                i += 1
                j += 1

                var expanded = true
                while expanded {
                    expanded = false
                    while i < localEdits.count && editsOverlap(spanStart..<spanEnd, localEdits[i].baseRange) {
                        spanStart = min(spanStart, localEdits[i].baseRange.lowerBound)
                        spanEnd = max(spanEnd, localEdits[i].baseRange.upperBound)
                        groupLocal.append(localEdits[i])
                        i += 1
                        expanded = true
                    }
                    while j < externalEdits.count && editsOverlap(spanStart..<spanEnd, externalEdits[j].baseRange) {
                        spanStart = min(spanStart, externalEdits[j].baseRange.lowerBound)
                        spanEnd = max(spanEnd, externalEdits[j].baseRange.upperBound)
                        groupExternal.append(externalEdits[j])
                        j += 1
                        expanded = true
                    }
                }

                if spanStart > baseCursor {
                    cleanBuffer.append(contentsOf: baseLines[baseCursor..<spanStart])
                }

                let spanRange = spanStart..<spanEnd
                let localChunk = applyEdits(groupLocal, over: spanRange)
                let externalChunk = applyEdits(groupExternal, over: spanRange)

                if localChunk == externalChunk {
                    // Both sides made the exact same edit
                    cleanBuffer.append(contentsOf: localChunk)
                } else {
                    flushCleanBuffer()
                    hunkCount += 1
                    segments.append(.conflict(DocumentConflictHunk(
                        index: hunkCount,
                        baseStartLine: max(1, spanStart + 1),
                        baseLines: Array(baseLines[spanRange]),
                        localLines: localChunk,
                        externalLines: externalChunk,
                        selectedResolution: .keepLocal
                    )))
                }

                baseCursor = spanEnd
            }
        }

        if baseCursor < baseLines.count {
            cleanBuffer.append(contentsOf: baseLines[baseCursor..<baseLines.count])
        }
        flushCleanBuffer()

        if hunkCount == 0 {
            let mergedLines = segments.flatMap { segment -> [String] in
                if case let .clean(lines) = segment { return lines }
                return []
            }
            return .clean(mergedText: mergedLines.joined(separator: "\n"), wasAutoMerged: true)
        } else {
            return .conflict(DocumentConflict(
                fileURL: fileURL,
                baseText: base,
                localText: local,
                externalText: external,
                segments: segments,
                sourceDescription: sourceDescription
            ))
        }
    }
}

