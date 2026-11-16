import AppKit
import FolioEngineFFI
import Foundation

extension LaTeXStylePass {

    nonisolated(unsafe) private static let tinyAtomicFont = NSFont.monospacedSystemFont(ofSize: 0.01, weight: .regular)

    private static let sizeScaleMap: [String: CGFloat] = [
        "Huge": 1.65, "huge": 1.48, "LARGE": 1.38, "Large": 1.28, "large": 1.14,
        "small": 0.90, "footnotesize": 0.82, "scriptsize": 0.82, "tiny": 0.82
    ]

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
                .font: tinyAtomicFont,
                .foregroundColor: NSColor.clear,
                .kern: 0.0,
                MKey.inlineMathSpan: spanInfo,
                MKey.noSpellCheck: true
            ], range: fullRange)
        storage.addAttribute(.kern, value: firstCharKern, range: NSRange(location: fullRange.location, length: 1))
    }

    mutating func styleInlineContent(
        range: NSRange,
        lineRange: NSRange,
        lineFont: NSFont,
        isActiveLine: Bool,
        dimFactor: CGFloat,
        flowStyle: LaTeXProseStyle = LaTeXProseStyle()
    ) {
        guard range.length > 0 else { return }
        let fontSize = lineFont.pointSize

        var effectiveRange = range
        var scannedText: String?
        if nsString.range(of: "\n", options: [], range: range).location != NSNotFound {
            scannedText = maskLineComments(range: range, hide: !isActiveLine && prettyMode)
        } else if let commentStart = LaTeXLexer.findUnescapedPercent(in: nsString, range: range) {
            let commentRange = NSRange(location: commentStart, length: NSMaxRange(range) - commentStart)
            storage.addAttribute(MKey.noSpellCheck, value: true, range: commentRange)
            let isWholeLineComment = nsString.substring(
                with: NSRange(location: range.location, length: commentStart - range.location)
            ).trimmingCharacters(in: .whitespaces).isEmpty

            if isActiveLine || !prettyMode {
                storage.addAttributes(
                    [
                        .font: docIndex.bodyFont(size: fontSize * 0.92, italic: true, fallbackTheme: theme),
                        .foregroundColor: theme.secondaryTextNSColor.withAlphaComponent(0.75 * dimFactor)
                    ], range: commentRange)
            } else {
                MarkdownLiveStyler.collapseWhitespaceRange(in: storage, range: commentRange)
                if isWholeLineComment {
                    let pStyle = NSMutableParagraphStyle()
                    pStyle.minimumLineHeight = 2.0
                    pStyle.maximumLineHeight = 2.0
                    pStyle.lineSpacing = 0
                    pStyle.paragraphSpacing = 0
                    storage.addAttributes(
                        [
                            .font: NSFont.systemFont(ofSize: 1.0),
                            .foregroundColor: NSColor.clear,
                            .paragraphStyle: pStyle
                        ], range: lineRange)
                }
            }
            effectiveRange = NSRange(location: range.location, length: max(0, commentStart - range.location))
        }
        guard effectiveRange.length > 0 else { return }
        let lineSub = scannedText ?? nsString.substring(with: effectiveRange)
        guard lineSub.contains("\\") || lineSub.contains("$") || lineSub.contains("``") || lineSub.contains("''") else {
            return
        }

        guard let scanRes = lineSub.withCString({ ot_engine_scan_latex_inlines($0) }) else { return }
        defer { ot_engine_free_latex_inlines(scanRes) }
        let count = Int(scanRes.pointee.span_count)
        guard count > 0, let spansPtr = scanRes.pointee.spans else { return }
        let spans = UnsafeBufferPointer(start: spansPtr, count: count)
        let baseLoc = effectiveRange.location
        let plan = Self.planProseMacroExpansions(
            spans: spans,
            baseLoc: baseLoc,
            lineText: lineSub as NSString,
            macros: docIndex.documentMacros,
            enabled: prettyMode && !isActiveLine
        )

        styleContainerSpans(
            spans: spans,
            baseLoc: baseLoc,
            lineFont: lineFont,
            fontSize: fontSize,
            isActiveLine: isActiveLine,
            dimFactor: dimFactor,
            plan: plan
        )

        applyInlineDeclarations(
            plan.declarations,
            text: lineSub as NSString,
            baseLoc: baseLoc,
            lineRange: lineRange,
            flowStyle: flowStyle,
            lineFont: lineFont
        )

        for idx in 0..<count {
            let sp = spans[idx]
            let fullRange = NSRange(location: baseLoc + Int(sp.full_loc), length: Int(sp.full_len))
            let openRange = NSRange(location: baseLoc + Int(sp.open_loc), length: Int(sp.open_len))
            let innerRange = NSRange(location: baseLoc + Int(sp.inner_loc), length: Int(sp.inner_len))
            let closeRange = NSRange(location: baseLoc + Int(sp.close_loc), length: Int(sp.close_len))
            guard !plan.hidesSpan(at: idx, location: fullRange.location) else { continue }
            let cmd = sp.cmd.map { String(cString: $0) } ?? ""
            let arg = sp.arg.map { String(cString: $0) } ?? ""

            switch sp.kind {
            case 1:
                styleInlineMathSpan(
                    fullRange: fullRange,
                    openRange: openRange,
                    innerRange: innerRange,
                    closeRange: closeRange,
                    latexStr: arg,
                    fontSize: fontSize,
                    isActiveLine: isActiveLine,
                    dimFactor: dimFactor
                )
            case 2:
                styleCiteSpan(
                    fullRange: fullRange,
                    rawKeysStr: arg,
                    lineFont: lineFont,
                    fontSize: fontSize,
                    isActiveLine: isActiveLine,
                    dimFactor: dimFactor
                )
            case 3:
                styleRefSpan(
                    fullRange: fullRange,
                    cmd: cmd,
                    rawKey: arg,
                    lineFont: lineFont,
                    fontSize: fontSize,
                    isActiveLine: isActiveLine,
                    dimFactor: dimFactor
                )
            case 4:
                if !isActiveLine && prettyMode && cmd == "\\\\" && !arg.isEmpty,
                    let len = LaTeXLength.parse(arg)
                {
                    let extraPt = max(0.0, len.resolvedPoints(baseSize: fontSize))
                    if extraPt > 0,
                        let existing = storage.attribute(.paragraphStyle, at: lineRange.location, effectiveRange: nil) as? NSParagraphStyle,
                        let mutable = existing.mutableCopy() as? NSMutableParagraphStyle
                    {
                        mutable.paragraphSpacing = extraPt
                        storage.addAttribute(.paragraphStyle, value: mutable, range: lineRange)
                    }
                }
                MarkdownLiveStyler.styleSyntaxToken(
                    in: storage,
                    range: fullRange,
                    isActiveLine: isActiveLine || !prettyMode,
                    theme: theme,
                    dimFactor: dimFactor
                )
            case 12 where plan.transparentCalls[idx] != nil:
                if let call = plan.transparentCalls[idx] {
                    styleTransparentCall(call, lineFont: lineFont, dimFactor: dimFactor)
                }
            case 12 where plan.hiddenCommands[idx] != nil:
                if let hidden = plan.hiddenCommands[idx] {
                    storage.addAttribute(MKey.noSpellCheck, value: true, range: hidden)
                    MarkdownLiveStyler.collapseWhitespaceRange(in: storage, range: hidden)
                }
            case 12:
                styleProseMacroSpan(
                    sp,
                    expansion: plan.expansions[idx],
                    baseLoc: baseLoc,
                    lineFont: lineFont,
                    showTokens: isActiveLine || !prettyMode,
                    dimFactor: dimFactor
                )
            case 10, 11, 13, 14:
                styleLeafSymbolOrMacroSpan(
                    kind: sp.kind,
                    cmd: cmd,
                    fullRange: fullRange,
                    openRange: openRange,
                    closeRange: closeRange,
                    lineFont: lineFont,
                    isActiveLine: isActiveLine,
                    dimFactor: dimFactor
                )
            default:
                break
            }
        }
        for hidden in plan.hiddenRanges {
            MarkdownLiveStyler.collapseWhitespaceRange(in: storage, range: hidden)
        }
        if prettyMode && !isActiveLine {
            styleControlSymbols(text: lineSub as NSString, baseLoc: baseLoc, lineFont: lineFont)
        }
    }

    private func maskLineComments(range: NSRange, hide: Bool) -> String {
        var units = [unichar](repeating: 0, count: range.length)
        nsString.getCharacters(&units, range: range)
        var lineStart = range.location
        while lineStart < NSMaxRange(range) {
            let lineEnd = nsString.range(of: "\n", options: [], range: NSRange(location: lineStart, length: NSMaxRange(range) - lineStart))
            let end = lineEnd.location == NSNotFound ? NSMaxRange(range) : lineEnd.location
            if let commentStart = LaTeXLexer.findUnescapedPercent(in: nsString, range: NSRange(location: lineStart, length: end - lineStart)) {
                for i in commentStart..<end { units[i - range.location] = 0x20 }
                let commentRange = NSRange(location: commentStart, length: end - commentStart)
                storage.addAttribute(MKey.noSpellCheck, value: true, range: commentRange)
                if hide {
                    MarkdownLiveStyler.collapseWhitespaceRange(in: storage, range: commentRange)
                    if lineEnd.location != NSNotFound {
                        storage.addAttribute(MarkdownLiveStyler.collapsedTokenAttributeKey, value: true, range: lineEnd)
                    }
                }
            }
            lineStart = end + 1
        }
        return String(utf16CodeUnits: units, count: units.count)
    }

    private mutating func styleContainerSpans(
        spans: UnsafeBufferPointer<OTLatexInlineSpan>,
        baseLoc: Int,
        lineFont: NSFont,
        fontSize: CGFloat,
        isActiveLine: Bool,
        dimFactor: CGFloat,
        plan: ProseMacroPlan
    ) {
        let showTokens = isActiveLine || !prettyMode

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
            case 5:
                storage.addAttribute(MKey.noSpellCheck, value: true, range: openRange)
                MarkdownLiveStyler.applyAttributesToVisibleCharacters(
                    in: storage,
                    range: innerRange,
                    attributes: [
                        .foregroundColor: theme.linkNSColor.withAlphaComponent(dimFactor),
                        .underlineStyle: NSUnderlineStyle.single.rawValue
                    ]
                )
            case 6:
                storage.addAttribute(MKey.noSpellCheck, value: true, range: fullRange)
                storage.addAttributes(
                    [
                        .font: theme.codeFont(size: fontSize * 0.90),
                        .foregroundColor: theme.linkNSColor.withAlphaComponent(dimFactor),
                        .underlineStyle: NSUnderlineStyle.single.rawValue
                    ], range: innerRange)
            case 7:
                let scale = Self.sizeScaleMap[cmd] ?? 1.0
                var attrs: [NSAttributedString.Key: Any] = [
                    .font: docIndex.bodyFont(size: fontSize * scale, semibold: scale >= 1.25, fallbackTheme: theme)
                ]
                if !arg.isEmpty {
                    let baseColor = docIndex.resolveColor(named: arg, fallbackTheme: theme)
                    storage.addAttribute(MKey.customColor, value: baseColor, range: innerRange)
                    attrs[.foregroundColor] = baseColor.withAlphaComponent(dimFactor)
                }
                MarkdownLiveStyler.applyAttributesToVisibleCharacters(in: storage, range: innerRange, attributes: attrs)
            case 8:
                let baseColor = docIndex.resolveColor(named: arg, fallbackTheme: theme)
                storage.addAttribute(MKey.customColor, value: baseColor, range: innerRange)
                MarkdownLiveStyler.applyAttributesToVisibleCharacters(
                    in: storage,
                    range: innerRange,
                    attributes: [.foregroundColor: baseColor.withAlphaComponent(dimFactor)]
                )
            case 9:
                storage.addAttribute(MKey.noSpellCheck, value: true, range: openRange)
                applyStyleCommandAttributes(cmd: cmd, innerRange: innerRange, lineFont: lineFont, fontSize: fontSize, dimFactor: dimFactor)
            default:
                break
            }
            MarkdownLiveStyler.styleSyntaxToken(in: storage, range: openRange, isActiveLine: showTokens, theme: theme, dimFactor: dimFactor)
            MarkdownLiveStyler.styleSyntaxToken(in: storage, range: closeRange, isActiveLine: showTokens, theme: theme, dimFactor: dimFactor)
        }
    }

    private mutating func applyStyleCommandAttributes(
        cmd: String,
        innerRange: NSRange,
        lineFont: NSFont,
        fontSize: CGFloat,
        dimFactor: CGFloat
    ) {
        switch cmd {
        case "textbf":
            MarkdownLiveStyler.applyFontTraitToVisibleCharacters(in: storage, range: innerRange, trait: .boldFontMask, fallbackFont: lineFont)
        case "textit", "emph":
            MarkdownLiveStyler.applyFontTraitToVisibleCharacters(in: storage, range: innerRange, trait: .italicFontMask, fallbackFont: lineFont)
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
                    lineRange: innerRange,
                    kind: .inlineCode(range: innerRange, fontSize: codeFontSize, dimFactor: dimFactor)
                ))
        case "textsc":
            MarkdownLiveStyler.applyAttributesToVisibleCharacters(
                in: storage,
                range: innerRange,
                attributes: [.font: docIndex.bodyFont(size: fontSize * 0.90, semibold: true, fallbackTheme: theme), .kern: 0.6]
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
    }

    private mutating func styleInlineMathSpan(
        fullRange: NSRange,
        openRange: NSRange,
        innerRange: NSRange,
        closeRange: NSRange,
        latexStr: String,
        fontSize: CGFloat,
        isActiveLine: Bool,
        dimFactor: CGFloat
    ) {
        storage.addAttribute(MKey.noSpellCheck, value: true, range: fullRange)
        if isActiveLine || !prettyMode {
            storage.addAttributes(
                [
                    .font: theme.codeFont(size: fontSize * 0.90),
                    .foregroundColor: theme.textNSColor.withAlphaComponent(dimFactor),
                    .backgroundColor: theme.codeBackgroundNSColor.withAlphaComponent(0.55 * dimFactor)
                ], range: innerRange)
            MarkdownLiveStyler.highlightLaTeXSource(in: storage, range: innerRange, theme: theme, dimFactor: dimFactor)
            MarkdownLiveStyler.styleSyntaxToken(in: storage, range: openRange, isActiveLine: true, theme: theme, dimFactor: dimFactor)
            MarkdownLiveStyler.styleSyntaxToken(in: storage, range: closeRange, isActiveLine: true, theme: theme, dimFactor: dimFactor)
        } else {
            let mathBox = LaTeXMathRenderer.layoutLatex(latexStr, baseFontSize: fontSize, isDisplayStyle: false)
            Self.reserveAtomicInlineSpan(
                in: storage,
                nsString: nsString,
                fullRange: fullRange,
                width: max(4.0, mathBox.width + 2.0),
                ascent: mathBox.ascent,
                descent: mathBox.descent,
                verticalPadding: 3.0
            )
            decorations.append(
                LineDecoration(
                    lineRange: fullRange,
                    kind: .inlineMathRendered(latex: latexStr, range: fullRange, fontSize: fontSize, dimFactor: dimFactor)
                ))
        }
    }

    private mutating func styleCiteSpan(
        fullRange: NSRange,
        rawKeysStr: String,
        lineFont: NSFont,
        fontSize: CGFloat,
        isActiveLine: Bool,
        dimFactor: CGFloat
    ) {
        storage.addAttribute(MKey.noSpellCheck, value: true, range: fullRange)
        if isActiveLine || !prettyMode {
            MarkdownLiveStyler.highlightLaTeXSource(in: storage, range: fullRange, theme: theme, dimFactor: dimFactor)
            return
        }
        let rawKeys = rawKeysStr.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        var labels: [String] = []
        var tooltips: [String] = []
        var firstLoc: Int?
        var firstURL: URL?
        for k in rawKeys {
            if let entry = docIndex.bibEntries[k] {
                labels.append(entry.shortCitation)
                tooltips.append(entry.title.isEmpty ? entry.key : "\(entry.author) (\(entry.year)) — \(entry.title)")
                if firstLoc == nil {
                    firstLoc = entry.characterLocation
                    firstURL = entry.fileURL
                }
            } else {
                labels.append(k)
                tooltips.append("Citation key: \(k)")
            }
        }
        let pillLabel = "[\(labels.joined(separator: "; "))]"
        let pillFont = NSFont.systemFont(ofSize: max(10.5, fontSize * 0.82), weight: .medium)
        let labelW = ceil((pillLabel as NSString).size(withAttributes: [.font: pillFont]).width) + 12.0
        Self.reserveAtomicInlineSpan(
            in: storage,
            nsString: nsString,
            fullRange: fullRange,
            width: labelW,
            ascent: lineFont.ascender,
            descent: -lineFont.descender
        )
        decorations.append(
            LineDecoration(
                lineRange: fullRange,
                kind: .latexInlinePill(
                    label: pillLabel,
                    tooltip: tooltips.joined(separator: "\n"),
                    targetLocation: firstLoc,
                    targetURL: firstURL,
                    range: fullRange,
                    fontSize: fontSize,
                    isCitation: true,
                    dimFactor: dimFactor
                )
            ))
    }

    private mutating func styleRefSpan(
        fullRange: NSRange,
        cmd: String,
        rawKey: String,
        lineFont: NSFont,
        fontSize: CGFloat,
        isActiveLine: Bool,
        dimFactor: CGFloat
    ) {
        storage.addAttribute(MKey.noSpellCheck, value: true, range: fullRange)
        if isActiveLine || !prettyMode {
            MarkdownLiveStyler.highlightLaTeXSource(in: storage, range: fullRange, theme: theme, dimFactor: dimFactor)
            return
        }
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let info = docIndex.labels[key]
        let num = info?.number ?? key
        let pillLabel = (cmd == "eqref") ? "(\(num))" : (["autoref", "cref", "Cref"].contains(cmd) ? "\(info?.kind ?? "Ref.") \(num)" : num)
        let tooltip = info.map { "\($0.kind) \($0.number): \($0.title)" } ?? "Label: \(key)"
        let pillFont = NSFont.systemFont(ofSize: max(10.5, fontSize * 0.82), weight: .medium)
        let labelW = ceil((pillLabel as NSString).size(withAttributes: [.font: pillFont]).width) + 12.0
        Self.reserveAtomicInlineSpan(
            in: storage,
            nsString: nsString,
            fullRange: fullRange,
            width: labelW,
            ascent: lineFont.ascender,
            descent: -lineFont.descender
        )
        decorations.append(
            LineDecoration(
                lineRange: fullRange,
                kind: .latexInlinePill(
                    label: pillLabel,
                    tooltip: tooltip,
                    targetLocation: info?.characterLocation,
                    targetURL: nil,
                    range: fullRange,
                    fontSize: fontSize,
                    isCitation: false,
                    dimFactor: dimFactor
                )
            ))
    }

    private mutating func styleLeafSymbolOrMacroSpan(
        kind: UInt32,
        cmd: String,
        fullRange: NSRange,
        openRange: NSRange,
        closeRange: NSRange,
        lineFont: NSFont,
        isActiveLine: Bool,
        dimFactor: CGFloat
    ) {
        let showTokens = isActiveLine || !prettyMode
        switch kind {
        case 10:
            storage.addAttribute(MKey.noSpellCheck, value: true, range: fullRange)
            MarkdownLiveStyler.styleSyntaxToken(in: storage, range: openRange, isActiveLine: showTokens, theme: theme, dimFactor: dimFactor)
            if closeRange.length > 0 {
                MarkdownLiveStyler.styleSyntaxToken(in: storage, range: closeRange, isActiveLine: showTokens, theme: theme, dimFactor: dimFactor)
            }
        case 11:
            storage.addAttribute(MKey.noSpellCheck, value: true, range: fullRange)
            if openRange.length > 0 {
                MarkdownLiveStyler.styleSyntaxToken(in: storage, range: openRange, isActiveLine: showTokens, theme: theme, dimFactor: dimFactor)
            }
        case 13:
            if showTokens {
                MarkdownLiveStyler.styleSyntaxToken(in: storage, range: fullRange, isActiveLine: true, theme: theme, dimFactor: dimFactor)
            } else {
                let quoteStr = cmd == "``" ? "“" : "”"
                let currentFont = (storage.attribute(.font, at: fullRange.location, effectiveRange: nil) as? NSFont) ?? lineFont
                let quoteW = max(3.0, ceil((quoteStr as NSString).size(withAttributes: [.font: currentFont]).width))
                Self.reserveAtomicInlineSpan(
                    in: storage,
                    nsString: nsString,
                    fullRange: fullRange,
                    width: quoteW,
                    ascent: currentFont.ascender,
                    descent: -currentFont.descender
                )
                decorations.append(
                    LineDecoration(
                        lineRange: fullRange,
                        kind: .latexInlineText(text: quoteStr, font: currentFont, range: fullRange, dimFactor: dimFactor)
                    ))
            }
        case 14:
            MarkdownLiveStyler.styleSyntaxToken(in: storage, range: openRange, isActiveLine: showTokens, theme: theme, dimFactor: dimFactor)
        default:
            break
        }
    }
}
