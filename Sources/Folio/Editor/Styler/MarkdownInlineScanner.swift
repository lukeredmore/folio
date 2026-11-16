import AppKit
import Foundation

extension MarkdownLiveStyler {

    /// Linear-time $O(N)$ CommonMark inline code span scanner.
    /// Collects contiguous backtick runs in a single pass, respects backslash-escaped opening
    /// backticks (`\``) outside code spans while keeping `\` literal inside open code spans,
    /// and pairs matching run lengths without quadratic rescanning.
    static func scanInlineCodeSpans(nsString: NSString, range: NSRange) -> [ScannedInlineCodeSpan] {
        let end = NSMaxRange(range)
        var runs: [(location: Int, length: Int, firstEscaped: Bool)] = []
        var runsByLength: [Int: [Int]] = [:]

        var idx = range.location
        while idx < end {
            let ch = nsString.character(at: idx)
            if ch == 0x60 {
                let start = idx
                var slashCount = 0
                var back = start
                while back > range.location && nsString.character(at: back - 1) == 0x5C {
                    slashCount += 1
                    back -= 1
                }
                while idx < end && nsString.character(at: idx) == 0x60 {
                    idx += 1
                }
                let len = idx - start
                let runIdx = runs.count
                runs.append((location: start, length: len, firstEscaped: (slashCount % 2) == 1))
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
            let rawOpen = runs[i]
            let openLocation = rawOpen.firstEscaped ? rawOpen.location + 1 : rawOpen.location
            let openLength = rawOpen.firstEscaped ? rawOpen.length - 1 : rawOpen.length
            guard openLength > 0, let candidates = runsByLength[openLength] else {
                i += 1
                continue
            }
            var cursor = cursorByLength[openLength] ?? 0
            while cursor < candidates.count && candidates[cursor] <= i {
                cursor += 1
            }
            cursorByLength[openLength] = cursor

            if cursor < candidates.count {
                let closeRunIdx = candidates[cursor]
                let closeRun = runs[closeRunIdx]
                let openEnd = openLocation + openLength
                let innerLen = closeRun.location - openEnd
                if innerLen > 0 {
                    let fullRange = NSRange(
                        location: openLocation,
                        length: (closeRun.location + closeRun.length) - openLocation
                    )
                    let openRange = NSRange(location: openLocation, length: openLength)
                    let innerRange = NSRange(location: openEnd, length: innerLen)
                    let closeRange = NSRange(location: closeRun.location, length: closeRun.length)
                    results.append(
                        ScannedInlineCodeSpan(
                            fullRange: fullRange,
                            openRange: openRange,
                            innerRange: innerRange,
                            closeRange: closeRange
                        ))
                    cursorByLength[openLength] = cursor + 1
                    i = closeRunIdx + 1
                    continue
                }
            }
            i += 1
        }

        return results
    }

    /// Linear-time CommonMark inline link & image scanner (`[label](destination "title")` and `![alt](destination)`).
    /// Validates CommonMark link destinations (`<...>` or non-space bare URLs with balanced parentheses)
    /// and optional quoted/parenthesized titles so prose/math expressions like `f[x](a, b)` are never
    /// misparsed as links and `)` inside quoted titles `[link](url "a :)")` is handled accurately.
    static func scanMarkdownLinks(
        nsString: NSString,
        range: NSRange,
        isDelimiterProtected: (NSRange) -> Bool
    ) -> [ScannedMarkdownLink] {
        let end = NSMaxRange(range)
        guard range.length >= 4 else { return [] }

        struct OpenBracketEntry {
            let openStart: Int
            let bracketPos: Int
            let isImage: Bool
        }

        struct TailFailureMemo {
            var noAngleCloseBefore = 0
            var unclosedDoubleQuoteFrom = Int.max
            var unclosedSingleQuoteFrom = Int.max
        }

        var memo = TailFailureMemo()

        func isLinkWhitespace(_ ch: unichar) -> Bool {
            ch == 0x20 || ch == 0x09 || ch == 0x0A || ch == 0x0D
        }

        func isASCIIPunctuation(_ ch: unichar) -> Bool {
            (ch >= 0x21 && ch <= 0x2F)
                || (ch >= 0x3A && ch <= 0x40)
                || (ch >= 0x5B && ch <= 0x60)
                || (ch >= 0x7B && ch <= 0x7E)
        }

        func skipLinkWhitespace(from start: Int) -> (pos: Int, valid: Bool) {
            var pos = start
            var newlineCount = 0
            while pos < end && isLinkWhitespace(nsString.character(at: pos)) {
                let ch = nsString.character(at: pos)
                if ch == 0x0A {
                    newlineCount += 1
                    if newlineCount > 1 {
                        return (pos, false)
                    }
                }
                pos += 1
            }
            return (pos, true)
        }

        func parseInlineLinkTail(openParenIdx: Int) -> (closeParenIdx: Int, url: String)? {
            let leadingWS = skipLinkWhitespace(from: openParenIdx + 1)
            guard leadingWS.valid else { return nil }
            var pos = leadingWS.pos
            guard pos < end else { return nil }

            if nsString.character(at: pos) == 0x29 {
                guard !isDelimiterProtected(NSRange(location: pos, length: 1)) else { return nil }
                return (closeParenIdx: pos, url: "")
            }

            let url: String
            if nsString.character(at: pos) == 0x3C {
                guard pos >= memo.noAngleCloseBefore else { return nil }
                var cursor = pos + 1
                var foundCloseAngle: Int?
                while cursor < end {
                    if isDelimiterProtected(NSRange(location: cursor, length: 1)) {
                        return nil
                    }
                    let ch = nsString.character(at: cursor)
                    if ch == 0x0A || ch == 0x0D || ch == 0x3C {
                        return nil
                    }
                    if ch == 0x5C {
                        guard cursor + 1 < end else { return nil }
                        let next = nsString.character(at: cursor + 1)
                        if next == 0x0A || next == 0x0D {
                            return nil
                        }
                        cursor += 2
                        continue
                    }
                    if ch == 0x3E {
                        foundCloseAngle = cursor
                        break
                    }
                    cursor += 1
                }
                guard let closeAngle = foundCloseAngle else {
                    if cursor >= end {
                        memo.noAngleCloseBefore = end
                    }
                    return nil
                }
                url = nsString.substring(with: NSRange(location: pos + 1, length: closeAngle - (pos + 1)))
                pos = closeAngle + 1
            } else {
                let destStart = pos
                var parenDepth = 0
                while pos < end {
                    let ch = nsString.character(at: pos)
                    if ch <= 0x20 || ch == 0x7F {
                        break
                    }
                    if isDelimiterProtected(NSRange(location: pos, length: 1)) {
                        return nil
                    }
                    if ch == 0x5C, pos + 1 < end, isASCIIPunctuation(nsString.character(at: pos + 1)) {
                        pos += 2
                        continue
                    }
                    if ch == 0x28 {
                        parenDepth += 1
                        if parenDepth > 32 {
                            return nil
                        }
                        pos += 1
                        continue
                    }
                    if ch == 0x29 {
                        if parenDepth == 0 {
                            break
                        }
                        parenDepth -= 1
                        pos += 1
                        continue
                    }
                    pos += 1
                }
                guard parenDepth == 0, pos > destStart else { return nil }
                url = nsString.substring(with: NSRange(location: destStart, length: pos - destStart))
            }

            let midWS = skipLinkWhitespace(from: pos)
            guard midWS.valid else { return nil }
            let hadWhitespace = midWS.pos > pos
            pos = midWS.pos
            guard pos < end else { return nil }

            if nsString.character(at: pos) == 0x29 {
                guard !isDelimiterProtected(NSRange(location: pos, length: 1)) else { return nil }
                return (closeParenIdx: pos, url: url)
            }

            guard hadWhitespace else { return nil }
            let titleOpen = nsString.character(at: pos)
            let titleClose: unichar
            switch titleOpen {
            case 0x22:
                guard pos < memo.unclosedDoubleQuoteFrom else { return nil }
                titleClose = 0x22
            case 0x27:
                guard pos < memo.unclosedSingleQuoteFrom else { return nil }
                titleClose = 0x27
            case 0x28:
                titleClose = 0x29
            default:
                return nil
            }

            let quoteStart = pos
            pos += 1
            var closedTitle = false
            var newlineRun = 0
            while pos < end {
                if isDelimiterProtected(NSRange(location: pos, length: 1)) {
                    return nil
                }
                let ch = nsString.character(at: pos)
                if ch == 0x0A {
                    newlineRun += 1
                    if newlineRun > 1 {
                        return nil
                    }
                } else if ch != 0x20 && ch != 0x09 && ch != 0x0D {
                    newlineRun = 0
                }
                if ch == 0x5C, pos + 1 < end {
                    pos += 2
                    continue
                }
                if titleOpen == 0x28 && ch == 0x28 {
                    return nil
                }
                if ch == titleClose {
                    pos += 1
                    closedTitle = true
                    break
                }
                pos += 1
            }
            guard closedTitle else {
                if pos >= end {
                    if titleOpen == 0x22 {
                        memo.unclosedDoubleQuoteFrom = min(memo.unclosedDoubleQuoteFrom, quoteStart)
                    } else if titleOpen == 0x27 {
                        memo.unclosedSingleQuoteFrom = min(memo.unclosedSingleQuoteFrom, quoteStart)
                    }
                }
                return nil
            }

            let trailingWS = skipLinkWhitespace(from: pos)
            guard trailingWS.valid else { return nil }
            pos = trailingWS.pos
            guard pos < end,
                nsString.character(at: pos) == 0x29,
                !isDelimiterProtected(NSRange(location: pos, length: 1))
            else {
                return nil
            }
            return (closeParenIdx: pos, url: url)
        }

        var results: [ScannedMarkdownLink] = []
        var openStack: [OpenBracketEntry] = []
        var idx = range.location

        while idx < end {
            let ch = nsString.character(at: idx)
            if ch == 0x5C, idx + 1 < end, isASCIIPunctuation(nsString.character(at: idx + 1)) {
                idx += 2
                continue
            }
            if ch == 0x21 && idx + 1 < end && nsString.character(at: idx + 1) == 0x5B {
                let openSyntaxRange = NSRange(location: idx, length: 2)
                if !isDelimiterProtected(openSyntaxRange) {
                    openStack.append(OpenBracketEntry(openStart: idx, bracketPos: idx + 1, isImage: true))
                    idx += 2
                    continue
                }
            } else if ch == 0x5B {
                let openSyntaxRange = NSRange(location: idx, length: 1)
                if !isDelimiterProtected(openSyntaxRange) {
                    openStack.append(OpenBracketEntry(openStart: idx, bracketPos: idx, isImage: false))
                    idx += 1
                    continue
                }
            } else if ch == 0x5D {
                let closeRange = NSRange(location: idx, length: 1)
                if !isDelimiterProtected(closeRange), let open = openStack.popLast() {
                    if idx + 1 < end,
                        nsString.character(at: idx + 1) == 0x28,
                        !isDelimiterProtected(NSRange(location: idx, length: 2)),
                        let parsedTail = parseInlineLinkTail(openParenIdx: idx + 1)
                    {
                        let closeParen = parsedTail.closeParenIdx
                        let rawDest = parsedTail.url
                        let labelRange = NSRange(location: open.bracketPos + 1, length: idx - (open.bracketPos + 1))
                        if labelRange.length > 0 || open.isImage {
                            // Anchor image `[![alt](img_url)](link_url)`
                            if open.isImage,
                                let outer = openStack.last,
                                !outer.isImage,
                                outer.openStart + 1 == open.openStart,
                                closeParen + 2 < end,
                                nsString.character(at: closeParen + 1) == 0x5D,
                                nsString.character(at: closeParen + 2) == 0x28,
                                !isDelimiterProtected(NSRange(location: closeParen + 1, length: 2)),
                                let outerTail = parseInlineLinkTail(openParenIdx: closeParen + 2)
                            {
                                let outerCloseParen = outerTail.closeParenIdx
                                openStack.removeLast()
                                let openSyntaxRange = NSRange(location: outer.openStart, length: 3)
                                let trailingRange = NSRange(location: idx, length: (outerCloseParen + 1) - idx)
                                let fullRange = NSRange(
                                    location: outer.openStart,
                                    length: (outerCloseParen + 1) - outer.openStart
                                )
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
                            let fullRange = NSRange(
                                location: open.openStart,
                                length: (closeParen + 1) - open.openStart
                            )
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
