import AppKit
import Foundation

extension MarkdownLiveStyler {

    static func applyFontTraitToVisibleCharacters(
        in storage: NSTextStorage,
        range: NSRange,
        trait: NSFontTraitMask,
        fallbackFont: NSFont
    ) {
        guard range.length > 0 else { return }
        storage.enumerateAttributes(in: range, options: []) { attrs, subrange, _ in
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
        storage.enumerateAttributes(in: range, options: []) { attrs, subrange, _ in
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

        // 1-2. Collapse leading and trailing spaces/tabs on each source line of the range
        for regex in [leadingSpaceRegex, trailingSpaceRegex] {
            regex.enumerateMatches(in: string, options: [], range: range) { match, _, _ in
                guard let match = match, match.range.length > 0, !isInCodeOrMath(match.range) else { return }
                collapseWhitespaceRange(in: storage, range: match.range)
            }
        }

        // 3. Collapse extra spaces in runs of 2+ internal spaces/tabs (preserving the first space)
        multiSpaceRegex.enumerateMatches(in: string, options: [], range: range) { match, _, _ in
            guard let match = match, match.range.length >= 2, !isInCodeOrMath(match.range) else { return }
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
        range: NSRange
    ) {
        guard range.length > 0 else { return }
        storage.addAttributes(collapsedTokenAttributes, range: range)
    }

    static func styleSyntaxToken(
        in storage: NSTextStorage,
        range: NSRange,
        isActiveLine: Bool,
        theme: EditorTheme,
        dimFactor: CGFloat
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
            collapseWhitespaceRange(in: storage, range: range)
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
            if let r = match?.range {
                storage.addAttribute(.foregroundColor, value: theme.linkNSColor.withAlphaComponent(dimFactor), range: r)
            }
        }
        latexBracesRegex.enumerateMatches(in: string, options: [], range: range) { match, _, _ in
            if let r = match?.range {
                storage.addAttribute(.foregroundColor, value: theme.inlineCodeNSColor.withAlphaComponent(dimFactor), range: r)
            }
        }
    }
}
