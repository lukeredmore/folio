import AppKit
import FolioEngineFFI
import Foundation

extension LaTeXStylePass {

    private static let builtinWrapperShapes: [String: (brackets: Int, braces: Int, trailingBrackets: Int)] = [
        "mbox": (0, 0, 0), "hbox": (0, 0, 0), "fbox": (0, 0, 0), "text": (0, 0, 0), "reflectbox": (0, 0, 0),
        "makebox": (2, 0, 0), "framebox": (2, 0, 0), "raisebox": (0, 1, 2), "scalebox": (0, 1, 1),
        "resizebox": (0, 2, 0), "rotatebox": (1, 1, 0), "parbox": (3, 1, 0)
    ]

    private static let controlSpaceEms: [UInt16: CGFloat] = [0x2C: 1.0 / 6.0, 0x3A: 4.0 / 18.0, 0x3B: 5.0 / 18.0]

    struct ProseMacroPlan {
        var expansions: [Int: (range: NSRange, segments: [LaTeXProseSegment])] = [:]
        var coveredRanges: [(owner: Int, range: NSRange)] = []
        var transparentCalls: [Int: TransparentCall] = [:]
        var hiddenCommands: [Int: NSRange] = [:]
        var hiddenRanges: [NSRange] = []
        var declarations: [(location: Int, declaration: LaTeXFlowDeclaration)] = []

        func hidesSpan(at index: Int, location: Int) -> Bool {
            coveredRanges.contains { $0.owner != index && location >= $0.range.location && location < NSMaxRange($0.range) }
        }
    }

    struct TransparentCall {
        let nameRange: NSRange
        let arguments: [(raw: NSRange, content: NSRange)?]
        let separators: [Int: [LaTeXProseSegment]]
    }

    static func planProseMacroExpansions(
        spans: UnsafeBufferPointer<OTLatexInlineSpan>,
        baseLoc: Int,
        lineText: NSString,
        macros: [String: LaTeXMacroDefinition],
        enabled: Bool
    ) -> ProseMacroPlan {
        var plan = ProseMacroPlan()
        guard enabled else { return plan }
        for idx in 0..<spans.count where spans[idx].kind == 12 {
            let loc = Int(spans[idx].full_loc)
            let docLoc = baseLoc + loc
            guard !plan.hidesSpan(at: idx, location: docLoc), let cmdPtr = spans[idx].cmd else { continue }
            let name = String(cString: cmdPtr)
            if let (def, consumesStar) = LaTeXProseMacroExpander.definition(forCall: name, in: macros) {
                if let expansion = LaTeXProseMacroExpander.expandCall(source: lineText.substring(from: loc), macros: macros) {
                    let range = NSRange(location: docLoc, length: expansion.consumedLength)
                    plan.expansions[idx] = (range, expansion.segments)
                    plan.coveredRanges.append((idx, range))
                } else if let layout = LaTeXTransparentMacro.analyze(def, macros: macros),
                    let call = transparentCall(def, consumesStar: consumesStar, separators: layout.separators, lineText: lineText, at: loc, baseLoc: baseLoc)
                {
                    plan.transparentCalls[idx] = call
                } else if def.argCount == 0, def.parameterText == nil, LaTeXLayoutLine.printsNothing(def.replacement, macros: macros) {
                    let span = spans[idx]
                    let length = span.full_len == span.open_len ? Int(span.full_len) : Int(span.open_len)
                    plan.hiddenCommands[idx] = NSRange(location: docLoc, length: length)
                }
                continue
            }
            planBuiltinCandidate(spans[idx], index: idx, name: name, baseLoc: baseLoc, lineText: lineText, into: &plan)
        }
        return plan
    }

