import AppKit
import Foundation

extension LaTeXLiveStyler {

    static let foldOnlyWrapperEnvironments: Set<String> = [
        "itemize", "enumerate", "description",
        "figure", "figure*", "table", "table*", "center"
    ]

    static let codeBlockEnvironments: Set<String> = [
        "verbatim", "lstlisting", "minted"
    ]

    static let italicTheoremEnvironments: Set<String> = [
        "theorem", "lemma", "proposition", "corollary", "claim", "conjecture"
    ]

    static func styleFrontmatterLine(
        in storage: NSTextStorage,
        string: String,
        nsString: NSString,
        lineRange: NSRange,
        contentRange: NSRange,
        match: NSTextCheckingResult,
        isActiveLine: Bool,
        docIndex: LaTeXDocumentIndex,
        theme: EditorTheme,
        typography: EditorTypographySettings,
        effectiveBaseSize: CGFloat,
        effectiveContainerWidth: CGFloat,
        prettyMode: Bool,
        dimFactor: CGFloat,
        baseDirectoryURL: URL?,
        decorations: inout [LineDecoration]
    ) {
        let lineStr = storage.string as NSString
        let cmdRange = NSRange(location: contentRange.location + match.range(at: 1).location, length: match.range(at: 1).length)
        let cmd = lineStr.substring(with: cmdRange)
        let innerLocal = match.range(at: 2)
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
            font = theme.headingFont(level: 1, scale: typography.fontSizeScale * 1.05)
            color = theme.headingNSColor
        case "author":
            font = theme.bodyFont(size: effectiveBaseSize * 1.06, semibold: true)
            color = theme.textNSColor
        default:
            font = theme.bodyFont(size: effectiveBaseSize * 0.94)
            color = theme.secondaryTextNSColor
        }

        storage.addAttributes([
            .font: font,
            .foregroundColor: color.withAlphaComponent(dimFactor),
            .paragraphStyle: pStyle
        ], range: lineRange)

        MarkdownLiveStyler.styleSyntaxToken(in: storage, range: openSyntaxRange, isActiveLine: isActiveLine || !prettyMode, theme: theme, dimFactor: dimFactor)
        MarkdownLiveStyler.styleSyntaxToken(in: storage, range: closeSyntaxRange, isActiveLine: isActiveLine || !prettyMode, theme: theme, dimFactor: dimFactor)

        styleLaTeXInlineContent(
            in: storage,
            string: string,
            nsString: nsString,
            range: innerRange,
            lineRange: lineRange,
            baseFont: font,
            isActiveLine: isActiveLine,
            docIndex: docIndex,
            theme: theme,
            dimFactor: dimFactor,
            prettyMode: prettyMode,
            baseDirectoryURL: baseDirectoryURL,
            decorations: &decorations
        )
    }

    static func tryStyleLaTeXEnvironmentBlock(
        envName: String,
        in storage: NSTextStorage,
        string: String,
        nsString: NSString,
        fullLength: Int,
        lineRange: NSRange,
        contentRange: NSRange,
        lineText: String,
        trimmedLine: String,
        isActiveLine: Bool,
        activeLineRange: NSRange,
        selectedRange: NSRange,
        docIndex: LaTeXDocumentIndex,
        theme: EditorTheme,
        typography: EditorTypographySettings,
        textAlignment: NSTextAlignment,
        baseFont: NSFont,
        effectiveBaseSize: CGFloat,
        effectiveContainerWidth: CGFloat,
        prettyMode: Bool,
        focusMode: Bool,
        baseDirectoryURL: URL?,
        decorations: inout [LineDecoration]
    ) -> (nextIndex: Int, lineDelta: Int)? {
        let dimFactor: CGFloat = (focusMode && !isActiveLine) ? 0.30 : 1.0

        // Wrapper environments whose children are styled line-by-line
        if foldOnlyWrapperEnvironments.contains(envName) {
            styleDocumentBoundaryLineHelper(
                in: storage,
                lineRange: lineRange,
                contentRange: contentRange,
                isActive: isActiveLine,
                prettyMode: prettyMode,
                theme: theme,
                effectiveBaseSize: effectiveBaseSize,
                effectiveContainerWidth: effectiveContainerWidth,
                dimFactor: dimFactor
            )
            return (NSMaxRange(lineRange), 1)
        }

        // Collect all lines until \end{envName}
        let closeToken = "\\end{\(envName)}"
        var envLines: [(lineRange: NSRange, contentRange: NSRange, text: String, isActive: Bool)] = [
            (lineRange, contentRange, lineText, isActiveLine)
        ]
        var scanIndex = NSMaxRange(lineRange)
        var scanLineCount = 1

        if !trimmedLine.hasSuffix(closeToken) {
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
                let nt = nextText.trimmingCharacters(in: .whitespaces)
                if nt.hasPrefix(closeToken) || nt.hasSuffix(closeToken) {
                    break
                }
            }
        }

        let fullBlockRange = NSRange(location: lineRange.location, length: scanIndex - lineRange.location)
        let isBlockActive = envLines.contains(where: { $0.isActive }) ||
            NSIntersectionRange(fullBlockRange, selectedRange).length > 0
        let blockDim: CGFloat = (focusMode && !isBlockActive) ? 0.30 : 1.0

        // Code block environments (verbatim / lstlisting / minted)
        if codeBlockEnvironments.contains(envName) {
            storage.addAttribute(MKey.noSpellCheck, value: true, range: fullBlockRange)
            let monoFont = theme.codeFont(size: effectiveBaseSize * 0.90)
            for (i, el) in envLines.enumerated() {
                let pStyle = NSMutableParagraphStyle()
                pStyle.lineSpacing = 3.0
                pStyle.firstLineHeadIndent = 14.0
                pStyle.headIndent = 14.0
                pStyle.tailIndent = effectiveContainerWidth
                storage.addAttributes([
                    .font: monoFont,
                    .foregroundColor: theme.textNSColor.withAlphaComponent(blockDim),
                    .paragraphStyle: pStyle
                ], range: el.lineRange)
                if (i == 0 || i == envLines.count - 1) && !isBlockActive && prettyMode {
                    MarkdownLiveStyler.collapseWhitespaceRange(in: storage, range: el.contentRange)
                }
                let kind: BlockDecorationKind = (i == 0)
                    ? .codeFenceStart(language: envName)
                    : (i == envLines.count - 1 ? .codeFenceEnd : .codeFenceBody)
                decorations.append(LineDecoration(lineRange: el.lineRange, kind: kind))
            }
            return (scanIndex, scanLineCount)
        }

        // Abstract, Theorem-like, Proof, or Quote environments
        if envName == "abstract" || envName == "quote" || envName == "quotation"
            || LaTeXDocumentIndexer.theoremEnvironments[envName] != nil || envName == "proof" {
            styleStructuredEnvironmentLines(
                envName: envName,
                envLines: envLines,
                fullBlockRange: fullBlockRange,
                isBlockActive: isBlockActive,
                blockDim: blockDim,
                in: storage,
                string: string,
                nsString: nsString,
                docIndex: docIndex,
                theme: theme,
                typography: typography,
                textAlignment: textAlignment,
                baseFont: baseFont,
                effectiveBaseSize: effectiveBaseSize,
                effectiveContainerWidth: effectiveContainerWidth,
                prettyMode: prettyMode,
                baseDirectoryURL: baseDirectoryURL,
                decorations: &decorations
            )
            return (scanIndex, scanLineCount)
        }

        return nil
    }

    static func styleDocumentBoundaryLineHelper(
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
