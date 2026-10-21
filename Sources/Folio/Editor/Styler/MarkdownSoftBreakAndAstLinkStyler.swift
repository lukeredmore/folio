import AppKit
import Foundation

extension MarkdownLiveStyler {

    static func applyDeferredProseInlineStyles(
        in storage: NSTextStorage,
        string: String,
        fullLength: Int,
        deferredProseInline: [DeferredInlineStyle],
        lineRecords: [Int: LineRecord],
        theme: EditorTheme,
        prettyMode: Bool,
        baseDirectoryURL: URL?,
        decorations: inout [LineDecoration]
    ) {
        // Style each run of lines joined by soft breaks as one inline range.
        var runStart = 0
        for i in deferredProseInline.indices {
            let item = deferredProseInline[i]
            let continuesRun = i + 1 < deferredProseInline.count
                && deferredProseInline[i + 1].line == item.line + 1
                && lineRecords[item.line].map { rec in
                    NSMaxRange(rec.contentRange) < fullLength
                        && storage.attribute(softLineBreakAttributeKey, at: NSMaxRange(rec.contentRange), effectiveRange: nil) != nil
                } == true
            guard !continuesRun else { continue }
            let run = deferredProseInline[runStart...i]
            let first = deferredProseInline[runStart]
            // Style consecutive lines with the same activity as one range: the cursor line reveals
            // its syntax, and the lines around it keep spans that cross soft breaks folded.
            var segmentStart = runStart
            for j in runStart...i where j == i || deferredProseInline[j + 1].isActive != deferredProseInline[j].isActive {
                let segFirst = deferredProseInline[segmentStart]
                let segLast = deferredProseInline[j]
                styleInlineMarkdown(
                    in: storage,
                    string: string,
                    range: NSRange(location: segFirst.range.location, length: NSMaxRange(segLast.range) - segFirst.range.location),
                    lineRange: (segmentStart == j) ? lineRecords[segFirst.line]?.lineRange : nil,
                    baseFont: first.baseFont,
                    isActiveLine: segFirst.isActive,
                    theme: theme,
                    dimFactor: segFirst.dimFactor,
                    normalizeWhitespace: !segFirst.isActive,
                    prettyMode: prettyMode,
                    baseDirectoryURL: baseDirectoryURL,
                    decorations: &decorations
                )
                segmentStart = j + 1
            }
            if run.count > 1 {
                // Whitespace at a soft break is not content: hide continuation indentation and
                // trailing spaces even while the paragraph is being edited.
                for entry in run {
                    guard let rec = lineRecords[entry.line] else { continue }
                    for regex in [leadingSpaceRegex, trailingSpaceRegex] {
                        let isLeading = regex === leadingSpaceRegex
                        if isLeading && entry.line == first.line { continue }
                        if !isLeading && entry.line == item.line { continue }
                        if let match = regex.firstMatch(in: string, options: [], range: rec.contentRange) {
                            collapseWhitespaceRange(in: storage, range: match.range)
                        }
                    }
                }
            }
            runStart = i + 1
        }
    }

