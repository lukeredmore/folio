import AppKit
import Foundation

extension MarkdownStylePass {

    // MARK: - Soft Line Breaks, Deferred Prose Inlines & AST-Resolved Links

    /// Marks source newlines inside cmark paragraphs in this pass's region as soft line breaks, so
    /// the layout manager renders them as spaces and the paragraph wraps to the container width.
    func applySoftLineBreaks() {
        for block in regionParagraphBlocks where block.endLine > block.startLine {
            for ln in block.startLine..<block.endLine {
                guard let rec = lineRecords[ln],
                    Styler.canJoinProseLines(proseLineKinds[ln], proseLineKinds[ln + 1]),
                    !Styler.endsWithHardLineBreak(rec.lineText)
                else {
                    continue
                }
                let newlineLocation = NSMaxRange(rec.contentRange)
                guard newlineLocation < NSMaxRange(rec.lineRange),
                    nsString.character(at: newlineLocation) == 10
                else {
                    continue
                }
                storage.addAttribute(
                    Styler.softLineBreakAttributeKey,
                    value: true,
                    range: NSRange(location: newlineLocation, length: 1)
                )
            }
        }
    }

    func applyDeferredProseInlineStyles() {
        guard !deferredProseInline.isEmpty else { return }
        var runStart = 0
        for i in deferredProseInline.indices {
            let item = deferredProseInline[i]
            let continuesRun =
                i + 1 < deferredProseInline.count
                && deferredProseInline[i + 1].line == item.line + 1
                && lineRecords[item.line].map { rec in
                    NSMaxRange(rec.contentRange) < fullLength
                        && storage.attribute(Styler.softLineBreakAttributeKey, at: NSMaxRange(rec.contentRange), effectiveRange: nil) != nil
                } == true
            guard !continuesRun else { continue }
            let run = deferredProseInline[runStart...i]
            let first = deferredProseInline[runStart]

            var segmentStart = runStart
            for j in runStart...i where j == i || deferredProseInline[j + 1].isActive != deferredProseInline[j].isActive {
                let segFirst = deferredProseInline[segmentStart]
                let segLast = deferredProseInline[j]
                Styler.styleInlineMarkdown(
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
                    decorations: &decorations.deferredInline
                )
                segmentStart = j + 1
            }

            if run.count > 1 {
                for entry in run {
                    guard let rec = lineRecords[entry.line] else { continue }
                    for regex in [Styler.leadingSpaceRegex, Styler.trailingSpaceRegex] {
                        let isLeading = regex === Styler.leadingSpaceRegex
                        if isLeading && entry.line == first.line { continue }
                        if !isLeading && entry.line == item.line { continue }
                        if let match = regex.firstMatch(in: string, options: [], range: rec.contentRange) {
                            Styler.collapseWhitespaceRange(in: storage, range: match.range)
                        }
                    }
                }
            }
            runStart = i + 1
        }
    }

    func applyAstResolvedLinks() {
        guard !astLinkLinesSorted.isEmpty else { return }
        var columns = Styler.LineUTF8ColumnCache(lineRecords: lineRecords)
        for ln in astLinkLinesSorted {
            if tableStyledLines.contains(ln) {
                if let tableDecos = tableLinkDecorationsByLine[ln] {
                    decorations.links.append(contentsOf: tableDecos)
                }
                continue
            }
            applyAstLinks(onLine: ln, columns: &columns, decorations: &decorations.links)
        }
    }

    private func continuationByteDeltas(forLine line: Int) -> [Int] {
        guard let paraStart = paragraphStartLineByLine[line],
            line > paraStart,
            let startPrefix = proseContentPrefixBytes[paraStart]
        else {
            return [0]
        }
        let linePrefix = proseContentPrefixBytes[line] ?? 0
        let nonLazyDelta = linePrefix - startPrefix
        let lazyDelta = -startPrefix
        var deltas: [Int] = [nonLazyDelta]
        if lazyDelta != nonLazyDelta {
            deltas.append(lazyDelta)
        }
        if !deltas.contains(0) {
            deltas.append(0)
        }
        return deltas
    }

