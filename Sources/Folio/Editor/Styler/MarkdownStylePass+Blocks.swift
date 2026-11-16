import AppKit
import Foundation

extension MarkdownStylePass {

    // MARK: - Source Code Mode & Fenced Code Blocks

    func styleSourceCodeLine(
        lineText: String,
        contentRange: NSRange,
        lineNumber: Int,
        dimFactor: CGFloat
    ) {
        if !state.inCodeFence,
            let fenceMatch = Styler.codeFenceOpenRegex.firstMatch(in: string, options: [], range: contentRange)
        {
            let markerStr = nsString.substring(with: fenceMatch.range(at: 1))
            let infoStr = nsString.substring(with: fenceMatch.range(at: 2)).trimmingCharacters(in: .whitespaces)
            let fenceChar = markerStr.first ?? "`"
            if !(fenceChar == "`" && infoStr.contains("`")) {
                state.inCodeFence = true
                state.fenceChar = fenceChar
                state.fenceLength = markerStr.count
                state.fenceContainer = Styler.CodeFenceContainer(
                    strippedSpaces: lineText.prefix(while: { $0 == " " }).count,
                    indent: 0
                )
                storage.addAttribute(Styler.noSpellCheckAttributeKey, value: true, range: contentRange)
                if dimFactor < 1.0 {
                    storage.addAttribute(.foregroundColor, value: baseColor.withAlphaComponent(dimFactor), range: contentRange)
                }
                return
            }
        } else if state.inCodeFence {
            let leadingSpaces = lineText.prefix(while: { $0 == " " }).count
            let afterLeading = String(lineText.dropFirst(leadingSpaces))
            let fenceRun = afterLeading.prefix(while: { $0 == state.fenceChar })
            let restAfterFence = afterLeading.dropFirst(fenceRun.count).trimmingCharacters(in: .whitespaces)
            if leadingSpaces <= 3 + state.fenceContainer.strippedSpaces
                && fenceRun.count >= state.fenceLength
                && restAfterFence.isEmpty
            {
                state.inCodeFence = false
            }
            storage.addAttribute(Styler.noSpellCheckAttributeKey, value: true, range: contentRange)
            if dimFactor < 1.0 {
                storage.addAttribute(.foregroundColor, value: baseColor.withAlphaComponent(dimFactor), range: contentRange)
            }
            return
        }

        if let match = Styler.headingRegex.firstMatch(in: string, options: [], range: contentRange),
            match.range(at: 3).location != NSNotFound
                || match.range(at: 2).length == contentRange.length - match.range(at: 1).length
        {
            let level = min(6, max(1, match.range(at: 2).length))
            let titleRange = match.range(at: 4)
            let title =
                titleRange.location != NSNotFound
                ? nsString.substring(with: titleRange).trimmingCharacters(in: .whitespaces)
                : ""
            if !title.isEmpty {
                headings.append(
                    OutlineHeading(
                        level: level,
                        title: title,
                        characterLocation: contentRange.location,
                        lineNumber: lineNumber
                    ))
            }
            storage.addAttribute(
                .foregroundColor,
                value: theme.headingNSColor.withAlphaComponent(dimFactor),
                range: contentRange
            )
            storage.addAttribute(
                .font,
                value: NSFont.monospacedSystemFont(ofSize: effectiveBaseSize, weight: .bold),
                range: contentRange
            )
        } else if dimFactor < 1.0 {
            storage.addAttribute(
                .foregroundColor,
                value: baseColor.withAlphaComponent(dimFactor),
                range: contentRange
            )
        }
    }

    func styleCodeFenceOpening(
        _ fenceMatch: NSTextCheckingResult,
        lineRange: NSRange,
        contentRange: NSRange,
        lineText: String,
        isActiveLine: Bool,
        dimFactor: CGFloat
    ) -> (nextIndex: Int, lineDelta: Int)? {
        let markerStr = nsString.substring(with: fenceMatch.range(at: 1))
        let infoStr = nsString.substring(with: fenceMatch.range(at: 2)).trimmingCharacters(in: .whitespaces)
        let fenceChar = markerStr.first ?? "`"
        guard !(fenceChar == "`" && infoStr.contains("`")) else { return nil }
        let lang = infoStr.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
        let lowerLang = lang.lowercased()
        if prettyMode && (lowerLang == "mermaid" || lowerLang == "svg"),
            let step = tryStyleDiagramCodeFence(
                lineRange: lineRange,
                contentRange: contentRange,
                lineText: lineText,
                isActiveLine: isActiveLine,
                fenceChar: fenceChar,
                openFenceLen: markerStr.count,
                lowerLang: lowerLang
            )
        {
            state.previousListTextIndent = nil
            return step
        }
        state.inCodeFence = true
        state.fenceChar = fenceChar
        state.fenceContainer = Styler.CodeFenceContainer(
            strippedSpaces: lineText.prefix(while: { $0 == " " }).count,
            indent: state.previousListTextIndent ?? 0
        )
        state.fenceLength = markerStr.count
        state.fenceLanguage = lowerLang
        state.previousListTextIndent = nil
        styleCodeFenceDelimiterLine(
            lineRange: lineRange,
            contentRange: contentRange,
            container: state.fenceContainer,
            isClosing: false,
            isActiveLine: isActiveLine,
            dimFactor: dimFactor
        )
        decorations.lines.append(LineDecoration(lineRange: lineRange, kind: .codeFenceStart(language: lang)))
        return (NSMaxRange(lineRange), 1)
    }

    func styleCodeFenceContinuation(
        lineRange: NSRange,
        contentRange: NSRange,
        lineText: String,
        isActiveLine: Bool,
        dimFactor: CGFloat
    ) {
        let leadingSpaces = lineText.prefix(while: { $0 == " " }).count
        let afterLeading = String(lineText.dropFirst(leadingSpaces))
        let fenceRun = afterLeading.prefix(while: { $0 == state.fenceChar })
        let restAfterFence = afterLeading.dropFirst(fenceRun.count).trimmingCharacters(in: .whitespaces)
        let container = state.fenceContainer
        if leadingSpaces <= 3 + container.strippedSpaces && fenceRun.count >= state.fenceLength && restAfterFence.isEmpty {
            state.inCodeFence = false
            state.fenceLanguage = ""
            styleCodeFenceDelimiterLine(
                lineRange: lineRange,
                contentRange: contentRange,
                container: container,
                isClosing: true,
                isActiveLine: isActiveLine,
                dimFactor: dimFactor
            )
            decorations.lines.append(LineDecoration(lineRange: lineRange, kind: .codeFenceEnd))
        } else {
            styleCodeFenceBodyLine(
                lineRange: lineRange,
                contentRange: contentRange,
                container: container,
                language: state.fenceLanguage,
                dimFactor: dimFactor
            )
        }
    }

