import AppKit
import FolioEngineFFI
import Foundation

extension LaTeXStylePass {

    static let displayMathEnvironments: Set<String> = [
        "equation", "equation*", "align", "align*", "gather", "gather*",
        "multline", "multline*", "flalign", "flalign*", "alignat", "alignat*"
    ]

    static let foldOnlyWrapperEnvironments: Set<String> = [
        "itemize", "enumerate", "description",
        "figure", "figure*", "table", "table*"
    ]

    static let codeBlockEnvironments: Set<String> = [
        "verbatim", "lstlisting", "minted"
    ]

    static let italicTheoremEnvironments: Set<String> = [
        "theorem", "lemma", "proposition", "corollary", "claim", "conjecture"
    ]

    mutating func styleDisplayMathBlock(
        lineRange: NSRange,
        contentRange: NSRange,
        lineText: String,
        trimmedLine: String,
        closeToken: String,
        envName: String?,
        equationNumber: String?,
        isActiveLine: Bool,
        limit: Int
    ) -> (nextIndex: Int, lineDelta: Int) {
        var mathLines: [(lineRange: NSRange, contentRange: NSRange, text: String, isActive: Bool)] = [
            (lineRange, contentRange, lineText, isActiveLine)
        ]

        var scanIndex = NSMaxRange(lineRange)
        var scanLineCount = 1
        let openToken: String
        if let envName {
            openToken = "\\begin{\(envName)}"
        } else if trimmedLine.hasPrefix("\\[") {
            openToken = "\\["
        } else {
            openToken = "$$"
        }

        let openCode = LaTeXLexer.stripLineComment(trimmedLine).trimmingCharacters(in: .whitespaces)
        let isSingleLine =
            openCode.count > (openToken.count + closeToken.count)
            && openCode.hasSuffix(closeToken)

        if !isSingleLine {
            while scanIndex < limit {
                let nextLR = nsString.lineRange(for: NSRange(location: scanIndex, length: 0))
                let nextCR = MarkdownLiveStyler.strippedLineContentRange(nsString: nsString, lineRange: nextLR)
                let nextText = nsString.substring(with: nextCR)
                let nextActive = MarkdownLiveStyler.isLineActive(
                    lineRange: nextLR,
                    activeLineRange: activeLineRange,
                    selectedRange: selectedRange
                )
                mathLines.append((nextLR, nextCR, nextText, nextActive))
                scanIndex = NSMaxRange(nextLR)
                scanLineCount += 1
                let nextCode = LaTeXLexer.stripLineComment(nextText).trimmingCharacters(in: .whitespaces)
                if nextCode.hasPrefix(closeToken) || nextCode.hasSuffix(closeToken) {
                    break
                }
            }
        }

        let fullBlockRange = NSRange(location: lineRange.location, length: scanIndex - lineRange.location)
        if fullBlockRange.length > lineRange.length {
            resetAttributes(range: NSRange(location: NSMaxRange(lineRange), length: fullBlockRange.length - lineRange.length))
        }
        storage.addAttribute(MKey.noSpellCheck, value: true, range: fullBlockRange)

        let isMathBlockActive = mathLines.contains(where: { $0.isActive }) || NSIntersectionRange(fullBlockRange, selectedRange).length > 0
        let blockDim: CGFloat = (focusMode && !isMathBlockActive) ? 0.30 : 1.0

        var latexParts: [String] = []
        for (idx, mLine) in mathLines.enumerated() {
            let cleanLine = LaTeXLexer.stripLineComment(mLine.text)
            let t = cleanLine.trimmingCharacters(in: .whitespaces)
            if isSingleLine {
                let inner = String(t.dropFirst(openToken.count).dropLast(closeToken.count))
                    .trimmingCharacters(in: .whitespaces)
                latexParts.append(inner)
                decorations.append(LineDecoration(lineRange: mLine.lineRange, kind: .mathBlockBody(isActive: isMathBlockActive)))
            } else if idx == 0 {
                let afterOpen = String(t.dropFirst(openToken.count)).trimmingCharacters(in: .whitespaces)
                if !afterOpen.isEmpty { latexParts.append(afterOpen) }
                decorations.append(LineDecoration(lineRange: mLine.lineRange, kind: .mathBlockStart(isActive: isMathBlockActive)))
            } else if idx == mathLines.count - 1 && (t.hasPrefix(closeToken) || t.hasSuffix(closeToken)) {
                if !t.hasPrefix(closeToken) {
                    let beforeClose = String(t.dropLast(closeToken.count)).trimmingCharacters(in: .whitespaces)
                    if !beforeClose.isEmpty { latexParts.append(beforeClose) }
                }
                decorations.append(LineDecoration(lineRange: mLine.lineRange, kind: .mathBlockEnd(isActive: isMathBlockActive)))
            } else {
                latexParts.append(cleanLine)
                decorations.append(LineDecoration(lineRange: mLine.lineRange, kind: .mathBlockBody(isActive: isMathBlockActive)))
            }
        }

        let rawCombined = latexParts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let (cleanedLatex, explicitTag) = Self.normalizeDisplayMathForSwiftMath(rawCombined, envName: envName)
        let resolvedEqNum = explicitTag ?? equationNumber

        if isMathBlockActive {
            for mLine in mathLines {
                let mathMono = theme.codeFont(size: effectiveBaseSize * 0.92)
                let mathPara = NSMutableParagraphStyle()
                mathPara.lineSpacing = 3.5
                mathPara.paragraphSpacing = 2.0
                mathPara.firstLineHeadIndent = 14.0
                mathPara.headIndent = 14.0
                mathPara.tailIndent = effectiveContainerWidth
                storage.addAttributes(
                    [
                        .font: mathMono,
                        .foregroundColor: theme.textNSColor,
                        .paragraphStyle: mathPara,
                        .kern: 0.0
                    ], range: mLine.lineRange)
                MarkdownLiveStyler.highlightLaTeXSource(in: storage, range: mLine.contentRange, theme: theme, dimFactor: 1.0)
            }
        } else {
            let displayLayout = LaTeXMathRenderer.layoutDisplayMath(
                cleanedLatex,
                baseFontSize: effectiveBaseSize
            )
            let totalCardHeight: CGFloat
            if displayLayout.isStandaloneMacroDefinitionBlock {
                totalCardHeight = 26.0
            } else {
                let naturalHeight = ceil(displayLayout.box.totalHeight) + 20.0
                let minBlockHeight = max(effectiveBaseSize * 2.1, 36.0)
                totalCardHeight = max(minBlockHeight, naturalHeight)
            }
            let perLineHeight = max(6.0, ceil(totalCardHeight / CGFloat(max(1, mathLines.count))))
            let hiddenLineFont = theme.bodyFont(size: min(effectiveBaseSize, max(4.0, perLineHeight * 0.55)))

            for mLine in mathLines {
                let mathPara = NSMutableParagraphStyle()
                mathPara.alignment = .center
                mathPara.lineSpacing = 0.0
                mathPara.paragraphSpacingBefore = 0.0
                mathPara.paragraphSpacing = 0.0
                mathPara.minimumLineHeight = perLineHeight
                mathPara.maximumLineHeight = perLineHeight
                mathPara.lineBreakMode = .byClipping
                mathPara.tailIndent = effectiveContainerWidth
                storage.addAttributes(
                    [
                        .font: hiddenLineFont,
                        .foregroundColor: NSColor.clear,
                        .paragraphStyle: mathPara,
                        .kern: 0.0
                    ], range: mLine.lineRange)
            }

            if !cleanedLatex.isEmpty {
                decorations.append(
                    LineDecoration(
                        lineRange: fullBlockRange,
                        kind: .mathBlockRendered(latex: cleanedLatex, fullBlockRange: fullBlockRange, dimFactor: blockDim)
                    ))
                if let eqNum = resolvedEqNum, !eqNum.isEmpty {
                    decorations.append(
                        LineDecoration(
                            lineRange: fullBlockRange,
                            kind: .latexEquationNumber(number: "(\(eqNum))", fullBlockRange: fullBlockRange, dimFactor: blockDim)
                        ))
                }
            }
        }

        return (scanIndex, scanLineCount)
    }