    private static func planBuiltinCandidate(
        _ span: OTLatexInlineSpan,
        index: Int,
        name: String,
        baseLoc: Int,
        lineText: NSString,
        into plan: inout ProseMacroPlan
    ) {
        let loc = Int(span.full_loc)
        let docLoc = baseLoc + loc
        if let text = LaTeXProseMacroExpander.builtinText(forCommand: name) {
            var length = span.full_len == span.open_len ? Int(span.full_len) : Int(span.open_len)
            while loc + length < lineText.length && [0x20, 0x09].contains(lineText.character(at: loc + length)) { length += 1 }
            let range = NSRange(location: docLoc, length: length)
            plan.expansions[index] = (range, [.text(text, LaTeXProseStyle())])
            plan.coveredRanges.append((index, range))
            return
        }
        let isWrapper = builtinWrapperShapes[name] != nil
        guard isWrapper || LaTeXLayoutCommands.entries[name] != nil || LaTeXLayoutCommands.definitionCommands.contains(name) else { return }
        let window = NSRange(location: loc, length: min(lineText.length - loc, 4000))
        let chars = Array(lineText.substring(with: window))
        if let shape = builtinWrapperShapes[name] {
            if let call = builtinWrapperCall(chars, shape: shape, docLoc: docLoc) { plan.transparentCalls[index] = call }
            return
        }
        let command = LaTeXLayoutLine.readCommand(chars, at: 0, macros: [:])
        guard command.isLayout, command.end > 0 else { return }
        var end = command.end
        if chars[end - 1].isLetter {
            while end < chars.count && (chars[end] == " " || chars[end] == "\t") { end += 1 }
        }
        let range = NSRange(location: docLoc, length: String(chars[0..<end]).utf16.count)
        plan.hiddenCommands[index] = range
        plan.coveredRanges.append((index, range))
        var declares = false
        for case .declaration(let declaration) in command.effects {
            plan.declarations.append((NSMaxRange(range), declaration))
            declares = true
        }
        if declares, loc > 0, lineText.character(at: loc - 1) == 0x7B {
            let close = LaTeXLexer.groupEnd(in: lineText, from: loc)
            plan.hiddenRanges.append(NSRange(location: docLoc - 1, length: 1))
            if close < lineText.length { plan.hiddenRanges.append(NSRange(location: baseLoc + close, length: 1)) }
        }
    }

    private static func transparentCall(
        _ def: LaTeXMacroDefinition,
        consumesStar: Bool,
        separators: [Int: [LaTeXProseSegment]],
        lineText: NSString,
        at loc: Int,
        baseLoc: Int
    ) -> TransparentCall? {
        let chars = Array(lineText.substring(from: loc))
        let (_, afterWord) = LaTeXMacroExpander.readControlWord(chars, at: 0)
        let nameEnd = consumesStar && afterWord < chars.count && chars[afterWord] == "*" ? afterWord + 1 : afterWord
        guard let (spans, _) = LaTeXMacroExpander.readArgumentSpans(for: def, in: chars, from: nameEnd) else { return nil }
        let offsets = utf16Offsets(chars)
        let docLoc = baseLoc + loc
        func docRange(_ range: Range<Int>) -> NSRange {
            NSRange(location: docLoc + offsets[range.lowerBound], length: offsets[range.upperBound] - offsets[range.lowerBound])
        }
        let arguments: [(raw: NSRange, content: NSRange)?] = spans.map { span in
            guard let raw = span.raw, let content = span.content else { return nil }
            return (docRange(raw), docRange(content))
        }
        return TransparentCall(nameRange: docRange(0..<nameEnd), arguments: arguments, separators: separators)
    }

    private static func builtinWrapperCall(
        _ chars: [Character],
        shape: (brackets: Int, braces: Int, trailingBrackets: Int),
        docLoc: Int
    ) -> TransparentCall? {
        var idx = LaTeXMacroExpander.readControlWord(chars, at: 0).1
        let nameEnd = idx
        func skipBrackets(_ limit: Int) {
            for _ in 0..<limit {
                let probe = LaTeXMacroExpander.skipSpaces(chars, from: idx)
                guard let (_, after) = LaTeXMacroExpander.readBracketGroup(chars, at: probe) else { return }
                idx = after
            }
        }
        skipBrackets(shape.brackets)
        for _ in 0..<shape.braces {
            guard let (_, after) = LaTeXMacroExpander.readBracedGroup(chars, at: LaTeXMacroExpander.skipSpaces(chars, from: idx)) else { return nil }
            idx = after
        }
        skipBrackets(shape.trailingBrackets)
        let open = LaTeXMacroExpander.skipSpaces(chars, from: idx)
        guard let (_, after) = LaTeXMacroExpander.readBracedGroup(chars, at: open) else { return nil }
        let offsets = utf16Offsets(Array(chars[0..<after]))
        func docRange(_ range: Range<Int>) -> NSRange {
            NSRange(location: docLoc + offsets[range.lowerBound], length: offsets[range.upperBound] - offsets[range.lowerBound])
        }
        return TransparentCall(
            nameRange: docRange(0..<nameEnd),
            arguments: [(docRange(open..<after), docRange((open + 1)..<(after - 1)))],
            separators: [:]
        )
    }

