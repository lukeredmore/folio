import AppKit
import Foundation

extension LaTeXLiveStyler {

    static func extractLaTeXOutlineHeadings(docIndex: LaTeXDocumentIndex) -> [OutlineHeading] {
        let sortedLocs = docIndex.lineSectionNumbers.keys.sorted()
        var result: [OutlineHeading] = []
        for (i, loc) in sortedLocs.enumerated() {
            guard let info = docIndex.lineSectionNumbers[loc] else { continue }
            let display = info.number.isEmpty ? info.title : "\(info.number) \(info.title)"
            result.append(
                OutlineHeading(
                    level: info.level,
                    title: display,
                    characterLocation: loc,
                    lineNumber: i + 1
                ))
        }
        return result
    }

    static func styleLaTeXDocumentBody(
        in storage: NSTextStorage,
        string: String,
        nsString: NSString,
        fullLength: Int,
        docIndex: LaTeXDocumentIndex,
        activeLineRange: NSRange,
        selectedRange: NSRange,
        theme: EditorTheme,
        typography: EditorTypographySettings,
        textAlignment: NSTextAlignment,
        baseFont: NSFont,
        effectiveBaseSize: CGFloat,
        effectiveContainerWidth: CGFloat,
        prettyMode: Bool,
        focusMode: Bool,
        baseDirectoryURL: URL?,
        session: (entry: LaTeXBlockStyleCache.StorageEntry, diff: LaTeXBlockStyleCache.DiffWindow)?,
        headings: inout [OutlineHeading],
        decorations: inout [LineDecoration],
        recordedBlocks: inout [LaTeXBlockStyleCache.CachedBlock]
    ) {
        var charIndex = 0
        var lineNumber = 1
        var flow = LaTeXFlowState()

        // 1. Collapsible Preamble Banner Card (\documentclass ... \begin{document})
        if let preambleRange = docIndex.preambleRange, preambleRange.location == 0, preambleRange.length > 0 {
            if let reused = LaTeXBlockStyleCache.tryReuseBlock(
                at: 0,
                lineNumber: lineNumber,
                in: storage,
                fullLength: fullLength,
                activeLineRange: activeLineRange,
                selectedRange: selectedRange,
                focusMode: focusMode,
                session: session,
                flow: &flow,
                headings: &headings,
                decorations: &decorations,
                recordedBlocks: &recordedBlocks
            ) {
                charIndex = reused.nextIndex
                lineNumber += reused.lineDelta
            } else {
                if session != nil {
                    LaTeXBlockStyleCache.resetAttributes(in: storage, range: preambleRange)
                }
                let hStart = headings.count
                let dStart = decorations.count
                let isPreambleActive = MarkdownLiveStyler.isLineActive(
                    lineRange: preambleRange,
                    activeLineRange: activeLineRange,
                    selectedRange: selectedRange
                )
                let dimFactor: CGFloat = (focusMode && !isPreambleActive) ? 0.30 : 1.0
                storage.addAttribute(MKey.noSpellCheck, value: true, range: preambleRange)

                var pLines: [NSRange] = []
                var scan = preambleRange.location
                while scan < NSMaxRange(preambleRange) {
                    let lr = nsString.lineRange(for: NSRange(location: scan, length: 0))
                    pLines.append(lr)
                    scan = NSMaxRange(lr)
                }

                if !isPreambleActive && prettyMode {
                    let targetHeight: CGFloat = 42.0
                    let perLineH = max(2.0, targetHeight / CGFloat(max(1, pLines.count)))
                    let tinyFont = NSFont.systemFont(ofSize: min(effectiveBaseSize, max(2.0, perLineH * 0.5)))
                    for lr in pLines {
                        let pStyle = NSMutableParagraphStyle()
                        pStyle.minimumLineHeight = perLineH
                        pStyle.maximumLineHeight = perLineH
                        pStyle.lineSpacing = 0
                        pStyle.paragraphSpacing = 0
                        pStyle.paragraphSpacingBefore = 0
                        pStyle.lineBreakMode = .byClipping
                        pStyle.tailIndent = effectiveContainerWidth
                        storage.addAttributes(
                            [
                                .font: tinyFont,
                                .foregroundColor: NSColor.clear,
                                .paragraphStyle: pStyle,
                                .kern: 0.0
                            ], range: lr)
                    }
                    decorations.append(
                        LineDecoration(
                            lineRange: preambleRange,
                            kind: .latexPreambleCard(
                                title: docIndex.preambleSummaryTitle,
                                subtitle: docIndex.preambleSummarySubtitle,
                                fullBlockRange: preambleRange,
                                dimFactor: dimFactor
                            )
                        ))
                } else {
                    let monoFont = theme.codeFont(size: effectiveBaseSize * 0.88)
                    for (i, lr) in pLines.enumerated() {
                        let pStyle = NSMutableParagraphStyle()
                        pStyle.lineSpacing = 2.0
                        pStyle.paragraphSpacing = 1.0
                        pStyle.firstLineHeadIndent = 14.0
                        pStyle.headIndent = 14.0
                        pStyle.tailIndent = effectiveContainerWidth
                        storage.addAttributes(
                            [
                                .font: monoFont,
                                .foregroundColor: theme.textNSColor.withAlphaComponent(dimFactor),
                                .paragraphStyle: pStyle
                            ], range: lr)
                        let kind: BlockDecorationKind =
                            (i == 0)
                            ? .codeFenceStart(language: "latex preamble")
                            : (i == pLines.count - 1 ? .codeFenceEnd : .codeFenceBody)
                        decorations.append(LineDecoration(lineRange: lr, kind: kind))
                    }
                    MarkdownLiveStyler.highlightLaTeXSource(in: storage, range: preambleRange, theme: theme, dimFactor: dimFactor)
                }

                recordedBlocks.append(
                    LaTeXBlockStyleCache.CachedBlock(
                        range: preambleRange,
                        startLineNumber: lineNumber,
                        lineCount: pLines.count,
                        isActive: isPreambleActive,
                        dimFactor: dimFactor,
                        headings: Array(headings[hStart...]),
                        decorations: Array(decorations[dStart...])
                    ))
                charIndex = NSMaxRange(preambleRange)
                lineNumber += pLines.count
            }
        }

        // 2. Main Document Loop
        while charIndex < fullLength {
            if let reused = LaTeXBlockStyleCache.tryReuseBlock(
                at: charIndex,
                lineNumber: lineNumber,
                in: storage,
                fullLength: fullLength,
                activeLineRange: activeLineRange,
                selectedRange: selectedRange,
                focusMode: focusMode,
                session: session,
                flow: &flow,
                headings: &headings,
                decorations: &decorations,
                recordedBlocks: &recordedBlocks
            ) {
                charIndex = reused.nextIndex
                lineNumber += reused.lineDelta
                continue
            }

            let blockStartChar = charIndex
            let blockStartLine = lineNumber
            let hStart = headings.count
            let dStart = decorations.count
            let entryFlow = flow
            let lineRange = nsString.lineRange(for: NSRange(location: charIndex, length: 0))
            if session != nil {
                LaTeXBlockStyleCache.resetAttributes(in: storage, range: lineRange)
            }
            LaTeXBlockStyleCache.currentBlockContext = nil
            let contentRange = MarkdownLiveStyler.strippedLineContentRange(nsString: nsString, lineRange: lineRange)
            let lineText = nsString.substring(with: contentRange)
            let trimmed = lineText.trimmingCharacters(in: .whitespaces)
            let isActive = MarkdownLiveStyler.isLineActive(
                lineRange: lineRange,
                activeLineRange: activeLineRange,
                selectedRange: selectedRange
            )
            let dimFactor: CGFloat = (focusMode && !isActive) ? 0.30 : 1.0
            let code = String(LaTeXFileFacts.stripComment(Substring(trimmed))).trimmingCharacters(in: .whitespaces)
            let layout = LaTeXLayoutLine.analyze(code, macros: docIndex.documentMacros)
            let flowFont = flow.isDefault ? baseFont : proseFont(for: flow.style, baseFont: baseFont, docIndex: docIndex, theme: theme)
            var advance: (nextIndex: Int, lineDelta: Int)
            // Blocks from the block and environment stylers record whether any of their lines is
            // active; the other paths style one line by its own activity.
            var recordsBlockActivity = false

            if isFoldableLayoutBoundaryLine(trimmed) || (layout.isLayoutOnly && !layout.drawsRule) {
                // \begin{document}, \end{document}, and lines that hold only layout commands
                styleDocumentBoundaryLine(
                    in: storage,
                    lineRange: lineRange,
                    contentRange: contentRange,
                    trimmed: trimmed,
                    isActive: isActive,
                    prettyMode: prettyMode,
                    theme: theme,
                    effectiveBaseSize: effectiveBaseSize,
                    effectiveContainerWidth: effectiveContainerWidth,
                    dimFactor: dimFactor
                )
                advance = (NSMaxRange(lineRange), 1)
            } else if layout.isLayoutOnly {
                styleRuleLine(
                    in: storage, lineRange: lineRange, contentRange: contentRange, isActive: isActive, prettyMode: prettyMode,
                    theme: theme, dimFactor: dimFactor, decorations: &decorations
                )
                advance = (NSMaxRange(lineRange), 1)
            } else if let definitionEnd = multiLineDefinitionEnd(lineRange: lineRange, code: code, nsString: nsString) {
                advance = styleDefinitionBlock(
                    NSRange(location: lineRange.location, length: definitionEnd - lineRange.location),
                    in: storage, nsString: nsString, activeLineRange: activeLineRange, selectedRange: selectedRange,
                    theme: theme, prettyMode: prettyMode, focusMode: focusMode, effectiveBaseSize: effectiveBaseSize,
                    effectiveContainerWidth: effectiveContainerWidth
                )
                recordsBlockActivity = true
            } else if let blockEnd = multiLineCallBlockEnd(lineRange: lineRange, trimmed: trimmed, code: code, nsString: nsString, docIndex: docIndex) {
                advance = styleMultiLineCallBlock(
                    NSRange(location: lineRange.location, length: blockEnd - lineRange.location),
                    in: storage, string: string, nsString: nsString, activeLineRange: activeLineRange,
                    selectedRange: selectedRange, docIndex: docIndex, theme: theme, baseFont: flowFont,
                    flowStyle: flow.style, prettyMode: prettyMode, focusMode: focusMode,
                    baseDirectoryURL: baseDirectoryURL, decorations: &decorations
                )
                recordsBlockActivity = true
            } else if let blockAdvance = tryStyleLaTeXBlockOrEnvironment(
                in: storage,
                string: string,
                nsString: nsString,
                fullLength: fullLength,
                lineRange: lineRange,
                contentRange: contentRange,
                lineText: lineText,
                trimmedLine: trimmed,
                lineNumber: lineNumber,
                isActiveLine: isActive,
                activeLineRange: activeLineRange,
                selectedRange: selectedRange,
                docIndex: docIndex,
                theme: theme,
                typography: typography,
                textAlignment: textAlignment,
                baseFont: baseFont,
                effectiveBaseSize: effectiveBaseSize,
                effectiveContainerWidth: effectiveContainerWidth,
                prettyMode: prettyMode,
                focusMode: focusMode,
                dimFactor: dimFactor,
                baseDirectoryURL: baseDirectoryURL,
                flow: flow,
                headings: &headings,
                decorations: &decorations
            ) {
                advance = blockAdvance
                recordsBlockActivity = true
            } else {
                // Standard prose line with LaTeX inline styling
                styleFlowParagraph(in: storage, lineRange: lineRange, font: flowFont, flow: flow, baseFont: baseFont)
                styleLaTeXInlineContent(
                    in: storage,
                    string: string,
                    nsString: nsString,
                    range: contentRange,
                    lineRange: lineRange,
                    baseFont: flowFont,
                    isActiveLine: isActive,
                    docIndex: docIndex,
                    theme: theme,
                    dimFactor: dimFactor,
                    prettyMode: prettyMode,
                    baseDirectoryURL: baseDirectoryURL,
                    flowStyle: flow.style,
                    decorations: &decorations
                )
                advance = (NSMaxRange(lineRange), 1)
            }
            if advance.lineDelta == 1 {
                flow.apply(layout.effects, documentFontSize: docIndex.documentStyle.documentFontSizePt ?? 10)
            }

            let blockRange = NSRange(location: blockStartChar, length: advance.nextIndex - blockStartChar)
            let blockActive = LaTeXBlockStyleCache.isBlockActive(
                range: blockRange,
                activeLineRange: activeLineRange,
                selectedRange: selectedRange
            )
            let blockDim: CGFloat = (focusMode && !blockActive) ? 0.30 : 1.0
            recordedBlocks.append(
                LaTeXBlockStyleCache.CachedBlock(
                    range: blockRange,
                    startLineNumber: blockStartLine,
                    lineCount: advance.lineDelta,
                    isActive: recordsBlockActivity ? blockActive : isActive,
                    dimFactor: recordsBlockActivity ? blockDim : dimFactor,
                    headings: Array(headings[hStart...]),
                    decorations: Array(decorations[dStart...]),
                    context: LaTeXBlockStyleCache.currentBlockContext,
                    entryFlow: entryFlow,
                    exitFlow: flow
                ))
            charIndex = advance.nextIndex
            lineNumber += advance.lineDelta
        }
    }