    static func normalizeDisplayMathForSwiftMath(_ raw: String, envName: String?) -> (latex: String, explicitTag: String?) {
        let envStr = envName ?? ""
        let res = raw.withCString { rawPtr in
            envStr.withCString { envPtr in
                ot_engine_normalize_display_math(rawPtr, envPtr)
            }
        }
        defer { ot_engine_free_normalized_display_math(res) }
        let cleaned = res.cleaned_latex.map { String(cString: $0) } ?? ""
        let rawTag = res.explicit_tag.map { String(cString: $0) } ?? ""
        return (cleaned, rawTag.isEmpty ? nil : rawTag)
    }

    mutating func tryStyleEnvironmentBlock(
        envName: String,
        lineRange: NSRange,
        contentRange: NSRange,
        lineText: String,
        trimmedLine: String,
        isActiveLine: Bool,
        flow: LaTeXFlowState
    ) -> (nextIndex: Int, lineDelta: Int)? {
        let dimFactor: CGFloat = (focusMode && !isActiveLine) ? 0.30 : 1.0

        if Self.foldOnlyWrapperEnvironments.contains(envName) {
            styleBoundaryLine(lineRange: lineRange, contentRange: contentRange, isActive: isActiveLine, dimFactor: dimFactor)
            return (NSMaxRange(lineRange), 1)
        }

        let isCodeEnv = Self.codeBlockEnvironments.contains(envName)
        let closeToken = "\\end{\(envName)}"
        var envLines: [(lineRange: NSRange, contentRange: NSRange, text: String, isActive: Bool)] = [
            (lineRange, contentRange, lineText, isActiveLine)
        ]
        var scanIndex = NSMaxRange(lineRange)
        var scanLineCount = 1

        let openToken = "\\begin{\(envName)}"
        var depth = 1
        let openCheck = isCodeEnv ? trimmedLine : LaTeXLexer.stripLineComment(trimmedLine).trimmingCharacters(in: .whitespaces)
        if !openCheck.hasSuffix(closeToken) {
            while scanIndex < fullLength {
                let nextLR = nsString.lineRange(for: NSRange(location: scanIndex, length: 0))
                let nextCR = MarkdownLiveStyler.strippedLineContentRange(nsString: nsString, lineRange: nextLR)
                let nextText = nsString.substring(with: nextCR)
                let nextActive = MarkdownLiveStyler.isLineActive(
                    lineRange: nextLR,
                    activeLineRange: activeLineRange,
                    selectedRange: selectedRange
                )
                envLines.append((nextLR, nextCR, nextText, nextActive))
                scanIndex = NSMaxRange(nextLR)
                scanLineCount += 1
                let nt = (isCodeEnv ? nextText : LaTeXLexer.stripLineComment(nextText)).trimmingCharacters(in: .whitespaces)
                if nt.hasPrefix(openToken) && !nt.hasSuffix(closeToken) {
                    depth += 1
                } else if nt.hasPrefix(closeToken) || nt.hasSuffix(closeToken) {
                    depth -= 1
                    if depth == 0 { break }
                }
            }
        }

        let fullBlockRange = NSRange(location: lineRange.location, length: scanIndex - lineRange.location)
        let isBlockActive = envLines.contains(where: { $0.isActive }) || NSIntersectionRange(fullBlockRange, selectedRange).length > 0
        let blockDim: CGFloat = (focusMode && !isBlockActive) ? 0.30 : 1.0

        if isCodeEnv {
            if fullBlockRange.length > lineRange.length {
                resetAttributes(range: NSRange(location: NSMaxRange(lineRange), length: fullBlockRange.length - lineRange.length))
            }
            storage.addAttribute(MKey.noSpellCheck, value: true, range: fullBlockRange)
            let monoFont = theme.codeFont(size: effectiveBaseSize * 0.90)
            for (i, el) in envLines.enumerated() {
                let pStyle = NSMutableParagraphStyle()
                pStyle.lineSpacing = 3.0
                pStyle.firstLineHeadIndent = 14.0
                pStyle.headIndent = 14.0
                pStyle.tailIndent = effectiveContainerWidth
                storage.addAttributes(
                    [
                        .font: monoFont,
                        .foregroundColor: theme.textNSColor.withAlphaComponent(blockDim),
                        .paragraphStyle: pStyle
                    ], range: el.lineRange)
                if (i == 0 || i == envLines.count - 1) && !isBlockActive && prettyMode {
                    MarkdownLiveStyler.collapseWhitespaceRange(in: storage, range: el.contentRange)
                }
                let kind: BlockDecorationKind =
                    (i == 0)
                    ? .codeFenceStart(language: envName)
                    : (i == envLines.count - 1 ? .codeFenceEnd : .codeFenceBody)
                decorations.append(LineDecoration(lineRange: el.lineRange, kind: kind))
            }
            return (scanIndex, scanLineCount)
        }

        if envName == "center" {
            if fullBlockRange.length > lineRange.length {
                resetAttributes(range: NSRange(location: NSMaxRange(lineRange), length: fullBlockRange.length - lineRange.length))
            }
            styleCenterEnvironmentLines(
                envLines: envLines,
                flow: flow,
                fullBlockRange: fullBlockRange,
                isBlockActive: isBlockActive,
                blockDim: blockDim
            )
            return (scanIndex, scanLineCount)
        }

        if envName == "abstract" || envName == "quote" || envName == "quotation"
            || LaTeXDocumentIndexer.theoremEnvironments[envName] != nil || envName == "proof"
        {
            if fullBlockRange.length > lineRange.length {
                resetAttributes(range: NSRange(location: NSMaxRange(lineRange), length: fullBlockRange.length - lineRange.length))
            }
            styleStructuredEnvironmentLines(
                envName: envName,
                envLines: envLines,
                fullBlockRange: fullBlockRange,
                isBlockActive: isBlockActive,
                blockDim: blockDim
            )
            return (scanIndex, scanLineCount)
        }

        if isUserEnvironmentBoundaryLine(trimmedLine, envName: envName) {
            styleBoundaryLine(lineRange: lineRange, contentRange: contentRange, isActive: isActiveLine, dimFactor: dimFactor)
            return (NSMaxRange(lineRange), 1)
        }
        return nil
    }