    static func applyAstResolvedLinks(
        in storage: NSTextStorage,
        nsString: NSString,
        fullLength: Int,
        astLinksByLine: [Int: [CmarkAstInline]],
        lineRecords: [Int: LineRecord],
        theme: EditorTheme,
        prettyMode: Bool,
        baseDirectoryURL: URL?,
        decorations: inout [LineDecoration]
    ) {
        guard !astLinksByLine.isEmpty else { return }
        for (ln, links) in astLinksByLine {
            guard var rec = lineRecords[ln] else { continue }
            for reported in links {
                let link = correctedInlineStart(reported, lineRecords: lineRecords)
                let spanLines = link.startLine...link.endLine
                if link.endLine > link.startLine {
                    // A multi-line span is only one visual span when its lines are joined.
                    let joined = (link.startLine..<link.endLine).allSatisfy { l in
                        guard let r = lineRecords[l], NSMaxRange(r.contentRange) < fullLength else { return false }
                        return storage.attribute(softLineBreakAttributeKey, at: NSMaxRange(r.contentRange), effectiveRange: nil) != nil
                    }
                    guard joined else { continue }
                }
                guard let docStart = documentOffset(lineRecords[link.startLine], byteColumn: link.startColumn - 1),
                      let docEnd = documentOffset(lineRecords[link.endLine], byteColumn: link.endColumn),
                      docEnd > docStart else {
                    continue
                }
                let docRange = NSRange(location: docStart, length: docEnd - docStart)
                guard NSMaxRange(docRange) <= fullLength, docRange.length > 0 else { continue }
                rec.isActive = spanLines.contains { lineRecords[$0]?.isActive ?? false }

                let spanText = nsString.substring(with: docRange)
                if spanText.hasPrefix("[") || spanText.hasPrefix("![") {
                    let isImg = spanText.hasPrefix("![")
                    let openLen = isImg ? 2 : 1
                    let spanNS = spanText as NSString
                    var scan = openLen
                    var depth = 1
                    var closeBracketOffset: Int? = nil
                    while scan < spanNS.length {
                        let c = spanNS.character(at: scan)
                        if c == 0x5C { // backslash escape
                            scan += 2
                            continue
                        } else if c == 0x5B {
                            depth += 1
                        } else if c == 0x5D {
                            depth -= 1
                            if depth == 0 {
                                closeBracketOffset = scan
                                break
                            }
                        }
                        scan += 1
                    }
                    guard let closeBracket = closeBracketOffset, closeBracket >= openLen else { continue }
                    // Inline `[label](url)` links were already styled by scanMarkdownLinks
                    if closeBracket + 1 < spanNS.length && spanNS.character(at: closeBracket + 1) == 0x28 {
                        continue
                    }
                    let openSyntaxRange = NSRange(location: docRange.location, length: openLen)
                    let labelRange = NSRange(location: docRange.location + openLen, length: closeBracket - openLen)
                    let trailingSyntaxRange = NSRange(
                        location: docRange.location + closeBracket,
                        length: docRange.length - closeBracket
                    )
                    if isImg && prettyMode && !rec.isActive && !link.url.isEmpty {
                        let altStr = nsString.substring(with: labelRange)
                        let display = FolioMediaImageCache.shared.displaySize(
                            for: link.url,
                            explicitWidth: nil,
                            explicitHeight: nil,
                            maxColumnWidth: theme.typography.maxColumnWidth,
                            baseDirectoryURL: baseDirectoryURL,
                            isDark: theme.isDark
                        )
                        let targetH = display.isLoaded ? max(26.0, display.size.height + 10.0) : 52.0
                        reserveMediaCardHeight(in: storage, lineRange: rec.lineRange, targetHeight: targetH)
                        collapseWhitespaceRange(in: storage, range: docRange)
                        decorations.append(LineDecoration(
                            lineRange: rec.lineRange,
                            kind: .imageRendered(
                                url: link.url,
                                alt: altStr,
                                fullRange: docRange,
                                explicitWidth: nil,
                                explicitHeight: nil,
                                baseDirectoryURL: baseDirectoryURL,
                                dimFactor: rec.dimFactor
                            )
                        ))
                    } else {
                        applyAttributesToVisibleCharacters(
                            in: storage,
                            range: labelRange,
                            attributes: [
                                .foregroundColor: theme.linkNSColor.withAlphaComponent(rec.dimFactor),
                                .underlineStyle: NSUnderlineStyle.single.rawValue
                            ]
                        )
                        styleSyntaxToken(in: storage, range: openSyntaxRange, isActiveLine: rec.isActive || !prettyMode, theme: theme, dimFactor: rec.dimFactor)
                        styleSyntaxToken(in: storage, range: trailingSyntaxRange, isActiveLine: rec.isActive || !prettyMode, theme: theme, dimFactor: rec.dimFactor)
                    }
                } else if !spanText.hasPrefix("<") {
                    // GFM extended bare autolink (e.g. www.example.com, https://example.com)
                    applyAttributesToVisibleCharacters(
                        in: storage,
                        range: docRange,
                        attributes: [
                            .foregroundColor: theme.linkNSColor.withAlphaComponent(rec.dimFactor),
                            .underlineStyle: NSUnderlineStyle.single.rawValue
                        ]
                    )
                }
            }
        }
    }

    // MARK: - Helpers for Line Ranges & Indentation

