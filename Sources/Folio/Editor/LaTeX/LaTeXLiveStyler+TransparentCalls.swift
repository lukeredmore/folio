import AppKit
import FolioEngineFFI
import Foundation

extension LaTeXLiveStyler {
    /// Built-in boxes that print one argument: the arguments before it (`[..]` and `{..}`) set
    /// sizes or offsets, which Folio does not emulate, so they are hidden.
    private static let builtinWrapperShapes: [String: (brackets: Int, braces: Int, trailingBrackets: Int)] = [
        "mbox": (0, 0, 0), "hbox": (0, 0, 0), "fbox": (0, 0, 0), "text": (0, 0, 0), "reflectbox": (0, 0, 0),
        "makebox": (2, 0, 0), "framebox": (2, 0, 0), "raisebox": (0, 1, 2), "scalebox": (0, 1, 1),
        "resizebox": (0, 2, 0), "rotatebox": (1, 1, 0), "parbox": (3, 1, 0)
    ]

    /// Width in ems of the thin-space control symbols.
    private static let controlSpaceEms: [UInt16: CGFloat] = [0x2C: 1.0 / 6.0, 0x3A: 4.0 / 18.0, 0x3B: 5.0 / 18.0]

    /// Plans a candidate without a user definition: a name such as `\contentsname`, a built-in
    /// box, or a command that prints nothing.
    static func planBuiltinCandidate(
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
            // TeX skips the spaces after a control word.
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
        // TeX skips the spaces after a control word.
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
        // The braces of a `{\itshape ...}` group print nothing.
        if declares, loc > 0, lineText.character(at: loc - 1) == 0x7B {
            let close = groupEnd(in: lineText, from: loc)
            plan.hiddenRanges.append(NSRange(location: docLoc - 1, length: 1))
            if close < lineText.length { plan.hiddenRanges.append(NSRange(location: baseLoc + close, length: 1)) }
        }
    }

