import AppKit
import Foundation

extension MarkdownLiveStyler {

    // MARK: - Inline Markdown Styling

    static func sortedRangesOverlap(_ ranges: [NSRange], _ target: NSRange) -> Bool {
        guard !ranges.isEmpty, target.length > 0 else { return false }
        let targetEnd = target.location + target.length
        var low = 0
        var high = ranges.count
        while low < high {
            let mid = (low + high) >> 1
            let r = ranges[mid]
            if r.location + r.length <= target.location {
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
        let currentPara = (storage.attribute(.paragraphStyle, at: lineRange.location, effectiveRange: nil) as? NSParagraphStyle)
        let mutablePara = (currentPara?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        mutablePara.minimumLineHeight = max(mutablePara.minimumLineHeight, targetHeight)
        mutablePara.maximumLineHeight = max(mutablePara.maximumLineHeight, targetHeight)
        storage.addAttribute(.paragraphStyle, value: mutablePara, range: lineRange)
    }

    static func parseHTMLMediaAttributes(attrsStr: String) -> (src: String, alt: String, width: CGFloat?, height: CGFloat?) {
        let attrsNS = attrsStr as NSString
        var src = ""
        var alt = ""
        var widthVal: CGFloat? = nil
        var heightVal: CGFloat? = nil

        htmlAttrRegex.enumerateMatches(in: attrsStr, options: [], range: NSRange(location: 0, length: attrsNS.length)) { attrMatch, _, _ in
            guard let attrMatch = attrMatch else { return }
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
                src = val
            case "alt", "title", "poster":
                if alt.isEmpty || name == "alt" { alt = val }
            case "width":
                let numStr = val.replacingOccurrences(of: "px", with: "")
                if let d = Double(numStr), d > 0 { widthVal = CGFloat(d) }
            case "height":
                let numStr = val.replacingOccurrences(of: "px", with: "")
                if let d = Double(numStr), d > 0 { heightVal = CGFloat(d) }
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

        // Ranges inside inline code or inline math are completely opaque to other inline syntax
        var codeAndMathRanges: [NSRange] = []
        // Ranges of escaped characters or link URL destinations `(url)` cannot act as emphasis delimiters
        var protectedDelimiterRanges: [NSRange] = []

        let isInCodeOrMath: (NSRange) -> Bool = { r in
            sortedRangesOverlap(codeAndMathRanges, r)
        }
        let isDelimiterProtected: (NSRange) -> Bool = { r in
            sortedRangesOverlap(codeAndMathRanges, r) || sortedRangesOverlap(protectedDelimiterRanges, r)
        }

        // 1. Inline Code (`code` or `` ` ``) - highest precedence in CommonMark (even `\` inside code is literal)
        let codeSpans = scanInlineCodeSpans(nsString: nsString, range: range)
        if !codeSpans.isEmpty {
            let codeFontSize = fontSize * 0.88
            let codeFont = theme.codeFont(size: codeFontSize)
            let inlineCodeAttrs: [NSAttributedString.Key: Any] = [
                .font: codeFont,
                .foregroundColor: theme.inlineCodeNSColor.withAlphaComponent(dimFactor),
                inlineCodeFontAttributeKey: true
            ]
            for codeSpan in codeSpans {
                let fullMatchRange = codeSpan.fullRange
                insertSortedRange(fullMatchRange, into: &codeAndMathRanges)

                var openRange = codeSpan.openRange
                var innerRange = codeSpan.innerRange
                var closeRange = codeSpan.closeRange

                // CommonMark rule: if code span has a leading AND trailing space (and is not all spaces), strip one space from each end
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
                decorations.append(LineDecoration(
                    lineRange: innerRange,
                    kind: .inlineCode(range: innerRange, fontSize: codeFontSize, dimFactor: dimFactor)
                ))
                styleSyntaxToken(in: storage, range: openRange, isActiveLine: isActiveLine, theme: theme, dimFactor: dimFactor)
                styleSyntaxToken(in: storage, range: closeRange, isActiveLine: isActiveLine, theme: theme, dimFactor: dimFactor)
            }
        }

        // 2. Inline Math ($E = mc^2$)
        inlineMathRegex.enumerateMatches(in: string, options: [], range: range) { match, _, _ in
            guard let match = match else { return }
            let fullMatchRange = match.range(at: 0)
            if isInCodeOrMath(fullMatchRange) {
                return
            }
            insertSortedRange(fullMatchRange, into: &codeAndMathRanges)

            let openRange = match.range(at: 1)
            let innerRange = match.range(at: 2)
            let closeRange = match.range(at: 3)
            let latexStr = nsString.substring(with: innerRange)

            if isActiveLine {
                let mathMono = theme.codeFont(size: fontSize * 0.90)
                storage.addAttributes([
                    .font: mathMono,
                    .foregroundColor: theme.textNSColor.withAlphaComponent(dimFactor),
                    .backgroundColor: theme.codeBackgroundNSColor.withAlphaComponent(0.55 * dimFactor)
                ], range: innerRange)
                highlightLaTeXSource(in: storage, range: innerRange, theme: theme, dimFactor: dimFactor)
                styleSyntaxToken(in: storage, range: openRange, isActiveLine: true, theme: theme, dimFactor: dimFactor)
                styleSyntaxToken(in: storage, range: closeRange, isActiveLine: true, theme: theme, dimFactor: dimFactor)
            } else {
                let mathBox = LaTeXMathRenderer.layoutLatex(latexStr, baseFontSize: fontSize, isDisplayStyle: false)
                let targetWidth = max(12.0, mathBox.width + 6.0)

                let tinyFont = NSFont.monospacedSystemFont(ofSize: 2.0, weight: .regular)
                let rawSubstr = nsString.substring(with: fullMatchRange) as NSString
                let baseW = rawSubstr.size(withAttributes: [.font: tinyFont]).width
                let perCharKern = (targetWidth - baseW) / CGFloat(max(1, fullMatchRange.length))

                storage.addAttributes([
                    .font: tinyFont,
                    .foregroundColor: NSColor.clear,
                    .kern: perCharKern
                ], range: fullMatchRange)

                decorations.append(LineDecoration(
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
            guard let match = match, !isInCodeOrMath(match.range) else { return }
            let slashRange = NSRange(location: match.range.location, length: 1)
            let escapedCharRange = match.range(at: 1)
            insertSortedRange(match.range, into: &protectedDelimiterRanges)
            styleSyntaxToken(in: storage, range: slashRange, isActiveLine: isActiveLine, theme: theme, dimFactor: dimFactor)
            _ = escapedCharRange
        }

        // 4. HTML <br/> tags outside inline code/math
        htmlBrRegex.enumerateMatches(in: string, options: [], range: range) { match, _, _ in
            guard let match = match, !isInCodeOrMath(match.range) else { return }
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
                let display = FolioMediaImageCache.shared.displaySize(
                    for: link.url,
                    explicitWidth: nil,
                    explicitHeight: nil,
                    maxColumnWidth: maxMediaColumnWidth,
                    baseDirectoryURL: baseDirectoryURL,
                    isDark: theme.isDark
                )
                let targetH = display.isLoaded ? max(26.0, display.size.height + 10.0) : 52.0
                reserveMediaCardHeight(in: storage, lineRange: effectiveLineRange, targetHeight: targetH)
                collapseWhitespaceRange(in: storage, range: link.fullRange)
                decorations.append(LineDecoration(
                    lineRange: effectiveLineRange,
                    kind: .imageRendered(
                        url: link.url,
                        alt: altStr,
                        fullRange: link.fullRange,
                        explicitWidth: nil,
                        explicitHeight: nil,
                        baseDirectoryURL: baseDirectoryURL,
                        dimFactor: dimFactor
                    )
                ))
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
}