    private func tryStyleDiagramCodeFence(
        lineRange: NSRange,
        contentRange: NSRange,
        lineText: String,
        isActiveLine: Bool,
        fenceChar: Character,
        openFenceLen: Int,
        lowerLang: String
    ) -> (nextIndex: Int, lineDelta: Int)? {
        var blockLines: [(lineRange: NSRange, contentRange: NSRange, text: String, isActive: Bool)] = [
            (lineRange, contentRange, lineText, isActiveLine)
        ]
        var scanIndex = NSMaxRange(lineRange)
        var scanLineCount = 1
        var foundClosingFence = false

        while scanIndex < fullLength {
            let nextLR = nsString.lineRange(for: NSRange(location: scanIndex, length: 0))
            let nextCR = Styler.strippedLineContentRange(nsString: nsString, lineRange: nextLR)
            let nextText = nsString.substring(with: nextCR)
            let nextActive = Styler.isLineActive(lineRange: nextLR, activeLineRange: activeLineRange, selectedRange: selectedRange)
            blockLines.append((nextLR, nextCR, nextText, nextActive))
            scanIndex = NSMaxRange(nextLR)
            scanLineCount += 1

            let leadingSpaces = nextText.prefix(while: { $0 == " " }).count
            let afterLeading = String(nextText.dropFirst(leadingSpaces))
            let fenceRun = afterLeading.prefix(while: { $0 == fenceChar })
            let restAfterFence = afterLeading.dropFirst(fenceRun.count).trimmingCharacters(in: .whitespaces)
            if leadingSpaces <= 3 && fenceRun.count >= openFenceLen && restAfterFence.isEmpty {
                foundClosingFence = true
                break
            }
        }

        let fullBlockRange = NSRange(location: lineRange.location, length: scanIndex - lineRange.location)
        let isDiagramBlockActive =
            blockLines.contains(where: { $0.isActive })
            || NSIntersectionRange(fullBlockRange, selectedRange).length > 0

        guard foundClosingFence && !isDiagramBlockActive && blockLines.count >= 3 else {
            return nil
        }

        let bodySource =
            blockLines
            .dropFirst()
            .dropLast()
            .map(\.text)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !bodySource.isEmpty else { return nil }

        let blockDim: CGFloat = (focusMode && !isDiagramBlockActive) ? 0.30 : 1.0
        storage.addAttribute(Styler.noSpellCheckAttributeKey, value: true, range: fullBlockRange)
        let diagramImg = DiagramImageRenderer.shared.image(
            for: DiagramImageRenderer.Key(
                kind: lowerLang == "mermaid" ? .mermaid(isDark: theme.isDark) : .svg,
                source: bodySource
            ))
        let availW = max(200.0, effectiveContainerWidth - 32.0)
        let totalCardHeight: CGFloat
        if let img = diagramImg, img.size.width > 0, img.size.height > 0 {
            let scale = min(1.0, availW / img.size.width)
            let naturalH = round(img.size.height * scale) + 28.0
            totalCardHeight = min(640.0, max(96.0, naturalH))
        } else {
            totalCardHeight = lowerLang == "mermaid" ? 220.0 : 190.0
        }
        let perLineHeight = max(6.0, round(totalCardHeight / CGFloat(blockLines.count)))
        collapseCardSourceLines(
            lineRanges: blockLines.map(\.lineRange),
            lineHeights: Array(repeating: perLineHeight, count: blockLines.count),
            minFontSize: 4.0,
            fontScale: 0.6,
            centered: true,
            clipLines: false,
            trailingSpacing: max(6.0, typography.paragraphSpacing * 0.55)
        )

        if lowerLang == "mermaid" {
            decorations.lines.append(
                LineDecoration(
                    lineRange: fullBlockRange,
                    kind: .mermaidBlockRendered(mermaidSource: bodySource, fullBlockRange: fullBlockRange, dimFactor: blockDim)
                ))
        } else {
            decorations.lines.append(
                LineDecoration(
                    lineRange: fullBlockRange,
                    kind: .svgBlockRendered(svgSource: bodySource, fullBlockRange: fullBlockRange, dimFactor: blockDim)
                ))
        }

        return (scanIndex, scanLineCount)
    }

    func styleCodeFenceDelimiterLine(
        lineRange: NSRange,
        contentRange: NSRange,
        container: Styler.CodeFenceContainer,
        isClosing: Bool,
        isActiveLine: Bool,
        dimFactor: CGFloat
    ) {
        let codeMono = theme.codeFont(size: effectiveBaseSize * 0.88)
        let fenceRowHeight: CGFloat = 23.0
        let fencePara = NSMutableParagraphStyle()
        fencePara.lineSpacing = 0.0
        fencePara.paragraphSpacingBefore = 0.0
        fencePara.paragraphSpacing = isClosing ? max(4.0, typography.paragraphSpacing * 0.55) : 0.0
        let fenceIndent = codeFenceContainerLayout(contentRange: contentRange, container: container, font: codeMono)
        fencePara.firstLineHeadIndent = fenceIndent.first
        fencePara.headIndent = fenceIndent.wrapped
        fencePara.minimumLineHeight = fenceRowHeight
        fencePara.maximumLineHeight = fenceRowHeight
        fencePara.tailIndent = effectiveContainerWidth

        storage.addAttributes(
            [
                .font: codeMono,
                .foregroundColor: theme.markdownTokenNSColor.withAlphaComponent(isActiveLine ? 0.9 : 0.45 * dimFactor),
                .paragraphStyle: fencePara,
                .baselineOffset: 0.0,
                .kern: 0.0,
                Styler.noSpellCheckAttributeKey: true
            ], range: lineRange)
        Styler.collapseWhitespaceRange(in: storage, range: fenceIndent.collapsed)
    }

    func styleCodeFenceBodyLine(
        lineRange: NSRange,
        contentRange: NSRange,
        container: Styler.CodeFenceContainer = Styler.CodeFenceContainer(),
        language: String?,
        dimFactor: CGFloat
    ) {
        decorations.lines.append(LineDecoration(lineRange: lineRange, kind: .codeFenceBody))
        let codeMono = theme.codeFont(size: effectiveBaseSize * 0.90)
        let bodyRowHeight: CGFloat = 22.0
        let codePara = NSMutableParagraphStyle()
        codePara.lineSpacing = 0.0
        codePara.paragraphSpacingBefore = 0.0
        codePara.paragraphSpacing = 0.0
        let bodyIndent = codeFenceContainerLayout(contentRange: contentRange, container: container, font: codeMono)
        codePara.firstLineHeadIndent = bodyIndent.first
        codePara.headIndent = bodyIndent.wrapped
        codePara.minimumLineHeight = bodyRowHeight
        codePara.maximumLineHeight = bodyRowHeight
        codePara.tailIndent = effectiveContainerWidth

        storage.addAttributes(
            [
                .font: codeMono,
                .foregroundColor: theme.textNSColor.withAlphaComponent(dimFactor),
                .paragraphStyle: codePara,
                .baselineOffset: 0.0,
                .kern: 0.0,
                Styler.noSpellCheckAttributeKey: true
            ], range: lineRange)

        if let language {
            Styler.highlightCodeLine(
                in: storage,
                string: string,
                range: contentRange,
                language: language,
                theme: theme,
                dimFactor: dimFactor
            )
        }
        Styler.collapseWhitespaceRange(in: storage, range: bodyIndent.collapsed)
    }