    /// The end of a multi-line macro call that starts on the line, or nil. Lines that other
    /// stylers own, such as sections, environments, and block-shaped macros (a line that is only
    /// `\name{`), are not probed.
    private static func multiLineCallBlockEnd(
        lineRange: NSRange,
        trimmed: String,
        code: String,
        nsString: NSString,
        docIndex: LaTeXDocumentIndex
    ) -> Int? {
        guard code.contains("\\"), !trimmed.hasPrefix("$$"), !trimmed.hasPrefix("\\["),
            docIndex.lineSectionNumbers[lineRange.location] == nil
        else { return nil }
        if code.hasPrefix("\\") {
            let chars = Array(code)
            let (word, after) = LaTeXMacroExpander.readControlWord(chars, at: 0)
            let name = String(word.dropFirst())
            if multiLineProbeExcludedCommands.contains(name) || name.hasPrefix("if") { return nil }
            var bodyStart = after < chars.count && chars[after] == "*" ? after + 1 : after
            if let (_, afterOption) = LaTeXMacroExpander.readBracketGroup(chars, at: bodyStart) { bodyStart = afterOption }
            if String(chars[bodyStart...]).trimmingCharacters(in: .whitespaces) == "{", let def = docIndex.documentMacros[word],
                def.parameterText == nil, def.argCount >= 1
            {
                return nil
            }
        }
        let probe = probeMultiLineCall(lineRange: lineRange, nsString: nsString, macros: docIndex.documentMacros)
        if probe.contextEnd > NSMaxRange(lineRange) {
            LaTeXBlockStyleCache.noteContext(NSRange(location: lineRange.location, length: probe.contextEnd - lineRange.location))
        }
        return probe.blockEnd
    }

