import AppKit
import Foundation

extension MarkdownLiveStyler {

    /// Linear-time $O(N)$ CommonMark inline code span scanner.
    /// Collects contiguous backtick runs in a single pass and pairs matching run lengths without quadratic rescanning.
    static func scanInlineCodeSpans(nsString: NSString, range: NSRange) -> [ScannedInlineCodeSpan] {
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
                    results.append(
                        ScannedInlineCodeSpan(
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

    /// Linear-time $O(N)$ Markdown link & image scanner (`[label](url)` and `![alt](url)`).
    /// Precomputes balanced parentheses in one pass and uses an explicit bracket stack to avoid $O(N^2)$ rescanning on unmatched `[` or `](`.
    static func scanMarkdownLinks(
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
                    let openParen = parenStack.popLast()
                {
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
                        let closeParen = matchingCloseParen[idx + 1]
                    {
                        let labelRange = NSRange(location: open.bracketPos + 1, length: idx - (open.bracketPos + 1))
                        if labelRange.length > 0 || open.isImage {
                            let rawDestRange = NSRange(location: idx + 2, length: max(0, closeParen - (idx + 2)))
                            var rawDest = nsString.substring(with: rawDestRange).trimmingCharacters(in: .whitespacesAndNewlines)
                            if rawDest.hasPrefix("<"), let closeAngleIdx = rawDest.firstIndex(of: ">") {
                                rawDest = String(rawDest[rawDest.index(after: rawDest.startIndex)..<closeAngleIdx])
                            } else if let spaceIdx = rawDest.firstIndex(where: { $0 == " " || $0 == "\t" }) {
                                rawDest = String(rawDest[..<spaceIdx])
                            }

                            // Check for anchor image `[![alt](img_url)](link_url)`
                            if open.isImage,
                                let outer = openStack.last,
                                !outer.isImage,
                                outer.openStart + 1 == open.openStart,
                                closeParen + 2 < end,
                                nsString.character(at: closeParen + 1) == 0x5D,
                                nsString.character(at: closeParen + 2) == 0x28,
                                !isDelimiterProtected(NSRange(location: closeParen + 1, length: 2)),
                                let outerCloseParen = matchingCloseParen[closeParen + 2]
                            {
                                openStack.removeLast()
                                let openSyntaxRange = NSRange(location: outer.openStart, length: 3)
                                let trailingRange = NSRange(location: idx, length: (outerCloseParen + 1) - idx)
                                let fullRange = NSRange(location: outer.openStart, length: (outerCloseParen + 1) - outer.openStart)
                                results.append(
                                    ScannedMarkdownLink(
                                        isImage: true,
                                        fullRange: fullRange,
                                        openSyntaxRange: openSyntaxRange,
                                        labelRange: labelRange,
                                        trailingSyntaxRange: trailingRange,
                                        url: rawDest
                                    ))
                                openStack.removeAll(keepingCapacity: true)
                                idx = outerCloseParen + 1
                                continue
                            }

                            let openSyntaxRange = NSRange(location: open.openStart, length: open.isImage ? 2 : 1)
                            let trailingRange = NSRange(location: idx, length: (closeParen + 1) - idx)
                            let fullRange = NSRange(location: open.openStart, length: (closeParen + 1) - open.openStart)
                            results.append(
                                ScannedMarkdownLink(
                                    isImage: open.isImage,
                                    fullRange: fullRange,
                                    openSyntaxRange: openSyntaxRange,
                                    labelRange: labelRange,
                                    trailingSyntaxRange: trailingRange,
                                    url: rawDest
                                ))
                            if !open.isImage {
                                openStack.removeAll(keepingCapacity: true)
                            }
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
}
