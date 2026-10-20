import AppKit
import Foundation

extension MarkdownLiveStyler {

    static func styleInlineHTMLAndEmphasis(
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
        func isInCodeOrMath(_ r: NSRange) -> Bool {
            sortedRangesOverlap(codeAndMathRanges, r)
        }
        func isDelimiterProtected(_ r: NSRange) -> Bool {
            sortedRangesOverlap(codeAndMathRanges, r) || sortedRangesOverlap(protectedDelimiterRanges, r)
        }

        // 5b. Autolinks (<https://...> or <user@example.com>)
        autolinkRegex.enumerateMatches(in: string, options: [], range: range) { match, _, _ in
            guard let match = match, !isDelimiterProtected(match.range) else { return }
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
                guard let match = match, !isDelimiterProtected(match.range) else { return }
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
                    let display = FolioMediaImageCache.shared.displaySize(
                        for: src,
                        explicitWidth: widthVal,
                        explicitHeight: heightVal,
                        maxColumnWidth: maxMediaColumnWidth,
                        baseDirectoryURL: baseDirectoryURL,
                        isDark: theme.isDark
                    )
                    let targetH: CGFloat
                    if display.isLoaded {
                        targetH = max(26.0, display.size.height + 10.0)
                    } else if isVideo {
                        targetH = 56.0
                    } else {
                        targetH = 52.0
                    }
                    reserveMediaCardHeight(in: storage, lineRange: effectiveLineRange, targetHeight: targetH)
                    collapseWhitespaceRange(in: storage, range: match.range)
                    decorations.append(LineDecoration(
                        lineRange: effectiveLineRange,
                        kind: .imageRendered(
                            url: src,
                            alt: alt,
                            fullRange: match.range,
                            explicitWidth: widthVal,
                            explicitHeight: heightVal,
                            baseDirectoryURL: baseDirectoryURL,
                            dimFactor: dimFactor
                        )
                    ))
                } else {
                    styleSyntaxToken(in: storage, range: match.range, isActiveLine: true, theme: theme, dimFactor: dimFactor)
                }
            }
        }

        // 5d. Inline HTML paired markup (<kbd>, <u>, <ins>, <mark>, <sup>, <sub>, <b>, <strong>, <i>, <em>, <s>, <del>, <code>, <summary>)
        htmlPairedTagRegex.enumerateMatches(in: string, options: [], range: range) { match, _, _ in
            guard let match = match else { return }
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
                    decorations.append(LineDecoration(
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
                    let highlightBg = theme.isDark
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
                    decorations.append(LineDecoration(
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
            guard let match = match, !isDelimiterProtected(match.range) else { return }
            insertSortedRange(match.range, into: &protectedDelimiterRanges)
            styleSyntaxToken(in: storage, range: match.range, isActiveLine: isActiveLine || !prettyMode, theme: theme, dimFactor: dimFactor)
        }

        // 6. Bold + Italic (***text*** or ___text___)
        boldItalicRegex.enumerateMatches(in: string, options: [], range: range) { match, _, _ in
            guard let match = match else { return }
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
                guard let match = match else { return }
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
                guard let match = match else { return }
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
            guard let match = match else { return }
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
            guard let match = match else { return }
            let openRange = match.range(at: 1)
            let innerRange = match.range(at: 2)
            let closeRange = match.range(at: 3)
            guard !isDelimiterProtected(openRange), !isDelimiterProtected(closeRange) else { return }

            insertSortedRange(openRange, into: &protectedDelimiterRanges)
            insertSortedRange(closeRange, into: &protectedDelimiterRanges)
            let highlightBg = theme.isDark
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
}