    /// The end of a definition that starts the line and closes on a later line, or nil.
    private static func multiLineDefinitionEnd(lineRange: NSRange, code: String, nsString: NSString) -> Int? {
        guard code.hasPrefix("\\") else { return nil }
        let (word, _) = LaTeXMacroExpander.readControlWord(Array(code.prefix(40)), at: 0)
        guard LaTeXLayoutCommands.definitionCommands.contains(String(word.dropFirst())) else { return nil }
        let probe = probeMultiLineDefinition(lineRange: lineRange, nsString: nsString)
        if probe.contextEnd > NSMaxRange(lineRange) {
            LaTeXBlockStyleCache.noteContext(NSRange(location: lineRange.location, length: probe.contextEnd - lineRange.location))
        }
        return probe.blockEnd
    }

    private static let multiLineProbeExcludedCommands: Set<String> = [
        "begin", "end", "item", "input", "include", "title", "author", "date", "caption", "includegraphics", "maketitle",
        "section", "subsection", "subsubsection", "chapter", "part", "paragraph", "subparagraph", "else", "fi"
    ]

    /// Applies the font and alignment of the open groups to a prose line.
    private static func styleFlowParagraph(in storage: NSTextStorage, lineRange: NSRange, font: NSFont, flow: LaTeXFlowState, baseFont: NSFont) {
        guard !flow.isDefault else { return }
        if font != baseFont { storage.addAttribute(.font, value: font, range: lineRange) }
        guard let alignment = flow.alignment,
            let existing = storage.attribute(.paragraphStyle, at: lineRange.location, effectiveRange: nil) as? NSParagraphStyle,
            let style = existing.mutableCopy() as? NSMutableParagraphStyle
        else { return }
        style.alignment = alignment
        storage.addAttribute(.paragraphStyle, value: style, range: lineRange)
    }

