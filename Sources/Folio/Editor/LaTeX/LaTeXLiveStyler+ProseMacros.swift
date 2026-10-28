import AppKit
import FolioEngineFFI
import Foundation

extension LaTeXLiveStyler {

    /// The user macro calls on one line that render as their expansion. Spans that start inside
    /// an expanded call belong to its arguments, so the styler skips them.
    struct ProseMacroPlan {
        var expansions: [Int: (range: NSRange, segments: [LaTeXProseSegment])] = [:]
        var coveredRanges: [NSRange] = []

        /// True when the span at `index`, which starts at document offset `location`, lies inside
        /// an expanded call and is not that call.
        func hidesSpan(at index: Int, location: Int) -> Bool {
            expansions[index] == nil && coveredRanges.contains { location >= $0.location && location < NSMaxRange($0) }
        }
    }

    /// Plans expansions for the `ProseMacroCandidate` spans of a line. `lineText` is the scanned
    /// text and starts at document offset `baseLoc`. Planning is off on the active line, which
    /// shows the source.
    static func planProseMacroExpansions(
        spans: UnsafeBufferPointer<OTLatexInlineSpan>,
        baseLoc: Int,
        lineText: NSString,
        macros: [String: LaTeXMacroDefinition],
        enabled: Bool
    ) -> ProseMacroPlan {
        var plan = ProseMacroPlan()
        guard enabled, !macros.isEmpty else { return plan }
        for idx in 0..<spans.count where spans[idx].kind == 12 {
            let loc = Int(spans[idx].full_loc)
            let docLoc = baseLoc + loc
            guard !plan.hidesSpan(at: idx, location: docLoc), let cmdPtr = spans[idx].cmd else { continue }
            guard LaTeXProseMacroExpander.definition(forCall: String(cString: cmdPtr), in: macros) != nil,
                let expansion = LaTeXProseMacroExpander.expandCall(source: lineText.substring(from: loc), macros: macros)
            else { continue }
            let range = NSRange(location: docLoc, length: expansion.consumedLength)
            plan.expansions[idx] = (range, expansion.segments)
            plan.coveredRanges.append(range)
        }
        return plan
    }

    /// Styles a `ProseMacroCandidate` span. Expanded calls draw their expansion over a hidden
    /// atomic span. On the active line a defined macro's name is styled as syntax and its
    /// arguments stay editable text. A zero-argument macro that the renderer cannot handle keeps
    /// the older plain-text rendering of its body.
    static func styleProseMacroSpan(
        _ sp: OTLatexInlineSpan,
        expansion: (range: NSRange, segments: [LaTeXProseSegment])?,
        baseLoc: Int,
        in storage: NSTextStorage,
        nsString: NSString,
        baseFont: NSFont,
        showTokens: Bool,
        docIndex: LaTeXDocumentIndex,
        theme: EditorTheme,
        dimFactor: CGFloat,
        decorations: inout [LineDecoration]
    ) {
        if let expansion {
            storage.addAttribute(MKey.noSpellCheck, value: true, range: expansion.range)
            renderProseExpansion(
                expansion.segments, range: expansion.range, in: storage, nsString: nsString, baseFont: baseFont,
                docIndex: docIndex, theme: theme, dimFactor: dimFactor, decorations: &decorations
            )
            return
        }
        let cmd = sp.cmd.map { String(cString: $0) } ?? ""
        guard let (def, _) = LaTeXProseMacroExpander.definition(forCall: cmd, in: docIndex.documentMacros) else { return }
        let fullRange = NSRange(location: baseLoc + Int(sp.full_loc), length: Int(sp.full_len))
        let openRange = NSRange(location: baseLoc + Int(sp.open_loc), length: Int(sp.open_len))
        storage.addAttribute(MKey.noSpellCheck, value: true, range: openRange)
        if showTokens {
            let isEmptyBraceCall = sp.full_len == sp.open_len
            MarkdownLiveStyler.styleSyntaxToken(
                in: storage, range: isEmptyBraceCall ? fullRange : openRange, isActiveLine: true, theme: theme, dimFactor: dimFactor
            )
        } else if def.argCount == 0 && def.parameterText == nil {
            let legacyRange = sp.full_len == sp.open_len ? fullRange : openRange
            styleLegacyProseMacro(
                def, fullRange: legacyRange, in: storage, nsString: nsString, baseFont: baseFont, dimFactor: dimFactor, decorations: &decorations
            )
        }
    }

