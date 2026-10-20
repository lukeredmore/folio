import Foundation

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

    static func computeLCSMatchesInSlice(
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
    static func longestIncreasingSubsequence(of pairs: [(Int, Int)]) -> [(Int, Int)] {
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
}
