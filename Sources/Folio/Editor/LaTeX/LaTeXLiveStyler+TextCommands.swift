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

    nonisolated(unsafe) private static let tinyAtomicFont = NSFont.monospacedSystemFont(ofSize: 0.01, weight: .regular)
    static let latexSizeGroupRegex = try! NSRegularExpression(
        pattern: #"(\{\\(Huge|huge|LARGE|Large|large|normalsize|small|footnotesize|scriptsize|tiny)\b[ \t]*(?:\\color\{([^}]+)\}[ \t]*)?)([^{}]*(?:\{[^{}]*\}[^{}]*)*)(\})"#
    )
    static let latexColorGroupRegex = try! NSRegularExpression(
        pattern: #"(\{\\color\{([^}]+)\}[ \t]*(?:\\(?:Huge|huge|LARGE|Large|large|normalsize|small|footnotesize|scriptsize|tiny)\b[ \t]*)?|\\textcolor\{([^}]+)\}\{)([^{}]*(?:\{[^{}]*\}[^{}]*)*)(\})"#
    )
    static let latexProseMacroRegex = try! NSRegularExpression(
        pattern: #"\\([A-Za-z]+)(?:\{\}|\b(?![\{]))"#
    )
    static let latexTeXQuotesRegex = try! NSRegularExpression(
        pattern: #"``|''"#
    )

    static func reserveAtomicInlineSpan(
        in storage: NSTextStorage,
        nsString: NSString,
        fullRange: NSRange,
        width: CGFloat,
        ascent: CGFloat,
        descent: CGFloat,
        verticalPadding: CGFloat = 0.0
    ) {
        guard fullRange.length > 0 else { return }
        _ = nsString
        let baseW = CGFloat(fullRange.length) * 0.006
        let firstCharKern = max(0.0, width - baseW)
        let spanInfo = MarkdownLiveStyler.InlineMathLayoutInfo(
            range: fullRange,
            width: width,
            ascent: ascent,
            descent: descent,
            padding: verticalPadding
        )
        storage.addAttributes([
            .font: tinyAtomicFont,
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
        lineSub: String,
        effectiveRange: NSRange,
        baseFont: NSFont,
        fontSize: CGFloat,
        isActiveLine: Bool,
        prettyMode: Bool,
        docIndex: LaTeXDocumentIndex,
        theme: EditorTheme,
        dimFactor: CGFloat,
        isProtected: (NSRange) -> Bool,
        decorations: inout [LineDecoration]
    ) {
        let showTokens = isActiveLine || !prettyMode

        // \href{url}{text}
        if lineSub.contains("\\href") {
            latexHrefRegex.enumerateMatches(in: string, options: [], range: effectiveRange) { match, _, _ in
                guard let match = match else { return }
                let openRange = match.range(at: 1)
                let urlRange = match.range(at: 2)
                let textRange = match.range(at: 3)
                let closeRange = match.range(at: 4)
                guard !isProtected(openRange) && !isProtected(closeRange) else { return }
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
        }

        // \url{...}
        if lineSub.contains("\\url") {
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
        }

        // {\Large ...}, {\large ...}, {\small ...} (with optional \color{...})
        if lineSub.contains("{\\") {
            latexSizeGroupRegex.enumerateMatches(in: string, options: [], range: effectiveRange) { match, _, _ in
                guard let match = match else { return }
                let openRange = match.range(at: 1)
                let sizeCmd = nsString.substring(with: match.range(at: 2))
                let colorRange = match.range(at: 3)
                let innerRange = match.range(at: 4)
                let closeRange = match.range(at: 5)
                guard !isProtected(openRange) && !isProtected(closeRange) else { return }
                let scaleMap: [String: CGFloat] = [
                    "Huge": 1.65, "huge": 1.48, "LARGE": 1.38, "Large": 1.28, "large": 1.14,
                    "small": 0.90, "footnotesize": 0.82, "scriptsize": 0.82, "tiny": 0.82
                ]
                let scale = scaleMap[sizeCmd] ?? 1.0
                let sizedFont = docIndex.bodyFont(size: fontSize * scale, semibold: scale >= 1.25, fallbackTheme: theme)
                var attrs: [NSAttributedString.Key: Any] = [.font: sizedFont]
                if colorRange.location != NSNotFound {
                    let baseColor = docIndex.resolveColor(named: nsString.substring(with: colorRange), fallbackTheme: theme)
                    storage.addAttribute(MKey.customColor, value: baseColor, range: innerRange)
                    attrs[.foregroundColor] = baseColor.withAlphaComponent(dimFactor)
                }
                MarkdownLiveStyler.applyAttributesToVisibleCharacters(in: storage, range: innerRange, attributes: attrs)
                MarkdownLiveStyler.styleSyntaxToken(in: storage, range: openRange, isActiveLine: showTokens, theme: theme, dimFactor: dimFactor)
                MarkdownLiveStyler.styleSyntaxToken(in: storage, range: closeRange, isActiveLine: showTokens, theme: theme, dimFactor: dimFactor)
            }
        }

        // {\color{...}...} and \textcolor{...}{...}
        if lineSub.contains("\\color{") || lineSub.contains("\\textcolor{") {
            latexColorGroupRegex.enumerateMatches(in: string, options: [], range: effectiveRange) { match, _, _ in
                guard let match = match else { return }
                let openRange = match.range(at: 1)
                let colorNameRange = match.range(at: 2).location != NSNotFound ? match.range(at: 2) : match.range(at: 3)
                let colorName = colorNameRange.location != NSNotFound ? nsString.substring(with: colorNameRange) : ""
                let innerRange = match.range(at: 4)
                let closeRange = match.range(at: 5)
                guard !isProtected(openRange) && !isProtected(closeRange) else { return }
                let baseColor = docIndex.resolveColor(named: colorName, fallbackTheme: theme)
                let resolvedColor = baseColor.withAlphaComponent(dimFactor)
                storage.addAttribute(MKey.customColor, value: baseColor, range: innerRange)
                MarkdownLiveStyler.applyAttributesToVisibleCharacters(
                    in: storage,
                    range: innerRange,
                    attributes: [.foregroundColor: resolvedColor]
                )
                MarkdownLiveStyler.styleSyntaxToken(in: storage, range: openRange, isActiveLine: showTokens, theme: theme, dimFactor: dimFactor)
                MarkdownLiveStyler.styleSyntaxToken(in: storage, range: closeRange, isActiveLine: showTokens, theme: theme, dimFactor: dimFactor)
            }
        }

        // \textbf{...}, \textit{...}, \emph{...}, \underline{...}, \texttt{...}, \textsc{...}, \footnote{...}
        if lineSub.contains("\\text") || lineSub.contains("\\emph") || lineSub.contains("\\underline") || lineSub.contains("\\footnote") {
            latexStyleCmdRegex.enumerateMatches(in: string, options: [], range: effectiveRange) { match, _, _ in
                guard let match = match else { return }
                let openRange = match.range(at: 1)
                let cmd = nsString.substring(with: match.range(at: 2))
                let innerRange = match.range(at: 3)
                let closeRange = match.range(at: 4)
                guard !isProtected(openRange) && !isProtected(closeRange) else { return }
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
                    let codeFont = docIndex.codeFont(size: codeFontSize, fallbackTheme: theme)
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
                            .font: docIndex.bodyFont(size: fontSize * 0.90, semibold: true, fallbackTheme: theme),
                            .kern: 0.6
                        ]
                    )
                case "footnote":
                    MarkdownLiveStyler.applyAttributesToVisibleCharacters(
                        in: storage,
                        range: innerRange,
                        attributes: [
                            .font: docIndex.bodyFont(size: fontSize * 0.86, italic: true, fallbackTheme: theme),
                            .foregroundColor: theme.secondaryTextNSColor.withAlphaComponent(dimFactor)
                        ]
                    )
                default:
                    break
                }

                MarkdownLiveStyler.styleSyntaxToken(in: storage, range: openRange, isActiveLine: showTokens, theme: theme, dimFactor: dimFactor)
                MarkdownLiveStyler.styleSyntaxToken(in: storage, range: closeRange, isActiveLine: showTokens, theme: theme, dimFactor: dimFactor)
            }
        }

        // \LaTeX{}, \TeX{}, \today
        if lineSub.contains("TeX") || lineSub.contains("\\today") {
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
        }

        // \textbackslash (e.g. inside \texttt{\textbackslash usepackage})
        if lineSub.contains("\\textbackslash") {
            latexTextBackslashRegex.enumerateMatches(in: string, options: [], range: effectiveRange) { match, _, _ in
                guard let match = match, !isProtected(match.range) else { return }
                storage.addAttribute(MKey.noSpellCheck, value: true, range: match.range)
                let wordRange = match.range(at: 1)
                if wordRange.location != NSNotFound && wordRange.length > 0 {
                    MarkdownLiveStyler.styleSyntaxToken(in: storage, range: wordRange, isActiveLine: showTokens, theme: theme, dimFactor: dimFactor)
                }
            }
        }

        // Zero-argument document macros in prose (e.g. \letterdate, \sendername, \originaltoll{}, \invoice{})
        let docMacros = LaTeXMathRenderer.currentDocumentMacros()
        if !docMacros.isEmpty && lineSub.contains("\\") {
            latexProseMacroRegex.enumerateMatches(in: string, options: [], range: effectiveRange) { match, _, _ in
                guard let match = match, !isProtected(match.range) else { return }
                let cmdName = nsString.substring(with: match.range(at: 1))
                guard let def = docMacros["\\\(cmdName)"], def.argCount == 0, def.operatorText == nil else { return }
                storage.addAttribute(MKey.noSpellCheck, value: true, range: match.range)
                if showTokens {
                    MarkdownLiveStyler.styleSyntaxToken(in: storage, range: match.range, isActiveLine: true, theme: theme, dimFactor: dimFactor)
                } else {
                    let parts = def.replacement.components(separatedBy: "\\\\")
                        .map { LaTeXDocumentIndexer.cleanTeXInlineText($0) }
                        .filter { !$0.isEmpty }
                    let displayText = parts.joined(separator: "\n")
                    guard !displayText.isEmpty else { return }
                    let currentFont = (storage.attribute(.font, at: match.range.location, effectiveRange: nil) as? NSFont) ?? baseFont
                    let maxW = parts.map { ceil(($0 as NSString).size(withAttributes: [.font: currentFont]).width) }.max() ?? 4.0
                    let lineStep = ceil((currentFont.ascender - currentFont.descender) * 1.10)
                    let extraDescent = CGFloat(max(0, parts.count - 1)) * lineStep
                    reserveAtomicInlineSpan(
                        in: storage,
                        nsString: nsString,
                        fullRange: match.range,
                        width: max(4.0, maxW),
                        ascent: currentFont.ascender,
                        descent: -currentFont.descender + extraDescent
                    )
                    decorations.append(LineDecoration(
                        lineRange: match.range,
                        kind: .latexInlineText(text: displayText, font: currentFont, range: match.range, dimFactor: dimFactor)
                    ))
                }
            }
        }

        // TeX quote ligatures: `` -> “ and '' -> ”
        if lineSub.contains("``") || lineSub.contains("''") {
            latexTeXQuotesRegex.enumerateMatches(in: string, options: [], range: effectiveRange) { match, _, _ in
                guard let match = match, !isProtected(match.range) else { return }
                if showTokens {
                    MarkdownLiveStyler.styleSyntaxToken(in: storage, range: match.range, isActiveLine: true, theme: theme, dimFactor: dimFactor)
                } else {
                    let raw = nsString.substring(with: match.range)
                    let quoteStr = raw == "``" ? "“" : "”"
                    let currentFont = (storage.attribute(.font, at: match.range.location, effectiveRange: nil) as? NSFont) ?? baseFont
                    let quoteW = max(3.0, ceil((quoteStr as NSString).size(withAttributes: [.font: currentFont]).width))
                    reserveAtomicInlineSpan(
                        in: storage,
                        nsString: nsString,
                        fullRange: match.range,
                        width: quoteW,
                        ascent: currentFont.ascender,
                        descent: -currentFont.descender
                    )
                    decorations.append(LineDecoration(
                        lineRange: match.range,
                        kind: .latexInlineText(text: quoteStr, font: currentFont, range: match.range, dimFactor: dimFactor)
                    ))
                }
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