    private func codeFenceContainerLayout(
        contentRange: NSRange,
        container: Styler.CodeFenceContainer,
        font: NSFont
    ) -> (first: CGFloat, wrapped: CGFloat, collapsed: NSRange) {
        let text = nsString.substring(with: contentRange)
        let leading = text.prefix(while: { $0 == " " }).count
        let stripped = min(leading, container.strippedSpaces)
        let first = 14.0 + container.indent
        let spaceWidth = (" " as NSString).size(withAttributes: [.font: font]).width
        let wrapped = first + min(CGFloat(leading - stripped) * spaceWidth, 160.0)
        return (first, wrapped, NSRange(location: contentRange.location, length: stripped))
    }

    func styleBlankLine(
        lineRange: NSRange,
        contentRange: NSRange,
        isActiveLine: Bool
    ) {
        let blankPara = NSMutableParagraphStyle()
        let blankH = round(effectiveBaseSize * (isActiveLine ? 1.15 : 0.55))
        blankPara.minimumLineHeight = blankH
        blankPara.maximumLineHeight = blankH
        blankPara.lineSpacing = 0.0
        blankPara.paragraphSpacing = 0.0
        blankPara.paragraphSpacingBefore = 0.0
        blankPara.tailIndent = effectiveContainerWidth
        storage.addAttributes(
            [
                .paragraphStyle: blankPara,
                .kern: 0.0
            ], range: lineRange)
        if !isActiveLine && contentRange.length > 0 {
            Styler.collapseWhitespaceRange(in: storage, range: contentRange)
        }
    }

    // MARK: - Display Math, Raw SVG, and HTML Blocks

