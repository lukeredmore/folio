import AppKit
import Foundation

extension MarkdownLiveStyler {

    static func styleSourceCodeLine(
        in storage: NSTextStorage,
        lineText: String,
        contentRange: NSRange,
        lineNumber: Int,
        effectiveBaseSize: CGFloat,
        baseColor: NSColor,
        theme: EditorTheme,
        dimFactor: CGFloat,
        headings: inout [OutlineHeading]
    ) {
        if lineText.hasPrefix("#") {
            let trimmed = lineText.prefix(while: { $0 == "#" })
            let level = min(6, max(1, trimmed.count))
            let title = String(lineText.dropFirst(level)).trimmingCharacters(in: .whitespaces)
            if !title.isEmpty {
                headings.append(OutlineHeading(
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

    static func tryStyleDiagramCodeFence(
        in storage: NSTextStorage,
        nsString: NSString,
        fullLength: Int,
        lineRange: NSRange,
        contentRange: NSRange,
        lineText: String,
        isActiveLine: Bool,
        activeLineRange: NSRange,
        selectedRange: NSRange,
        fenceChar: Character,
        openFenceLen: Int,
        lowerLang: String,
        theme: EditorTheme,
        typography: EditorTypographySettings,
        effectiveBaseSize: CGFloat,
        effectiveContainerWidth: CGFloat,
        focusMode: Bool,
        decorations: inout [LineDecoration]
    ) -> (nextIndex: Int, lineDelta: Int)? {
        var blockLines: [(lineRange: NSRange, contentRange: NSRange, text: String, isActive: Bool)] = [
            (lineRange, contentRange, lineText, isActiveLine)
        ]
        var scanIndex = NSMaxRange(lineRange)
        var scanLineCount = 1
        var foundClosingFence = false

        while scanIndex < fullLength {
            let nextLR = nsString.lineRange(for: NSRange(location: scanIndex, length: 0))
            let nextCR = strippedLineContentRange(nsString: nsString, lineRange: nextLR)
            let nextText = nsString.substring(with: nextCR)
            let nextActive = isLineActive(lineRange: nextLR, activeLineRange: activeLineRange, selectedRange: selectedRange)
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
        let isDiagramBlockActive = blockLines.contains(where: { $0.isActive }) ||
            NSIntersectionRange(fullBlockRange, selectedRange).length > 0

        guard foundClosingFence && !isDiagramBlockActive && blockLines.count >= 3 else {
            return nil
        }

        let bodySource = blockLines
            .dropFirst()
            .dropLast()
            .map(\.text)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !bodySource.isEmpty else { return nil }

        let blockDim: CGFloat = (focusMode && !isDiagramBlockActive) ? 0.30 : 1.0
        // Rendered in the background; until it is ready, the card reserves a default height.
        let diagramImg = DiagramImageRenderer.shared.image(for: DiagramImageRenderer.Key(
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
        let hiddenLineFont = theme.bodyFont(size: min(effectiveBaseSize, max(4.0, perLineHeight * 0.6)))

        for (bIdx, bLine) in blockLines.enumerated() {
            let cardPara = NSMutableParagraphStyle()
            cardPara.alignment = .center
            cardPara.lineSpacing = 0.0
            cardPara.paragraphSpacingBefore = 0.0
            cardPara.paragraphSpacing = (bIdx == blockLines.count - 1) ? max(6.0, typography.paragraphSpacing * 0.55) : 0.0
            cardPara.minimumLineHeight = perLineHeight
            cardPara.maximumLineHeight = perLineHeight
            cardPara.tailIndent = effectiveContainerWidth
            storage.addAttributes([
                .font: hiddenLineFont,
                .foregroundColor: NSColor.clear,
                .paragraphStyle: cardPara,
                .kern: 0.0
            ], range: bLine.lineRange)
        }

        if lowerLang == "mermaid" {
            decorations.append(LineDecoration(
                lineRange: fullBlockRange,
                kind: .mermaidBlockRendered(mermaidSource: bodySource, fullBlockRange: fullBlockRange, dimFactor: blockDim)
            ))
        } else {
            decorations.append(LineDecoration(
                lineRange: fullBlockRange,
                kind: .svgBlockRendered(svgSource: bodySource, fullBlockRange: fullBlockRange, dimFactor: blockDim)
            ))
        }

        return (scanIndex, scanLineCount)
    }

    static func styleCodeFenceDelimiterLine(
        in storage: NSTextStorage,
        lineRange: NSRange,
        isClosing: Bool,
        isActiveLine: Bool,
        theme: EditorTheme,
        typography: EditorTypographySettings,
        effectiveBaseSize: CGFloat,
        effectiveContainerWidth: CGFloat,
        dimFactor: CGFloat
    ) {
        let codeMono = theme.codeFont(size: effectiveBaseSize * 0.88)
        let fenceRowHeight: CGFloat = 23.0
        let fencePara = NSMutableParagraphStyle()
        fencePara.lineSpacing = 0.0
        fencePara.paragraphSpacingBefore = 0.0
        fencePara.paragraphSpacing = isClosing ? max(4.0, typography.paragraphSpacing * 0.55) : 0.0
        fencePara.firstLineHeadIndent = 14.0
        fencePara.headIndent = 14.0
        fencePara.minimumLineHeight = fenceRowHeight
        fencePara.maximumLineHeight = fenceRowHeight
        fencePara.tailIndent = effectiveContainerWidth

        storage.addAttributes([
            .font: codeMono,
            .foregroundColor: theme.markdownTokenNSColor.withAlphaComponent(isActiveLine ? 0.9 : 0.45 * dimFactor),
            .paragraphStyle: fencePara,
            .baselineOffset: 0.0,
            .kern: 0.0
        ], range: lineRange)
    }

    static func styleCodeFenceBodyLine(
        in storage: NSTextStorage,
        lineRange: NSRange,
        contentRange: NSRange,
        language: String?,
        theme: EditorTheme,
        effectiveBaseSize: CGFloat,
        effectiveContainerWidth: CGFloat,
        dimFactor: CGFloat,
        decorations: inout [LineDecoration]
    ) {
        decorations.append(LineDecoration(lineRange: lineRange, kind: .codeFenceBody))
        let codeMono = theme.codeFont(size: effectiveBaseSize * 0.90)
        let bodyRowHeight: CGFloat = 22.0
        let codePara = NSMutableParagraphStyle()
        codePara.lineSpacing = 0.0
        codePara.paragraphSpacingBefore = 0.0
        codePara.paragraphSpacing = 0.0
        codePara.firstLineHeadIndent = 14.0
        codePara.headIndent = 14.0
        codePara.minimumLineHeight = bodyRowHeight
        codePara.maximumLineHeight = bodyRowHeight
        codePara.tailIndent = effectiveContainerWidth

        storage.addAttributes([
            .font: codeMono,
            .foregroundColor: theme.textNSColor.withAlphaComponent(dimFactor),
            .paragraphStyle: codePara,
            .baselineOffset: 0.0,
            .kern: 0.0
        ], range: lineRange)

        if let language = language {
            highlightCodeLine(
                in: storage,
                range: contentRange,
                language: language,
                theme: theme,
                dimFactor: dimFactor
            )
        }
    }

    static func styleBlankLine(
        in storage: NSTextStorage,
        lineRange: NSRange,
        contentRange: NSRange,
        isActiveLine: Bool,
        effectiveBaseSize: CGFloat,
        effectiveContainerWidth: CGFloat
    ) {
        let blankPara = NSMutableParagraphStyle()
        let blankH = round(effectiveBaseSize * (isActiveLine ? 1.15 : 0.55))
        blankPara.minimumLineHeight = blankH
        blankPara.maximumLineHeight = blankH
        blankPara.lineSpacing = 0.0
        blankPara.paragraphSpacing = 0.0
        blankPara.paragraphSpacingBefore = 0.0
        blankPara.tailIndent = effectiveContainerWidth
        storage.addAttributes([
            .paragraphStyle: blankPara,
            .kern: 0.0
        ], range: lineRange)
        if !isActiveLine && contentRange.length > 0 {
            collapseWhitespaceRange(in: storage, range: contentRange)
        }
    }
}