    private static func styleLegacyProseMacro(
        _ def: LaTeXMacroDefinition,
        fullRange: NSRange,
        in storage: NSTextStorage,
        nsString: NSString,
        baseFont: NSFont,
        dimFactor: CGFloat,
        decorations: inout [LineDecoration]
    ) {
        let parts = def.replacement.components(separatedBy: "\\\\")
            .map { LaTeXDocumentIndexer.cleanTeXInlineText($0) }
            .filter { !$0.isEmpty }
        stylePlainInlineText(parts, fullRange: fullRange, in: storage, nsString: nsString, baseFont: baseFont, dimFactor: dimFactor, decorations: &decorations)
    }

    /// Draws `parts`, one per line, in the current font over a hidden atomic span.
    private static func stylePlainInlineText(
        _ parts: [String],
        fullRange: NSRange,
        in storage: NSTextStorage,
        nsString: NSString,
        baseFont: NSFont,
        dimFactor: CGFloat,
        decorations: inout [LineDecoration]
    ) {
        let displayText = parts.joined(separator: "\n")
        guard !displayText.isEmpty else { return }
        let currentFont = (storage.attribute(.font, at: fullRange.location, effectiveRange: nil) as? NSFont) ?? baseFont
        let maxW = parts.map { ceil(($0 as NSString).size(withAttributes: [.font: currentFont]).width) }.max() ?? 4.0
        let extraDescent = CGFloat(max(0, parts.count - 1)) * ceil((currentFont.ascender - currentFont.descender) * 1.10)
        reserveAtomicInlineSpan(
            in: storage, nsString: nsString, fullRange: fullRange, width: max(4.0, maxW),
            ascent: currentFont.ascender, descent: -currentFont.descender + extraDescent
        )
        decorations.append(
            LineDecoration(
                lineRange: fullRange,
                kind: .latexInlineText(text: displayText, font: currentFont, range: fullRange, dimFactor: dimFactor)
            ))
    }

    private static func renderProseExpansion(
        _ segments: [LaTeXProseSegment],
        range: NSRange,
        in storage: NSTextStorage,
        nsString: NSString,
        baseFont: NSFont,
        docIndex: LaTeXDocumentIndex,
        theme: EditorTheme,
        dimFactor: CGFloat,
        decorations: inout [LineDecoration]
    ) {
        if let parts = plainLines(segments) {
            stylePlainInlineText(parts, fullRange: range, in: storage, nsString: nsString, baseFont: baseFont, dimFactor: dimFactor, decorations: &decorations)
            return
        }
        let currentFont = (storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont) ?? baseFont
        let lines = richTextLines(segments, baseFont: currentFont, docIndex: docIndex, theme: theme)
        let widths = lines.map { $0.reduce(0.0) { $0 + richRunWidth($1) } }
        guard let maxWidth = widths.max(), maxWidth > 0 else {
            MarkdownLiveStyler.collapseWhitespaceRange(in: storage, range: range)
            return
        }
        let lineStep = richTextLineStep(lines)
        let (ascent, descent) = richLineMetrics(lines.first ?? [], fallback: currentFont)
        reserveAtomicInlineSpan(
            in: storage, nsString: nsString, fullRange: range, width: ceil(maxWidth),
            ascent: ascent, descent: descent + CGFloat(max(0, lines.count - 1)) * lineStep
        )
        decorations.append(LineDecoration(lineRange: range, kind: .latexInlineRichText(lines: lines, range: range, dimFactor: dimFactor)))
    }

