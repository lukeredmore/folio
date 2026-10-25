import AppKit
import Foundation

extension LaTeXLiveStyler {

    static func styleLaTeXDisplayMathBlock(
        in storage: NSTextStorage,
        nsString: NSString,
        fullLength: Int,
        lineRange: NSRange,
        contentRange: NSRange,
        lineText: String,
        trimmedLine: String,
        closeToken: String,
        envName: String?,
        equationNumber: String?,
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
        let openToken: String
        if let envName = envName {
            openToken = "\\begin{\(envName)}"
        } else if trimmedLine.hasPrefix("\\[") {
            openToken = "\\["
        } else {
            openToken = "$$"
        }

        let isSingleLine = trimmedLine.count > (openToken.count + closeToken.count)
            && trimmedLine.hasSuffix(closeToken)

        if !isSingleLine {
            while scanIndex < fullLength {
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
                let nextTrimmed = nextText.trimmingCharacters(in: .whitespaces)
                if nextTrimmed.hasPrefix(closeToken) || nextTrimmed.hasSuffix(closeToken) {
                    break
                }
            }
        }

        let fullBlockRange = NSRange(location: lineRange.location, length: scanIndex - lineRange.location)
        storage.addAttribute(MKey.noSpellCheck, value: true, range: fullBlockRange)

        let isMathBlockActive = mathLines.contains(where: { $0.isActive }) ||
            NSIntersectionRange(fullBlockRange, selectedRange).length > 0
        let blockDim: CGFloat = (focusMode && !isMathBlockActive) ? 0.30 : 1.0

        var latexParts: [String] = []
        for (idx, mLine) in mathLines.enumerated() {
            let t = mLine.text.trimmingCharacters(in: .whitespaces)
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
                latexParts.append(mLine.text)
                decorations.append(LineDecoration(lineRange: mLine.lineRange, kind: .mathBlockBody(isActive: isMathBlockActive)))
            }
        }

        let rawCombined = latexParts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let (cleanedLatex, explicitTag) = normalizeDisplayMathForSwiftMath(rawCombined, envName: envName)
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
                storage.addAttributes([
                    .font: mathMono,
                    .foregroundColor: theme.textNSColor,
                    .paragraphStyle: mathPara,
                    .kern: 0.0
                ], range: mLine.lineRange)
                MarkdownLiveStyler.highlightLaTeXSource(in: storage, range: mLine.contentRange, theme: theme, dimFactor: 1.0)
            }
        } else {
            let mathBox = LaTeXMathRenderer.layoutLatex(
                cleanedLatex,
                baseFontSize: effectiveBaseSize,
                isDisplayStyle: true
            )
            let totalCardHeight: CGFloat
            if mathBox.width == 0 && LaTeXMacroExpander.isStandaloneMacroDefinitionBlock(cleanedLatex) {
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
                storage.addAttributes([
                    .font: hiddenLineFont,
                    .foregroundColor: NSColor.clear,
                    .paragraphStyle: mathPara,
                    .kern: 0.0
                ], range: mLine.lineRange)
            }

            if !cleanedLatex.isEmpty {
                decorations.append(LineDecoration(
                    lineRange: fullBlockRange,
                    kind: .mathBlockRendered(latex: cleanedLatex, fullBlockRange: fullBlockRange, dimFactor: blockDim)
                ))
                if let eqNum = resolvedEqNum, !eqNum.isEmpty {
                    decorations.append(LineDecoration(
                        lineRange: fullBlockRange,
                        kind: .latexEquationNumber(number: "(\(eqNum))", fullBlockRange: fullBlockRange, dimFactor: blockDim)
                    ))
                }
            }
        }

        return (scanIndex, scanLineCount)
    }

    private static let tagRegex = try! NSRegularExpression(pattern: #"\\tag\*?\{([^}]+)\}"#)

    static func normalizeDisplayMathForSwiftMath(_ raw: String, envName: String?) -> (latex: String, explicitTag: String?) {
        var explicitTag: String?
        let ns = raw as NSString
        if let tm = tagRegex.firstMatch(in: raw, range: NSRange(location: 0, length: ns.length)) {
            explicitTag = ns.substring(with: tm.range(at: 1))
        }

        var s = raw
            .replacingOccurrences(of: #"\\label\{[^}]*\}"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\\tag\*?\{[^}]*\}"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\nonumber", with: "")
            .replacingOccurrences(of: "\\notag", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let env = envName?.replacingOccurrences(of: "*", with: "") {
            if (env == "align" || env == "flalign" || env == "alignat")
                && !s.contains("\\begin{aligned}") && (s.contains("&") || s.contains("\\\\")) {
                s = "\\begin{aligned}\n\(s)\n\\end{aligned}"
            } else if (env == "gather" || env == "multline")
                && !s.contains("\\begin{gathered}") && s.contains("\\\\") {
                s = "\\begin{gathered}\n\(s)\n\\end{gathered}"
            }
        }
        return (s, explicitTag)
    }
}