    func styleDisplayMathBlock(
        lineRange: NSRange,
        contentRange: NSRange,
        lineText: String,
        trimmedLine: String,
        isActiveLine: Bool
    ) -> (nextIndex: Int, lineDelta: Int) {
        var mathLines: [(lineRange: NSRange, contentRange: NSRange, text: String, isActive: Bool)] = [
            (lineRange, contentRange, lineText, isActiveLine)
        ]

        var scanIndex = NSMaxRange(lineRange)
        var scanLineCount = 1
        let isSingleLineMath = trimmedLine.count > 4 && trimmedLine.hasSuffix("$$")

        if !isSingleLineMath {
            while scanIndex < fullLength {
                let nextLR = nsString.lineRange(for: NSRange(location: scanIndex, length: 0))
                let nextCR = Styler.strippedLineContentRange(nsString: nsString, lineRange: nextLR)
                let nextText = nsString.substring(with: nextCR)
                let nextActive = Styler.isLineActive(lineRange: nextLR, activeLineRange: activeLineRange, selectedRange: selectedRange)
                mathLines.append((nextLR, nextCR, nextText, nextActive))
                scanIndex = NSMaxRange(nextLR)
                scanLineCount += 1
                if nextText.trimmingCharacters(in: .whitespaces).hasPrefix("$$") {
                    break
                }
            }
        }

        let fullBlockRange = NSRange(location: lineRange.location, length: scanIndex - lineRange.location)
        let isMathBlockActive =
            mathLines.contains(where: { $0.isActive })
            || NSIntersectionRange(fullBlockRange, selectedRange).length > 0
        let blockDim: CGFloat = (focusMode && !isMathBlockActive) ? 0.30 : 1.0
        storage.addAttribute(Styler.noSpellCheckAttributeKey, value: true, range: fullBlockRange)

        var latexParts: [String] = []
        for (idx, mLine) in mathLines.enumerated() {
            let t = mLine.text.trimmingCharacters(in: .whitespaces)
            if isSingleLineMath {
                let inner = String(t.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces)
                latexParts.append(inner)
                decorations.lines.append(LineDecoration(lineRange: mLine.lineRange, kind: .mathBlockBody(isActive: isMathBlockActive)))
            } else if idx == 0 {
                let afterFence = String(t.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if !afterFence.isEmpty { latexParts.append(afterFence) }
                decorations.lines.append(LineDecoration(lineRange: mLine.lineRange, kind: .mathBlockStart(isActive: isMathBlockActive)))
            } else if idx == mathLines.count - 1 && t.hasPrefix("$$") {
                decorations.lines.append(LineDecoration(lineRange: mLine.lineRange, kind: .mathBlockEnd(isActive: isMathBlockActive)))
            } else {
                latexParts.append(mLine.text)
                decorations.lines.append(LineDecoration(lineRange: mLine.lineRange, kind: .mathBlockBody(isActive: isMathBlockActive)))
            }
        }

        let combinedLatex = latexParts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

        if isMathBlockActive {
            let mathMono = theme.codeFont(size: effectiveBaseSize * 0.92)
            for mLine in mathLines {
                let t = mLine.text.trimmingCharacters(in: .whitespaces)
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

                if t.hasPrefix("$$") {
                    storage.addAttribute(.foregroundColor, value: theme.linkNSColor.withAlphaComponent(0.9), range: mLine.contentRange)
                } else {
                    Styler.highlightLaTeXSource(in: storage, range: mLine.contentRange, theme: theme, dimFactor: 1.0)
                }
            }
        } else {
            let mathBox = LaTeXMathRenderer.layoutLatex(
                combinedLatex,
                baseFontSize: effectiveBaseSize,
                isDisplayStyle: true
            )
            let totalCardHeight: CGFloat
            if mathBox.width == 0 && LaTeXMacroExpander.isStandaloneMacroDefinitionBlock(combinedLatex) {
                totalCardHeight = 26.0
            } else {
                let naturalHeight = ceil(mathBox.totalHeight) + 20.0
                let minBlockHeight = max(effectiveBaseSize * 2.1, 36.0)
                totalCardHeight = max(minBlockHeight, naturalHeight)
            }
            let perLineHeight = max(6.0, ceil(totalCardHeight / CGFloat(max(1, mathLines.count))))
            collapseCardSourceLines(
                lineRanges: mathLines.map(\.lineRange),
                lineHeights: Array(repeating: perLineHeight, count: mathLines.count),
                minFontSize: 4.0,
                fontScale: 0.55,
                centered: true,
                clipLines: true,
                trailingSpacing: 0.0
            )

            if !combinedLatex.isEmpty {
                decorations.lines.append(
                    LineDecoration(
                        lineRange: fullBlockRange,
                        kind: .mathBlockRendered(latex: combinedLatex, fullBlockRange: fullBlockRange, dimFactor: blockDim)
                    ))
            }
        }

        return (scanIndex, scanLineCount)
    }

    func tryStyleRawSVGBlock(
        lineRange: NSRange,
        contentRange: NSRange,
        lineText: String,
        lowerTrimmedLine: String,
        isActiveLine: Bool
    ) -> (nextIndex: Int, lineDelta: Int)? {
        var svgLines: [(lineRange: NSRange, contentRange: NSRange, text: String, isActive: Bool)] = [
            (lineRange, contentRange, lineText, isActiveLine)
        ]
        var scanIndex = NSMaxRange(lineRange)
        var scanLineCount = 1
        let isSingleLineSVG = lowerTrimmedLine.contains("</svg>") || lowerTrimmedLine.hasSuffix("/>")
        var foundClosingSVG = isSingleLineSVG

        if !isSingleLineSVG {
            while scanIndex < fullLength {
                let nextLR = nsString.lineRange(for: NSRange(location: scanIndex, length: 0))
                let nextCR = Styler.strippedLineContentRange(nsString: nsString, lineRange: nextLR)
                let nextText = nsString.substring(with: nextCR)
                let nextActive = Styler.isLineActive(lineRange: nextLR, activeLineRange: activeLineRange, selectedRange: selectedRange)
                svgLines.append((nextLR, nextCR, nextText, nextActive))
                scanIndex = NSMaxRange(nextLR)
                scanLineCount += 1
                if nextText.lowercased().contains("</svg>") {
                    foundClosingSVG = true
                    break
                }
            }
        }

        guard foundClosingSVG else { return nil }

        let fullBlockRange = NSRange(location: lineRange.location, length: scanIndex - lineRange.location)
        storage.addAttribute(Styler.noSpellCheckAttributeKey, value: true, range: fullBlockRange)
        let isSVGBlockActive =
            svgLines.contains(where: { $0.isActive })
            || NSIntersectionRange(fullBlockRange, selectedRange).length > 0
        let blockDim: CGFloat = (focusMode && !isSVGBlockActive) ? 0.30 : 1.0

        let combinedSVG = svgLines.map(\.text).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if prettyMode && !isSVGBlockActive && !combinedSVG.isEmpty {
            let svgImg = DiagramImageRenderer.shared.image(for: DiagramImageRenderer.Key(kind: .svg, source: combinedSVG))
            let availW = max(200.0, effectiveContainerWidth - 32.0)
            let totalCardHeight: CGFloat
            if let img = svgImg, img.size.width > 0, img.size.height > 0 {
                let scale = min(1.0, availW / img.size.width)
                let naturalH = round(img.size.height * scale) + 28.0
                totalCardHeight = min(640.0, max(96.0, naturalH))
            } else {
                totalCardHeight = 190.0
            }
            let perLineHeight = max(6.0, round(totalCardHeight / CGFloat(svgLines.count)))
            collapseCardSourceLines(
                lineRanges: svgLines.map(\.lineRange),
                lineHeights: Array(repeating: perLineHeight, count: svgLines.count),
                minFontSize: 4.0,
                fontScale: 0.6,
                centered: true,
                clipLines: false,
                trailingSpacing: max(6.0, typography.paragraphSpacing * 0.55)
            )
            decorations.lines.append(
                LineDecoration(
                    lineRange: fullBlockRange,
                    kind: .svgBlockRendered(svgSource: combinedSVG, fullBlockRange: fullBlockRange, dimFactor: blockDim)
                ))
        } else {
            styleActiveMarkupLines(
                svgLines.map { ($0.lineRange, $0.contentRange) },
                language: "svg",
                dimFactor: blockDim
            )
        }

        return (scanIndex, scanLineCount)
    }

    func tryStyleHTMLBlock(
        lineRange: NSRange,
        endLineCount: Int
    ) -> (nextIndex: Int, lineDelta: Int)? {
        guard prettyMode, endLineCount >= 1 else { return nil }

        let firstLine = nsString.substring(with: Styler.strippedLineContentRange(nsString: nsString, lineRange: lineRange))
        let closingTag = Styler.rawTextBlockClosingTag(firstLine: firstLine)
        var lines: [(lineRange: NSRange, contentRange: NSRange, isActive: Bool)] = []
        var scanIndex = lineRange.location
        while scanIndex < fullLength {
            let nextLR = nsString.lineRange(for: NSRange(location: scanIndex, length: 0))
            let nextCR = Styler.strippedLineContentRange(nsString: nsString, lineRange: nextLR)
            let active = Styler.isLineActive(lineRange: nextLR, activeLineRange: activeLineRange, selectedRange: selectedRange)
            lines.append((nextLR, nextCR, active))
            scanIndex = NSMaxRange(nextLR)
            if let closingTag {
                if nsString.substring(with: nextCR).lowercased().contains(closingTag) { break }
            } else if lines.count >= endLineCount {
                break
            }
        }
        guard let lastLine = lines.last else { return nil }

        let sourceRange = NSRange(location: lineRange.location, length: NSMaxRange(lastLine.contentRange) - lineRange.location)
        let source = nsString.substring(with: sourceRange)
        guard HTMLBlockMarkup.rendersInWebView(source) else { return nil }

        let fullBlockRange = NSRange(location: lineRange.location, length: scanIndex - lineRange.location)
        storage.addAttribute(Styler.noSpellCheckAttributeKey, value: true, range: fullBlockRange)
        let isBlockActive =
            lines.contains(where: { $0.isActive })
            || NSIntersectionRange(fullBlockRange, selectedRange).length > 0
        let blockDim: CGFloat = (focusMode && !isBlockActive) ? 0.30 : 1.0

        if isBlockActive {
            styleActiveMarkupLines(
                lines.map { ($0.lineRange, $0.contentRange) },
                language: "html",
                dimFactor: 1.0
            )
            return (scanIndex, lines.count)
        }

        let style = HTMLBlockPageStyle(theme: theme, typography: typography)
        let key = HTMLBlockLayoutCache.key(source: source, width: effectiveContainerWidth, style: style)
        let blockHeight =
            HTMLBlockLayoutCache.shared.height(for: key)
            ?? HTMLBlockLayoutCache.estimatedHeight(
                lineCount: lines.count,
                fontSize: effectiveBaseSize,
                lineHeight: style.lineHeight
            )
        let lineHeights = Styler.hiddenLineHeights(totalHeight: blockHeight, lineCount: lines.count)
        collapseCardSourceLines(
            lineRanges: lines.map(\.lineRange),
            lineHeights: lineHeights,
            minFontSize: 1.0,
            fontScale: 0.5,
            centered: false,
            clipLines: true,
            trailingSpacing: max(6.0, typography.paragraphSpacing * 0.65)
        )
        decorations.lines.append(
            LineDecoration(
                lineRange: fullBlockRange,
                kind: .htmlBlockRendered(
                    htmlSource: source,
                    fullBlockRange: fullBlockRange,
                    layoutWidth: effectiveContainerWidth,
                    dimFactor: blockDim
                )
            ))
        return (scanIndex, lines.count)
    }

    private func collapseCardSourceLines(
        lineRanges: [NSRange],
        lineHeights: [CGFloat],
        minFontSize: CGFloat,
        fontScale: CGFloat,
        centered: Bool,
        clipLines: Bool,
        trailingSpacing: CGFloat
    ) {
        for (index, lineRange) in lineRanges.enumerated() {
            let lineHeight = lineHeights[index]
            let para = NSMutableParagraphStyle()
            if centered { para.alignment = .center }
            para.lineSpacing = 0.0
            para.paragraphSpacingBefore = 0.0
            para.paragraphSpacing = index == lineRanges.count - 1 ? trailingSpacing : 0.0
            para.minimumLineHeight = lineHeight
            para.maximumLineHeight = lineHeight
            if clipLines { para.lineBreakMode = .byClipping }
            para.tailIndent = effectiveContainerWidth
            storage.addAttributes(
                [
                    .font: theme.bodyFont(size: min(effectiveBaseSize, max(minFontSize, lineHeight * fontScale))),
                    .foregroundColor: NSColor.clear,
                    .paragraphStyle: para,
                    .kern: 0.0
                ], range: lineRange)
        }
    }

    private func styleActiveMarkupLines(
        _ lines: [(lineRange: NSRange, contentRange: NSRange)],
        language: String,
        dimFactor: CGFloat
    ) {
        let codeMono = theme.codeFont(size: effectiveBaseSize * 0.90)
        for line in lines {
            decorations.lines.append(LineDecoration(lineRange: line.lineRange, kind: .codeFenceBody))
            let codePara = NSMutableParagraphStyle()
            codePara.lineSpacing = 2.0
            codePara.paragraphSpacing = 1.0
            codePara.firstLineHeadIndent = 14.0
            codePara.headIndent = 14.0
            codePara.tailIndent = effectiveContainerWidth
            storage.addAttributes(
                [
                    .font: codeMono,
                    .foregroundColor: theme.textNSColor.withAlphaComponent(dimFactor),
                    .paragraphStyle: codePara,
                    .kern: 0.0
                ], range: line.lineRange)
            Styler.highlightCodeLine(
                in: storage,
                string: string,
                range: line.contentRange,
                language: language,
                theme: theme,
                dimFactor: dimFactor
            )
        }
    }

    // MARK: - Headings, Rules, Blockquotes, Lists, Link Refs, and Paragraphs

    func styleHorizontalRuleLine(
        lineRange: NSRange,
        contentRange: NSRange,
        isActiveLine: Bool,
        dimFactor: CGFloat
    ) {
        decorations.lines.append(LineDecoration(lineRange: lineRange, kind: .horizontalRule))
        let hrPara = NSMutableParagraphStyle()
        hrPara.minimumLineHeight = 28.0
        hrPara.maximumLineHeight = 28.0
        hrPara.paragraphSpacingBefore = 6.0 * typography.headingSpacingScale
        hrPara.paragraphSpacing = 6.0 * typography.headingSpacingScale
        hrPara.tailIndent = effectiveContainerWidth
        storage.addAttribute(.paragraphStyle, value: hrPara, range: lineRange)
        Styler.styleSyntaxToken(
            in: storage,
            range: contentRange,
            isActiveLine: isActiveLine,
            theme: theme,
            dimFactor: dimFactor
        )
    }

    func styleATXHeadingLine(
        match: NSTextCheckingResult,
        lineRange: NSRange,
        contentRange: NSRange,
        lineNumber: Int,
        isActiveLine: Bool,
        dimFactor: CGFloat
    ) {
        let leadingRange = match.range(at: 1)
        let hashesRange = match.range(at: 2)
        let spaceRange = match.range(at: 3)
        let titleRange = match.range(at: 4)
        let level = min(6, max(1, hashesRange.length))
        let titleText = titleRange.location != NSNotFound ? nsString.substring(with: titleRange) : ""

        if !titleText.isEmpty {
            headings.append(
                OutlineHeading(
                    level: level,
                    title: titleText,
                    characterLocation: contentRange.location,
                    lineNumber: lineNumber
                ))
        }

        let hFont = theme.headingFont(level: level, scale: typography.fontSizeScale)
        let hScale = typography.headingSpacingScale
        let hPara = NSMutableParagraphStyle()
        hPara.lineHeightMultiple = max(1.10, typography.lineHeightMultiple * 0.90)
        hPara.lineSpacing = max(1.5, typography.lineSpacing * 0.5)
        hPara.tailIndent = effectiveContainerWidth
        switch level {
        case 1:
            hPara.paragraphSpacingBefore = 12.0 * hScale
            hPara.paragraphSpacing = (typography.showHeadingUnderlines ? 14.0 : 8.0) * hScale
        case 2:
            hPara.paragraphSpacingBefore = 10.0 * hScale
            hPara.paragraphSpacing = (typography.showHeadingUnderlines ? 12.0 : 7.0) * hScale
        case 3:
            hPara.paragraphSpacingBefore = 8.0 * hScale
            hPara.paragraphSpacing = 6.0 * hScale
        default:
            hPara.paragraphSpacingBefore = 6.0 * hScale
            hPara.paragraphSpacing = 4.0 * hScale
        }

        storage.addAttributes(
            [
                .font: hFont,
                .foregroundColor: theme.headingNSColor.withAlphaComponent(dimFactor),
                .paragraphStyle: hPara,
                .kern: typography.headingCharacterSpacing
            ], range: lineRange)

        let prefixEnd = spaceRange.location != NSNotFound ? NSMaxRange(spaceRange) : NSMaxRange(hashesRange)
        let prefixRange = NSRange(location: leadingRange.location, length: prefixEnd - leadingRange.location)
        Styler.styleSyntaxToken(
            in: storage,
            range: prefixRange,
            isActiveLine: isActiveLine,
            theme: theme,
            dimFactor: dimFactor
        )

        if titleRange.location != NSNotFound {
            let suffixStart = NSMaxRange(titleRange)
            let suffixLen = NSMaxRange(contentRange) - suffixStart
            if suffixLen > 0 {
                Styler.styleSyntaxToken(
                    in: storage,
                    range: NSRange(location: suffixStart, length: suffixLen),
                    isActiveLine: isActiveLine,
                    theme: theme,
                    dimFactor: dimFactor
                )
            }
        }

        if level <= 2 && typography.showHeadingUnderlines {
            decorations.lines.append(LineDecoration(lineRange: lineRange, kind: .headingUnderline(level: level)))
        }

        if titleRange.location != NSNotFound && titleRange.length > 0 {
            Styler.styleInlineMarkdown(
                in: storage,
                string: string,
                range: titleRange,
                lineRange: lineRange,
                baseFont: hFont,
                isActiveLine: isActiveLine,
                theme: theme,
                dimFactor: dimFactor,
                normalizeWhitespace: !isActiveLine,
                prettyMode: prettyMode,
                baseDirectoryURL: baseDirectoryURL,
                decorations: &decorations.lines
            )
        }
    }

    func styleBlockquoteLine(
        match: NSTextCheckingResult,
        lineRange: NSRange,
        lineNumber: Int,
        isActiveLine: Bool,
        dimFactor: CGFloat
    ) {
        let markerRange = match.range(at: 1)
        let bodyRange = match.range(at: 2)
        let markerText = nsString.substring(with: markerRange)
        let nestLevel = max(1, markerText.filter { $0 == ">" }.count)

        decorations.lines.append(LineDecoration(lineRange: lineRange, kind: .blockquote(nestLevel: nestLevel)))

        let bqPara = NSMutableParagraphStyle()
        bqPara.firstLineHeadIndent = CGFloat(nestLevel) * 16.0
        bqPara.headIndent = CGFloat(nestLevel) * 16.0
        bqPara.lineHeightMultiple = typography.lineHeightMultiple
        bqPara.lineSpacing = max(1.0, typography.lineSpacing * 0.75)
        bqPara.paragraphSpacing = max(3.0, typography.paragraphSpacing * 0.45)
        bqPara.tailIndent = effectiveContainerWidth

        var bqFont = theme.bodyFont(size: effectiveBaseSize, italic: theme.italicBlockquotes)
        var bqColor = theme.blockquoteTextNSColor.withAlphaComponent(dimFactor)
        var inlineRange = bodyRange

        if bodyRange.length > 0,
            let innerHeading = Styler.headingRegex.firstMatch(in: string, options: [], range: bodyRange),
            innerHeading.range(at: 3).location != NSNotFound
        {
            let hLevel = min(6, max(1, innerHeading.range(at: 2).length))
            bqFont = theme.headingFont(level: hLevel, scale: typography.fontSizeScale)
            bqColor = theme.headingNSColor.withAlphaComponent(dimFactor)
            let innerPrefixEnd = NSMaxRange(innerHeading.range(at: 3))
            let innerPrefixRange = NSRange(location: bodyRange.location, length: innerPrefixEnd - bodyRange.location)
            inlineRange = innerHeading.range(at: 4)
            storage.addAttributes(
                [
                    .font: bqFont,
                    .foregroundColor: bqColor,
                    .paragraphStyle: bqPara,
                    .kern: typography.headingCharacterSpacing
                ], range: lineRange)
            Styler.styleSyntaxToken(in: storage, range: innerPrefixRange, isActiveLine: isActiveLine, theme: theme, dimFactor: dimFactor)
        } else {
            proseLineKinds[lineNumber] = .blockquote(nestLevel: nestLevel)
            storage.addAttributes(
                [
                    .font: bqFont,
                    .foregroundColor: bqColor,
                    .paragraphStyle: bqPara,
                    .kern: typography.characterSpacing
                ], range: lineRange)
        }

        Styler.styleSyntaxToken(
            in: storage,
            range: markerRange,
            isActiveLine: isActiveLine,
            theme: theme,
            dimFactor: dimFactor
        )

        styleOrDeferProseInline(
            range: inlineRange,
            lineRange: lineRange,
            lineNumber: lineNumber,
            baseFont: bqFont,
            isActiveLine: isActiveLine,
            dimFactor: dimFactor
        )
    }

    func styleTaskListLine(
        match: NSTextCheckingResult,
        lineRange: NSRange,
        lineNumber: Int,
        isActiveLine: Bool,
        dimFactor: CGFloat
    ) -> CGFloat {
        let leadingWSRange = match.range(at: 1)
        let spaceAfterMarkerRange = match.range(at: 3)
        let boxRange = match.range(at: 4)
        let spaceAfterBoxRange = match.range(at: 5)
        let textRange = match.range(at: 6)
        let boxStr = nsString.substring(with: boxRange).lowercased()
        let isChecked = boxStr == "[x]"

        let indentCols = Styler.indentationColumnCount(nsString: nsString, range: leadingWSRange)
        let nestLevel = indentCols / 2
        let baseIndent: CGFloat = 10.0 + CGFloat(nestLevel) * 18.0
        let textIndent: CGFloat = baseIndent + 26.0

        let bulletPrefixRange = NSRange(
            location: leadingWSRange.location,
            length: NSMaxRange(spaceAfterMarkerRange) - leadingWSRange.location
        )
        Styler.styleSyntaxToken(
            in: storage,
            range: bulletPrefixRange,
            isActiveLine: isActiveLine,
            theme: theme,
            dimFactor: dimFactor
        )

        proseLineKinds[lineNumber] = .listItem
        let boxFont = NSFont.monospacedSystemFont(ofSize: effectiveBaseSize * 0.92, weight: .bold)
        storage.addAttributes(
            [
                .font: boxFont,
                .foregroundColor: (isChecked ? theme.linkNSColor : theme.secondaryTextNSColor).withAlphaComponent(dimFactor),
                .kern: 0.0
            ], range: boxRange)

        let syntaxFont = NSFont.monospacedSystemFont(ofSize: max(11.0, theme.baseFontSize * 0.85), weight: .regular)
        let activePrefixW =
            isActiveLine
            ? (nsString.substring(with: bulletPrefixRange) as NSString).size(withAttributes: [.font: syntaxFont]).width
            : 0.0

        let listPara = NSMutableParagraphStyle()
        listPara.firstLineHeadIndent = isActiveLine ? max(0.0, baseIndent - activePrefixW) : baseIndent
        listPara.headIndent = textIndent
        listPara.lineHeightMultiple = typography.lineHeightMultiple
        listPara.lineSpacing = max(1.0, typography.lineSpacing * 0.70)
        listPara.paragraphSpacing = max(2.5, typography.paragraphSpacing * 0.35)
        listPara.tailIndent = effectiveContainerWidth
        storage.addAttribute(.paragraphStyle, value: listPara, range: lineRange)

        let boxW = (nsString.substring(with: boxRange) as NSString).size(withAttributes: [.font: boxFont]).width
        if !isActiveLine && spaceAfterBoxRange.length > 0 {
            let desiredGap = max(4.0, (textIndent - baseIndent) - boxW)
            Styler.collapseWhitespaceRange(in: storage, range: spaceAfterBoxRange)
            storage.addAttribute(.kern, value: desiredGap, range: NSRange(location: spaceAfterBoxRange.location, length: 1))
        } else if isActiveLine && spaceAfterBoxRange.length > 0 {
            let spaceW = (nsString.substring(with: spaceAfterBoxRange) as NSString).size(withAttributes: [.font: baseFont]).width
            let extraKern = max(0.0, (textIndent - baseIndent) - boxW - spaceW)
            storage.addAttribute(.kern, value: extraKern, range: NSRange(location: NSMaxRange(spaceAfterBoxRange) - 1, length: 1))
        }

        if isChecked {
            storage.addAttributes(
                [
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    .foregroundColor: theme.secondaryTextNSColor.withAlphaComponent(0.75 * dimFactor)
                ], range: textRange)
        } else if dimFactor < 1.0 {
            storage.addAttribute(.foregroundColor, value: baseColor.withAlphaComponent(dimFactor), range: textRange)
        }

        styleOrDeferProseInline(
            range: textRange,
            lineRange: lineRange,
            lineNumber: lineNumber,
            baseFont: baseFont,
            isActiveLine: isActiveLine,
            dimFactor: dimFactor
        )

        return textIndent
    }

    func styleStandardListLine(
        match: NSTextCheckingResult,
        lineRange: NSRange,
        contentRange: NSRange,
        lineNumber: Int,
        isActiveLine: Bool,
        dimFactor: CGFloat
    ) -> CGFloat {
        let leadingWSRange = match.range(at: 1)
        let markerSymbolRange = match.range(at: 2)
        let postMarkerWSRange = match.range(at: 3)
        let bodyRange = match.range(at: 4)

        let indentCols = Styler.indentationColumnCount(nsString: nsString, range: leadingWSRange)
        let nestLevel = indentCols / 2
        let isOrdered = Styler.orderedListRegex.firstMatch(in: string, options: [], range: contentRange) != nil
        let baseIndent: CGFloat = 10.0 + CGFloat(nestLevel) * 18.0
        let markerAdvance: CGFloat = isOrdered ? 22.0 : 16.0
        let textIndent: CGFloat = baseIndent + markerAdvance
        proseLineKinds[lineNumber] = .listItem

        let markerFont = theme.bodyFont(size: effectiveBaseSize, bold: true)
        let markerStr = nsString.substring(with: markerSymbolRange) as NSString
        let markerW = markerStr.size(withAttributes: [.font: markerFont]).width
        let leadW =
            isActiveLine && leadingWSRange.length > 0
            ? (nsString.substring(with: leadingWSRange) as NSString).size(withAttributes: [.font: markerFont]).width
            : 0.0

        let listPara = NSMutableParagraphStyle()
        listPara.firstLineHeadIndent = isActiveLine ? max(0.0, baseIndent - leadW) : baseIndent
        listPara.headIndent = textIndent
        listPara.lineHeightMultiple = typography.lineHeightMultiple
        listPara.lineSpacing = max(1.0, typography.lineSpacing * 0.70)
        listPara.paragraphSpacing = max(2.5, typography.paragraphSpacing * 0.35)
        listPara.tailIndent = effectiveContainerWidth
        storage.addAttribute(.paragraphStyle, value: listPara, range: lineRange)

        storage.addAttributes(
            [
                .font: markerFont,
                .foregroundColor: (!isActiveLine && !isOrdered)
                    ? NSColor.clear
                    : theme.linkNSColor.withAlphaComponent(dimFactor),
                .kern: 0.0
            ], range: markerSymbolRange)

        if !isActiveLine {
            if !isOrdered {
                decorations.lines.append(
                    LineDecoration(
                        lineRange: lineRange,
                        kind: .listBullet(range: markerSymbolRange, dimFactor: dimFactor)
                    ))
            }
            if leadingWSRange.length > 0 {
                Styler.collapseWhitespaceRange(in: storage, range: leadingWSRange)
            }
            if postMarkerWSRange.length > 0 {
                let desiredGap = max(4.0, markerAdvance - markerW)
                Styler.collapseWhitespaceRange(in: storage, range: postMarkerWSRange)
                storage.addAttribute(.kern, value: desiredGap, range: NSRange(location: postMarkerWSRange.location, length: 1))
            }
        } else {
            storage.addAttributes(
                [
                    .font: markerFont,
                    .foregroundColor: theme.linkNSColor.withAlphaComponent(dimFactor)
                ], range: NSRange(location: leadingWSRange.location, length: NSMaxRange(postMarkerWSRange) - leadingWSRange.location))
            if !isOrdered && markerStr.isEqual(to: "*") {
                storage.addAttribute(.baselineOffset, value: -effectiveBaseSize * 0.14, range: markerSymbolRange)
            }
            if postMarkerWSRange.length > 0 {
                let postW = (nsString.substring(with: postMarkerWSRange) as NSString).size(withAttributes: [.font: markerFont]).width
                let extraKern = max(0.0, markerAdvance - markerW - postW)
                storage.addAttribute(.kern, value: extraKern, range: NSRange(location: NSMaxRange(postMarkerWSRange) - 1, length: 1))
            }
        }

        if dimFactor < 1.0 {
            storage.addAttribute(.foregroundColor, value: baseColor.withAlphaComponent(dimFactor), range: bodyRange)
        }

        styleOrDeferProseInline(
            range: bodyRange,
            lineRange: lineRange,
            lineNumber: lineNumber,
            baseFont: baseFont,
            isActiveLine: isActiveLine,
            dimFactor: dimFactor
        )

        return textIndent
    }

    func styleLinkReferenceDefinitionLine(
        refDefMatch: NSTextCheckingResult,
        isActiveLine: Bool,
        dimFactor: CGFloat
    ) {
        let prefixRange = refDefMatch.range(at: 1)
        let destRange = refDefMatch.range(at: 3)
        let titleRange = refDefMatch.range(at: 5)
        let refFont = theme.codeFont(size: max(11.0, effectiveBaseSize * 0.86))

        storage.addAttributes(
            [
                .font: refFont,
                .foregroundColor: theme.markdownTokenNSColor.withAlphaComponent((isActiveLine ? 0.90 : 0.65) * dimFactor),
                Styler.noSpellCheckAttributeKey: true
            ], range: prefixRange)

        if destRange.location != NSNotFound && destRange.length > 0 {
            storage.addAttributes(
                [
                    .font: refFont,
                    .foregroundColor: theme.linkNSColor.withAlphaComponent((isActiveLine ? 0.95 : 0.75) * dimFactor),
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    Styler.noSpellCheckAttributeKey: true
                ], range: destRange)
        }

        if titleRange.location != NSNotFound && titleRange.length > 0 {
            storage.addAttributes(
                [
                    .font: refFont,
                    .foregroundColor: theme.secondaryTextNSColor.withAlphaComponent((isActiveLine ? 0.90 : 0.70) * dimFactor)
                ], range: titleRange)
        }
    }

    func tryStyleSetextHeadingBlock(
        lineRange: NSRange,
        contentRange: NSRange,
        trimmedLine: String,
        lineNumber: Int,
        isActiveLine: Bool
    ) -> Int? {
        let nextLineStart = NSMaxRange(lineRange)
        guard nextLineStart < fullLength else { return nil }
        let nextLR = nsString.lineRange(for: NSRange(location: nextLineStart, length: 0))
        let nextCR = Styler.strippedLineContentRange(nsString: nsString, lineRange: nextLR)
        guard nextCR.length > 0 else { return nil }

        let isSetextH1 = Styler.setextH1Regex.firstMatch(in: string, options: [], range: nextCR) != nil
        let isSetextH2 = !isSetextH1 && Styler.setextH2Regex.firstMatch(in: string, options: [], range: nextCR) != nil
        guard isSetextH1 || isSetextH2 else { return nil }

        let level = isSetextH1 ? 1 : 2
        let nextActive = Styler.isLineActive(lineRange: nextLR, activeLineRange: activeLineRange, selectedRange: selectedRange)
        let combinedActive = isActiveLine || nextActive
        let setextDim: CGFloat = (focusMode && !combinedActive) ? 0.30 : 1.0

        let titleText = trimmedLine
        if !titleText.isEmpty {
            headings.append(
                OutlineHeading(
                    level: level,
                    title: titleText,
                    characterLocation: contentRange.location,
                    lineNumber: lineNumber
                ))
        }

        let hFont = theme.headingFont(level: level, scale: typography.fontSizeScale)
        let hScale = typography.headingSpacingScale
        let hPara = NSMutableParagraphStyle()
        hPara.lineHeightMultiple = max(1.10, typography.lineHeightMultiple * 0.90)
        hPara.lineSpacing = max(1.5, typography.lineSpacing * 0.5)
        hPara.paragraphSpacingBefore = (level == 1 ? 12.0 : 10.0) * hScale
        hPara.paragraphSpacing = (typography.showHeadingUnderlines ? (level == 1 ? 14.0 : 12.0) : 8.0) * hScale
        hPara.tailIndent = effectiveContainerWidth

        storage.addAttributes(
            [
                .font: hFont,
                .foregroundColor: theme.headingNSColor.withAlphaComponent(setextDim),
                .paragraphStyle: hPara,
                .kern: typography.headingCharacterSpacing
            ], range: lineRange)

        if typography.showHeadingUnderlines {
            decorations.lines.append(LineDecoration(lineRange: lineRange, kind: .headingUnderline(level: level)))
        }

        Styler.styleInlineMarkdown(
            in: storage,
            string: string,
            range: contentRange,
            lineRange: lineRange,
            baseFont: hFont,
            isActiveLine: combinedActive,
            theme: theme,
            dimFactor: setextDim,
            normalizeWhitespace: !combinedActive,
            prettyMode: prettyMode,
            baseDirectoryURL: baseDirectoryURL,
            decorations: &decorations.lines
        )

        let underlinePara = NSMutableParagraphStyle()
        underlinePara.lineSpacing = 0.0
        underlinePara.paragraphSpacing = 0.0
        underlinePara.paragraphSpacingBefore = 0.0
        underlinePara.minimumLineHeight = combinedActive ? 20.0 : 1.0
        underlinePara.maximumLineHeight = combinedActive ? 20.0 : 1.0
        underlinePara.tailIndent = effectiveContainerWidth
        storage.addAttribute(.paragraphStyle, value: underlinePara, range: nextLR)
        Styler.styleSyntaxToken(in: storage, range: nextCR, isActiveLine: combinedActive, theme: theme, dimFactor: setextDim)

        return NSMaxRange(nextLR)
    }

    func styleDefaultParagraphOrListContinuationLine(
        lineRange: NSRange,
        contentRange: NSRange,
        lineNumber: Int,
        isActiveLine: Bool,
        dimFactor: CGFloat
    ) {
        if let listIndent = state.previousListTextIndent,
            let leadMatch = Styler.leadingSpaceRegex.firstMatch(in: string, options: [], range: contentRange),
            Styler.indentationColumnCount(nsString: nsString, range: leadMatch.range) >= 2
        {
            let leadW =
                isActiveLine && leadMatch.range.length > 0
                ? (nsString.substring(with: leadMatch.range) as NSString).size(withAttributes: [.font: baseFont]).width
                : 0.0
            if !isActiveLine && leadMatch.range.length > 0 {
                Styler.collapseWhitespaceRange(in: storage, range: leadMatch.range)
            }
            let contPara = NSMutableParagraphStyle()
            contPara.firstLineHeadIndent = isActiveLine ? max(0.0, listIndent - leadW) : listIndent
            contPara.headIndent = listIndent
            contPara.lineHeightMultiple = typography.lineHeightMultiple
            contPara.lineSpacing = max(1.0, typography.lineSpacing * 0.70)
            contPara.paragraphSpacing = max(2.5, typography.paragraphSpacing * 0.35)
            contPara.tailIndent = effectiveContainerWidth
            storage.addAttribute(.paragraphStyle, value: contPara, range: lineRange)
        } else {
            state.previousListTextIndent = nil
        }

        proseLineKinds[lineNumber] = .paragraph
        if dimFactor < 1.0 {
            storage.addAttribute(.foregroundColor, value: baseColor.withAlphaComponent(dimFactor), range: contentRange)
        }

        styleOrDeferProseInline(
            range: contentRange,
            lineRange: lineRange,
            lineNumber: lineNumber,
            baseFont: baseFont,
            isActiveLine: isActiveLine,
            dimFactor: dimFactor
        )
    }

    private func styleOrDeferProseInline(
        range: NSRange,
        lineRange: NSRange,
        lineNumber: Int,
        baseFont: NSFont,
        isActiveLine: Bool,
        dimFactor: CGFloat
    ) {
        if let contentStart = lineRecords[lineNumber]?.contentRange.location {
            var firstNonWS = range.location
            let rangeEnd = NSMaxRange(range)
            while firstNonWS < rangeEnd {
                let ch = nsString.character(at: firstNonWS)
                if ch == 32 || ch == 9 {
                    firstNonWS += 1
                } else {
                    break
                }
            }
            proseContentPrefixBytes[lineNumber] = max(0, firstNonWS - contentStart)
        }
        if multiLineParagraphLines.contains(lineNumber) && proseLineKinds[lineNumber] != nil {
            deferredProseInline.append(
                Styler.DeferredInlineStyle(
                    line: lineNumber,
                    range: range,
                    baseFont: baseFont,
                    isActive: isActiveLine,
                    dimFactor: dimFactor
                ))
        } else {
            Styler.styleInlineMarkdown(
                in: storage,
                string: string,
                range: range,
                lineRange: lineRange,
                baseFont: baseFont,
                isActiveLine: isActiveLine,
                theme: theme,
                dimFactor: dimFactor,
                normalizeWhitespace: !isActiveLine,
                prettyMode: prettyMode,
                baseDirectoryURL: baseDirectoryURL,
                decorations: &decorations.lines
            )
        }
    }

    func applyProseAlignment() {
        let alignment = parameters.textAlignment
        guard alignment != .natural && alignment != .left else { return }
        for lineNumber in proseLineKinds.keys {
            guard let record = lineRecords[lineNumber], record.lineRange.length > 0,
                let style = storage.attribute(.paragraphStyle, at: record.lineRange.location, effectiveRange: nil) as? NSParagraphStyle,
                let mutable = style.mutableCopy() as? NSMutableParagraphStyle
            else { continue }
            mutable.alignment = alignment
            storage.addAttribute(.paragraphStyle, value: mutable, range: record.lineRange)
        }
    }
}

extension MarkdownLiveStyler {

    /// The end tag that closes a CommonMark type 1 HTML block (`<pre>`, `<script>`, `<style>`,
    /// `<textarea>`), which ends on the line with that tag rather than at a blank line.
    static func rawTextBlockClosingTag(firstLine: String) -> String? {
        let lower = firstLine.trimmingCharacters(in: .whitespaces).lowercased()
        for tag in ["pre", "script", "style", "textarea"] where lower.hasPrefix("<\(tag)") {
            let next = lower.dropFirst(tag.count + 1).first
            if next == nil || next == ">" || next?.isWhitespace == true {
                return "</\(tag)"
            }
        }
        return nil
    }

    /// Heights of the hidden source lines, which add up to `totalHeight` (each line is at
    /// least 2 points, so a short block with many source lines can come out taller).
    static func hiddenLineHeights(totalHeight: CGFloat, lineCount: Int) -> [CGFloat] {
        guard lineCount > 0 else { return [] }
        let minimum: CGFloat = 2.0
        let total = max(totalHeight, minimum * CGFloat(lineCount))
        let perLine = floor(total / CGFloat(lineCount))
        var heights = Array(repeating: perLine, count: lineCount)
        heights[lineCount - 1] = total - perLine * CGFloat(lineCount - 1)
        return heights
    }
}
