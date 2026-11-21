import AppKit
import FolioEngineFFI
import Foundation

struct LaTeXStylePass {
    typealias MKey = LaTeXLiveStyler.MKey

    let storage: NSTextStorage
    let string: String
    let nsString: NSString
    let fullLength: Int
    let docIndex: LaTeXDocumentIndex
    let activeLineRange: NSRange
    let selectedRange: NSRange
    let theme: EditorTheme
    let typography: EditorTypographySettings
    let textAlignment: NSTextAlignment
    let baseFont: NSFont
    let effectiveBaseSize: CGFloat
    let effectiveContainerWidth: CGFloat
    let prettyMode: Bool
    let focusMode: Bool
    let baseDirectoryURL: URL?
    let baseAttributes: [NSAttributedString.Key: Any]
    let session: (entry: LaTeXBlockStyleCache.StorageEntry, diff: LaTeXBlockStyleCache.DiffWindow)?

    var headings: [OutlineHeading] = []
    var decorations: [LineDecoration] = []
    var recordedBlocks: [LaTeXBlockStyleCache.CachedBlock] = []
    var pendingGlyphInvalidationRanges: [NSRange] = []
    var currentBlockContext: NSRange?

    func resetAttributes(range: NSRange) {
        guard range.length > 0, NSMaxRange(range) <= storage.length else { return }
        storage.setAttributes(baseAttributes, range: range)
    }

    mutating func noteContext(_ range: NSRange) {
        currentBlockContext = currentBlockContext.map { NSUnionRange($0, range) } ?? range
    }

