import AppKit
import Foundation

extension LaTeXLiveStyler {

    static func extractLaTeXOutlineHeadings(docIndex: LaTeXDocumentIndex) -> [OutlineHeading] {
        let sortedLocs = docIndex.lineSectionNumbers.keys.sorted()
        var result: [OutlineHeading] = []
        for (i, loc) in sortedLocs.enumerated() {
            guard let info = docIndex.lineSectionNumbers[loc] else { continue }
            let display = info.number.isEmpty ? info.title : "\(info.number) \(info.title)"
            result.append(OutlineHeading(
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
                        storage.addAttributes([
                            .font: tinyFont,
                            .foregroundColor: NSColor.clear,
                            .paragraphStyle: pStyle,
                            .kern: 0.0
                        ], range: lr)
                    }
                    decorations.append(LineDecoration(
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
                        storage.addAttributes([
                            .font: monoFont,
                            .foregroundColor: theme.textNSColor.withAlphaComponent(dimFactor),
                            .paragraphStyle: pStyle
                        ], range: lr)
                        let kind: BlockDecorationKind = (i == 0)
                            ? .codeFenceStart(language: "latex preamble")
                            : (i == pLines.count - 1 ? .codeFenceEnd : .codeFenceBody)
                        decorations.append(LineDecoration(lineRange: lr, kind: kind))
                    }
                    MarkdownLiveStyler.highlightLaTeXSource(in: storage, range: preambleRange, theme: theme, dimFactor: dimFactor)
                }

                recordedBlocks.append(LaTeXBlockStyleCache.CachedBlock(
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
            let lineRange = nsString.lineRange(for: NSRange(location: charIndex, length: 0))
            if session != nil {
                LaTeXBlockStyleCache.resetAttributes(in: storage, range: lineRange)
            }
            let contentRange = MarkdownLiveStyler.strippedLineContentRange(nsString: nsString, lineRange: lineRange)
            let lineText = nsString.substring(with: contentRange)
            let trimmed = lineText.trimmingCharacters(in: .whitespaces)
            let isActive = MarkdownLiveStyler.isLineActive(
                lineRange: lineRange,
                activeLineRange: activeLineRange,
                selectedRange: selectedRange
            )
            let dimFactor: CGFloat = (focusMode && !isActive) ? 0.30 : 1.0

            // \begin{document} / \end{document}
            if trimmed == "\\begin{document}" || trimmed == "\\end{document}" {
                styleDocumentBoundaryLine(
                    in: storage,
                    lineRange: lineRange,
                    contentRange: contentRange,
                    isActive: isActive,
                    prettyMode: prettyMode,
                    theme: theme,
                    effectiveBaseSize: effectiveBaseSize,
                    effectiveContainerWidth: effectiveContainerWidth,
                    dimFactor: dimFactor
                )
                recordedBlocks.append(LaTeXBlockStyleCache.CachedBlock(
                    range: lineRange,
                    startLineNumber: blockStartLine,
                    lineCount: 1,
                    isActive: isActive,
                    dimFactor: dimFactor,
                    headings: [],
                    decorations: []
                ))
                charIndex = NSMaxRange(lineRange)
                lineNumber += 1
                continue
            }

            // Multi-line or specialized LaTeX environments & blocks
            if let advance = tryStyleLaTeXBlockOrEnvironment(
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
                headings: &headings,
                decorations: &decorations
            ) {
                let blockRange = NSRange(location: blockStartChar, length: advance.nextIndex - blockStartChar)
                let blockActive = LaTeXBlockStyleCache.isBlockActive(
                    range: blockRange,
                    activeLineRange: activeLineRange,
                    selectedRange: selectedRange
                )
                let blockDim: CGFloat = (focusMode && !blockActive) ? 0.30 : 1.0
                recordedBlocks.append(LaTeXBlockStyleCache.CachedBlock(
                    range: blockRange,
                    startLineNumber: blockStartLine,
                    lineCount: advance.lineDelta,
                    isActive: blockActive,
                    dimFactor: blockDim,
                    headings: Array(headings[hStart...]),
                    decorations: Array(decorations[dStart...])
                ))
                charIndex = advance.nextIndex
                lineNumber += advance.lineDelta
                continue
            }

            // Standard prose line with LaTeX inline styling
            styleLaTeXInlineContent(
                in: storage,
                string: string,
                nsString: nsString,
                range: contentRange,
                lineRange: lineRange,
                baseFont: baseFont,
                isActiveLine: isActive,
                docIndex: docIndex,
                theme: theme,
                dimFactor: dimFactor,
                prettyMode: prettyMode,
                baseDirectoryURL: baseDirectoryURL,
                decorations: &decorations
            )

            recordedBlocks.append(LaTeXBlockStyleCache.CachedBlock(
                range: lineRange,
                startLineNumber: blockStartLine,
                lineCount: 1,
                isActive: isActive,
                dimFactor: dimFactor,
                headings: Array(headings[hStart...]),
                decorations: Array(decorations[dStart...])
            ))
            charIndex = NSMaxRange(lineRange)
            lineNumber += 1
        }
    }

    private static func styleDocumentBoundaryLine(
        in storage: NSTextStorage,
        lineRange: NSRange,
        contentRange: NSRange,
        isActive: Bool,
        prettyMode: Bool,
        theme: EditorTheme,
        effectiveBaseSize: CGFloat,
        effectiveContainerWidth: CGFloat,
        dimFactor: CGFloat
    ) {
        storage.addAttribute(MKey.noSpellCheck, value: true, range: lineRange)
        if !isActive && prettyMode {
            let pStyle = NSMutableParagraphStyle()
            pStyle.minimumLineHeight = 4.0
            pStyle.maximumLineHeight = 4.0
            pStyle.lineSpacing = 0
            pStyle.paragraphSpacing = 0
            pStyle.tailIndent = effectiveContainerWidth
            storage.addAttributes([
                .font: NSFont.systemFont(ofSize: 2.0),
                .foregroundColor: NSColor.clear,
                .paragraphStyle: pStyle
            ], range: lineRange)
        } else {
            storage.addAttributes([
                .font: theme.codeFont(size: effectiveBaseSize * 0.86),
                .foregroundColor: theme.markdownTokenNSColor.withAlphaComponent(0.85 * dimFactor)
            ], range: contentRange)
        }
    }
}