    /// A line that only draws `\rule` or `\hrule` bars shows a horizontal rule.
    private static func styleRuleLine(
        in storage: NSTextStorage,
        lineRange: NSRange,
        contentRange: NSRange,
        isActive: Bool,
        prettyMode: Bool,
        theme: EditorTheme,
        dimFactor: CGFloat,
        decorations: inout [LineDecoration]
    ) {
        storage.addAttribute(MKey.noSpellCheck, value: true, range: lineRange)
        if !isActive && prettyMode {
            MarkdownLiveStyler.collapseWhitespaceRange(in: storage, range: contentRange)
            decorations.append(LineDecoration(lineRange: lineRange, kind: .horizontalRule))
        } else {
            MarkdownLiveStyler.styleSyntaxToken(in: storage, range: contentRange, isActiveLine: true, theme: theme, dimFactor: dimFactor)
        }
    }

    private static func styleDocumentBoundaryLine(
        in storage: NSTextStorage,
        lineRange: NSRange,
        contentRange: NSRange,
        trimmed: String,
        isActive: Bool,
        prettyMode: Bool,
        theme: EditorTheme,
        effectiveBaseSize: CGFloat,
        effectiveContainerWidth: CGFloat,
        dimFactor: CGFloat
    ) {
        storage.addAttribute(MKey.noSpellCheck, value: true, range: lineRange)
        if !isActive && prettyMode {
            let lineH = foldedBoundaryLineHeight(for: trimmed, effectiveBaseSize: effectiveBaseSize)
            let pStyle = NSMutableParagraphStyle()
            pStyle.minimumLineHeight = lineH
            pStyle.maximumLineHeight = lineH
            pStyle.lineSpacing = 0
            pStyle.paragraphSpacing = 0
            pStyle.tailIndent = effectiveContainerWidth
            storage.addAttributes(
                [
                    .font: NSFont.systemFont(ofSize: 2.0),
                    .foregroundColor: NSColor.clear,
                    .paragraphStyle: pStyle
                ], range: lineRange)
        } else {
            storage.addAttributes(
                [
                    .font: theme.codeFont(size: effectiveBaseSize * 0.86),
                    .foregroundColor: theme.markdownTokenNSColor.withAlphaComponent(0.85 * dimFactor)
                ], range: contentRange)
        }
    }
}