    private static func utf16Offsets(_ chars: [Character]) -> [Int] {
        var offsets = [0]
        offsets.reserveCapacity(chars.count + 1)
        for ch in chars { offsets.append(offsets[offsets.count - 1] + ch.utf16.count) }
        return offsets
    }

    mutating func styleProseMacroSpan(
        _ sp: OTLatexInlineSpan,
        expansion: (range: NSRange, segments: [LaTeXProseSegment])?,
        baseLoc: Int,
        lineFont: NSFont,
        showTokens: Bool,
        dimFactor: CGFloat
    ) {
        if let expansion {
            storage.addAttribute(MKey.noSpellCheck, value: true, range: expansion.range)
            renderProseExpansion(expansion.segments, range: expansion.range, lineFont: lineFont, dimFactor: dimFactor)
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
                in: storage,
                range: isEmptyBraceCall ? fullRange : openRange,
                isActiveLine: true,
                theme: theme,
                dimFactor: dimFactor
            )
        } else if def.argCount == 0 && def.parameterText == nil {
            let legacyRange = sp.full_len == sp.open_len ? fullRange : openRange
            let parts = def.replacement.components(separatedBy: "\\\\")
                .map { LaTeXDocumentIndexer.cleanTeXInlineText($0) }
                .filter { !$0.isEmpty }
            stylePlainInlineText(parts, fullRange: legacyRange, lineFont: lineFont, dimFactor: dimFactor)
        }
    }

    private mutating func stylePlainInlineText(
        _ parts: [String],
        fullRange: NSRange,
        lineFont: NSFont,
        dimFactor: CGFloat
    ) {
        let displayText = parts.joined(separator: "\n")
        guard !displayText.isEmpty else { return }
        let currentFont = (storage.attribute(.font, at: fullRange.location, effectiveRange: nil) as? NSFont) ?? lineFont
        let maxW = parts.map { ceil(($0 as NSString).size(withAttributes: [.font: currentFont]).width) }.max() ?? 4.0
        let extraDescent = CGFloat(max(0, parts.count - 1)) * ceil((currentFont.ascender - currentFont.descender) * 1.10)
        Self.reserveAtomicInlineSpan(
            in: storage,
            nsString: nsString,
            fullRange: fullRange,
            width: max(4.0, maxW),
            ascent: currentFont.ascender,
            descent: -currentFont.descender + extraDescent
        )
        decorations.append(
            LineDecoration(
                lineRange: fullRange,
                kind: .latexInlineText(text: displayText, font: currentFont, range: fullRange, dimFactor: dimFactor)
            ))
    }

    mutating func renderProseExpansion(
        _ segments: [LaTeXProseSegment],
        range: NSRange,
        lineFont: NSFont,
        dimFactor: CGFloat
    ) {
        if let parts = Self.plainLines(segments) {
            stylePlainInlineText(parts, fullRange: range, lineFont: lineFont, dimFactor: dimFactor)
            return
        }
        let currentFont = (storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont) ?? lineFont
        let lines = Self.richTextLines(segments, baseFont: currentFont, docIndex: docIndex, theme: theme)
        let widths = lines.map { $0.reduce(0.0) { $0 + Self.richRunWidth($1) } }
        guard let maxWidth = widths.max(), maxWidth > 0 else {
            MarkdownLiveStyler.collapseWhitespaceRange(in: storage, range: range)
            return
        }
        let lineStep = Self.richTextLineStep(lines)
        let (ascent, descent) = Self.richLineMetrics(lines.first ?? [], fallback: currentFont)
        Self.reserveAtomicInlineSpan(
            in: storage,
            nsString: nsString,
            fullRange: range,
            width: ceil(maxWidth),
            ascent: ascent,
            descent: descent + CGFloat(max(0, lines.count - 1)) * lineStep
        )
        decorations.append(LineDecoration(lineRange: range, kind: .latexInlineRichText(lines: lines, range: range, dimFactor: dimFactor)))
    }

    mutating func styleTransparentCall(
        _ call: TransparentCall,
        lineFont: NSFont,
        dimFactor: CGFloat
    ) {
        storage.addAttribute(MKey.noSpellCheck, value: true, range: call.nameRange)
        MarkdownLiveStyler.collapseWhitespaceRange(in: storage, range: call.nameRange)
        var previousEnd = NSMaxRange(call.nameRange)
        var shownArguments = 0
        var lastRawEnd = previousEnd
        for (index, argument) in call.arguments.enumerated() {
            guard let argument else { continue }
            let gap = NSRange(location: previousEnd, length: max(0, argument.content.location - previousEnd))
            if shownArguments == 0 {
                MarkdownLiveStyler.collapseWhitespaceRange(in: storage, range: gap)
            } else {
                styleTransparentSeparator(
                    call.separators[index],
                    gap: gap,
                    callEnd: NSMaxRange(call.arguments.compactMap { $0?.raw }.last ?? argument.raw),
                    lineFont: lineFont,
                    dimFactor: dimFactor
                )
            }
            shownArguments += 1
            collapseEdgeWhitespace(of: argument.content)
            previousEnd = NSMaxRange(argument.content)
            lastRawEnd = NSMaxRange(argument.raw)
        }
        MarkdownLiveStyler.collapseWhitespaceRange(in: storage, range: NSRange(location: previousEnd, length: max(0, lastRawEnd - previousEnd)))
    }

    private func collapseEdgeWhitespace(of range: NSRange) {
        func isSpace(_ index: Int) -> Bool {
            let ch = nsString.character(at: index)
            return ch == 0x20 || ch == 0x09 || ch == 0x0A || ch == 0x0D
                || storage.attribute(MarkdownLiveStyler.collapsedTokenAttributeKey, at: index, effectiveRange: nil) != nil
        }
        var start = range.location
        while start < NSMaxRange(range) && isSpace(start) { start += 1 }
        MarkdownLiveStyler.collapseWhitespaceRange(in: storage, range: NSRange(location: range.location, length: start - range.location))
        var end = NSMaxRange(range)
        while end > start && isSpace(end - 1) { end -= 1 }
        MarkdownLiveStyler.collapseWhitespaceRange(in: storage, range: NSRange(location: end, length: NSMaxRange(range) - end))
    }

    private mutating func styleTransparentSeparator(
        _ hint: [LaTeXProseSegment]?,
        gap: NSRange,
        callEnd: Int,
        lineFont: NSFont,
        dimFactor: CGFloat
    ) {
        guard gap.length > 0 else { return }
        let lineBreak = nsString.range(of: "\n", options: [], range: gap)
        var anchor: Int?
        var idx = NSMaxRange(gap) - 1
        while idx >= gap.location {
            let ch = nsString.character(at: idx)
            if ch == 0x0A { break }
            if ch != 0x20 && ch != 0x09 {
                anchor = idx
                break
            }
            idx -= 1
        }
        MarkdownLiveStyler.collapseWhitespaceRange(in: storage, range: gap)
        var segments = hint
        if lineBreak.location != NSNotFound {
            storage.removeAttribute(MarkdownLiveStyler.collapsedTokenAttributeKey, range: lineBreak)
            storage.removeAttribute(MarkdownLiveStyler.softLineBreakAttributeKey, range: lineBreak)
            indentParagraphs(from: NSMaxRange(lineBreak), to: callEnd, by: lineFont.pointSize * 1.5)
        } else {
            anchor = anchor ?? NSMaxRange(gap) - 1
            segments = hint.map { [.text("\u{2002}", LaTeXProseStyle())] + $0 } ?? LaTeXTransparentMacro.defaultSeparator
        }
        guard let segments, let anchor else { return }
        renderProseExpansion(segments, range: NSRange(location: anchor, length: 1), lineFont: lineFont, dimFactor: dimFactor)
    }

    private func indentParagraphs(from start: Int, to end: Int, by indent: CGFloat) {
        guard end > start, end <= storage.length else { return }
        let range = NSRange(location: start, length: end - start)
        let existing = storage.attribute(.paragraphStyle, at: start, effectiveRange: nil) as? NSParagraphStyle ?? NSParagraphStyle.default
        guard let style = existing.mutableCopy() as? NSMutableParagraphStyle else { return }
        style.firstLineHeadIndent = existing.headIndent + indent
        style.headIndent = existing.headIndent + indent
        storage.addAttribute(.paragraphStyle, value: style, range: range)
    }

    func applyInlineDeclarations(
        _ declarations: [(location: Int, declaration: LaTeXFlowDeclaration)],
        text: NSString,
        baseLoc: Int,
        lineRange: NSRange,
        flowStyle: LaTeXProseStyle,
        lineFont: NSFont
    ) {
        guard !declarations.isEmpty else { return }
        let documentSize = docIndex.documentStyle.documentFontSizePt ?? 10
        let unscaledSize = lineFont.pointSize / max(0.01, flowStyle.sizeScale)
        var scopes: [(start: Int, end: Int, style: LaTeXProseStyle)] = []
        for (location, declaration) in declarations.sorted(by: { $0.location < $1.location }) {
            let end = baseLoc + LaTeXLexer.groupEnd(in: text, from: location - baseLoc)
            let previous = scopes.last { $0.start <= location && location < $0.end }?.style ?? flowStyle
            var next = previous
            if case .alignment(let alignment) = declaration {
                setAlignment(alignment, range: lineRange)
                continue
            }
            LaTeXFlowState.apply(declaration, to: &next, documentFontSize: documentSize)
            scopes.append((location, end, next))
            guard end > location else { continue }
            restyleFonts(
                range: NSRange(location: location, length: end - location),
                from: previous,
                to: next,
                unscaledSize: unscaledSize,
                lineFont: lineFont
            )
        }
    }

    private func setAlignment(_ alignment: NSTextAlignment, range: NSRange) {
        guard range.length > 0, NSMaxRange(range) <= storage.length else { return }
        let existing = storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle ?? NSParagraphStyle.default
        guard let style = existing.mutableCopy() as? NSMutableParagraphStyle else { return }
        style.alignment = alignment
        storage.addAttribute(.paragraphStyle, value: style, range: range)
    }

    private func restyleFonts(
        range: NSRange,
        from previous: LaTeXProseStyle,
        to next: LaTeXProseStyle,
        unscaledSize: CGFloat,
        lineFont: NSFont
    ) {
        guard previous != next, NSMaxRange(range) <= storage.length else { return }
        let manager = NSFontManager.shared
        let docIndex = self.docIndex
        let theme = self.theme
        storage.enumerateAttributes(in: range, options: []) { attrs, subrange, _ in
            if attrs[MKey.collapsed] != nil || attrs[MKey.inlineMathSpan] != nil || (attrs[.foregroundColor] as? NSColor) == NSColor.clear {
                return
            }
            var font = (attrs[.font] as? NSFont) ?? lineFont
            let traits = manager.traits(of: font)
            let size = next.sizeScale != previous.sizeScale ? unscaledSize * next.sizeScale : font.pointSize
            if next.monospace != previous.monospace || next.sans != previous.sans {
                var family = LaTeXProseStyle()
                family.monospace = next.monospace
                family.sans = next.sans
                let sizedBase = NSFont(descriptor: lineFont.fontDescriptor, size: size) ?? lineFont
                font = Self.proseFont(for: family, baseFont: sizedBase, docIndex: docIndex, theme: theme)
            } else if size != font.pointSize {
                font = NSFont(descriptor: font.fontDescriptor, size: size) ?? font
            }
            let bold = next.bold != previous.bold ? next.bold : traits.contains(.boldFontMask)
            let italic = next.italic != previous.italic ? next.italic : traits.contains(.italicFontMask)
            font = bold ? manager.convert(font, toHaveTrait: .boldFontMask) : manager.convert(font, toNotHaveTrait: .boldFontMask)
            font = italic ? manager.convert(font, toHaveTrait: .italicFontMask) : manager.convert(font, toNotHaveTrait: .italicFontMask)
            storage.addAttribute(.font, value: font, range: subrange)
        }
    }

    func styleControlSymbols(text: NSString, baseLoc: Int, lineFont: NSFont) {
        var idx = 0
        while idx + 1 < text.length {
            guard text.character(at: idx) == 0x5C else {
                idx += 1
                continue
            }
            let next = text.character(at: idx + 1)
            let docLoc = baseLoc + idx
            defer { idx += 2 }
            guard storage.attribute(MKey.collapsed, at: docLoc, effectiveRange: nil) == nil,
                storage.attribute(MKey.inlineMathSpan, at: docLoc, effectiveRange: nil) == nil
            else { continue }
            switch next {
            case 0x2F, 0x40, 0x2D, 0x21:
                MarkdownLiveStyler.collapseWhitespaceRange(in: storage, range: NSRange(location: docLoc, length: 2))
            case 0x20:
                MarkdownLiveStyler.collapseWhitespaceRange(in: storage, range: NSRange(location: docLoc, length: 1))
            case 0x2C, 0x3A, 0x3B:
                let font = (storage.attribute(.font, at: docLoc, effectiveRange: nil) as? NSFont) ?? lineFont
                let width = font.pointSize * (Self.controlSpaceEms[next] ?? 0.2)
                Self.reserveAtomicInlineSpan(
                    in: storage,
                    nsString: text,
                    fullRange: NSRange(location: docLoc, length: 2),
                    width: width,
                    ascent: font.ascender,
                    descent: -font.descender
                )
            default:
                break
            }
        }
    }

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