    private mutating func styleStructuredEnvironmentLines(
        envName: String,
        envLines: [(lineRange: NSRange, contentRange: NSRange, text: String, isActive: Bool)],
        fullBlockRange: NSRange,
        isBlockActive: Bool,
        blockDim: CGFloat
    ) {
        _ = isBlockActive
        let isAbstract = (envName == "abstract")
        let isQuote = (envName == "quote" || envName == "quotation")
        let isTheoremOrProof = !isAbstract && !isQuote
        let isItalicBody = Self.italicTheoremEnvironments.contains(envName)
        let bodyFont =
            isItalicBody
            ? docIndex.bodyFont(size: effectiveBaseSize, italic: true, fallbackTheme: theme)
            : (isAbstract ? docIndex.bodyFont(size: effectiveBaseSize * 0.95, fallbackTheme: theme) : baseFont)
        let indent: CGFloat = isAbstract ? 28.0 : (isQuote ? 20.0 : 18.0)

        for (i, el) in envLines.enumerated() {
            let isFirst = (i == 0)
            let isLast = (i == envLines.count - 1 && envLines.count > 1)

            if (isFirst || isLast) && !el.isActive && prettyMode {
                let headerHeight: CGFloat =
                    isFirst
                    ? (isAbstract ? 26.0 : (isTheoremOrProof ? 26.0 : 6.0))
                    : (envName == "proof" ? 10.0 : 6.0)
                let pStyle = NSMutableParagraphStyle()
                pStyle.minimumLineHeight = headerHeight
                pStyle.maximumLineHeight = headerHeight
                pStyle.lineSpacing = 0
                pStyle.paragraphSpacing = 0
                pStyle.tailIndent = effectiveContainerWidth
                storage.addAttributes(
                    [
                        .font: NSFont.systemFont(ofSize: max(2.0, headerHeight * 0.4)),
                        .foregroundColor: NSColor.clear,
                        .paragraphStyle: pStyle,
                        MKey.noSpellCheck: true
                    ], range: el.lineRange)
                continue
            }

            let pStyle = NSMutableParagraphStyle()
            pStyle.alignment = textAlignment
            pStyle.lineHeightMultiple = docIndex.effectiveLineHeightMultiple(fallback: typography)
            pStyle.lineSpacing = docIndex.effectiveLineSpacing(fallback: typography)
            pStyle.paragraphSpacing = max(3.0, typography.paragraphSpacing * 0.5)
            pStyle.firstLineHeadIndent = indent
            pStyle.headIndent = indent
            pStyle.tailIndent =
                isAbstract
                ? max(120.0, effectiveContainerWidth - 28.0)
                : effectiveContainerWidth

            storage.addAttributes(
                [
                    .font: bodyFont,
                    .foregroundColor: (isQuote ? theme.blockquoteTextNSColor : theme.textNSColor).withAlphaComponent(blockDim),
                    .paragraphStyle: pStyle
                ], range: el.lineRange)

            if (isFirst || isLast) && (el.isActive || !prettyMode) {
                storage.addAttribute(MKey.noSpellCheck, value: true, range: el.lineRange)
                MarkdownLiveStyler.highlightLaTeXSource(in: storage, range: el.contentRange, theme: theme, dimFactor: blockDim)
            } else {
                styleInlineContent(
                    range: el.contentRange,
                    lineRange: el.lineRange,
                    lineFont: bodyFont,
                    isActiveLine: el.isActive,
                    dimFactor: blockDim
                )
            }

            if isQuote {
                decorations.append(LineDecoration(lineRange: el.lineRange, kind: .blockquote(nestLevel: 1)))
            }
        }

        let showHeader = !(envLines.first?.isActive ?? false) && prettyMode
        if isAbstract {
            decorations.append(
                LineDecoration(
                    lineRange: fullBlockRange,
                    kind: .latexAbstractCard(showHeader: showHeader, fullBlockRange: fullBlockRange, dimFactor: blockDim)
                ))
        } else if isTheoremOrProof {
            let header = docIndex.blockTheoremHeaders[envLines[0].lineRange.location]?.header ?? envName.capitalized
            decorations.append(
                LineDecoration(
                    lineRange: fullBlockRange,
                    kind: .latexTheoremCard(
                        header: header,
                        isProof: envName == "proof",
                        showHeader: showHeader,
                        fullBlockRange: fullBlockRange,
                        dimFactor: blockDim
                    )
                ))
        }
    }