    private func resolveAstLinkSpan(
        _ reported: CmarkAstInline,
        currentLine: Int,
        currentLineDeltas: [Int],
        columns: inout Styler.LineUTF8ColumnCache
    ) -> (startLine: Int, endLine: Int, docRange: NSRange)? {
        func deltas(for line: Int) -> [Int] {
            line == currentLine ? currentLineDeltas : continuationByteDeltas(forLine: line)
        }

        func makeSpan(startLine: Int, startByteColumn: Int, endLine: Int, endByteColumn: Int) -> (startLine: Int, endLine: Int, docRange: NSRange)? {
            guard let docStart = columns.documentOffset(line: startLine, byteColumn: startByteColumn),
                let docEnd = columns.documentOffset(line: endLine, byteColumn: endByteColumn),
                docEnd > docStart,
                docEnd <= fullLength
            else {
                return nil
            }
            return (startLine, endLine, NSRange(location: docStart, length: docEnd - docStart))
        }

        func startsWithLinkBracket(line: Int, column: Int) -> Bool {
            guard let byte = columns.byte(line: line, column: column) else { return false }
            if byte == UInt8(ascii: "[") { return true }
            return byte == UInt8(ascii: "!") && columns.byte(line: line, column: column + 1) == UInt8(ascii: "[")
        }

        let endDeltas = deltas(for: reported.endLine)
        let startDeltas = deltas(for: reported.startLine)
        for endDelta in endDeltas {
            let candidateEndCol = reported.endColumn + endDelta
            let endByte = columns.byte(line: reported.endLine, column: candidateEndCol - 1)
            guard endByte == UInt8(ascii: "]") || endByte == UInt8(ascii: ")") else { continue }

            for startDelta in startDeltas {
                let candidateStartCol = reported.startColumn - 1 + startDelta
                if startsWithLinkBracket(line: reported.startLine, column: candidateStartCol) {
                    return makeSpan(
                        startLine: reported.startLine,
                        startByteColumn: candidateStartCol,
                        endLine: reported.endLine,
                        endByteColumn: candidateEndCol
                    )
                }
            }

            if reported.startLine > 1 {
                var prevLine = reported.startLine - 1
                while prevLine >= 1, columns.lineRecords[prevLine] != nil {
                    for startDelta in deltas(for: prevLine) {
                        let candidateStartCol = reported.startColumn - 1 + startDelta
                        if startsWithLinkBracket(line: prevLine, column: candidateStartCol) {
                            return makeSpan(
                                startLine: prevLine,
                                startByteColumn: candidateStartCol,
                                endLine: reported.endLine,
                                endByteColumn: candidateEndCol
                            )
                        }
                    }
                    prevLine -= 1
                }
            }
        }

        guard reported.startLine == reported.endLine else {
            return makeSpan(
                startLine: reported.startLine,
                startByteColumn: reported.startColumn - 1 + startDeltas[0],
                endLine: reported.endLine,
                endByteColumn: reported.endColumn + endDeltas[0]
            )
        }

        if startDeltas.count == 1 {
            let delta = startDeltas[0]
            return makeSpan(
                startLine: reported.startLine,
                startByteColumn: reported.startColumn - 1 + delta,
                endLine: reported.endLine,
                endByteColumn: reported.endColumn + delta
            )
        }

        let literalUTF8 = reported.literal.utf8
        for delta in startDeltas {
            let startCol = reported.startColumn - 1 + delta
            let endCol = reported.endColumn + delta
            guard startCol >= 0, endCol > startCol,
                columns.byte(line: reported.startLine, column: endCol - 1) != nil
            else {
                continue
            }
            if !literalUTF8.isEmpty {
                guard endCol - startCol == literalUTF8.count else { continue }
                var matches = true
                var col = startCol
                for expected in literalUTF8 {
                    if columns.byte(line: reported.startLine, column: col) != expected {
                        matches = false
                        break
                    }
                    col += 1
                }
                if matches {
                    return makeSpan(
                        startLine: reported.startLine,
                        startByteColumn: startCol,
                        endLine: reported.endLine,
                        endByteColumn: endCol
                    )
                }
            } else {
                var hasWhitespace = false
                for col in startCol..<endCol {
                    guard let byte = columns.byte(line: reported.startLine, column: col) else {
                        hasWhitespace = true
                        break
                    }
                    if byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D {
                        hasWhitespace = true
                        break
                    }
                }
                if !hasWhitespace {
                    return makeSpan(
                        startLine: reported.startLine,
                        startByteColumn: startCol,
                        endLine: reported.endLine,
                        endByteColumn: endCol
                    )
                }
            }
        }

        let primaryDelta = startDeltas[0]
        return makeSpan(
            startLine: reported.startLine,
            startByteColumn: reported.startColumn - 1 + primaryDelta,
            endLine: reported.endLine,
            endByteColumn: reported.endColumn + primaryDelta
        )
    }

    func applyAstLinks(
        onLine ln: Int,
        columns: inout Styler.LineUTF8ColumnCache,
        decorations: inout [LineDecoration]
    ) {
        guard let links = astLinksByLine[ln], let rec = lineRecords[ln] else { return }
        let lineDeltas = continuationByteDeltas(forLine: ln)
        let linkAttributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: theme.linkNSColor.withAlphaComponent(rec.dimFactor),
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]
        for reported in links {
            guard
                let resolved = resolveAstLinkSpan(
                    reported,
                    currentLine: ln,
                    currentLineDeltas: lineDeltas,
                    columns: &columns
                )
            else {
                continue
            }
            if resolved.endLine > resolved.startLine {
                let joined = (resolved.startLine..<resolved.endLine).allSatisfy { line in
                    guard let record = lineRecords[line], NSMaxRange(record.contentRange) < fullLength else { return false }
                    return storage.attribute(Styler.softLineBreakAttributeKey, at: NSMaxRange(record.contentRange), effectiveRange: nil) != nil
                }
                guard joined else { continue }
            }
            let docRange = resolved.docRange
            guard !Styler.rangeContainsCodeOrMath(in: storage, range: docRange) else {
                continue
            }
            let isActive =
                resolved.startLine == ln && resolved.endLine == ln
                ? rec.isActive
                : (resolved.startLine...resolved.endLine).contains { lineRecords[$0]?.isActive ?? false }

            let firstChar = nsString.character(at: docRange.location)
            let isBracketLink =
                firstChar == 0x5B
                || (firstChar == 0x21 && docRange.length >= 2 && nsString.character(at: docRange.location + 1) == 0x5B)
            if isBracketLink {
                let spanText = nsString.substring(with: docRange)
                let isImg = firstChar == 0x21
                let openLen = isImg ? 2 : 1
                let spanNS = spanText as NSString
                var scan = openLen
                var depth = 1
                var closeBracketOffset: Int?
                while scan < spanNS.length {
                    let ch = spanNS.character(at: scan)
                    if ch == 0x5C {
                        scan += 2
                        continue
                    } else if ch == 0x5B {
                        depth += 1
                    } else if ch == 0x5D {
                        depth -= 1
                        if depth == 0 {
                            closeBracketOffset = scan
                            break
                        }
                    }
                    scan += 1
                }
                guard let closeBracket = closeBracketOffset, closeBracket >= openLen else { continue }
                if closeBracket + 1 < spanNS.length && spanNS.character(at: closeBracket + 1) == 0x28 {
                    continue
                }
                let openSyntaxRange = NSRange(location: docRange.location, length: openLen)
                let labelRange = NSRange(location: docRange.location + openLen, length: closeBracket - openLen)
                let trailingSyntaxRange = NSRange(
                    location: docRange.location + closeBracket,
                    length: docRange.length - closeBracket
                )
                if isImg && prettyMode && !isActive && !reported.url.isEmpty {
                    let startRec = lineRecords[resolved.startLine] ?? rec
                    let currentParaTail =
                        (storage.attribute(.paragraphStyle, at: startRec.lineRange.location, effectiveRange: nil) as? NSParagraphStyle)?
                        .tailIndent ?? 0.0
                    let maxMediaColumnWidth = currentParaTail > 120.0 ? max(200.0, currentParaTail - 16.0) : typography.maxColumnWidth
                    let altStr = nsString.substring(with: labelRange)
                    Styler.attachInlineMediaCard(
                        in: storage,
                        lineRange: startRec.lineRange,
                        fullRange: docRange,
                        url: reported.url,
                        alt: altStr,
                        maxColumnWidth: maxMediaColumnWidth,
                        baseDirectoryURL: baseDirectoryURL,
                        isDark: theme.isDark,
                        dimFactor: startRec.dimFactor,
                        preserveAlignmentKern: true,
                        decorations: &decorations
                    )
                } else {
                    Styler.applyAttributesToVisibleCharacters(
                        in: storage,
                        range: labelRange,
                        attributes: linkAttributes
                    )
                    Styler.styleSyntaxToken(
                        in: storage,
                        range: openSyntaxRange,
                        isActiveLine: isActive || !prettyMode,
                        theme: theme,
                        dimFactor: rec.dimFactor,
                        preserveAlignmentKern: true
                    )
                    Styler.styleSyntaxToken(
                        in: storage,
                        range: trailingSyntaxRange,
                        isActiveLine: isActive || !prettyMode,
                        theme: theme,
                        dimFactor: rec.dimFactor,
                        preserveAlignmentKern: true
                    )
                }
            } else if firstChar != 0x3C {
                Styler.applyAttributesToVisibleCharacters(
                    in: storage,
                    range: docRange,
                    attributes: linkAttributes
                )
            }
        }
    }
}

