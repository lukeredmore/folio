import AppKit
import Foundation

extension LaTeXLiveStyler {
    /// Bounds on a macro call whose arguments continue on later lines.
    enum MultiLineCallLimits {
        /// Most lines in one call, including the first.
        static let maxLines = 40
        /// Most UTF-16 characters in one call.
        static let maxCharacters = 4_000
    }

    /// The result of looking for a multi-line macro call that starts on a line.
    struct MultiLineCallProbe: Equatable {
        /// End of the last line of the call, or nil when no call continues past the line.
        let blockEnd: Int?
        /// End of the text that the probe read. A cached block that depends on the probe stays
        /// valid only while this text is unchanged.
        let contextEnd: Int
    }

    /// Looks for a call to a user macro, or a built-in box, on the line at `lineRange` whose
    /// arguments close on a later line. The search reads at most `MultiLineCallLimits` and stops
    /// at a blank line, which ends a TeX paragraph.
    static func probeMultiLineCall(
        lineRange: NSRange,
        nsString: NSString,
        macros: [String: LaTeXMacroDefinition]
    ) -> MultiLineCallProbe {
        let lineContent = MarkdownLiveStyler.strippedLineContentRange(nsString: nsString, lineRange: lineRange)
        let none = MultiLineCallProbe(blockEnd: nil, contextEnd: NSMaxRange(lineRange))
        guard lineContent.length > 0, nsString.range(of: "\\", options: [], range: lineContent).location != NSNotFound else { return none }
        let lineText = maskedComments(nsString.substring(with: lineContent))
        let lineChars = Array(lineText)
        let starts = callStarts(in: lineChars, macros: macros)
        guard starts.contains(where: { needsFollowingLines(lineChars, call: $0, macros: macros) }) else { return none }

        let window = probeWindow(from: lineRange.location, nsString: nsString)
        let windowText = maskedComments(nsString.substring(with: window))
        let chars = Array(windowText)
        var offsets = [0]
        offsets.reserveCapacity(chars.count + 1)
        for ch in chars { offsets.append(offsets[offsets.count - 1] + ch.utf16.count) }
        var lastCharacter = lineContent.location + lineContent.length - lineRange.location
        var index = 0
        var calls = starts
        while index < calls.count {
            let call = calls[index]
            index += 1
            guard let end = callEnd(chars, call: call, macros: macros) else { continue }
            let endOffset = offsets[end]
            guard endOffset > lastCharacter else { continue }
            let previousLast = lastCharacter
            let callLastLine = nsString.lineRange(for: NSRange(location: window.location + endOffset - 1, length: 0))
            let callLastContent = MarkdownLiveStyler.strippedLineContentRange(nsString: nsString, lineRange: callLastLine)
            lastCharacter = NSMaxRange(callLastContent) - window.location
            // A call that starts on the new last line after this call may continue further.
            let tailStart = offsets.firstIndex { $0 >= max(endOffset, previousLast) } ?? chars.count
            let tailEnd = offsets.firstIndex { $0 >= lastCharacter } ?? chars.count
            if tailStart < tailEnd {
                calls += callStarts(in: Array(chars[0..<tailEnd]), macros: macros, from: tailStart)
            }
        }
        let contentEnd = lineContent.location + lineContent.length
        guard window.location + lastCharacter > contentEnd else {
            return MultiLineCallProbe(blockEnd: nil, contextEnd: windowContextEnd(window, nsString: nsString))
        }
        let lastLine = nsString.lineRange(for: NSRange(location: window.location + lastCharacter - 1, length: 0))
        return MultiLineCallProbe(blockEnd: NSMaxRange(lastLine), contextEnd: windowContextEnd(window, nsString: nsString))
    }