    private mutating func styleCenterEnvironmentLines(
        envLines: [(lineRange: NSRange, contentRange: NSRange, text: String, isActive: Bool)],
        flow entryFlow: LaTeXFlowState,
        fullBlockRange: NSRange,
        isBlockActive: Bool,
        blockDim: CGFloat
    ) {
        var condStack: [(cond: Bool, inElse: Bool)] = []
        var collapsedLineRanges: [NSRange] = []
        let documentFontSize = docIndex.documentStyle.documentFontSizePt ?? 10
        var flow = entryFlow
        flow.apply([.beginEnvironment("center")], documentFontSize: documentFontSize)
        let wrappers = LaTeXLayoutCommands.flowWrapperEnvironments.union(["center"])

        for (i, el) in envLines.enumerated() {
            let isBoundary = (i == 0 || (i == envLines.count - 1 && envLines.count > 1))
            if isBoundary {
                styleBoundaryLine(
                    lineRange: el.lineRange,
                    contentRange: el.contentRange,
                    isActive: el.isActive,
                    dimFactor: blockDim
                )
                continue
            }
            let trimmed = el.text.trimmingCharacters(in: .whitespacesAndNewlines)
            var isDirective = false
            if let val = Self.parseIfDirective(trimmed, conditionals: docIndex.documentStyle.conditionals) {
                condStack.append((val, false))
                isDirective = true
            } else if Self.isElseDirective(trimmed), !condStack.isEmpty {
                condStack[condStack.count - 1].inElse = true
                isDirective = true
            } else if Self.isFiDirective(trimmed), !condStack.isEmpty {
                condStack.removeLast()
                isDirective = true
            }
            let branchEnabled = condStack.allSatisfy { $0.inElse ? !$0.cond : $0.cond }
            let code = LaTeXLexer.stripLineComment(trimmed).trimmingCharacters(in: .whitespaces)
            let layout = LaTeXLayoutLine.analyze(code, macros: docIndex.documentMacros, wrappers: wrappers)
            if branchEnabled && !isDirective && layout.isLayoutOnly && layout.drawsRule && !isBlockActive && prettyMode {
                MarkdownLiveStyler.collapseWhitespaceRange(in: storage, range: el.contentRange)
                storage.addAttribute(MKey.noSpellCheck, value: true, range: el.lineRange)
                decorations.append(LineDecoration(lineRange: el.lineRange, kind: .horizontalRule))
                continue
            }
            if branchEnabled && !isDirective && layout.isLayoutOnly {
                flow.apply(layout.effects, documentFontSize: documentFontSize)
                isDirective = true
            }
            if isDirective || !branchEnabled {
                styleCollapsedOrDimmedConditionalLine(
                    lineRange: el.lineRange,
                    contentRange: el.contentRange,
                    isDirective: isDirective,
                    isBlockActive: isBlockActive,
                    dimFactor: blockDim
                )
                if !isBlockActive && prettyMode {
                    collapsedLineRanges.append(el.lineRange)
                }
                continue
            }

            let pStyle = NSMutableParagraphStyle()
            pStyle.alignment = .center
            pStyle.lineHeightMultiple = docIndex.effectiveLineHeightMultiple(fallback: typography)
            pStyle.lineSpacing = docIndex.effectiveLineSpacing(fallback: typography)
            pStyle.paragraphSpacing = max(3.0, typography.paragraphSpacing * 0.5)
            pStyle.tailIndent = effectiveContainerWidth
            let lineFont =
                flow.style == LaTeXProseStyle()
                ? baseFont
                : Self.proseFont(for: flow.style, baseFont: baseFont, docIndex: docIndex, theme: theme)
            storage.addAttributes(
                [
                    .font: lineFont,
                    .foregroundColor: theme.textNSColor.withAlphaComponent(blockDim),
                    .paragraphStyle: pStyle
                ], range: el.lineRange)
            if !el.isActive && prettyMode {
                let indent = el.text.prefix { $0 == " " || $0 == "\t" }.utf16.count
                MarkdownLiveStyler.collapseWhitespaceRange(in: storage, range: NSRange(location: el.contentRange.location, length: indent))
            }
            styleInlineContent(
                range: el.contentRange,
                lineRange: el.lineRange,
                lineFont: lineFont,
                isActiveLine: el.isActive,
                dimFactor: blockDim,
                flowStyle: flow.style
            )
            flow.apply(layout.effects, documentFontSize: documentFontSize)
        }
        collapseContiguousLineRuns(collapsedLineRanges)
        pendingGlyphInvalidationRanges.append(fullBlockRange)
    }