    /// The lines of an expansion that is only unstyled text, or nil. Such text is drawn in the
    /// surrounding font, as macros without arguments always were.
    private static func plainLines(_ segments: [LaTeXProseSegment]) -> [String]? {
        var lines = [""]
        for segment in segments {
            switch segment {
            case let .text(text, style) where style == LaTeXProseStyle():
                lines[lines.count - 1] += text
            case .lineBreak:
                lines.append("")
            default:
                return nil
            }
        }
        let trimmed = lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Converts segments to drawable runs, one array per `\\` line.
    static func richTextLines(
        _ segments: [LaTeXProseSegment],
        baseFont: NSFont,
        docIndex: LaTeXDocumentIndex,
        theme: EditorTheme
    ) -> [[LaTeXInlineRichRun]] {
        var lines: [[LaTeXInlineRichRun]] = [[]]
        for segment in segments {
            switch segment {
            case .lineBreak:
                lines.append([])
            case let .text(text, style):
                guard !(lines[lines.count - 1].isEmpty && text == " ") else { continue }
                let font = proseFont(for: style, baseFont: baseFont, docIndex: docIndex, theme: theme)
                let shown = style.smallCaps ? text.uppercased() : text
                lines[lines.count - 1].append(
                    .text(shown, font: font, underline: style.underline, baselineOffset: scriptOffset(style, baseFont: baseFont)))
            case let .math(latex, style):
                let size = baseFont.pointSize * style.sizeScale * (style.script == .none ? 1.0 : 0.7)
                lines[lines.count - 1].append(.math(latex: latex, fontSize: size, baselineOffset: scriptOffset(style, baseFont: baseFont)))
            }
        }
        return lines
    }

    static func proseFont(for style: LaTeXProseStyle, baseFont: NSFont, docIndex: LaTeXDocumentIndex, theme: EditorTheme) -> NSFont {
        var size = baseFont.pointSize * style.sizeScale
        if style.script != .none { size *= 0.7 }
        if style.smallCaps { size *= 0.82 }
        var font: NSFont
        if style.monospace {
            font = docIndex.codeFont(size: size * 0.92, fallbackTheme: theme)
        } else if style.sans {
            font = NSFont(name: docIndex.documentStyle.sansFontFamily ?? "Helvetica Neue", size: size) ?? NSFont.systemFont(ofSize: size)
        } else {
            font = NSFont(descriptor: baseFont.fontDescriptor, size: size) ?? baseFont
        }
        let manager = NSFontManager.shared
        if style.bold { font = manager.convert(font, toHaveTrait: .boldFontMask) }
        if style.italic { font = manager.convert(font, toHaveTrait: .italicFontMask) }
        return font
    }

    private static func scriptOffset(_ style: LaTeXProseStyle, baseFont: NSFont) -> CGFloat {
        switch style.script {
        case .none: return 0
        case .lowered: return -baseFont.pointSize * 0.22
        case .raised: return baseFont.pointSize * 0.36
        }
    }

    static func richRunWidth(_ run: LaTeXInlineRichRun) -> CGFloat {
        switch run {
        case let .text(text, font, _, _):
            return (text as NSString).size(withAttributes: [.font: font]).width
        case let .math(latex, fontSize, _):
            return LaTeXMathRenderer.layoutLatex(latex, baseFontSize: fontSize, isDisplayStyle: false).width
        }
    }

    private static func richLineMetrics(_ runs: [LaTeXInlineRichRun], fallback: NSFont) -> (ascent: CGFloat, descent: CGFloat) {
        var ascent = fallback.ascender
        var descent = -fallback.descender
        for run in runs {
            switch run {
            case let .text(_, font, _, offset):
                ascent = max(ascent, font.ascender + offset)
                descent = max(descent, -font.descender - offset)
            case let .math(latex, fontSize, offset):
                let box = LaTeXMathRenderer.layoutLatex(latex, baseFontSize: fontSize, isDisplayStyle: false)
                ascent = max(ascent, box.ascent + offset)
                descent = max(descent, box.descent - offset)
            }
        }
        return (ceil(ascent), ceil(descent))
    }

    /// Distance between the baselines of consecutive lines of a rich-text decoration.
    static func richTextLineStep(_ lines: [[LaTeXInlineRichRun]]) -> CGFloat {
        var step: CGFloat = 0
        for run in lines.joined() {
            if case let .text(_, font, _, _) = run {
                step = max(step, ceil((font.ascender - font.descender) * 1.10))
            } else if case let .math(_, fontSize, _) = run {
                step = max(step, ceil(fontSize * 1.3))
            }
        }
        return max(step, 12.0)
    }
}