    /// Looks for a definition, such as `\renewenvironment{name}{..}{..}` in a document body, that
    /// starts the line at `lineRange` and ends on a later line with nothing after it.
    static func probeMultiLineDefinition(lineRange: NSRange, nsString: NSString) -> MultiLineCallProbe {
        let none = MultiLineCallProbe(blockEnd: nil, contextEnd: NSMaxRange(lineRange))
        let window = probeWindow(from: lineRange.location, nsString: nsString)
        let chars = Array(maskedComments(nsString.substring(with: window)))
        let start = LaTeXMacroExpander.skipSpaces(chars, from: 0)
        guard start < chars.count, chars[start] == "\\" else { return none }
        let command = LaTeXLayoutLine.readCommand(chars, at: start, macros: [:])
        guard command.isLayout, command.end > start else { return MultiLineCallProbe(blockEnd: nil, contextEnd: windowContextEnd(window, nsString: nsString)) }
        let endOffset = String(chars[0..<command.end]).utf16.count
        let lastLine = nsString.lineRange(for: NSRange(location: window.location + endOffset - 1, length: 0))
        let rest = NSRange(location: window.location + endOffset, length: NSMaxRange(lastLine) - window.location - endOffset)
        let restText = maskedComments(nsString.substring(with: rest)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard NSMaxRange(lastLine) > NSMaxRange(lineRange), restText.isEmpty else {
            return MultiLineCallProbe(blockEnd: nil, contextEnd: windowContextEnd(window, nsString: nsString))
        }
        return MultiLineCallProbe(blockEnd: NSMaxRange(lastLine), contextEnd: windowContextEnd(window, nsString: nsString))
    }

    /// Folds the lines of a definition block, or shows their source when the block is active.
    static func styleDefinitionBlock(
        _ blockRange: NSRange,
        in storage: NSTextStorage,
        nsString: NSString,
        activeLineRange: NSRange,
        selectedRange: NSRange,
        theme: EditorTheme,
        prettyMode: Bool,
        focusMode: Bool,
        effectiveBaseSize: CGFloat,
        effectiveContainerWidth: CGFloat
    ) -> (nextIndex: Int, lineDelta: Int) {
        let firstLine = nsString.lineRange(for: NSRange(location: blockRange.location, length: 0))
        if blockRange.length > firstLine.length {
            LaTeXBlockStyleCache.resetAttributes(
                in: storage, range: NSRange(location: NSMaxRange(firstLine), length: blockRange.length - firstLine.length)
            )
        }
        let isActive = LaTeXBlockStyleCache.isBlockActive(range: blockRange, activeLineRange: activeLineRange, selectedRange: selectedRange)
        let dimFactor: CGFloat = (focusMode && !isActive) ? 0.30 : 1.0
        var scan = blockRange.location
        var count = 0
        while scan < NSMaxRange(blockRange) {
            let lineRange = nsString.lineRange(for: NSRange(location: scan, length: 0))
            styleDocumentBoundaryLineHelper(
                in: storage, lineRange: lineRange, contentRange: MarkdownLiveStyler.strippedLineContentRange(nsString: nsString, lineRange: lineRange),
                isActive: isActive, prettyMode: prettyMode, theme: theme, effectiveBaseSize: effectiveBaseSize,
                effectiveContainerWidth: effectiveContainerWidth, dimFactor: dimFactor
            )
            scan = NSMaxRange(lineRange)
            count += 1
        }
        if !isActive && prettyMode {
            LaTeXBlockStyleCache.collapseInternalNewlines(in: storage, nsString: nsString, range: blockRange)
        }
        LaTeXBlockStyleCache.pendingGlyphInvalidationRanges.append(blockRange)
        return (NSMaxRange(blockRange), count)
    }

    /// A call start: the index of its backslash, its definition, or a built-in box name.
    private struct CallStart {
        let position: Int
        let afterName: Int
        let definition: LaTeXMacroDefinition?
        let builtin: String?
    }

    private static func callStarts(in chars: [Character], macros: [String: LaTeXMacroDefinition], from start: Int = 0) -> [CallStart] {
        var result: [CallStart] = []
        var idx = start
        while idx < chars.count {
            guard chars[idx] == "\\", idx + 1 < chars.count else {
                idx += 1
                continue
            }
            guard chars[idx + 1].isLetter else {
                idx += 2
                continue
            }
            let (word, after) = LaTeXMacroExpander.readControlWord(chars, at: idx)
            let hasStar = after < chars.count && chars[after] == "*"
            let name = String(word.dropFirst())
            if let (def, consumesStar) = LaTeXProseMacroExpander.definition(forCall: name + (hasStar ? "*" : ""), in: macros),
                def.argCount > 0 || def.parameterText != nil
            {
                result.append(CallStart(position: idx, afterName: consumesStar ? after + 1 : after, definition: def, builtin: nil))
            } else if multiLineBuiltinBoxes.contains(name) {
                result.append(CallStart(position: idx, afterName: after, definition: nil, builtin: name))
            }
            idx = after
        }
        return result
    }

    /// Built-in boxes whose content argument may continue on later lines.
    private static let multiLineBuiltinBoxes: Set<String> = ["makebox", "mbox", "fbox", "framebox", "parbox", "raisebox", "reflectbox"]

    /// True when the call's arguments may continue past the end of `chars`, one line.
    private static func needsFollowingLines(_ chars: [Character], call: CallStart, macros: [String: LaTeXMacroDefinition]) -> Bool {
        guard let end = callEnd(chars, call: call, macros: macros) else { return true }
        return call.definition?.parameterText != nil && end >= chars.count
    }

    /// Where the call's last argument ends, ignoring a trailing whitespace delimiter, or nil when
    /// `chars` does not hold all its arguments.
    private static func callEnd(_ chars: [Character], call: CallStart, macros: [String: LaTeXMacroDefinition]) -> Int? {
        if let def = call.definition {
            guard let (spans, end) = LaTeXMacroExpander.readArgumentSpans(for: def, in: chars, from: call.afterName) else { return nil }
            var visibleEnd = end
            while visibleEnd > call.afterName && chars[visibleEnd - 1].isWhitespace { visibleEnd -= 1 }
            return max(visibleEnd, spans.compactMap { $0.raw?.upperBound }.max() ?? visibleEnd)
        }
        // A built-in box: the last braced group of the adjacent groups after the name.
        var idx = call.afterName
        var end: Int?
        while true {
            let probe = LaTeXMacroExpander.skipSpaces(chars, from: idx)
            if let (_, after) = LaTeXMacroExpander.readBracketGroup(chars, at: probe) {
                idx = after
            } else if let (_, after) = LaTeXMacroExpander.readBracedGroup(chars, at: probe) {
                idx = after
                end = after
            } else if probe < chars.count && chars[probe] == "{" {
                return nil
            } else {
                return end
            }
        }
    }

    /// The lines that a call starting at `start` may span.
    private static func probeWindow(from start: Int, nsString: NSString) -> NSRange {
        var end = start
        var lines = 0
        while end < nsString.length && lines < MultiLineCallLimits.maxLines {
            let lineRange = nsString.lineRange(for: NSRange(location: end, length: 0))
            let content = MarkdownLiveStyler.strippedLineContentRange(nsString: nsString, lineRange: lineRange)
            if lines > 0 && nsString.substring(with: content).trimmingCharacters(in: .whitespaces).isEmpty { break }
            guard NSMaxRange(lineRange) - start <= MultiLineCallLimits.maxCharacters || lines == 0 else { break }
            end = NSMaxRange(lineRange)
            lines += 1
        }
        return NSRange(location: start, length: end - start)
    }

    /// The end of the text that decided `window`: the window and the line that stopped it, such
    /// as the blank line that ends the paragraph.
    private static func windowContextEnd(_ window: NSRange, nsString: NSString) -> Int {
        guard NSMaxRange(window) < nsString.length else { return NSMaxRange(window) }
        return NSMaxRange(nsString.lineRange(for: NSRange(location: NSMaxRange(window), length: 0)))
    }

    /// `text` with each `%` comment replaced by spaces, so UTF-16 offsets stay the same.
    static func maskedComments(_ text: String) -> String {
        guard text.contains("%") else { return text }
        var units = Array(text.utf16)
        var idx = 0
        var inComment = false
        while idx < units.count {
            let unit = units[idx]
            if unit == 0x0A {
                inComment = false
            } else if inComment {
                units[idx] = 0x20
            } else if unit == 0x5C {
                idx += 2
                continue
            } else if unit == 0x25 {
                inComment = true
                units[idx] = 0x20
            }
            idx += 1
        }
        return String(utf16CodeUnits: units, count: units.count)
    }

    /// Styles a macro call that spans `blockRange`. When the block is active or pretty mode is
    /// off, each line shows its source. Otherwise the lines join into one paragraph, as TeX
    /// reads them, and the inline styler renders the call.
    static func styleMultiLineCallBlock(
        _ blockRange: NSRange,
        in storage: NSTextStorage,
        string: String,
        nsString: NSString,
        activeLineRange: NSRange,
        selectedRange: NSRange,
        docIndex: LaTeXDocumentIndex,
        theme: EditorTheme,
        baseFont: NSFont,
        flowStyle: LaTeXProseStyle,
        prettyMode: Bool,
        focusMode: Bool,
        baseDirectoryURL: URL?,
        decorations: inout [LineDecoration]
    ) -> (nextIndex: Int, lineDelta: Int) {
        let firstLine = nsString.lineRange(for: NSRange(location: blockRange.location, length: 0))
        if blockRange.length > firstLine.length {
            LaTeXBlockStyleCache.resetAttributes(
                in: storage, range: NSRange(location: NSMaxRange(firstLine), length: blockRange.length - firstLine.length)
            )
        }
        var lines: [NSRange] = []
        var scan = blockRange.location
        while scan < NSMaxRange(blockRange) {
            let lineRange = nsString.lineRange(for: NSRange(location: scan, length: 0))
            lines.append(lineRange)
            scan = NSMaxRange(lineRange)
        }
        let isActive = LaTeXBlockStyleCache.isBlockActive(range: blockRange, activeLineRange: activeLineRange, selectedRange: selectedRange)
        let dimFactor: CGFloat = (focusMode && !isActive) ? 0.30 : 1.0
        LaTeXBlockStyleCache.pendingGlyphInvalidationRanges.append(blockRange)
        if isActive || !prettyMode {
            for lineRange in lines {
                styleLaTeXInlineContent(
                    in: storage, string: string, nsString: nsString,
                    range: MarkdownLiveStyler.strippedLineContentRange(nsString: nsString, lineRange: lineRange), lineRange: lineRange,
                    baseFont: baseFont, isActiveLine: true, docIndex: docIndex, theme: theme, dimFactor: dimFactor,
                    prettyMode: prettyMode, baseDirectoryURL: baseDirectoryURL, flowStyle: flowStyle, decorations: &decorations
                )
            }
            return (NSMaxRange(blockRange), lines.count)
        }
        storage.addAttribute(.font, value: baseFont, range: blockRange)
        for (index, lineRange) in lines.enumerated() where index > 0 {
            let newline = NSRange(location: lineRange.location - 1, length: 1)
            storage.addAttribute(MarkdownLiveStyler.softLineBreakAttributeKey, value: true, range: newline)
            var indentEnd = lineRange.location
            while indentEnd < NSMaxRange(lineRange) {
                let ch = nsString.character(at: indentEnd)
                guard ch == 0x20 || ch == 0x09 else { break }
                indentEnd += 1
            }
            MarkdownLiveStyler.collapseWhitespaceRange(in: storage, range: NSRange(location: lineRange.location, length: indentEnd - lineRange.location))
        }
        let firstContent = MarkdownLiveStyler.strippedLineContentRange(nsString: nsString, lineRange: lines[0])
        let lastContent = MarkdownLiveStyler.strippedLineContentRange(nsString: nsString, lineRange: lines[lines.count - 1])
        let content = NSRange(location: firstContent.location, length: NSMaxRange(lastContent) - firstContent.location)
        styleLaTeXInlineContent(
            in: storage, string: string, nsString: nsString, range: content, lineRange: blockRange,
            baseFont: baseFont, isActiveLine: false, docIndex: docIndex, theme: theme, dimFactor: dimFactor,
            prettyMode: prettyMode, baseDirectoryURL: baseDirectoryURL, flowStyle: flowStyle, decorations: &decorations
        )
        // A line break inside an atomic span, such as stacked alternatives, takes no width.
        for lineRange in lines.dropFirst() {
            let newline = lineRange.location - 1
            if storage.attribute(MKey.inlineMathSpan, at: newline, effectiveRange: nil) != nil {
                storage.addAttribute(MKey.collapsed, value: true, range: NSRange(location: newline, length: 1))
            }
        }
        return (NSMaxRange(blockRange), lines.count)
    }
}