extension MarkdownLiveStyler {

    // MARK: - Inline Markdown Styling & Attribute Helpers

    static func applyFontTraitToVisibleCharacters(
        in storage: NSTextStorage,
        range: NSRange,
        trait: NSFontTraitMask,
        fallbackFont: NSFont
    ) {
        guard range.length > 0 else { return }
        storage.enumerateAttributes(in: range, options: .longestEffectiveRangeNotRequired) { attrs, subrange, _ in
            if attrs[collapsedTokenAttributeKey] != nil
                || attrs[inlineMathSpanAttributeKey] != nil
                || (attrs[.foregroundColor] as? NSColor) == NSColor.clear
            {
                return
            }
            let currentFont = (attrs[.font] as? NSFont) ?? fallbackFont
            let converted = NSFontManager.shared.convert(currentFont, toHaveTrait: trait)
            storage.addAttribute(.font, value: converted, range: subrange)
        }
    }

    static func applyAttributesToVisibleCharacters(
        in storage: NSTextStorage,
        range: NSRange,
        attributes: [NSAttributedString.Key: Any]
    ) {
        guard range.length > 0 else { return }
        storage.enumerateAttributes(in: range, options: .longestEffectiveRangeNotRequired) { attrs, subrange, _ in
            if attrs[collapsedTokenAttributeKey] != nil
                || attrs[inlineMathSpanAttributeKey] != nil
                || (attrs[.foregroundColor] as? NSColor) == NSColor.clear
            {
                return
            }
            storage.addAttributes(attributes, range: subrange)
        }
    }

    static func normalizeProseWhitespace(
        in storage: NSTextStorage,
        string: String,
        range: NSRange,
        isInCodeOrMath: (NSRange) -> Bool
    ) {
        guard range.length > 0 else { return }

        for regex in [leadingSpaceRegex, trailingSpaceRegex] {
            regex.enumerateMatches(in: string, options: [], range: range) { match, _, _ in
                guard let match, match.range.length > 0, !isInCodeOrMath(match.range) else { return }
                collapseWhitespaceRange(in: storage, range: match.range)
            }
        }

        multiSpaceRegex.enumerateMatches(in: string, options: [], range: range) { match, _, _ in
            guard let match, match.range.length >= 2, !isInCodeOrMath(match.range) else { return }
            if storage.attribute(collapsedTokenAttributeKey, at: match.range.location, effectiveRange: nil) != nil {
                return
            }
            let extraRange = NSRange(location: match.range.location + 1, length: match.range.length - 1)
            collapseWhitespaceRange(in: storage, range: extraRange)
        }
    }

    nonisolated(unsafe) static let collapsedTokenAttributes: [NSAttributedString.Key: Any] = [
        .foregroundColor: NSColor.clear,
        .backgroundColor: NSColor.clear,
        .font: NSFont.systemFont(ofSize: 0.001),
        .kern: 0.0,
        .underlineStyle: 0,
        .strikethroughStyle: 0,
        collapsedTokenAttributeKey: true,
        noSpellCheckAttributeKey: true
    ]

    static func collapseWhitespaceRange(
        in storage: NSTextStorage,
        range: NSRange,
        preserveAlignmentKern: Bool = false
    ) {
        guard range.length > 0 else { return }
        if !preserveAlignmentKern {
            storage.addAttributes(collapsedTokenAttributes, range: range)
            return
        }
        var preservedKerns: [(NSRange, CGFloat)] = []
        storage.enumerateAttributes(in: range, options: .longestEffectiveRangeNotRequired) { attrs, subrange, _ in
            if attrs[collapsedTokenAttributeKey] != nil,
                let existingKern = attrs[.kern] as? CGFloat,
                existingKern != 0
            {
                preservedKerns.append((subrange, existingKern))
            }
        }
        storage.addAttributes(collapsedTokenAttributes, range: range)
        for (subrange, kern) in preservedKerns {
            storage.addAttribute(.kern, value: kern, range: subrange)
        }
    }

    static func styleSyntaxToken(
        in storage: NSTextStorage,
        range: NSRange,
        isActiveLine: Bool,
        theme: EditorTheme,
        dimFactor: CGFloat,
        preserveAlignmentKern: Bool = false
    ) {
        guard range.length > 0 else { return }
        if isActiveLine {
            storage.addAttributes(
                [
                    .foregroundColor: theme.markdownTokenNSColor.withAlphaComponent(0.85 * dimFactor),
                    .font: theme.codeFont(size: max(11.0, theme.baseFontSize * 0.85)),
                    noSpellCheckAttributeKey: true
                ], range: range)
        } else {
            collapseWhitespaceRange(in: storage, range: range, preserveAlignmentKern: preserveAlignmentKern)
        }
    }

    static func highlightLaTeXSource(
        in storage: NSTextStorage,
        range: NSRange,
        theme: EditorTheme,
        dimFactor: CGFloat
    ) {
        guard range.length > 0 else { return }
        storage.addAttribute(noSpellCheckAttributeKey, value: true, range: range)
        let string = storage.string
        latexCommandRegex.enumerateMatches(in: string, options: [], range: range) { match, _, _ in
            if let matchRange = match?.range {
                storage.addAttribute(.foregroundColor, value: theme.linkNSColor.withAlphaComponent(dimFactor), range: matchRange)
            }
        }
        latexBracesRegex.enumerateMatches(in: string, options: [], range: range) { match, _, _ in
            if let matchRange = match?.range {
                storage.addAttribute(.foregroundColor, value: theme.inlineCodeNSColor.withAlphaComponent(dimFactor), range: matchRange)
            }
        }
    }

