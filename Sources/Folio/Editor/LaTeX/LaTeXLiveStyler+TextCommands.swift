import AppKit
import Foundation

extension LaTeXLiveStyler {

    static func findUnescapedPercent(in nsString: NSString, range: NSRange) -> Int? {
        let end = NSMaxRange(range)
        var i = range.location
        while i < end {
            if nsString.character(at: i) == 0x25 { // '%'
                var backslashes = 0
                var p = i - 1
                while p >= range.location && nsString.character(at: p) == 0x5C { // '\'
                    backslashes += 1
                    p -= 1
                }
                if backslashes % 2 == 0 {
                    return i
                }
            }
            i += 1
        }
        return nil
    }

    static func reserveAtomicInlineSpan(
        in storage: NSTextStorage,
        nsString: NSString,
        fullRange: NSRange,
        width: CGFloat,
        ascent: CGFloat,
        descent: CGFloat
    ) {
        guard fullRange.length > 0 else { return }
        let tinyFont = NSFont.monospacedSystemFont(ofSize: 0.01, weight: .regular)
        let rawSubstr = nsString.substring(with: fullRange) as NSString
        let baseW = rawSubstr.size(withAttributes: [.font: tinyFont]).width
        let firstCharKern = max(0.0, width - baseW)
        let spanInfo = MarkdownLiveStyler.InlineMathLayoutInfo(
            range: fullRange,
            width: width,
            ascent: ascent,
            descent: descent
        )
        storage.addAttributes([
            .font: tinyFont,
            .foregroundColor: NSColor.clear,
            .kern: 0.0,
            MKey.inlineMathSpan: spanInfo,
            MKey.noSpellCheck: true
        ], range: fullRange)
        storage.addAttribute(
            .kern,
            value: firstCharKern,
            range: NSRange(location: fullRange.location, length: 1)
        )
    }