    /// Builds the transparent call for a user macro call at `lineText[loc]`.
    static func transparentCall(
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

    /// UTF-16 offset of each character index, with one more entry for the end.
    private static func utf16Offsets(_ chars: [Character]) -> [Int] {
        var offsets = [0]
        offsets.reserveCapacity(chars.count + 1)
        for ch in chars { offsets.append(offsets[offsets.count - 1] + ch.utf16.count) }
        return offsets
    }

    /// Hides the call's name and argument braces and draws its separators. A separator whose
    /// source has a line break starts a new, indented paragraph at that break.
    static func styleTransparentCall(
        _ call: TransparentCall,
        in storage: NSTextStorage,
        nsString: NSString,
        baseFont: NSFont,
        docIndex: LaTeXDocumentIndex,
        theme: EditorTheme,
        dimFactor: CGFloat,
        decorations: inout [LineDecoration]
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
                    call.separators[index], gap: gap, callEnd: NSMaxRange(call.arguments.compactMap { $0?.raw }.last ?? argument.raw),
                    in: storage, nsString: nsString, baseFont: baseFont, docIndex: docIndex, theme: theme,
                    dimFactor: dimFactor, decorations: &decorations
                )
            }
            shownArguments += 1
            collapseEdgeWhitespace(of: argument.content, in: storage, nsString: nsString)
            previousEnd = NSMaxRange(argument.content)
            lastRawEnd = NSMaxRange(argument.raw)
        }
        MarkdownLiveStyler.collapseWhitespaceRange(in: storage, range: NSRange(location: previousEnd, length: max(0, lastRawEnd - previousEnd)))
    }

    /// Hides the spaces and line breaks at the start and end of an argument. The separator and
    /// the paragraph edges replace them, and a trailing space could wrap onto an empty line.
    private static func collapseEdgeWhitespace(of range: NSRange, in storage: NSTextStorage, nsString: NSString) {
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

    private static func styleTransparentSeparator(
        _ hint: [LaTeXProseSegment]?,
        gap: NSRange,
        callEnd: Int,
        in storage: NSTextStorage,
        nsString: NSString,
        baseFont: NSFont,
        docIndex: LaTeXDocumentIndex,
        theme: EditorTheme,
        dimFactor: CGFloat,
        decorations: inout [LineDecoration]
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
            indentParagraphs(in: storage, from: NSMaxRange(lineBreak), to: callEnd, by: baseFont.pointSize * 1.5)
        } else {
            anchor = anchor ?? NSMaxRange(gap) - 1
            // An en space: rich text drops a plain space at the start of a line.
            segments = hint.map { [.text("\u{2002}", LaTeXProseStyle())] + $0 } ?? LaTeXTransparentMacro.defaultSeparator
        }
        guard let segments, let anchor else { return }
        renderProseExpansion(
            segments, range: NSRange(location: anchor, length: 1), in: storage, nsString: nsString, baseFont: baseFont,
            docIndex: docIndex, theme: theme, dimFactor: dimFactor, decorations: &decorations
        )
    }

    private static func indentParagraphs(in storage: NSTextStorage, from start: Int, to end: Int, by indent: CGFloat) {
        guard end > start, end <= storage.length else { return }
        let range = NSRange(location: start, length: end - start)
        let existing = storage.attribute(.paragraphStyle, at: start, effectiveRange: nil) as? NSParagraphStyle ?? NSParagraphStyle.default
        guard let style = existing.mutableCopy() as? NSMutableParagraphStyle else { return }
        style.firstLineHeadIndent = existing.headIndent + indent
        style.headIndent = existing.headIndent + indent
        storage.addAttribute(.paragraphStyle, value: style, range: range)
    }

    /// Applies inline font declarations to the visible text up to the end of their group.
    /// `text` is the scanned text, which starts at document offset `baseLoc`; `flowStyle` is the
    /// style that the line starts with.
    static func applyInlineDeclarations(
        _ declarations: [(location: Int, declaration: LaTeXFlowDeclaration)],
        text: NSString,
        baseLoc: Int,
        lineRange: NSRange,
        flowStyle: LaTeXProseStyle,
        in storage: NSTextStorage,
        baseFont: NSFont,
        docIndex: LaTeXDocumentIndex,
        theme: EditorTheme
    ) {
        guard !declarations.isEmpty else { return }
        let documentSize = docIndex.documentStyle.documentFontSizePt ?? 10
        let unscaledSize = baseFont.pointSize / max(0.01, flowStyle.sizeScale)
        var scopes: [(start: Int, end: Int, style: LaTeXProseStyle)] = []
        for (location, declaration) in declarations.sorted(by: { $0.location < $1.location }) {
            let end = baseLoc + groupEnd(in: text, from: location - baseLoc)
            let previous = scopes.last { $0.start <= location && location < $0.end }?.style ?? flowStyle
            var next = previous
            if case .alignment(let alignment) = declaration {
                setAlignment(alignment, in: storage, range: lineRange)
                continue
            }
            LaTeXFlowState.apply(declaration, to: &next, documentFontSize: documentSize)
            scopes.append((location, end, next))
            guard end > location else { continue }
            restyleFonts(
                in: storage, range: NSRange(location: location, length: end - location), from: previous, to: next,
                unscaledSize: unscaledSize, baseFont: baseFont, docIndex: docIndex, theme: theme
            )
        }
    }

    /// The offset in `text` of the `}` that closes the group containing `start`, or the end.
    private static func groupEnd(in text: NSString, from start: Int) -> Int {
        var depth = 0
        var idx = start
        while idx < text.length {
            let ch = text.character(at: idx)
            if ch == 0x5C {
                idx += 2
                continue
            }
            if ch == 0x7B {
                depth += 1
            } else if ch == 0x7D {
                if depth == 0 { return idx }
                depth -= 1
            }
            idx += 1
        }
        return text.length
    }

    private static func setAlignment(_ alignment: NSTextAlignment, in storage: NSTextStorage, range: NSRange) {
        guard range.length > 0, NSMaxRange(range) <= storage.length else { return }
        let existing = storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle ?? NSParagraphStyle.default
        guard let style = existing.mutableCopy() as? NSMutableParagraphStyle else { return }
        style.alignment = alignment
        storage.addAttribute(.paragraphStyle, value: style, range: range)
    }

    /// Changes the fonts of the visible characters in `range` for the fields that differ
    /// between `previous` and `next`. Traits that other commands set, such as `\textbf`, stay.
    private static func restyleFonts(
        in storage: NSTextStorage,
        range: NSRange,
        from previous: LaTeXProseStyle,
        to next: LaTeXProseStyle,
        unscaledSize: CGFloat,
        baseFont: NSFont,
        docIndex: LaTeXDocumentIndex,
        theme: EditorTheme
    ) {
        guard previous != next, NSMaxRange(range) <= storage.length else { return }
        let manager = NSFontManager.shared
        storage.enumerateAttributes(in: range, options: []) { attrs, subrange, _ in
            if attrs[MKey.collapsed] != nil || attrs[MKey.inlineMathSpan] != nil || (attrs[.foregroundColor] as? NSColor) == NSColor.clear {
                return
            }
            var font = (attrs[.font] as? NSFont) ?? baseFont
            let traits = manager.traits(of: font)
            let size = next.sizeScale != previous.sizeScale ? unscaledSize * next.sizeScale : font.pointSize
            if next.monospace != previous.monospace || next.sans != previous.sans {
                var family = LaTeXProseStyle()
                family.monospace = next.monospace
                family.sans = next.sans
                font = proseFont(for: family, baseFont: NSFont(descriptor: baseFont.fontDescriptor, size: size) ?? baseFont, docIndex: docIndex, theme: theme)
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

    /// Hides `\/`, `\@`, `\-`, and `\!`, shows `\ ` as a space, and draws `\,`, `\:`, and `\;` as
    /// thin spaces. `text` is the scanned text, which starts at document offset `baseLoc`.
    static func styleControlSymbols(text: NSString, baseLoc: Int, in storage: NSTextStorage, baseFont: NSFont) {
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
            case 0x2F, 0x40, 0x2D, 0x21: // / @ - !
                MarkdownLiveStyler.collapseWhitespaceRange(in: storage, range: NSRange(location: docLoc, length: 2))
            case 0x20: // control space
                MarkdownLiveStyler.collapseWhitespaceRange(in: storage, range: NSRange(location: docLoc, length: 1))
            case 0x2C, 0x3A, 0x3B: // , : ;
                let font = (storage.attribute(.font, at: docLoc, effectiveRange: nil) as? NSFont) ?? baseFont
                let width = font.pointSize * (controlSpaceEms[next] ?? 0.2)
                reserveAtomicInlineSpan(
                    in: storage, nsString: text, fullRange: NSRange(location: docLoc, length: 2), width: width,
                    ascent: font.ascender, descent: -font.descender
                )
            default:
                break
            }
        }
    }
}