    static func rangeContainsCodeOrMath(in storage: NSTextStorage, range: NSRange) -> Bool {
        guard range.length > 0, NSMaxRange(range) <= storage.length else { return false }
        var found = false
        storage.enumerateAttributes(in: range, options: .longestEffectiveRangeNotRequired) { attrs, _, stop in
            if attrs[inlineCodeFontAttributeKey] != nil
                || attrs[inlineMathLatexAttributeKey] != nil
                || attrs[inlineMathSpanAttributeKey] != nil
            {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    static func sortedRangesOverlap(_ ranges: [NSRange], _ target: NSRange) -> Bool {
        guard !ranges.isEmpty, target.length > 0 else { return false }
        let targetEnd = target.location + target.length
        var low = 0
        var high = ranges.count
        while low < high {
            let mid = (low + high) >> 1
            let candidate = ranges[mid]
            if candidate.location + candidate.length <= target.location {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low < ranges.count && ranges[low].location < targetEnd
    }

    static func insertSortedRange(_ range: NSRange, into ranges: inout [NSRange]) {
        guard range.length > 0 else { return }
        if let last = ranges.last, last.location <= range.location {
            ranges.append(range)
            return
        }
        var low = 0
        var high = ranges.count
        while low < high {
            let mid = (low + high) >> 1
            if ranges[mid].location < range.location {
                low = mid + 1
            } else {
                high = mid
            }
        }
        ranges.insert(range, at: low)
    }

    static func reserveMediaCardHeight(in storage: NSTextStorage, lineRange: NSRange, targetHeight: CGFloat) {
        guard lineRange.length > 0, lineRange.location < storage.length else { return }
        let currentPara = storage.attribute(.paragraphStyle, at: lineRange.location, effectiveRange: nil) as? NSParagraphStyle
        let mutablePara = (currentPara?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        mutablePara.minimumLineHeight = max(mutablePara.minimumLineHeight, targetHeight)
        mutablePara.maximumLineHeight = max(mutablePara.maximumLineHeight, targetHeight)
        storage.addAttribute(.paragraphStyle, value: mutablePara, range: lineRange)
    }

    static func attachInlineMediaCard(
        in storage: NSTextStorage,
        lineRange: NSRange,
        fullRange: NSRange,
        url: String,
        alt: String,
        explicitWidth: CGFloat? = nil,
        explicitHeight: CGFloat? = nil,
        maxColumnWidth: CGFloat,
        placeholderHeight: CGFloat = 52.0,
        baseDirectoryURL: URL?,
        isDark: Bool,
        dimFactor: CGFloat,
        preserveAlignmentKern: Bool = false,
        decorations: inout [LineDecoration]
    ) {
        let display = FolioMediaImageCache.shared.displaySize(
            for: url,
            explicitWidth: explicitWidth,
            explicitHeight: explicitHeight,
            maxColumnWidth: maxColumnWidth,
            baseDirectoryURL: baseDirectoryURL,
            isDark: isDark
        )
        let targetHeight = display.isLoaded ? max(26.0, display.size.height + 10.0) : placeholderHeight
        reserveMediaCardHeight(in: storage, lineRange: lineRange, targetHeight: targetHeight)
        collapseWhitespaceRange(in: storage, range: fullRange, preserveAlignmentKern: preserveAlignmentKern)
        decorations.append(
            LineDecoration(
                lineRange: lineRange,
                kind: .imageRendered(
                    url: url,
                    alt: alt,
                    fullRange: fullRange,
                    explicitWidth: explicitWidth,
                    explicitHeight: explicitHeight,
                    baseDirectoryURL: baseDirectoryURL,
                    dimFactor: dimFactor
                )
            ))
    }

    static func parseHTMLMediaAttributes(attrsStr: String) -> (src: String, alt: String, width: CGFloat?, height: CGFloat?) {
        let attrsNS = attrsStr as NSString
        var src = ""
        var alt = ""
        var widthVal: CGFloat?
        var heightVal: CGFloat?

        htmlAttrRegex.enumerateMatches(in: attrsStr, options: [], range: NSRange(location: 0, length: attrsNS.length)) { attrMatch, _, _ in
            guard let attrMatch else { return }
            let name = attrsNS.substring(with: attrMatch.range(at: 1)).lowercased()
            let valRange: NSRange
            if attrMatch.range(at: 2).location != NSNotFound {
                valRange = attrMatch.range(at: 2)
            } else if attrMatch.range(at: 3).location != NSNotFound {
                valRange = attrMatch.range(at: 3)
            } else if attrMatch.range(at: 4).location != NSNotFound {
                valRange = attrMatch.range(at: 4)
            } else {
                return
            }
            let val = attrsNS.substring(with: valRange)
            switch name {
            case "src":
                src = val.replacingOccurrences(of: "&amp;", with: "&")
            case "alt", "title", "poster":
                if alt.isEmpty || name == "alt" { alt = val }
            case "width":
                let numStr = val.replacingOccurrences(of: "px", with: "")
                if let parsed = Double(numStr), parsed > 0 { widthVal = CGFloat(parsed) }
            case "height":
                let numStr = val.replacingOccurrences(of: "px", with: "")
                if let parsed = Double(numStr), parsed > 0 { heightVal = CGFloat(parsed) }
            default:
                break
            }
        }
        return (src, alt, widthVal, heightVal)
    }

    static func styleInlineMarkdown(
        in storage: NSTextStorage,
        string: String,
        range: NSRange,
        lineRange: NSRange? = nil,
        baseFont: NSFont,
        isActiveLine: Bool,
        theme: EditorTheme,
        dimFactor: CGFloat,
        normalizeWhitespace: Bool = false,
        prettyMode: Bool = true,
        baseDirectoryURL: URL? = nil,
        decorations: inout [LineDecoration]
    ) {
        guard range.length > 0 else { return }
        let nsString = string as NSString
        let fontSize = baseFont.pointSize
        let effectiveLineRange = lineRange ?? range

        var codeAndMathRanges: [NSRange] = []
        var protectedDelimiterRanges: [NSRange] = []

        let isInCodeOrMath: (NSRange) -> Bool = { candidate in
            sortedRangesOverlap(codeAndMathRanges, candidate)
        }
        let isDelimiterProtected: (NSRange) -> Bool = { candidate in
            sortedRangesOverlap(codeAndMathRanges, candidate) || sortedRangesOverlap(protectedDelimiterRanges, candidate)
        }

        // 1. Inline Code (`code` or `` ` ``)
        let codeSpans = scanInlineCodeSpans(nsString: nsString, range: range)
        if !codeSpans.isEmpty {
            let codeFontSize = fontSize * 0.88
            let codeFont = theme.codeFont(size: codeFontSize)
            let inlineCodeAttrs: [NSAttributedString.Key: Any] = [
                .font: codeFont,
                .foregroundColor: theme.inlineCodeNSColor.withAlphaComponent(dimFactor),
                inlineCodeFontAttributeKey: true,
                noSpellCheckAttributeKey: true
            ]
            for codeSpan in codeSpans {
                let fullMatchRange = codeSpan.fullRange
                insertSortedRange(fullMatchRange, into: &codeAndMathRanges)
                storage.addAttribute(noSpellCheckAttributeKey, value: true, range: fullMatchRange)

                var openRange = codeSpan.openRange
                var innerRange = codeSpan.innerRange
                var closeRange = codeSpan.closeRange

                if innerRange.length >= 2 {
                    let firstChar = nsString.character(at: innerRange.location)
                    let lastChar = nsString.character(at: NSMaxRange(innerRange) - 1)
                    let innerSub = nsString.substring(with: innerRange)
                    if firstChar == 32 && lastChar == 32 && innerSub.contains(where: { $0 != " " }) {
                        openRange.length += 1
                        innerRange.location += 1
                        innerRange.length -= 2
                        closeRange.location -= 1
                        closeRange.length += 1
                    }
                }

                storage.addAttributes(inlineCodeAttrs, range: innerRange)
                decorations.append(
                    LineDecoration(
                        lineRange: innerRange,
                        kind: .inlineCode(range: innerRange, fontSize: codeFontSize, dimFactor: dimFactor)
                    ))
                styleSyntaxToken(in: storage, range: openRange, isActiveLine: isActiveLine, theme: theme, dimFactor: dimFactor)
                styleSyntaxToken(in: storage, range: closeRange, isActiveLine: isActiveLine, theme: theme, dimFactor: dimFactor)
            }
        }

        // 2. Inline Math ($E = mc^2$); `$` inside link destinations (e.g. CloudWatch `$3F`) is literal
        let linkDestinationRanges =
            nsString.range(of: "$", options: .literal, range: range).location == NSNotFound
            ? [] : scanMarkdownLinks(nsString: nsString, range: range, isDelimiterProtected: isInCodeOrMath).map(\.trailingSyntaxRange)
        inlineMathRegex.enumerateMatches(in: string, options: [], range: range) { match, _, _ in
            guard let match else { return }
            let fullMatchRange = match.range(at: 0)
            if isInCodeOrMath(fullMatchRange) || linkDestinationRanges.contains(where: { NSIntersectionRange($0, fullMatchRange).length > 0 }) {
                return
            }
            insertSortedRange(fullMatchRange, into: &codeAndMathRanges)

            let openRange = match.range(at: 1)
            let innerRange = match.range(at: 2)
            let closeRange = match.range(at: 3)
            let latexStr = nsString.substring(with: innerRange)
            storage.addAttributes(
                [
                    noSpellCheckAttributeKey: true,
                    inlineMathLatexAttributeKey: true
                ], range: fullMatchRange)

            if isActiveLine {
                let mathMono = theme.codeFont(size: fontSize * 0.90)
                storage.addAttributes(
                    [
                        .font: mathMono,
                        .foregroundColor: theme.textNSColor.withAlphaComponent(dimFactor),
                        .backgroundColor: theme.codeBackgroundNSColor.withAlphaComponent(0.55 * dimFactor),
                        noSpellCheckAttributeKey: true
                    ], range: innerRange)
                highlightLaTeXSource(in: storage, range: innerRange, theme: theme, dimFactor: dimFactor)
                styleSyntaxToken(in: storage, range: openRange, isActiveLine: true, theme: theme, dimFactor: dimFactor)
                styleSyntaxToken(in: storage, range: closeRange, isActiveLine: true, theme: theme, dimFactor: dimFactor)
            } else {
                let mathBox = LaTeXMathRenderer.layoutLatex(latexStr, baseFontSize: fontSize, isDisplayStyle: false)
                let targetWidth = max(4.0, mathBox.width + 2.0)
                let tinyFont = NSFont.monospacedSystemFont(ofSize: 0.01, weight: .regular)
                let rawSubstr = nsString.substring(with: fullMatchRange) as NSString
                let baseWidth = rawSubstr.size(withAttributes: [.font: tinyFont]).width
                let firstCharKern = max(0.0, targetWidth - baseWidth)
                let spanInfo = InlineMathLayoutInfo(
                    range: fullMatchRange,
                    width: targetWidth,
                    ascent: mathBox.ascent,
                    descent: mathBox.descent
                )

                storage.addAttributes(
                    [
                        .font: tinyFont,
                        .foregroundColor: NSColor.clear,
                        .kern: 0.0,
                        inlineMathSpanAttributeKey: spanInfo,
                        inlineMathLatexAttributeKey: true,
                        noSpellCheckAttributeKey: true
                    ], range: fullMatchRange)
                storage.addAttribute(
                    .kern,
                    value: firstCharKern,
                    range: NSRange(location: fullMatchRange.location, length: 1)
                )

                decorations.append(
                    LineDecoration(
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

        // 3. Backslash escapes (\*, \_, \|, \[, etc.) outside inline code/math
        escapeRegex.enumerateMatches(in: string, options: [], range: range) { match, _, _ in
            guard let match, !isInCodeOrMath(match.range) else { return }
            let slashRange = NSRange(location: match.range.location, length: 1)
            insertSortedRange(match.range, into: &protectedDelimiterRanges)
            styleSyntaxToken(in: storage, range: slashRange, isActiveLine: isActiveLine, theme: theme, dimFactor: dimFactor)
        }

        // 4. HTML <br/> tags outside inline code/math
        htmlBrRegex.enumerateMatches(in: string, options: [], range: range) { match, _, _ in
            guard let match, !isInCodeOrMath(match.range) else { return }
            insertSortedRange(match.range, into: &protectedDelimiterRanges)
            styleSyntaxToken(in: storage, range: match.range, isActiveLine: isActiveLine || !prettyMode, theme: theme, dimFactor: dimFactor)
            if !isActiveLine && prettyMode && match.range.length > 0 {
                storage.addAttribute(.kern, value: 6.0, range: NSRange(location: match.range.location, length: 1))
            }
        }

        let currentParaTail = (storage.attribute(.paragraphStyle, at: effectiveLineRange.location, effectiveRange: nil) as? NSParagraphStyle)?.tailIndent ?? 0.0
        let maxMediaColumnWidth = currentParaTail > 120.0 ? max(200.0, currentParaTail - 16.0) : 660.0

        // 5. Links ([label](url)), Images (![alt](url)), and Anchor Images ([![alt](img_url)](link_url))
        let linkMatches = scanMarkdownLinks(nsString: nsString, range: range, isDelimiterProtected: isDelimiterProtected)
        for link in linkMatches {
            if link.isImage && prettyMode && !isActiveLine && !link.url.isEmpty {
                insertSortedRange(link.fullRange, into: &protectedDelimiterRanges)
                let altStr = nsString.substring(with: link.labelRange)
                attachInlineMediaCard(
                    in: storage,
                    lineRange: effectiveLineRange,
                    fullRange: link.fullRange,
                    url: link.url,
                    alt: altStr,
                    maxColumnWidth: maxMediaColumnWidth,
                    baseDirectoryURL: baseDirectoryURL,
                    isDark: theme.isDark,
                    dimFactor: dimFactor,
                    decorations: &decorations
                )
            } else {
                insertSortedRange(link.openSyntaxRange, into: &protectedDelimiterRanges)
                insertSortedRange(link.trailingSyntaxRange, into: &protectedDelimiterRanges)

                applyAttributesToVisibleCharacters(
                    in: storage,
                    range: link.labelRange,
                    attributes: [
                        .foregroundColor: theme.linkNSColor.withAlphaComponent(dimFactor),
                        .underlineStyle: NSUnderlineStyle.single.rawValue
                    ]
                )
                let showTokens = isActiveLine || (link.isImage && !prettyMode)
                styleSyntaxToken(in: storage, range: link.openSyntaxRange, isActiveLine: showTokens, theme: theme, dimFactor: dimFactor)
                styleSyntaxToken(in: storage, range: link.trailingSyntaxRange, isActiveLine: showTokens, theme: theme, dimFactor: dimFactor)
            }
        }

        // 5b-11. Autolinks, HTML tags, Emphasis, Strikethrough, Highlight, and Whitespace Normalization
        styleInlineHTMLAndEmphasis(
            in: storage,
            string: string,
            nsString: nsString,
            range: range,
            effectiveLineRange: effectiveLineRange,
            baseFont: baseFont,
            fontSize: fontSize,
            maxMediaColumnWidth: maxMediaColumnWidth,
            isActiveLine: isActiveLine,
            theme: theme,
            dimFactor: dimFactor,
            normalizeWhitespace: normalizeWhitespace,
            prettyMode: prettyMode,
            baseDirectoryURL: baseDirectoryURL,
            codeAndMathRanges: codeAndMathRanges,
            protectedDelimiterRanges: &protectedDelimiterRanges,
            decorations: &decorations
        )
    }

    private static func styleInlineHTMLAndEmphasis(
        in storage: NSTextStorage,
        string: String,
        nsString: NSString,
        range: NSRange,
        effectiveLineRange: NSRange,
        baseFont: NSFont,
        fontSize: CGFloat,
        maxMediaColumnWidth: CGFloat,
        isActiveLine: Bool,
        theme: EditorTheme,
        dimFactor: CGFloat,
        normalizeWhitespace: Bool,
        prettyMode: Bool,
        baseDirectoryURL: URL?,
        codeAndMathRanges: [NSRange],
        protectedDelimiterRanges: inout [NSRange],
        decorations: inout [LineDecoration]
    ) {
        func isInCodeOrMath(_ candidate: NSRange) -> Bool {
            sortedRangesOverlap(codeAndMathRanges, candidate)
        }
        func isDelimiterProtected(_ candidate: NSRange) -> Bool {
            sortedRangesOverlap(codeAndMathRanges, candidate) || sortedRangesOverlap(protectedDelimiterRanges, candidate)
        }

        // 5b. Autolinks (<https://...> or <user@example.com>)
        autolinkRegex.enumerateMatches(in: string, options: [], range: range) { match, _, _ in
            guard let match, !isDelimiterProtected(match.range) else { return }
            let openAngle = match.range(at: 1)
            let urlRange = match.range(at: 2)
            let closeAngle = match.range(at: 3)
            insertSortedRange(match.range, into: &protectedDelimiterRanges)

            applyAttributesToVisibleCharacters(
                in: storage,
                range: urlRange,
                attributes: [
                    .foregroundColor: theme.linkNSColor.withAlphaComponent(dimFactor),
                    .underlineStyle: NSUnderlineStyle.single.rawValue
                ]
            )
            styleSyntaxToken(in: storage, range: openAngle, isActiveLine: isActiveLine, theme: theme, dimFactor: dimFactor)
            styleSyntaxToken(in: storage, range: closeAngle, isActiveLine: isActiveLine, theme: theme, dimFactor: dimFactor)
        }

        // 5c. HTML <img ...> and <video ...> tags
        for mediaRegex in [htmlImgTagRegex, htmlVideoTagRegex] {
            mediaRegex.enumerateMatches(in: string, options: [], range: range) { match, _, _ in
                guard let match, !isDelimiterProtected(match.range) else { return }
                insertSortedRange(match.range, into: &protectedDelimiterRanges)

                let attrsStr = nsString.substring(with: match.range(at: 1))
                var (src, alt, widthVal, heightVal) = parseHTMLMediaAttributes(attrsStr: attrsStr)
                if src.isEmpty && match.numberOfRanges > 2 && match.range(at: 2).location != NSNotFound {
                    let innerStr = nsString.substring(with: match.range(at: 2))
                    let innerParsed = parseHTMLMediaAttributes(attrsStr: innerStr)
                    if !innerParsed.src.isEmpty {
                        src = innerParsed.src
                    }
                }

                if prettyMode && !isActiveLine && !src.isEmpty {
                    let isVideo = FolioMediaImageCache.isVideoURL(src) || (mediaRegex === htmlVideoTagRegex)
                    attachInlineMediaCard(
                        in: storage,
                        lineRange: effectiveLineRange,
                        fullRange: match.range,
                        url: src,
                        alt: alt,
                        explicitWidth: widthVal,
                        explicitHeight: heightVal,
                        maxColumnWidth: maxMediaColumnWidth,
                        placeholderHeight: isVideo ? 56.0 : 52.0,
                        baseDirectoryURL: baseDirectoryURL,
                        isDark: theme.isDark,
                        dimFactor: dimFactor,
                        decorations: &decorations
                    )
                } else {
                    styleSyntaxToken(in: storage, range: match.range, isActiveLine: true, theme: theme, dimFactor: dimFactor)
                }
            }
        }

        // 5d. Inline HTML paired markup (<kbd>, <u>, <ins>, <mark>, <sup>, <sub>, <b>, <strong>, <i>, <em>, <s>, <del>, <code>, <summary>)
        htmlPairedTagRegex.enumerateMatches(in: string, options: [], range: range) { match, _, _ in
            guard let match else { return }
            let openTagRange = match.range(at: 1)
            let tagNameRange = match.range(at: 2)
            let innerRange = match.range(at: 3)
            let closeTagRange = match.range(at: 4)
            guard !isDelimiterProtected(openTagRange), !isDelimiterProtected(closeTagRange) else { return }

            insertSortedRange(openTagRange, into: &protectedDelimiterRanges)
            insertSortedRange(closeTagRange, into: &protectedDelimiterRanges)

            let tagName = nsString.substring(with: tagNameRange).lowercased()
            let showRawTag = isActiveLine || !prettyMode

            if prettyMode && innerRange.length > 0 {
                switch tagName {
                case "kbd":
                    let kbdFontSize = fontSize * 0.84
                    let kbdFont = theme.codeFont(size: kbdFontSize)
                    applyAttributesToVisibleCharacters(
                        in: storage,
                        range: innerRange,
                        attributes: [
                            .font: kbdFont,
                            .foregroundColor: theme.textNSColor.withAlphaComponent(dimFactor),
                            inlineCodeFontAttributeKey: true
                        ]
                    )
                    decorations.append(
                        LineDecoration(
                            lineRange: innerRange,
                            kind: .kbdPill(range: innerRange, fontSize: kbdFontSize, dimFactor: dimFactor)
                        ))
                case "u", "ins":
                    applyAttributesToVisibleCharacters(
                        in: storage,
                        range: innerRange,
                        attributes: [.underlineStyle: NSUnderlineStyle.single.rawValue]
                    )
                case "mark":
                    let highlightBg =
                        theme.isDark
                        ? NSColor(srgbRed: 0.55, green: 0.45, blue: 0.12, alpha: 0.55 * dimFactor)
                        : NSColor(srgbRed: 1.0, green: 0.93, blue: 0.45, alpha: 0.65 * dimFactor)
                    applyAttributesToVisibleCharacters(
                        in: storage,
                        range: innerRange,
                        attributes: [.backgroundColor: highlightBg]
                    )
                case "sup":
                    let subFont = theme.bodyFont(size: fontSize * 0.74)
                    applyAttributesToVisibleCharacters(
                        in: storage,
                        range: innerRange,
                        attributes: [
                            .font: subFont,
                            .baselineOffset: fontSize * 0.32
                        ]
                    )
                case "sub":
                    let subFont = theme.bodyFont(size: fontSize * 0.74)
                    applyAttributesToVisibleCharacters(
                        in: storage,
                        range: innerRange,
                        attributes: [
                            .font: subFont,
                            .baselineOffset: -fontSize * 0.18
                        ]
                    )
                case "b", "strong", "summary":
                    applyFontTraitToVisibleCharacters(in: storage, range: innerRange, trait: .boldFontMask, fallbackFont: baseFont)
                case "i", "em":
                    applyFontTraitToVisibleCharacters(in: storage, range: innerRange, trait: .italicFontMask, fallbackFont: baseFont)
                case "s", "del", "strike":
                    applyAttributesToVisibleCharacters(
                        in: storage,
                        range: innerRange,
                        attributes: [
                            .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                            .foregroundColor: theme.secondaryTextNSColor.withAlphaComponent(dimFactor)
                        ]
                    )
                case "code":
                    let codeFontSize = fontSize * 0.88
                    let codeFont = theme.codeFont(size: codeFontSize)
                    applyAttributesToVisibleCharacters(
                        in: storage,
                        range: innerRange,
                        attributes: [
                            .font: codeFont,
                            .foregroundColor: theme.inlineCodeNSColor.withAlphaComponent(dimFactor),
                            inlineCodeFontAttributeKey: true
                        ]
                    )
                    decorations.append(
                        LineDecoration(
                            lineRange: innerRange,
                            kind: .inlineCode(range: innerRange, fontSize: codeFontSize, dimFactor: dimFactor)
                        ))
                default:
                    break
                }
            }

            styleSyntaxToken(in: storage, range: openTagRange, isActiveLine: showRawTag, theme: theme, dimFactor: dimFactor)
            styleSyntaxToken(in: storage, range: closeTagRange, isActiveLine: showRawTag, theme: theme, dimFactor: dimFactor)
        }

        // 5e. HTML <details> and </details> tags
        htmlDetailsTagRegex.enumerateMatches(in: string, options: [], range: range) { match, _, _ in
            guard let match, !isDelimiterProtected(match.range) else { return }
            insertSortedRange(match.range, into: &protectedDelimiterRanges)
            styleSyntaxToken(in: storage, range: match.range, isActiveLine: isActiveLine || !prettyMode, theme: theme, dimFactor: dimFactor)
        }

        // 6. Bold + Italic (***text*** or ___text___)
        boldItalicRegex.enumerateMatches(in: string, options: [], range: range) { match, _, _ in
            guard let match else { return }
            let innerRange = match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range(at: 2)
            guard innerRange.location != NSNotFound else { return }
            let openRange = NSRange(location: match.range.location, length: 3)
            let closeRange = NSRange(location: NSMaxRange(innerRange), length: 3)
            guard !isDelimiterProtected(openRange), !isDelimiterProtected(closeRange) else { return }

            insertSortedRange(openRange, into: &protectedDelimiterRanges)
            insertSortedRange(closeRange, into: &protectedDelimiterRanges)
            applyFontTraitToVisibleCharacters(in: storage, range: innerRange, trait: [.boldFontMask, .italicFontMask], fallbackFont: baseFont)
            styleSyntaxToken(in: storage, range: openRange, isActiveLine: isActiveLine, theme: theme, dimFactor: dimFactor)
            styleSyntaxToken(in: storage, range: closeRange, isActiveLine: isActiveLine, theme: theme, dimFactor: dimFactor)
        }

        // 7. Bold (**text** or __text__)
        for regex in [boldAsteriskRegex, boldUnderscoreRegex] {
            regex.enumerateMatches(in: string, options: [], range: range) { match, _, _ in
                guard let match else { return }
                let innerRange = match.range(at: 1)
                let openRange = NSRange(location: match.range.location, length: 2)
                let closeRange = NSRange(location: NSMaxRange(innerRange), length: 2)
                guard !isDelimiterProtected(openRange), !isDelimiterProtected(closeRange) else { return }

                insertSortedRange(openRange, into: &protectedDelimiterRanges)
                insertSortedRange(closeRange, into: &protectedDelimiterRanges)
                applyFontTraitToVisibleCharacters(in: storage, range: innerRange, trait: .boldFontMask, fallbackFont: baseFont)
                styleSyntaxToken(in: storage, range: openRange, isActiveLine: isActiveLine, theme: theme, dimFactor: dimFactor)
                styleSyntaxToken(in: storage, range: closeRange, isActiveLine: isActiveLine, theme: theme, dimFactor: dimFactor)
            }
        }

        // 8. Italic (*text* or _text_)
        for regex in [italicAsteriskRegex, italicUnderscoreRegex] {
            regex.enumerateMatches(in: string, options: [], range: range) { match, _, _ in
                guard let match else { return }
                let innerRange = match.range(at: 1)
                let openRange = NSRange(location: match.range.location, length: 1)
                let closeRange = NSRange(location: NSMaxRange(innerRange), length: 1)
                guard !isDelimiterProtected(openRange), !isDelimiterProtected(closeRange) else { return }

                insertSortedRange(openRange, into: &protectedDelimiterRanges)
                insertSortedRange(closeRange, into: &protectedDelimiterRanges)
                applyFontTraitToVisibleCharacters(in: storage, range: innerRange, trait: .italicFontMask, fallbackFont: baseFont)
                styleSyntaxToken(in: storage, range: openRange, isActiveLine: isActiveLine, theme: theme, dimFactor: dimFactor)
                styleSyntaxToken(in: storage, range: closeRange, isActiveLine: isActiveLine, theme: theme, dimFactor: dimFactor)
            }
        }

        // 9. Strikethrough (~~text~~)
        strikeRegex.enumerateMatches(in: string, options: [], range: range) { match, _, _ in
            guard let match else { return }
            let openRange = match.range(at: 1)
            let innerRange = match.range(at: 2)
            let closeRange = match.range(at: 3)
            guard !isDelimiterProtected(openRange), !isDelimiterProtected(closeRange) else { return }

            insertSortedRange(openRange, into: &protectedDelimiterRanges)
            insertSortedRange(closeRange, into: &protectedDelimiterRanges)
            applyAttributesToVisibleCharacters(
                in: storage,
                range: innerRange,
                attributes: [
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    .foregroundColor: theme.secondaryTextNSColor.withAlphaComponent(dimFactor)
                ]
            )
            styleSyntaxToken(in: storage, range: openRange, isActiveLine: isActiveLine, theme: theme, dimFactor: dimFactor)
            styleSyntaxToken(in: storage, range: closeRange, isActiveLine: isActiveLine, theme: theme, dimFactor: dimFactor)
        }

        // 10. Highlight (==text==)
        highlightRegex.enumerateMatches(in: string, options: [], range: range) { match, _, _ in
            guard let match else { return }
            let openRange = match.range(at: 1)
            let innerRange = match.range(at: 2)
            let closeRange = match.range(at: 3)
            guard !isDelimiterProtected(openRange), !isDelimiterProtected(closeRange) else { return }

            insertSortedRange(openRange, into: &protectedDelimiterRanges)
            insertSortedRange(closeRange, into: &protectedDelimiterRanges)
            let highlightBg =
                theme.isDark
                ? NSColor(srgbRed: 0.55, green: 0.45, blue: 0.12, alpha: 0.55 * dimFactor)
                : NSColor(srgbRed: 1.0, green: 0.93, blue: 0.45, alpha: 0.65 * dimFactor)
            applyAttributesToVisibleCharacters(
                in: storage,
                range: innerRange,
                attributes: [.backgroundColor: highlightBg]
            )
            styleSyntaxToken(in: storage, range: openRange, isActiveLine: isActiveLine, theme: theme, dimFactor: dimFactor)
            styleSyntaxToken(in: storage, range: closeRange, isActiveLine: isActiveLine, theme: theme, dimFactor: dimFactor)
        }

        // 11. CommonMark Whitespace Normalization on inactive lines (outside inline code & math)
        if normalizeWhitespace && !isActiveLine {
            normalizeProseWhitespace(
                in: storage,
                string: string,
                range: range,
                isInCodeOrMath: isInCodeOrMath
            )
        }
    }

    // MARK: - Line Range & AST Column Helpers

    static func canJoinProseLines(_ current: ProseLineKind?, _ next: ProseLineKind?) -> Bool {
        switch (current, next) {
        case (.paragraph?, .paragraph?), (.listItem?, .paragraph?):
            return true
        case let (.blockquote(left)?, .blockquote(right)?):
            return left == right
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
        NSIntersectionRange(lineRange, activeLineRange).length > 0
            || (selectedRange.location == lineRange.location + lineRange.length && lineRange.location == activeLineRange.location)
    }

    static func indentationColumnCount(nsString: NSString, range: NSRange) -> Int {
        var cols = 0
        let end = NSMaxRange(range)
        var idx = range.location
        while idx < end {
            let ch = nsString.character(at: idx)
            if ch == 9 {
                cols += 4 - (cols % 4)
            } else if ch == 32 {
                cols += 1
            }
            idx += 1
        }
        return cols
    }
}