    mutating func run() {
        var charIndex = 0
        var lineNumber = 1
        var flow = LaTeXFlowState()
        let storage = self.storage
        let fullLength = self.fullLength
        let activeLineRange = self.activeLineRange
        let selectedRange = self.selectedRange
        let focusMode = self.focusMode
        let session = self.session

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
                let preambleAdv = stylePreambleBlock(preambleRange: preambleRange, startLineNumber: lineNumber)
                charIndex = preambleAdv.nextIndex
                lineNumber += preambleAdv.lineDelta
            }
        }

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
                resetAttributes(range: lineRange)
            }
            currentBlockContext = nil
            let contentRange = MarkdownLiveStyler.strippedLineContentRange(nsString: nsString, lineRange: lineRange)
            let lineText = nsString.substring(with: contentRange)
            let trimmed = lineText.trimmingCharacters(in: .whitespaces)
            let isActive = MarkdownLiveStyler.isLineActive(
                lineRange: lineRange,
                activeLineRange: activeLineRange,
                selectedRange: selectedRange
            )
            let dimFactor: CGFloat = (focusMode && !isActive) ? 0.30 : 1.0
            let code = LaTeXLexer.stripLineComment(trimmed).trimmingCharacters(in: .whitespaces)
            let layout = LaTeXLayoutLine.analyze(code, macros: docIndex.documentMacros)
            let flowFont = flow.isDefault ? baseFont : Self.proseFont(for: flow.style, baseFont: baseFont, docIndex: docIndex, theme: theme)
            let advance: (nextIndex: Int, lineDelta: Int)
            var recordsBlockActivity = false

            if Self.isFoldableLayoutBoundaryLine(trimmed) || (layout.isLayoutOnly && !layout.drawsRule) {
                let lineH = Self.foldedBoundaryLineHeight(for: trimmed, effectiveBaseSize: effectiveBaseSize)
                styleBoundaryLine(
                    lineRange: lineRange,
                    contentRange: contentRange,
                    isActive: isActive,
                    dimFactor: dimFactor,
                    height: lineH
                )
                advance = (NSMaxRange(lineRange), 1)
            } else if layout.isLayoutOnly {
                styleRuleLine(lineRange: lineRange, contentRange: contentRange, isActive: isActive, dimFactor: dimFactor)
                advance = (NSMaxRange(lineRange), 1)
            } else if let definitionEnd = multiLineDefinitionEnd(lineRange: lineRange, code: code) {
                advance = styleDefinitionBlock(NSRange(location: lineRange.location, length: definitionEnd - lineRange.location))
                recordsBlockActivity = true
            } else if let blockEnd = multiLineCallBlockEnd(
                lineRange: lineRange,
                contentRange: contentRange,
                lineText: lineText,
                trimmed: trimmed,
                code: code
            ) {
                advance = styleMultiLineCallBlock(
                    NSRange(location: lineRange.location, length: blockEnd - lineRange.location),
                    lineFont: flowFont,
                    flow: flow
                )
                recordsBlockActivity = true
            } else if let blockAdvance = tryStyleBlockOrEnvironment(
                lineRange: lineRange,
                contentRange: contentRange,
                lineText: lineText,
                trimmedLine: trimmed,
                lineNumber: lineNumber,
                isActiveLine: isActive,
                dimFactor: dimFactor,
                flow: flow
            ) {
                advance = blockAdvance
                recordsBlockActivity = true
            } else {
                styleFlowParagraph(lineRange: lineRange, font: flowFont, flow: flow)
                if !isActive && prettyMode {
                    let indent = lineText.utf16.prefix { $0 == 0x20 || $0 == 0x09 }.count
                    if indent > 0 {
                        MarkdownLiveStyler.collapseWhitespaceRange(
                            in: storage, range: NSRange(location: contentRange.location, length: indent)
                        )
                    }
                }
                styleInlineContent(
                    range: contentRange,
                    lineRange: lineRange,
                    lineFont: flowFont,
                    isActiveLine: isActive,
                    dimFactor: dimFactor,
                    flow: flow
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
                    context: currentBlockContext,
                    entryFlow: entryFlow,
                    exitFlow: flow
                ))
            charIndex = advance.nextIndex
            lineNumber += advance.lineDelta
        }
    }

    private mutating func stylePreambleBlock(preambleRange: NSRange, startLineNumber: Int) -> (nextIndex: Int, lineDelta: Int) {
        if session != nil {
            resetAttributes(range: preambleRange)
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
                startLineNumber: startLineNumber,
                lineCount: pLines.count,
                isActive: isPreambleActive,
                dimFactor: dimFactor,
                headings: Array(headings[hStart...]),
                decorations: Array(decorations[dStart...])
            ))
        return (NSMaxRange(preambleRange), pLines.count)
    }

    mutating func styleBlankLineBlock(
        lineRange: NSRange,
        isActiveLine: Bool,
        limit: Int
    ) -> (nextIndex: Int, lineDelta: Int) {
        var blankRanges: [NSRange] = [lineRange]
        var anyActive = isActiveLine
        var scanIndex = NSMaxRange(lineRange)
        while scanIndex < limit {
            let nextLR = nsString.lineRange(for: NSRange(location: scanIndex, length: 0))
            let nextCR = MarkdownLiveStyler.strippedLineContentRange(nsString: nsString, lineRange: nextLR)
            let nextTrimmed = nsString.substring(with: nextCR).trimmingCharacters(in: .whitespaces)
            guard nextTrimmed.isEmpty else { break }
            if MarkdownLiveStyler.isLineActive(lineRange: nextLR, activeLineRange: activeLineRange, selectedRange: selectedRange) {
                anyActive = true
            }
            blankRanges.append(nextLR)
            scanIndex = NSMaxRange(nextLR)
        }
        let fullBlockRange = NSRange(location: lineRange.location, length: scanIndex - lineRange.location)
        if fullBlockRange.length > lineRange.length {
            resetAttributes(range: NSRange(location: NSMaxRange(lineRange), length: fullBlockRange.length - lineRange.length))
        }
        let isBlockActive = anyActive || NSIntersectionRange(fullBlockRange, selectedRange).length > 0
        var context = fullBlockRange
        let redundant = docIndex.isBlankBlockRedundant(range: fullBlockRange, in: nsString, fullLength: limit, context: &context)
        noteContext(context)
        let parskip = max(2.0, docIndex.effectiveParagraphSpacing(baseSize: effectiveBaseSize, fallback: typography))
        let lineH: CGFloat =
            (!isBlockActive && prettyMode)
            ? (redundant ? 0.5 : parskip)
            : max(parskip, round(effectiveBaseSize * 1.05))
        let pStyle = NSMutableParagraphStyle()
        pStyle.minimumLineHeight = lineH
        pStyle.maximumLineHeight = lineH
        pStyle.lineSpacing = 0
        pStyle.paragraphSpacing = 0
        pStyle.paragraphSpacingBefore = 0
        pStyle.tailIndent = effectiveContainerWidth
        storage.addAttributes(
            [
                .font: NSFont.systemFont(ofSize: max(0.1, min(effectiveBaseSize, lineH * 0.7))),
                .paragraphStyle: pStyle
            ], range: fullBlockRange)
        if !isBlockActive && prettyMode && blankRanges.count > 1 {
            LaTeXBlockStyleCache.collapseInternalNewlines(in: storage, nsString: nsString, range: fullBlockRange)
        }
        pendingGlyphInvalidationRanges.append(fullBlockRange)
        return (scanIndex, blankRanges.count)
    }

    mutating func styleCommentBlock(
        lineRange: NSRange,
        contentRange: NSRange,
        isActiveLine: Bool,
        limit: Int? = nil
    ) -> (nextIndex: Int, lineDelta: Int) {
        let scanLimit = limit ?? fullLength
        var commentLines: [(lineRange: NSRange, contentRange: NSRange, isActive: Bool)] = [
            (lineRange, contentRange, isActiveLine)
        ]
        var pendingBlankLines: [(lineRange: NSRange, contentRange: NSRange, isActive: Bool)] = []
        var scanIndex = NSMaxRange(lineRange)

        while scanIndex < scanLimit {
            let nextLR = nsString.lineRange(for: NSRange(location: scanIndex, length: 0))
            let nextCR = MarkdownLiveStyler.strippedLineContentRange(nsString: nsString, lineRange: nextLR)
            let nextTrimmed = nsString.substring(with: nextCR).trimmingCharacters(in: .whitespaces)
            let nextActive = MarkdownLiveStyler.isLineActive(
                lineRange: nextLR,
                activeLineRange: activeLineRange,
                selectedRange: selectedRange
            )
            if nextTrimmed.hasPrefix("%") {
                commentLines.append(contentsOf: pendingBlankLines)
                pendingBlankLines.removeAll(keepingCapacity: true)
                commentLines.append((nextLR, nextCR, nextActive))
                scanIndex = NSMaxRange(nextLR)
            } else if nextTrimmed.isEmpty {
                pendingBlankLines.append((nextLR, nextCR, nextActive))
                scanIndex = NSMaxRange(nextLR)
            } else {
                break
            }
        }

        let endChar = commentLines.last.map { NSMaxRange($0.lineRange) } ?? NSMaxRange(lineRange)
        let fullBlockRange = NSRange(location: lineRange.location, length: endChar - lineRange.location)
        let readEnd = scanIndex < scanLimit ? NSMaxRange(nsString.lineRange(for: NSRange(location: scanIndex, length: 0))) : scanLimit
        noteContext(NSRange(location: lineRange.location, length: readEnd - lineRange.location))
        if fullBlockRange.length > lineRange.length {
            resetAttributes(range: NSRange(location: NSMaxRange(lineRange), length: fullBlockRange.length - lineRange.length))
        }
        storage.addAttribute(MKey.noSpellCheck, value: true, range: fullBlockRange)

        let isBlockActive = commentLines.contains(where: { $0.isActive }) || NSIntersectionRange(fullBlockRange, selectedRange).length > 0
        let blockDim: CGFloat = (focusMode && !isBlockActive) ? 0.30 : 1.0

        if !isBlockActive && prettyMode {
            let pStyle = NSMutableParagraphStyle()
            pStyle.minimumLineHeight = 0.5
            pStyle.maximumLineHeight = 0.5
            pStyle.lineSpacing = 0
            pStyle.paragraphSpacing = 0
            pStyle.paragraphSpacingBefore = 0
            pStyle.lineBreakMode = .byClipping
            pStyle.tailIndent = effectiveContainerWidth
            storage.addAttributes(
                [
                    .font: NSFont.systemFont(ofSize: 0.1),
                    .foregroundColor: NSColor.clear,
                    .paragraphStyle: pStyle,
                    .kern: 0.0
                ], range: fullBlockRange)
            LaTeXBlockStyleCache.collapseInternalNewlines(in: storage, nsString: nsString, range: fullBlockRange)
        } else {
            let commentFont = theme.bodyFont(size: effectiveBaseSize * 0.92, italic: true)
            for cl in commentLines where cl.contentRange.length > 0 {
                storage.addAttributes(
                    [
                        .font: commentFont,
                        .foregroundColor: theme.secondaryTextNSColor.withAlphaComponent(0.75 * blockDim)
                    ], range: cl.contentRange)
            }
        }
        pendingGlyphInvalidationRanges.append(fullBlockRange)
        return (endChar, commentLines.count)
    }

    mutating func tryStyleBlockOrEnvironment(
        lineRange: NSRange,
        contentRange: NSRange,
        lineText: String,
        trimmedLine: String,
        lineNumber: Int,
        isActiveLine: Bool,
        dimFactor: CGFloat,
        flow: LaTeXFlowState
    ) -> (nextIndex: Int, lineDelta: Int)? {
        if trimmedLine.isEmpty {
            return styleBlankLineBlock(lineRange: lineRange, isActiveLine: isActiveLine, limit: fullLength)
        }
        guard trimmedLine.hasPrefix("\\") || trimmedLine.hasPrefix("$$") || trimmedLine.hasPrefix("%") else { return nil }

        if trimmedLine.hasPrefix("%") {
            return styleCommentBlock(lineRange: lineRange, contentRange: contentRange, isActiveLine: isActiveLine)
        }

        if let secInfo = docIndex.lineSectionNumbers[lineRange.location] {
            let cls = lineText.withCString { ot_engine_classify_latex_line($0) }
            defer { ot_engine_free_latex_line_classification(cls) }
            if cls.kind == 5 && cls.close_len > 0 {
                let innerLocal = NSRange(location: Int(cls.body_loc), length: Int(cls.body_len))
                styleSectionLine(
                    lineRange: lineRange,
                    contentRange: contentRange,
                    innerLocal: innerLocal,
                    secInfo: secInfo,
                    lineNumber: lineNumber,
                    isActiveLine: isActiveLine,
                    dimFactor: dimFactor
                )
                return (NSMaxRange(lineRange), 1)
            }
        }

        let strippedCode = LaTeXLexer.stripLineComment(trimmedLine).trimmingCharacters(in: .whitespaces)
        if trimmedLine == "\\maketitle" || strippedCode == "\\maketitle" || isHeaderBuilderCallLine(strippedCode) {
            styleRuleLine(lineRange: lineRange, contentRange: contentRange, isActive: isActiveLine, dimFactor: dimFactor)
            return (NSMaxRange(lineRange), 1)
        }

        if trimmedLine.hasPrefix("\\title") || trimmedLine.hasPrefix("\\author") || trimmedLine.hasPrefix("\\date") {
            let cls = lineText.withCString { ot_engine_classify_latex_line($0) }
            defer { ot_engine_free_latex_line_classification(cls) }
            let cmd = cls.cmd.map { String(cString: $0) } ?? ""
            if cls.kind == 5 && cls.close_len > 0 && (cmd == "title" || cmd == "author" || cmd == "date") {
                let innerLocal = NSRange(location: Int(cls.body_loc), length: Int(cls.body_len))
                styleFrontmatterLine(
                    lineRange: lineRange,
                    contentRange: contentRange,
                    cmd: cmd,
                    innerLocal: innerLocal,
                    isActiveLine: isActiveLine,
                    dimFactor: dimFactor
                )
                return (NSMaxRange(lineRange), 1)
            }
        }

        if trimmedLine.hasPrefix("\\input") || trimmedLine.hasPrefix("\\include") {
            let cls = lineText.withCString { ot_engine_classify_latex_line($0) }
            defer { ot_engine_free_latex_line_classification(cls) }
            let cmd = cls.cmd.map { String(cString: $0) } ?? ""
            if cls.kind == 5 && cls.close_len > 0 && (cmd == "input" || cmd == "include") {
                let relPath = cls.arg1.map { String(cString: $0) } ?? ""
                styleInputCard(
                    relPath: relPath,
                    lineRange: lineRange,
                    contentRange: contentRange,
                    isActiveLine: isActiveLine,
                    dimFactor: dimFactor
                )
                return (NSMaxRange(lineRange), 1)
            }
        }

        if let sidebarPath = resolveSidebarInputTarget(code: strippedCode) {
            styleInputCard(
                relPath: sidebarPath,
                lineRange: lineRange,
                contentRange: contentRange,
                isActiveLine: isActiveLine,
                dimFactor: dimFactor
            )
            return (NSMaxRange(lineRange), 1)
        }

        if trimmedLine.hasPrefix("$$") || trimmedLine.hasPrefix("\\[") {
            let closeToken = trimmedLine.hasPrefix("\\[") ? "\\]" : "$$"
            return styleDisplayMathBlock(
                lineRange: lineRange,
                contentRange: contentRange,
                lineText: lineText,
                trimmedLine: trimmedLine,
                closeToken: closeToken,
                envName: nil,
                equationNumber: nil,
                isActiveLine: isActiveLine,
                limit: fullLength
            )
        }

        if let envName = LaTeXDocumentIndexer.parseBeginEnvironment(trimmedLine) {
            if Self.displayMathEnvironments.contains(envName) {
                let eqNum = docIndex.blockEquationNumbers[lineRange.location]
                return styleDisplayMathBlock(
                    lineRange: lineRange,
                    contentRange: contentRange,
                    lineText: lineText,
                    trimmedLine: trimmedLine,
                    closeToken: "\\end{\(envName)}",
                    envName: envName,
                    equationNumber: eqNum,
                    isActiveLine: isActiveLine,
                    limit: fullLength
                )
            }
            return tryStyleEnvironmentBlock(
                envName: envName,
                lineRange: lineRange,
                contentRange: contentRange,
                lineText: lineText,
                trimmedLine: trimmedLine,
                isActiveLine: isActiveLine,
                flow: flow
            )
        }

        if let condAdv = tryStyleConditionalBlock(
            lineRange: lineRange,
            contentRange: contentRange,
            lineText: lineText,
            trimmedLine: trimmedLine,
            isActiveLine: isActiveLine
        ) {
            return condAdv
        }

        if let macroAdv = tryStyleMacroBlock(
            lineRange: lineRange,
            contentRange: contentRange,
            lineText: lineText,
            trimmedLine: trimmedLine,
            lineNumber: lineNumber,
            isActiveLine: isActiveLine
        ) {
            return macroAdv
        }

        return tryStyleSingleLineListOrFigureCommand(
            lineRange: lineRange,
            contentRange: contentRange,
            lineText: lineText,
            trimmedLine: trimmedLine,
            isActiveLine: isActiveLine,
            dimFactor: dimFactor,
            flow: flow
        )
    }

    private mutating func styleInputCard(
        relPath: String,
        lineRange: NSRange,
        contentRange: NSRange,
        isActiveLine: Bool,
        dimFactor: CGFloat
    ) {
        let resolvedURL =
            docIndex.inputURLs[relPath] ?? LaTeXDocumentIndexer.defaultTeXFileURL(path: relPath, baseDirectoryURL: baseDirectoryURL)
        storage.addAttribute(MKey.noSpellCheck, value: true, range: lineRange)
        if !isActiveLine && prettyMode {
            let pStyle = NSMutableParagraphStyle()
            pStyle.minimumLineHeight = 34.0
            pStyle.maximumLineHeight = 34.0
            pStyle.tailIndent = effectiveContainerWidth
            storage.addAttributes(
                [
                    .font: NSFont.systemFont(ofSize: 10.0),
                    .foregroundColor: NSColor.clear,
                    .paragraphStyle: pStyle
                ], range: lineRange)
            decorations.append(
                LineDecoration(
                    lineRange: lineRange,
                    kind: .latexInputCard(path: relPath, resolvedURL: resolvedURL, lineRange: lineRange, dimFactor: dimFactor)
                ))
        } else {
            MarkdownLiveStyler.highlightLaTeXSource(in: storage, range: contentRange, theme: theme, dimFactor: dimFactor)
        }
    }

    private func isHeaderBuilderCallLine(_ strippedCode: String) -> Bool {
        guard strippedCode.hasPrefix("\\") else { return false }
        let chars = Array(strippedCode)
        let (word, afterWord) = LaTeXMacroExpander.readControlWord(chars, at: 0)
        guard let def = docIndex.documentMacros[word], LaTeXLayoutLine.isHeaderBuilderMacro(def) else { return false }
        let rest = String(chars[afterWord...]).trimmingCharacters(in: .whitespaces)
        return rest.isEmpty || rest == "{}"
    }

    private func resolveSidebarInputTarget(code: String) -> String? {
        guard code.hasPrefix("\\") else { return nil }
        let chars = Array(code)
        let (word, afterWord) = LaTeXMacroExpander.readControlWord(chars, at: 0)
        guard let def = docIndex.documentMacros[word],
            !def.isEnvironment,
            def.operatorText == nil,
            def.argCount >= 1,
            def.replacement.contains("\\input") || def.replacement.contains("\\addsidebar")
        else { return nil }
        guard let (args, end) = LaTeXMacroExpander.readArguments(for: def, in: chars, from: afterWord),
            end == chars.count
        else { return nil }
        var body = LaTeXMacroExpander.substituteArguments(args, into: def.replacement)
        for _ in 0..<2 {
            let clean = LaTeXLexer.stripLineComment(body).trimmingCharacters(in: .whitespacesAndNewlines)
            if let range = clean.range(of: "\\input{") {
                let afterOpen = range.upperBound
                if let close = clean[afterOpen...].firstIndex(of: "}") {
                    let target = String(clean[afterOpen..<close]).trimmingCharacters(in: .whitespaces)
                    if !target.isEmpty {
                        let withoutInput = clean.replacingCharacters(in: range.lowerBound...close, with: "")
                            .replacingOccurrences(of: "\\ifstrequal", with: "\\@ifstrequal")
                        if !withoutInput.contains("\\LARGE") && !withoutInput.contains("\\Large")
                            && !withoutInput.contains("\\Huge") && !withoutInput.contains("\\huge")
                            && !withoutInput.contains("\\rule")
                            && (withoutInput.contains("\\marginpar") || withoutInput.contains("\\afterpage"))
                        {
                            return target
                        }
                    }
                    return nil
                }
            }
            let (expanded, _) = LaTeXMacroExpander.expandMacrosOnce(in: body, macros: docIndex.documentMacros, maxUTF8Bytes: 4096)
            if expanded == body { break }
            body = expanded
        }
        return nil
    }

    private mutating func styleSectionLine(
        lineRange: NSRange,
        contentRange: NSRange,
        innerLocal: NSRange,
        secInfo: (level: Int, number: String, title: String, starred: Bool),
        lineNumber: Int,
        isActiveLine: Bool,
        dimFactor: CGFloat
    ) {
        let level = secInfo.level
        let headingTitle = secInfo.number.isEmpty ? secInfo.title : "\(secInfo.number) \(secInfo.title)"
        headings.append(
            OutlineHeading(
                level: level,
                title: headingTitle,
                characterLocation: lineRange.location,
                lineNumber: lineNumber
            ))

        let headingFont = docIndex.headingFont(
            level: level,
            scale: typography.fontSizeScale,
            baseSize: effectiveBaseSize,
            fallbackTheme: theme
        )
        let innerRange = NSRange(location: contentRange.location + innerLocal.location, length: innerLocal.length)
        let openSyntaxRange = NSRange(location: contentRange.location, length: innerLocal.location)
        let closeStart = NSMaxRange(innerRange)
        let closeSyntaxRange = NSRange(location: closeStart, length: max(0, NSMaxRange(contentRange) - closeStart))

        let badgeIndent: CGFloat
        if !isActiveLine && !secInfo.number.isEmpty {
            let numWidth = CGFloat(secInfo.number.count) * (headingFont.pointSize * 0.62) + 12.0
            badgeIndent = max(24.0, numWidth)
        } else {
            badgeIndent = 0.0
        }

        let pStyle = NSMutableParagraphStyle()
        pStyle.lineSpacing = max(2.0, typography.lineSpacing * 0.7)
        pStyle.paragraphSpacingBefore = level == 1 ? 16.0 : (level == 2 ? 12.0 : 8.0)
        pStyle.paragraphSpacing = level <= 2 ? 10.0 : 6.0
        pStyle.firstLineHeadIndent = badgeIndent
        pStyle.headIndent = badgeIndent
        pStyle.tailIndent = effectiveContainerWidth

        storage.addAttributes(
            [
                .font: headingFont,
                .foregroundColor: theme.headingNSColor.withAlphaComponent(dimFactor),
                .paragraphStyle: pStyle
            ], range: lineRange)

        MarkdownLiveStyler.styleSyntaxToken(in: storage, range: openSyntaxRange, isActiveLine: isActiveLine, theme: theme, dimFactor: dimFactor)
        MarkdownLiveStyler.styleSyntaxToken(in: storage, range: closeSyntaxRange, isActiveLine: isActiveLine, theme: theme, dimFactor: dimFactor)

        styleInlineContent(
            range: innerRange,
            lineRange: lineRange,
            lineFont: headingFont,
            isActiveLine: isActiveLine,
            dimFactor: dimFactor
        )

        if !isActiveLine && !secInfo.number.isEmpty {
            decorations.append(
                LineDecoration(
                    lineRange: lineRange,
                    kind: .latexSectionBadge(number: secInfo.number, level: level, lineRange: lineRange, dimFactor: dimFactor)
                ))
        }
        if level <= 2 {
            decorations.append(LineDecoration(lineRange: lineRange, kind: .headingUnderline(level: level)))
        }
    }

    private mutating func styleFrontmatterLine(
        lineRange: NSRange,
        contentRange: NSRange,
        cmd: String,
        innerLocal: NSRange,
        isActiveLine: Bool,
        dimFactor: CGFloat
    ) {
        let innerRange = NSRange(location: contentRange.location + innerLocal.location, length: innerLocal.length)
        let openSyntaxRange = NSRange(location: contentRange.location, length: innerLocal.location)
        let closeStart = NSMaxRange(innerRange)
        let closeSyntaxRange = NSRange(location: closeStart, length: max(0, NSMaxRange(contentRange) - closeStart))

        let pStyle = NSMutableParagraphStyle()
        pStyle.alignment = .center
        pStyle.paragraphSpacingBefore = cmd == "title" ? 12.0 : 2.0
        pStyle.paragraphSpacing = cmd == "date" ? 14.0 : 4.0
        pStyle.tailIndent = effectiveContainerWidth

        let font: NSFont
        let color: NSColor
        switch cmd {
        case "title":
            font = docIndex.headingFont(
                level: 1,
                scale: typography.fontSizeScale * 1.05,
                baseSize: effectiveBaseSize * 1.05,
                fallbackTheme: theme
            )
            color = theme.headingNSColor
        case "author":
            font = docIndex.bodyFont(size: effectiveBaseSize * 1.06, semibold: true, fallbackTheme: theme)
            color = theme.textNSColor
        default:
            font = docIndex.bodyFont(size: effectiveBaseSize * 0.94, fallbackTheme: theme)
            color = theme.secondaryTextNSColor
        }

        storage.addAttributes(
            [
                .font: font,
                .foregroundColor: color.withAlphaComponent(dimFactor),
                .paragraphStyle: pStyle
            ], range: lineRange)

        MarkdownLiveStyler.styleSyntaxToken(in: storage, range: openSyntaxRange, isActiveLine: isActiveLine || !prettyMode, theme: theme, dimFactor: dimFactor)
        MarkdownLiveStyler.styleSyntaxToken(in: storage, range: closeSyntaxRange, isActiveLine: isActiveLine || !prettyMode, theme: theme, dimFactor: dimFactor)

        styleInlineContent(
            range: innerRange,
            lineRange: lineRange,
            lineFont: font,
            isActiveLine: isActiveLine,
            dimFactor: dimFactor
        )
    }

    private mutating func tryStyleSingleLineListOrFigureCommand(
        lineRange: NSRange,
        contentRange: NSRange,
        lineText: String,
        trimmedLine: String,
        isActiveLine: Bool,
        dimFactor: CGFloat,
        flow: LaTeXFlowState
    ) -> (nextIndex: Int, lineDelta: Int)? {
        if let endEnv = LaTeXDocumentIndexer.parseEndEnvironment(trimmedLine),
            Self.foldOnlyWrapperEnvironments.contains(endEnv)
                || isUserEnvironmentBoundaryLine(trimmedLine, envName: endEnv)
        {
            styleBoundaryLine(lineRange: lineRange, contentRange: contentRange, isActive: isActiveLine, dimFactor: dimFactor)
            return (NSMaxRange(lineRange), 1)
        }

        guard trimmedLine.hasPrefix("\\") else { return nil }
        let cls = lineText.withCString { ot_engine_classify_latex_line($0) }
        defer { ot_engine_free_latex_line_classification(cls) }

        if cls.kind == 1 {
            styleRuleLine(lineRange: lineRange, contentRange: contentRange, isActive: isActiveLine, dimFactor: dimFactor)
            return (NSMaxRange(lineRange), 1)
        }

        if cls.kind == 2 {
            let itemTokenRange = NSRange(location: contentRange.location + Int(cls.open_loc), length: Int(cls.open_len))
            let spaceRange = NSRange(location: contentRange.location + Int(cls.space_loc), length: Int(cls.space_len))
            let bodyRange = NSRange(location: contentRange.location + Int(cls.body_loc), length: Int(cls.body_len))

            let baseIndent: CGFloat = 14.0
            let textIndent: CGFloat = 28.0
            let pStyle = NSMutableParagraphStyle()
            pStyle.lineHeightMultiple = docIndex.effectiveLineHeightMultiple(fallback: typography)
            pStyle.lineSpacing = docIndex.effectiveLineSpacing(fallback: typography)
            pStyle.paragraphSpacing = max(3.0, typography.paragraphSpacing * 0.45)
            pStyle.firstLineHeadIndent = baseIndent
            pStyle.headIndent = textIndent
            pStyle.tailIndent = effectiveContainerWidth
            storage.addAttribute(.paragraphStyle, value: pStyle, range: lineRange)

            if cls.has_opt_arg {
                let bracketFull = NSRange(
                    location: contentRange.location + Int(cls.opt_loc) - 1,
                    length: Int(cls.opt_len) + 2
                )
                MarkdownLiveStyler.styleSyntaxToken(in: storage, range: itemTokenRange, isActiveLine: isActiveLine, theme: theme, dimFactor: dimFactor)
                storage.addAttribute(.font, value: docIndex.bodyFont(size: effectiveBaseSize, bold: true, fallbackTheme: theme), range: bracketFull)
            } else if !isActiveLine && prettyMode {
                let prefixRange = NSRange(
                    location: contentRange.location,
                    length: NSMaxRange(spaceRange) - contentRange.location
                )
                MarkdownLiveStyler.collapseWhitespaceRange(in: storage, range: prefixRange)
                if prefixRange.length > 0 {
                    storage.addAttribute(
                        .kern,
                        value: textIndent - baseIndent,
                        range: NSRange(location: NSMaxRange(prefixRange) - 1, length: 1)
                    )
                }
                decorations.append(LineDecoration(lineRange: lineRange, kind: .listBullet(range: itemTokenRange, dimFactor: dimFactor)))
            } else {
                MarkdownLiveStyler.styleSyntaxToken(in: storage, range: itemTokenRange, isActiveLine: true, theme: theme, dimFactor: dimFactor)
            }

            let itemFont = flow.isDefault ? baseFont : Self.proseFont(for: flow.style, baseFont: baseFont, docIndex: docIndex, theme: theme)
            styleInlineContent(
                range: bodyRange,
                lineRange: lineRange,
                lineFont: itemFont,
                isActiveLine: isActiveLine,
                dimFactor: dimFactor,
                flow: flow
            )
            return (NSMaxRange(lineRange), 1)
        }

        if cls.kind == 3 {
            let imgPath = cls.arg1.map { String(cString: $0) } ?? ""
            storage.addAttribute(MKey.noSpellCheck, value: true, range: lineRange)
            if !isActiveLine && prettyMode {
                let maxW = max(200.0, effectiveContainerWidth - 40.0)
                let (imgSize, _) = FolioMediaImageCache.shared.displaySize(
                    for: imgPath,
                    maxColumnWidth: maxW,
                    baseDirectoryURL: baseDirectoryURL,
                    isDark: theme.isDark
                )
                let h = max(48.0, ceil(imgSize.height) + 16.0)
                let pStyle = NSMutableParagraphStyle()
                pStyle.minimumLineHeight = h
                pStyle.maximumLineHeight = h
                pStyle.alignment = .center
                pStyle.tailIndent = effectiveContainerWidth
                storage.addAttributes(
                    [
                        .font: NSFont.systemFont(ofSize: 10.0),
                        .foregroundColor: NSColor.clear,
                        .paragraphStyle: pStyle
                    ], range: lineRange)
                decorations.append(
                    LineDecoration(
                        lineRange: lineRange,
                        kind: .imageRendered(
                            url: imgPath,
                            alt: (imgPath as NSString).lastPathComponent,
                            fullRange: contentRange,
                            explicitWidth: nil,
                            explicitHeight: nil,
                            baseDirectoryURL: baseDirectoryURL,
                            dimFactor: dimFactor
                        )
                    ))
            } else {
                MarkdownLiveStyler.highlightLaTeXSource(in: storage, range: contentRange, theme: theme, dimFactor: dimFactor)
            }
            return (NSMaxRange(lineRange), 1)
        }

        if cls.kind == 4 {
            let openRange = NSRange(location: contentRange.location + Int(cls.open_loc), length: Int(cls.open_len))
            let innerRange = NSRange(location: contentRange.location + Int(cls.body_loc), length: Int(cls.body_len))
            let closeRange = NSRange(location: contentRange.location + Int(cls.close_loc), length: Int(cls.close_len))
            let captionFont = docIndex.bodyFont(size: effectiveBaseSize * 0.90, italic: true, fallbackTheme: theme)
            let pStyle = NSMutableParagraphStyle()
            pStyle.alignment = .center
            pStyle.paragraphSpacingBefore = 4.0
            pStyle.paragraphSpacing = 8.0
            pStyle.tailIndent = effectiveContainerWidth
            storage.addAttributes(
                [
                    .font: captionFont,
                    .foregroundColor: theme.secondaryTextNSColor.withAlphaComponent(dimFactor),
                    .paragraphStyle: pStyle
                ], range: lineRange)
            MarkdownLiveStyler.styleSyntaxToken(in: storage, range: openRange, isActiveLine: isActiveLine, theme: theme, dimFactor: dimFactor)
            MarkdownLiveStyler.styleSyntaxToken(in: storage, range: closeRange, isActiveLine: isActiveLine, theme: theme, dimFactor: dimFactor)
            styleInlineContent(
                range: innerRange,
                lineRange: lineRange,
                lineFont: captionFont,
                isActiveLine: isActiveLine,
                dimFactor: dimFactor
            )
            return (NSMaxRange(lineRange), 1)
        }

        return nil
    }

    func styleBoundaryLine(
        lineRange: NSRange,
        contentRange: NSRange,
        isActive: Bool,
        dimFactor: CGFloat,
        height: CGFloat = 4.0
    ) {
        storage.addAttribute(MKey.noSpellCheck, value: true, range: lineRange)
        if !isActive && prettyMode {
            let pStyle = NSMutableParagraphStyle()
            pStyle.minimumLineHeight = height
            pStyle.maximumLineHeight = height
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

    mutating func styleRuleLine(
        lineRange: NSRange,
        contentRange: NSRange,
        isActive: Bool,
        dimFactor: CGFloat
    ) {
        storage.addAttribute(MKey.noSpellCheck, value: true, range: lineRange)
        if !isActive && prettyMode {
            MarkdownLiveStyler.collapseWhitespaceRange(in: storage, range: contentRange)
            decorations.append(LineDecoration(lineRange: lineRange, kind: .horizontalRule))
        } else {
            MarkdownLiveStyler.styleSyntaxToken(in: storage, range: contentRange, isActiveLine: true, theme: theme, dimFactor: dimFactor)
        }
    }

    private func styleFlowParagraph(lineRange: NSRange, font: NSFont, flow: LaTeXFlowState) {
        guard !flow.isDefault else { return }
        if font != baseFont { storage.addAttribute(.font, value: font, range: lineRange) }
        if flow.style.letterSpaceEm != 0 {
            storage.addAttribute(.kern, value: font.pointSize * flow.style.letterSpaceEm, range: lineRange)
        }
        guard let alignment = flow.alignment,
            let existing = storage.attribute(.paragraphStyle, at: lineRange.location, effectiveRange: nil) as? NSParagraphStyle,
            let style = existing.mutableCopy() as? NSMutableParagraphStyle
        else { return }
        style.alignment = alignment
        storage.addAttribute(.paragraphStyle, value: style, range: lineRange)
    }

    static func isFoldableLayoutBoundaryLine(_ trimmed: String) -> Bool {
        guard !trimmed.hasPrefix("%") else { return false }
        let code = LaTeXLexer.stripLineComment(trimmed).trimmingCharacters(in: .whitespaces)
        if code == "\\begin{document}" || code == "\\end{document}" || code == "}" {
            return true
        }
        if code == "\\vfill" || code == "\\newpage" || code == "\\clearpage"
            || code == "\\else" || code == "\\fi"
            || code == "\\answersfalse" || code == "\\answerstrue"
        {
            return true
        }
        if code.hasPrefix("\\vspace") && code.hasSuffix("}") && !code.dropFirst(7).contains("\\") {
            return true
        }
        return code.hasPrefix("\\index{") && isIndexOnlyLine(trimmed)
    }

    static func isIndexOnlyLine(_ trimmed: String) -> Bool {
        let chars = Array(LaTeXLexer.stripLineComment(Substring(trimmed)))
        var idx = LaTeXMacroExpander.skipSpaces(chars, from: 0)
        guard idx < chars.count else { return false }
        while idx < chars.count {
            let (word, after) = LaTeXMacroExpander.readControlWord(chars, at: idx)
            guard word == "\\index", let (_, end) = LaTeXMacroExpander.readBracedGroup(chars, at: after) else { return false }
            idx = LaTeXMacroExpander.skipSpaces(chars, from: end)
        }
        return true
    }

    func isUserEnvironmentBoundaryLine(_ trimmed: String, envName: String) -> Bool {
        guard docIndex.documentMacros[LaTeXMacroDefinition.environmentKey(envName)] != nil else { return false }
        let code = LaTeXLexer.stripLineComment(trimmed).trimmingCharacters(in: .whitespaces)
        if code == "\\end{\(envName)}" { return true }
        let open = "\\begin{\(envName)}"
        guard code.hasPrefix(open) else { return false }
        let chars = Array(code.dropFirst(open.count))
        var idx = 0
        while idx < chars.count {
            idx = LaTeXMacroExpander.skipSpaces(chars, from: idx)
            guard idx < chars.count else { break }
            guard let (_, after) = LaTeXMacroExpander.readBracedGroup(chars, at: idx) ?? LaTeXMacroExpander.readBracketGroup(chars, at: idx)
            else { return false }
            idx = after
        }
        return true
    }

    static func foldedBoundaryLineHeight(for trimmed: String, effectiveBaseSize: CGFloat) -> CGFloat {
        let code = LaTeXLexer.stripLineComment(trimmed).trimmingCharacters(in: .whitespaces)
        if code.hasPrefix("\\vspace"),
            let openBrace = code.firstIndex(of: "{"),
            let closeBrace = code.lastIndex(of: "}"),
            openBrace < closeBrace
        {
            let arg = code[code.index(after: openBrace)..<closeBrace].trimmingCharacters(in: .whitespaces)
            if arg.hasSuffix("em"), let val = Double(arg.dropLast(2)), val > 0 {
                return min(72.0, max(4.0, CGFloat(val) * effectiveBaseSize))
            }
            if arg.hasSuffix("pt"), let val = Double(arg.dropLast(2)), val > 0 {
                return min(72.0, max(4.0, CGFloat(val)))
            }
        }
        return 4.0
    }
}