    /// Marks source newlines inside cmark paragraphs as soft line breaks, so the layout manager
    /// renders them as spaces and the paragraph wraps to the container width. This includes the
    /// paragraph that contains the cursor, so entering a paragraph does not change its layout.
    static func applySoftLineBreaks(
        to storage: NSTextStorage,
        blocks: [CmarkAstBlock],
        lineRecords: [Int: LineRecord],
        proseLineKinds: [Int: ProseLineKind]
    ) {
        let nsString = storage.string as NSString
        for block in blocks where block.kind == 8 && block.endLine > block.startLine && block.startLine > 0 {
            for ln in block.startLine..<block.endLine {
                guard let rec = lineRecords[ln],
                      canJoinProseLines(proseLineKinds[ln], proseLineKinds[ln + 1]),
                      !endsWithHardLineBreak(rec.lineText) else {
                    continue
                }
                let newlineLocation = NSMaxRange(rec.contentRange)
                guard newlineLocation < NSMaxRange(rec.lineRange),
                      nsString.character(at: newlineLocation) == 10 else {
                    continue
                }
                // TextKit lays out the joined paragraph with the style of its first source line.
                storage.addAttribute(softLineBreakAttributeKey, value: true, range: NSRange(location: newlineLocation, length: 1))
            }
        }
    }

    /// cmark-gfm reports the closing line as the start line of a link that crosses a line break
    /// (e.g. `3:36-3:10` for a link that starts on line 2). When the reported start is not `[` or
    /// `!`, uses the nearest earlier line that has one at the reported start column.
    static func correctedInlineStart(
        _ inline: CmarkAstInline,
        lineRecords: [Int: LineRecord]
    ) -> CmarkAstInline {
        let col = inline.startColumn - 1
        let startsWithBracket: (Int) -> Bool = { line in
            guard let rec = lineRecords[line] else { return false }
            let bytes = Array(rec.lineText.utf8)
            return col >= 0 && col < bytes.count && (bytes[col] == UInt8(ascii: "[") || bytes[col] == UInt8(ascii: "!"))
        }
        guard !startsWithBracket(inline.startLine) else { return inline }
        var line = inline.startLine - 1
        while line >= 1, lineRecords[line] != nil {
            if startsWithBracket(line) {
                return CmarkAstInline(
                    kind: inline.kind,
                    startLine: line,
                    startColumn: inline.startColumn,
                    endLine: inline.endLine,
                    endColumn: inline.endColumn,
                    url: inline.url,
                    literal: inline.literal
                )
            }
            line -= 1
        }
        return inline
    }

    /// UTF-16 document offset of a 0-based UTF-8 byte column in a line's content.
    static func documentOffset(
        _ rec: LineRecord?,
        byteColumn: Int
    ) -> Int? {
        guard let rec = rec else { return nil }
        let utf8 = rec.lineText.utf8
        guard let idx = utf8.index(utf8.startIndex, offsetBy: max(0, min(byteColumn, utf8.count)), limitedBy: utf8.endIndex) else {
            return nil
        }
        return rec.contentRange.location + NSRange(utf8.startIndex..<idx, in: rec.lineText).length
    }

    static func canJoinProseLines(_ current: ProseLineKind?, _ next: ProseLineKind?) -> Bool {
        switch (current, next) {
        case (.paragraph?, .paragraph?), (.listItem?, .paragraph?):
            return true
        case let (.blockquote(a)?, .blockquote(b)?):
            return a == b
        default:
            return false
        }
    }

    /// CommonMark hard line break: two or more trailing spaces, a trailing unescaped backslash, or `<br>`.
    static func endsWithHardLineBreak(_ lineText: String) -> Bool {
        if lineText.hasSuffix("  ") {
            return true
        }
        let trailingBackslashes = lineText.reversed().prefix(while: { $0 == "\\" }).count
        if trailingBackslashes % 2 == 1 {
            return true
        }
        let lower = lineText.lowercased().trimmingCharacters(in: .whitespaces)
        return lower.hasSuffix("<br>") || lower.hasSuffix("<br/>") || lower.hasSuffix("<br />")
    }

    static func strippedLineContentRange(nsString: NSString, lineRange: NSRange) -> NSRange {
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

    static func isLineActive(lineRange: NSRange, activeLineRange: NSRange, selectedRange: NSRange) -> Bool {
        return NSIntersectionRange(lineRange, activeLineRange).length > 0 ||
            (selectedRange.location == lineRange.location + lineRange.length && lineRange.location == activeLineRange.location)
    }

    static func indentationColumnCount(nsString: NSString, range: NSRange) -> Int {
        var cols = 0
        let end = NSMaxRange(range)
        var i = range.location
        while i < end {
            let ch = nsString.character(at: i)
            if ch == 9 { // tab
                cols += 4 - (cols % 4)
            } else if ch == 32 {
                cols += 1
            }
            i += 1
        }
        return cols
    }
}