    static func styleLaTeXLinksAndTextCommands(
        in storage: NSTextStorage,
        string: String,
        nsString: NSString,
        effectiveRange: NSRange,
        baseFont: NSFont,
        fontSize: CGFloat,
        isActiveLine: Bool,
        prettyMode: Bool,
        theme: EditorTheme,
        dimFactor: CGFloat,
        isProtected: (NSRange) -> Bool,
        decorations: inout [LineDecoration]
    ) {
        let showTokens = isActiveLine || !prettyMode

        // \href{url}{text}
        latexHrefRegex.enumerateMatches(in: string, options: [], range: effectiveRange) { match, _, _ in
            guard let match = match, !isProtected(match.range) else { return }
            let openRange = match.range(at: 1)
            let urlRange = match.range(at: 2)
            let textRange = match.range(at: 3)
            let closeRange = match.range(at: 4)
            storage.addAttribute(MKey.noSpellCheck, value: true, range: openRange)
            storage.addAttribute(MKey.noSpellCheck, value: true, range: urlRange)
            MarkdownLiveStyler.applyAttributesToVisibleCharacters(
                in: storage,
                range: textRange,
                attributes: [
                    .foregroundColor: theme.linkNSColor.withAlphaComponent(dimFactor),
                    .underlineStyle: NSUnderlineStyle.single.rawValue
                ]
            )
            MarkdownLiveStyler.styleSyntaxToken(in: storage, range: openRange, isActiveLine: showTokens, theme: theme, dimFactor: dimFactor)
            MarkdownLiveStyler.styleSyntaxToken(in: storage, range: closeRange, isActiveLine: showTokens, theme: theme, dimFactor: dimFactor)
        }

        // \url{...}
        latexUrlRegex.enumerateMatches(in: string, options: [], range: effectiveRange) { match, _, _ in
            guard let match = match, !isProtected(match.range) else { return }
            let openRange = match.range(at: 1)
            let urlRange = match.range(at: 2)
            let closeRange = match.range(at: 3)
            storage.addAttribute(MKey.noSpellCheck, value: true, range: match.range)
            storage.addAttributes([
                .font: theme.codeFont(size: fontSize * 0.90),
                .foregroundColor: theme.linkNSColor.withAlphaComponent(dimFactor),
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ], range: urlRange)
            MarkdownLiveStyler.styleSyntaxToken(in: storage, range: openRange, isActiveLine: showTokens, theme: theme, dimFactor: dimFactor)
            MarkdownLiveStyler.styleSyntaxToken(in: storage, range: closeRange, isActiveLine: showTokens, theme: theme, dimFactor: dimFactor)
        }

        // \textbf{...}, \textit{...}, \emph{...}, \underline{...}, \texttt{...}, \textsc{...}, \footnote{...}
        latexStyleCmdRegex.enumerateMatches(in: string, options: [], range: effectiveRange) { match, _, _ in
            guard let match = match, !isProtected(match.range) else { return }
            let openRange = match.range(at: 1)
            let cmd = nsString.substring(with: match.range(at: 2))
            let innerRange = match.range(at: 3)
            let closeRange = match.range(at: 4)
            storage.addAttribute(MKey.noSpellCheck, value: true, range: openRange)

            switch cmd {
            case "textbf":
                MarkdownLiveStyler.applyFontTraitToVisibleCharacters(
                    in: storage, range: innerRange, trait: .boldFontMask, fallbackFont: baseFont
                )
            case "textit", "emph":
                MarkdownLiveStyler.applyFontTraitToVisibleCharacters(
                    in: storage, range: innerRange, trait: .italicFontMask, fallbackFont: baseFont
                )
            case "underline":
                MarkdownLiveStyler.applyAttributesToVisibleCharacters(
                    in: storage,
                    range: innerRange,
                    attributes: [.underlineStyle: NSUnderlineStyle.single.rawValue]
                )
            case "texttt":
                let codeFontSize = fontSize * 0.88
                let codeFont = theme.codeFont(size: codeFontSize)
                storage.addAttributes([
                    .font: codeFont,
                    .foregroundColor: theme.inlineCodeNSColor.withAlphaComponent(dimFactor),
                    MarkdownLiveStyler.inlineCodeFontAttributeKey: true,
                    MKey.noSpellCheck: true
                ], range: innerRange)
                decorations.append(LineDecoration(
                    lineRange: innerRange,
                    kind: .inlineCode(range: innerRange, fontSize: codeFontSize, dimFactor: dimFactor)
                ))
            case "textsc":
                MarkdownLiveStyler.applyAttributesToVisibleCharacters(
                    in: storage,
                    range: innerRange,
                    attributes: [
                        .font: theme.bodyFont(size: fontSize * 0.90, semibold: true),
                        .kern: 0.6
                    ]
                )
            case "footnote":
                MarkdownLiveStyler.applyAttributesToVisibleCharacters(
                    in: storage,
                    range: innerRange,
                    attributes: [
                        .font: theme.bodyFont(size: fontSize * 0.86, italic: true),
                        .foregroundColor: theme.secondaryTextNSColor.withAlphaComponent(dimFactor)
                    ]
                )
            default:
                break
            }

            MarkdownLiveStyler.styleSyntaxToken(in: storage, range: openRange, isActiveLine: showTokens, theme: theme, dimFactor: dimFactor)
            MarkdownLiveStyler.styleSyntaxToken(in: storage, range: closeRange, isActiveLine: showTokens, theme: theme, dimFactor: dimFactor)
        }

        // \LaTeX{}, \TeX{}, \today
        latexLogoCmdRegex.enumerateMatches(in: string, options: [], range: effectiveRange) { match, _, _ in
            guard let match = match, !isProtected(match.range) else { return }
            storage.addAttribute(MKey.noSpellCheck, value: true, range: match.range)
            let slashRange = NSRange(location: match.range.location, length: 1)
            MarkdownLiveStyler.styleSyntaxToken(in: storage, range: slashRange, isActiveLine: showTokens, theme: theme, dimFactor: dimFactor)
            let bracesRange = match.range(at: 2)
            if bracesRange.location != NSNotFound && bracesRange.length > 0 {
                MarkdownLiveStyler.styleSyntaxToken(in: storage, range: bracesRange, isActiveLine: showTokens, theme: theme, dimFactor: dimFactor)
            }
        }

        // \textbackslash (e.g. inside \texttt{\textbackslash usepackage})
        latexTextBackslashRegex.enumerateMatches(in: string, options: [], range: effectiveRange) { match, _, _ in
            guard let match = match, !isProtected(match.range) else { return }
            storage.addAttribute(MKey.noSpellCheck, value: true, range: match.range)
            let wordRange = match.range(at: 1)
            if wordRange.location != NSNotFound && wordRange.length > 0 {
                MarkdownLiveStyler.styleSyntaxToken(in: storage, range: wordRange, isActiveLine: showTokens, theme: theme, dimFactor: dimFactor)
            }
        }

        // Escaped special characters: \&, \%, \$, \#, \_, \{, \}
        latexEscapedCharRegex.enumerateMatches(in: string, options: [], range: effectiveRange) { match, _, _ in
            guard let match = match, !isProtected(match.range) else { return }
            let slashRange = NSRange(location: match.range.location, length: 1)
            MarkdownLiveStyler.styleSyntaxToken(in: storage, range: slashRange, isActiveLine: showTokens, theme: theme, dimFactor: dimFactor)
        }
    }
}