    mutating func tryStyleConditionalBlock(
        lineRange: NSRange,
        contentRange: NSRange,
        lineText: String,
        trimmedLine: String,
        isActiveLine: Bool
    ) -> (nextIndex: Int, lineDelta: Int)? {
        guard let rootVal = Self.parseIfDirective(trimmedLine, conditionals: docIndex.documentStyle.conditionals) else {
            return nil
        }
        var lines: [(lineRange: NSRange, contentRange: NSRange, text: String, trimmed: String, isActive: Bool)] = [
            (lineRange, contentRange, lineText, trimmedLine, isActiveLine)
        ]
        var depth = 1
        var scanIndex = NSMaxRange(lineRange)
        while scanIndex < fullLength && depth > 0 {
            let nextLR = nsString.lineRange(for: NSRange(location: scanIndex, length: 0))
            let nextCR = MarkdownLiveStyler.strippedLineContentRange(nsString: nsString, lineRange: nextLR)
            let nextText = nsString.substring(with: nextCR)
            let nextTrim = nextText.trimmingCharacters(in: .whitespacesAndNewlines)
            let nextAct = MarkdownLiveStyler.isLineActive(lineRange: nextLR, activeLineRange: activeLineRange, selectedRange: selectedRange)
            if Self.parseIfDirective(nextTrim, conditionals: docIndex.documentStyle.conditionals) != nil {
                depth += 1
            } else if Self.isFiDirective(nextTrim) {
                depth -= 1
            }
            lines.append((nextLR, nextCR, nextText, nextTrim, nextAct))
            scanIndex = NSMaxRange(nextLR)
        }
        let fullBlockRange = NSRange(location: lineRange.location, length: scanIndex - lineRange.location)
        if fullBlockRange.length > lineRange.length {
            resetAttributes(range: NSRange(location: NSMaxRange(lineRange), length: fullBlockRange.length - lineRange.length))
        }
        let isBlockActive = LaTeXBlockStyleCache.isBlockActive(range: fullBlockRange, activeLineRange: activeLineRange, selectedRange: selectedRange)
        let blockDim: CGFloat = (focusMode && !isBlockActive) ? 0.30 : 1.0
        var stack: [(cond: Bool, inElse: Bool)] = [(rootVal, false)]
        var collapsedRuns: [NSRange] = []

        for (i, cl) in lines.enumerated() {
            var isDirective = (i == 0)
            if i > 0 {
                if let nested = Self.parseIfDirective(cl.trimmed, conditionals: docIndex.documentStyle.conditionals) {
                    stack.append((nested, false))
                    isDirective = true
                } else if Self.isElseDirective(cl.trimmed), !stack.isEmpty {
                    stack[stack.count - 1].inElse = true
                    isDirective = true
                } else if Self.isFiDirective(cl.trimmed), !stack.isEmpty {
                    stack.removeLast()
                    isDirective = true
                }
            }
            let enabled = stack.allSatisfy { $0.inElse ? !$0.cond : $0.cond }
            if isDirective || !enabled {
                styleCollapsedOrDimmedConditionalLine(
                    lineRange: cl.lineRange,
                    contentRange: cl.contentRange,
                    isDirective: isDirective,
                    isBlockActive: isBlockActive,
                    dimFactor: blockDim
                )
                if !isBlockActive && prettyMode {
                    collapsedRuns.append(cl.lineRange)
                }
            } else {
                styleInlineContent(
                    range: cl.contentRange,
                    lineRange: cl.lineRange,
                    lineFont: baseFont,
                    isActiveLine: cl.isActive,
                    dimFactor: blockDim
                )
            }
        }
        collapseContiguousLineRuns(collapsedRuns)
        pendingGlyphInvalidationRanges.append(fullBlockRange)
        return (scanIndex, lines.count)
    }

