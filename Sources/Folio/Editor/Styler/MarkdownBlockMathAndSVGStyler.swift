import AppKit
import Foundation

extension MarkdownLiveStyler {

    static func styleDisplayMathBlock(
        in storage: NSTextStorage,
        nsString: NSString,
        fullLength: Int,
        lineRange: NSRange,
        contentRange: NSRange,
        lineText: String,
        trimmedLine: String,
        isActiveLine: Bool,
        activeLineRange: NSRange,
        selectedRange: NSRange,
        theme: EditorTheme,
        effectiveBaseSize: CGFloat,
        effectiveContainerWidth: CGFloat,
        focusMode: Bool,
        decorations: inout [LineDecoration]
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
                let nextCR = strippedLineContentRange(nsString: nsString, lineRange: nextLR)
                let nextText = nsString.substring(with: nextCR)
                let nextActive = isLineActive(lineRange: nextLR, activeLineRange: activeLineRange, selectedRange: selectedRange)
                mathLines.append((nextLR, nextCR, nextText, nextActive))
                scanIndex = NSMaxRange(nextLR)
                scanLineCount += 1
                if nextText.trimmingCharacters(in: .whitespaces).hasPrefix("$$") {
                    break
                }
            }
        }

        let isMathBlockActive =
            mathLines.contains(where: { $0.isActive })
            || NSIntersectionRange(
                NSRange(location: lineRange.location, length: scanIndex - lineRange.location),
                selectedRange
            ).length > 0
        let blockDim: CGFloat = (focusMode && !isMathBlockActive) ? 0.30 : 1.0
        let fullBlockRange = NSRange(location: lineRange.location, length: scanIndex - lineRange.location)
        storage.addAttribute(noSpellCheckAttributeKey, value: true, range: fullBlockRange)

        var latexParts: [String] = []
        for (idx, mLine) in mathLines.enumerated() {
            let t = mLine.text.trimmingCharacters(in: .whitespaces)
            if isSingleLineMath {
                let inner = String(t.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces)
                latexParts.append(inner)
                decorations.append(LineDecoration(lineRange: mLine.lineRange, kind: .mathBlockBody(isActive: isMathBlockActive)))
            } else if idx == 0 {
                let afterFence = String(t.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if !afterFence.isEmpty { latexParts.append(afterFence) }
                decorations.append(LineDecoration(lineRange: mLine.lineRange, kind: .mathBlockStart(isActive: isMathBlockActive)))
            } else if idx == mathLines.count - 1 && t.hasPrefix("$$") {
                decorations.append(LineDecoration(lineRange: mLine.lineRange, kind: .mathBlockEnd(isActive: isMathBlockActive)))
            } else {
                latexParts.append(mLine.text)
                decorations.append(LineDecoration(lineRange: mLine.lineRange, kind: .mathBlockBody(isActive: isMathBlockActive)))
            }
        }

        let combinedLatex = latexParts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

        if isMathBlockActive {
            for mLine in mathLines {
                let t = mLine.text.trimmingCharacters(in: .whitespaces)
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

                if t.hasPrefix("$$") {
                    storage.addAttribute(.foregroundColor, value: theme.linkNSColor.withAlphaComponent(0.9), range: mLine.contentRange)
                } else {
                    highlightLaTeXSource(in: storage, range: mLine.contentRange, theme: theme, dimFactor: 1.0)
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

            if !combinedLatex.isEmpty {
                decorations.append(
                    LineDecoration(
                        lineRange: fullBlockRange,
                        kind: .mathBlockRendered(latex: combinedLatex, fullBlockRange: fullBlockRange, dimFactor: blockDim)
                    ))
            }
        }

        return (scanIndex, scanLineCount)
    }

    static func tryStyleRawSVGBlock(
        in storage: NSTextStorage,
        nsString: NSString,
        fullLength: Int,
        lineRange: NSRange,
        contentRange: NSRange,
        lineText: String,
        lowerTrimmedLine: String,
        isActiveLine: Bool,
        activeLineRange: NSRange,
        selectedRange: NSRange,
        theme: EditorTheme,
        typography: EditorTypographySettings,
        effectiveBaseSize: CGFloat,
        effectiveContainerWidth: CGFloat,
        focusMode: Bool,
        prettyMode: Bool,
        decorations: inout [LineDecoration]
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
                let nextCR = strippedLineContentRange(nsString: nsString, lineRange: nextLR)
                let nextText = nsString.substring(with: nextCR)
                let nextActive = isLineActive(lineRange: nextLR, activeLineRange: activeLineRange, selectedRange: selectedRange)
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
        storage.addAttribute(noSpellCheckAttributeKey, value: true, range: fullBlockRange)
        let isSVGBlockActive = svgLines.contains(where: { $0.isActive }) || NSIntersectionRange(fullBlockRange, selectedRange).length > 0
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
            let hiddenLineFont = theme.bodyFont(size: min(effectiveBaseSize, max(4.0, perLineHeight * 0.6)))
            for (sIdx, sLine) in svgLines.enumerated() {
                let svgPara = NSMutableParagraphStyle()
                svgPara.alignment = .center
                svgPara.lineSpacing = 0.0
                svgPara.paragraphSpacingBefore = 0.0
                svgPara.paragraphSpacing = (sIdx == svgLines.count - 1) ? max(6.0, typography.paragraphSpacing * 0.55) : 0.0
                svgPara.minimumLineHeight = perLineHeight
                svgPara.maximumLineHeight = perLineHeight
                svgPara.tailIndent = effectiveContainerWidth
                storage.addAttributes(
                    [
                        .font: hiddenLineFont,
                        .foregroundColor: NSColor.clear,
                        .paragraphStyle: svgPara,
                        .kern: 0.0
                    ], range: sLine.lineRange)
            }
            decorations.append(
                LineDecoration(
                    lineRange: fullBlockRange,
                    kind: .svgBlockRendered(svgSource: combinedSVG, fullBlockRange: fullBlockRange, dimFactor: blockDim)
                ))
        } else {
            let codeMono = theme.codeFont(size: effectiveBaseSize * 0.90)
            for sLine in svgLines {
                decorations.append(LineDecoration(lineRange: sLine.lineRange, kind: .codeFenceBody))
                let codePara = NSMutableParagraphStyle()
                codePara.lineSpacing = 2.0
                codePara.paragraphSpacing = 1.0
                codePara.firstLineHeadIndent = 14.0
                codePara.headIndent = 14.0
                codePara.tailIndent = effectiveContainerWidth
                storage.addAttributes(
                    [
                        .font: codeMono,
                        .foregroundColor: theme.textNSColor.withAlphaComponent(blockDim),
                        .paragraphStyle: codePara,
                        .kern: 0.0
                    ], range: sLine.lineRange)
                highlightCodeLine(in: storage, range: sLine.contentRange, language: "svg", theme: theme, dimFactor: blockDim)
            }
        }

        return (scanIndex, scanLineCount)
    }
}
