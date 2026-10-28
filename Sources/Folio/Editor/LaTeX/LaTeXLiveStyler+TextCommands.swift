import AppKit
import FolioEngineFFI
import Foundation

extension LaTeXLiveStyler {

    static func findUnescapedPercent(in nsString: NSString, range: NSRange) -> Int? {
        let end = NSMaxRange(range)
        var i = range.location
        while i < end {
            if nsString.character(at: i) == 0x25 { // '%'
                var backslashes = 0
                var p = i - 1
                while p >= range.location && nsString.character(at: p) == 0x5C {
                    backslashes += 1
                    p -= 1
                }
                if backslashes % 2 == 0 { return i }
            }
            i += 1
        }
        return nil
    }

    nonisolated(unsafe) private static let tinyAtomicFont = NSFont.monospacedSystemFont(ofSize: 0.01, weight: .regular)

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
        let firstCharKern = max(0.0, width - CGFloat(fullRange.length) * 0.006)
        let spanInfo = MarkdownLiveStyler.InlineMathLayoutInfo(
            range: fullRange, width: width, ascent: ascent, descent: descent, padding: verticalPadding
        )
        storage.addAttributes(
            [
                .font: tinyAtomicFont, .foregroundColor: NSColor.clear, .kern: 0.0,
                MKey.inlineMathSpan: spanInfo, MKey.noSpellCheck: true
            ], range: fullRange)
        storage.addAttribute(.kern, value: firstCharKern, range: NSRange(location: fullRange.location, length: 1))
    }

    static func styleLaTeXContainerSpans(
        spans: UnsafeBufferPointer<OTLatexInlineSpan>,
        baseLoc: Int,
        in storage: NSTextStorage,
        nsString: NSString,
        baseFont: NSFont,
        fontSize: CGFloat,
        isActiveLine: Bool,
        prettyMode: Bool,
        docIndex: LaTeXDocumentIndex,
        theme: EditorTheme,
        dimFactor: CGFloat,
        plan: ProseMacroPlan,
        decorations: inout [LineDecoration]
    ) {
        _ = nsString
        let showTokens = isActiveLine || !prettyMode
        let scaleMap: [String: CGFloat] = [
            "Huge": 1.65, "huge": 1.48, "LARGE": 1.38, "Large": 1.28, "large": 1.14,
            "small": 0.90, "footnotesize": 0.82, "scriptsize": 0.82, "tiny": 0.82
        ]

        for idx in 0..<spans.count {
            let sp = spans[idx]
            guard sp.kind >= 5 && sp.kind <= 9 else { continue }
            let fullRange = NSRange(location: baseLoc + Int(sp.full_loc), length: Int(sp.full_len))
            guard !plan.hidesSpan(at: idx, location: fullRange.location) else { continue }
            let openRange = NSRange(location: baseLoc + Int(sp.open_loc), length: Int(sp.open_len))
            let innerRange = NSRange(location: baseLoc + Int(sp.inner_loc), length: Int(sp.inner_len))
            let closeRange = NSRange(location: baseLoc + Int(sp.close_loc), length: Int(sp.close_len))
            let cmd = sp.cmd.map { String(cString: $0) } ?? ""
            let arg = sp.arg.map { String(cString: $0) } ?? ""

            switch sp.kind {
            case 5: // Href
                storage.addAttribute(MKey.noSpellCheck, value: true, range: openRange)
                MarkdownLiveStyler.applyAttributesToVisibleCharacters(
                    in: storage, range: innerRange,
                    attributes: [.foregroundColor: theme.linkNSColor.withAlphaComponent(dimFactor), .underlineStyle: NSUnderlineStyle.single.rawValue]
                )
            case 6: // Url
                storage.addAttribute(MKey.noSpellCheck, value: true, range: fullRange)
                storage.addAttributes(
                    [
                        .font: theme.codeFont(size: fontSize * 0.90),
                        .foregroundColor: theme.linkNSColor.withAlphaComponent(dimFactor),
                        .underlineStyle: NSUnderlineStyle.single.rawValue
                    ], range: innerRange)
            case 7: // SizeGroup
                let scale = scaleMap[cmd] ?? 1.0
                var attrs: [NSAttributedString.Key: Any] = [
                    .font: docIndex.bodyFont(size: fontSize * scale, semibold: scale >= 1.25, fallbackTheme: theme)
                ]
                if !arg.isEmpty {
                    let baseColor = docIndex.resolveColor(named: arg, fallbackTheme: theme)
                    storage.addAttribute(MKey.customColor, value: baseColor, range: innerRange)
                    attrs[.foregroundColor] = baseColor.withAlphaComponent(dimFactor)
                }
                MarkdownLiveStyler.applyAttributesToVisibleCharacters(in: storage, range: innerRange, attributes: attrs)
            case 8: // ColorGroup
                let baseColor = docIndex.resolveColor(named: arg, fallbackTheme: theme)
                storage.addAttribute(MKey.customColor, value: baseColor, range: innerRange)
                MarkdownLiveStyler.applyAttributesToVisibleCharacters(
                    in: storage, range: innerRange, attributes: [.foregroundColor: baseColor.withAlphaComponent(dimFactor)]
                )
            case 9: // StyleCmd
                storage.addAttribute(MKey.noSpellCheck, value: true, range: openRange)
                applyStyleCommandAttributes(
                    cmd: cmd, innerRange: innerRange, in: storage, baseFont: baseFont,
                    fontSize: fontSize, docIndex: docIndex, theme: theme, dimFactor: dimFactor,
                    decorations: &decorations
                )
            default:
                break
            }
            MarkdownLiveStyler.styleSyntaxToken(in: storage, range: openRange, isActiveLine: showTokens, theme: theme, dimFactor: dimFactor)
            MarkdownLiveStyler.styleSyntaxToken(in: storage, range: closeRange, isActiveLine: showTokens, theme: theme, dimFactor: dimFactor)
        }
    }

    private static func applyStyleCommandAttributes(
        cmd: String, innerRange: NSRange, in storage: NSTextStorage, baseFont: NSFont,
        fontSize: CGFloat, docIndex: LaTeXDocumentIndex, theme: EditorTheme,
        dimFactor: CGFloat, decorations: inout [LineDecoration]
    ) {
        switch cmd {
        case "textbf":
            MarkdownLiveStyler.applyFontTraitToVisibleCharacters(in: storage, range: innerRange, trait: .boldFontMask, fallbackFont: baseFont)
        case "textit", "emph":
            MarkdownLiveStyler.applyFontTraitToVisibleCharacters(in: storage, range: innerRange, trait: .italicFontMask, fallbackFont: baseFont)
        case "underline":
            MarkdownLiveStyler.applyAttributesToVisibleCharacters(
                in: storage, range: innerRange, attributes: [.underlineStyle: NSUnderlineStyle.single.rawValue]
            )
        case "texttt":
            let codeFontSize = fontSize * 0.88
            storage.addAttributes(
                [
                    .font: docIndex.codeFont(size: codeFontSize, fallbackTheme: theme),
                    .foregroundColor: theme.inlineCodeNSColor.withAlphaComponent(dimFactor),
                    MarkdownLiveStyler.inlineCodeFontAttributeKey: true,
                    MKey.noSpellCheck: true
                ], range: innerRange)
            decorations.append(
                LineDecoration(
                    lineRange: innerRange, kind: .inlineCode(range: innerRange, fontSize: codeFontSize, dimFactor: dimFactor)
                ))
        case "textsc":
            MarkdownLiveStyler.applyAttributesToVisibleCharacters(
                in: storage, range: innerRange,
                attributes: [.font: docIndex.bodyFont(size: fontSize * 0.90, semibold: true, fallbackTheme: theme), .kern: 0.6]
            )
        case "footnote":
            MarkdownLiveStyler.applyAttributesToVisibleCharacters(
                in: storage, range: innerRange,
                attributes: [
                    .font: docIndex.bodyFont(size: fontSize * 0.86, italic: true, fallbackTheme: theme),
                    .foregroundColor: theme.secondaryTextNSColor.withAlphaComponent(dimFactor)
                ]
            )
        default:
            break
        }
    }

    static func styleLaTeXLeafSymbolOrMacroSpan(
        kind: UInt32, cmd: String, fullRange: NSRange, openRange: NSRange, closeRange: NSRange,
        in storage: NSTextStorage, nsString: NSString, baseFont: NSFont, isActiveLine: Bool,
        prettyMode: Bool, theme: EditorTheme, dimFactor: CGFloat, decorations: inout [LineDecoration]
    ) {
        let showTokens = isActiveLine || !prettyMode
        switch kind {
        case 10: // LogoCmd (\LaTeX, \TeX, \today)
            storage.addAttribute(MKey.noSpellCheck, value: true, range: fullRange)
            MarkdownLiveStyler.styleSyntaxToken(in: storage, range: openRange, isActiveLine: showTokens, theme: theme, dimFactor: dimFactor)
            if closeRange.length > 0 {
                MarkdownLiveStyler.styleSyntaxToken(in: storage, range: closeRange, isActiveLine: showTokens, theme: theme, dimFactor: dimFactor)
            }
        case 11: // TextBackslash (\textbackslash)
            storage.addAttribute(MKey.noSpellCheck, value: true, range: fullRange)
            if openRange.length > 0 {
                MarkdownLiveStyler.styleSyntaxToken(in: storage, range: openRange, isActiveLine: showTokens, theme: theme, dimFactor: dimFactor)
            }
        case 13: // TexQuote (`` or '')
            if showTokens {
                MarkdownLiveStyler.styleSyntaxToken(in: storage, range: fullRange, isActiveLine: true, theme: theme, dimFactor: dimFactor)
            } else {
                let quoteStr = cmd == "``" ? "“" : "”"
                let currentFont = (storage.attribute(.font, at: fullRange.location, effectiveRange: nil) as? NSFont) ?? baseFont
                let quoteW = max(3.0, ceil((quoteStr as NSString).size(withAttributes: [.font: currentFont]).width))
                reserveAtomicInlineSpan(
                    in: storage, nsString: nsString, fullRange: fullRange, width: quoteW,
                    ascent: currentFont.ascender, descent: -currentFont.descender
                )
                decorations.append(
                    LineDecoration(
                        lineRange: fullRange,
                        kind: .latexInlineText(text: quoteStr, font: currentFont, range: fullRange, dimFactor: dimFactor)
                    ))
            }
        case 14: // EscapedChar (\&, \%, \$, \#, \_, \{, \})
            MarkdownLiveStyler.styleSyntaxToken(in: storage, range: openRange, isActiveLine: showTokens, theme: theme, dimFactor: dimFactor)
        default:
            break
        }
    }
}