    static func parseIfDirective(_ trimmed: String, conditionals: [String: Bool]) -> Bool? {
        guard trimmed.hasPrefix("\\if"), !trimmed.hasPrefix("\\iff") else { return nil }
        let afterIf = trimmed.dropFirst(3)
        let nameChars = afterIf.prefix { ($0 >= "a" && $0 <= "z") || ($0 >= "A" && $0 <= "Z") || $0 == "@" }
        let condName = String(nameChars)
        guard !condName.isEmpty else { return nil }
        let remainder = afterIf.dropFirst(condName.count).trimmingCharacters(in: .whitespaces)
        guard remainder.isEmpty || remainder.hasPrefix("%") else { return nil }
        return conditionals[condName] ?? false
    }

    static func isElseDirective(_ trimmed: String) -> Bool {
        guard trimmed.hasPrefix("\\else") else { return false }
        let rem = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
        return rem.isEmpty || rem.hasPrefix("%")
    }

    static func isFiDirective(_ trimmed: String) -> Bool {
        guard trimmed.hasPrefix("\\fi") else { return false }
        let rem = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
        return rem.isEmpty || rem.hasPrefix("%")
    }

    static func evaluateConditionalsInTeX(_ text: String, conditionals: [String: Bool]) -> String {
        guard text.contains("\\if") else { return text }
        let rawLines = text.components(separatedBy: "\n")
        var output: [String] = []
        var stack: [(cond: Bool, inElse: Bool)] = []
        for rawLine in rawLines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if let val = parseIfDirective(trimmed, conditionals: conditionals) {
                stack.append((val, false))
                continue
            }
            if isElseDirective(trimmed), !stack.isEmpty {
                stack[stack.count - 1].inElse = true
                continue
            }
            if isFiDirective(trimmed), !stack.isEmpty {
                stack.removeLast()
                continue
            }
            let active = stack.allSatisfy { $0.inElse ? !$0.cond : $0.cond }
            if active {
                output.append(rawLine)
            }
        }
        return output.joined(separator: "\n")
    }

    func styleCollapsedOrDimmedConditionalLine(
        lineRange: NSRange,
        contentRange: NSRange,
        isDirective: Bool,
        isBlockActive: Bool,
        dimFactor: CGFloat
    ) {
        storage.addAttribute(MKey.noSpellCheck, value: true, range: lineRange)
        if !isBlockActive && prettyMode {
            let pStyle = NSMutableParagraphStyle()
            pStyle.minimumLineHeight = 0.5
            pStyle.maximumLineHeight = 0.5
            pStyle.lineSpacing = 0
            pStyle.paragraphSpacing = 0
            pStyle.paragraphSpacingBefore = 0
            pStyle.tailIndent = effectiveContainerWidth
            MarkdownLiveStyler.collapseWhitespaceRange(in: storage, range: contentRange)
            storage.addAttributes(
                [
                    .font: NSFont.systemFont(ofSize: 0.1),
                    .foregroundColor: NSColor.clear,
                    .paragraphStyle: pStyle
                ], range: lineRange)
        } else {
            let font = isDirective ? theme.codeFont(size: effectiveBaseSize * 0.86) : baseFont
            let color =
                isDirective
                ? theme.markdownTokenNSColor.withAlphaComponent(0.85 * dimFactor)
                : theme.secondaryTextNSColor.withAlphaComponent(0.65 * dimFactor)
            storage.addAttributes([.font: font, .foregroundColor: color], range: contentRange)
        }
    }

    func collapseContiguousLineRuns(_ ranges: [NSRange]) {
        guard !ranges.isEmpty else { return }
        var runStart = ranges[0].location
        var runEnd = NSMaxRange(ranges[0])
        for r in ranges.dropFirst() {
            if r.location == runEnd {
                runEnd = NSMaxRange(r)
            } else {
                LaTeXBlockStyleCache.collapseInternalNewlines(
                    in: storage, nsString: nsString, range: NSRange(location: runStart, length: runEnd - runStart)
                )
                runStart = r.location
                runEnd = NSMaxRange(r)
            }
        }
        LaTeXBlockStyleCache.collapseInternalNewlines(
            in: storage, nsString: nsString, range: NSRange(location: runStart, length: runEnd - runStart)
        )
    }
}
