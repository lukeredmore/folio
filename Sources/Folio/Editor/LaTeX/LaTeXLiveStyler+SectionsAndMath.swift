import AppKit
import FolioEngineFFI
import Foundation

extension LaTeXLiveStyler {

    static let displayMathEnvironments: Set<String> = [
        "equation", "equation*", "align", "align*", "gather", "gather*",
        "multline", "multline*", "flalign", "flalign*", "alignat", "alignat*"
    ]

    static func tryStyleLaTeXBlockOrEnvironment(
        in storage: NSTextStorage,
        string: String,
        nsString: NSString,
        fullLength: Int,
        lineRange: NSRange,
        contentRange: NSRange,
        lineText: String,
        trimmedLine: String,
        lineNumber: Int,
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
        dimFactor: CGFloat,
        baseDirectoryURL: URL?,
        flow: LaTeXFlowState = LaTeXFlowState(),
        headings: inout [OutlineHeading],
        decorations: inout [LineDecoration]
    ) -> (nextIndex: Int, lineDelta: Int)? {
        if trimmedLine.isEmpty {
            return styleLaTeXBlankLineBlock(
                in: storage, nsString: nsString, fullLength: fullLength, lineRange: lineRange,
                isActiveLine: isActiveLine, activeLineRange: activeLineRange, selectedRange: selectedRange,
                docIndex: docIndex, typography: typography, effectiveBaseSize: effectiveBaseSize,
                effectiveContainerWidth: effectiveContainerWidth, prettyMode: prettyMode
            )
        }
        guard trimmedLine.hasPrefix("\\") || trimmedLine.hasPrefix("$$") || trimmedLine.hasPrefix("%") else { return nil }

        if trimmedLine.hasPrefix("%") {
            return styleLaTeXCommentBlock(
                in: storage, nsString: nsString, fullLength: fullLength, lineRange: lineRange,
                contentRange: contentRange, isActiveLine: isActiveLine, activeLineRange: activeLineRange,
                selectedRange: selectedRange, theme: theme, effectiveBaseSize: effectiveBaseSize,
                effectiveContainerWidth: effectiveContainerWidth, prettyMode: prettyMode, focusMode: focusMode
            )
        }

        // 1. Sectioning commands (\section{...}, \subsection{...}, etc.)
        if let secInfo = docIndex.lineSectionNumbers[lineRange.location] {
            let cls = lineText.withCString { ot_engine_classify_latex_line($0) }
            defer { ot_engine_free_latex_line_classification(cls) }
            if cls.kind == 5 && cls.close_len > 0 {
                let innerLocal = NSRange(location: Int(cls.body_loc), length: Int(cls.body_len))
                styleSectionLine(
                    in: storage,
                    string: string,
                    nsString: nsString,
                    lineRange: lineRange,
                    contentRange: contentRange,
                    innerLocal: innerLocal,
                    secInfo: secInfo,
                    lineNumber: lineNumber,
                    isActiveLine: isActiveLine,
                    docIndex: docIndex,
                    theme: theme,
                    typography: typography,
                    effectiveBaseSize: effectiveBaseSize,
                    effectiveContainerWidth: effectiveContainerWidth,
                    prettyMode: prettyMode,
                    dimFactor: dimFactor,
                    baseDirectoryURL: baseDirectoryURL,
                    headings: &headings,
                    decorations: &decorations
                )
                return (NSMaxRange(lineRange), 1)
            }
        }

        // 2. Frontmatter (\title{...}, \author{...}, \date{...}, \maketitle)
        if trimmedLine == "\\maketitle" {
            storage.addAttribute(MKey.noSpellCheck, value: true, range: lineRange)
            if !isActiveLine && prettyMode {
                MarkdownLiveStyler.collapseWhitespaceRange(in: storage, range: contentRange)
                decorations.append(LineDecoration(lineRange: lineRange, kind: .horizontalRule))
            } else {
                MarkdownLiveStyler.styleSyntaxToken(in: storage, range: contentRange, isActiveLine: true, theme: theme, dimFactor: dimFactor)
            }
            return (NSMaxRange(lineRange), 1)
        }
        if trimmedLine.hasPrefix("\\title") || trimmedLine.hasPrefix("\\author") || trimmedLine.hasPrefix("\\date") {
            let cls = lineText.withCString { ot_engine_classify_latex_line($0) }
            defer { ot_engine_free_latex_line_classification(cls) }
            let cmd = cls.cmd.map { String(cString: $0) } ?? ""
            if cls.kind == 5 && cls.close_len > 0 && (cmd == "title" || cmd == "author" || cmd == "date") {
                let innerLocal = NSRange(location: Int(cls.body_loc), length: Int(cls.body_len))
                styleFrontmatterLine(
                    in: storage,
                    string: string,
                    nsString: nsString,
                    lineRange: lineRange,
                    contentRange: contentRange,
                    cmd: cmd,
                    innerLocal: innerLocal,
                    isActiveLine: isActiveLine,
                    docIndex: docIndex,
                    theme: theme,
                    typography: typography,
                    effectiveBaseSize: effectiveBaseSize,
                    effectiveContainerWidth: effectiveContainerWidth,
                    prettyMode: prettyMode,
                    dimFactor: dimFactor,
                    baseDirectoryURL: baseDirectoryURL,
                    decorations: &decorations
                )
                return (NSMaxRange(lineRange), 1)
            }
        }

        // 3. \input{...} and \include{...}
        if trimmedLine.hasPrefix("\\input") || trimmedLine.hasPrefix("\\include") {
            let cls = lineText.withCString { ot_engine_classify_latex_line($0) }
            defer { ot_engine_free_latex_line_classification(cls) }
            let cmd = cls.cmd.map { String(cString: $0) } ?? ""
            if cls.kind == 5 && cls.close_len > 0 && (cmd == "input" || cmd == "include") {
                let relPath = cls.arg1.map { String(cString: $0) } ?? ""
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
                return (NSMaxRange(lineRange), 1)
            }
        }

        // 4. Display Math: $$...$$, \[...\], or \begin{equation|align|gather|multline}
        if trimmedLine.hasPrefix("$$") || trimmedLine.hasPrefix("\\[") {
            let closeToken = trimmedLine.hasPrefix("\\[") ? "\\]" : "$$"
            return styleLaTeXDisplayMathBlock(
                in: storage,
                nsString: nsString,
                fullLength: fullLength,
                lineRange: lineRange,
                contentRange: contentRange,
                lineText: lineText,
                trimmedLine: trimmedLine,
                closeToken: closeToken,
                envName: nil,
                equationNumber: nil,
                isActiveLine: isActiveLine,
                activeLineRange: activeLineRange,
                selectedRange: selectedRange,
                theme: theme,
                effectiveBaseSize: effectiveBaseSize,
                effectiveContainerWidth: effectiveContainerWidth,
                focusMode: focusMode,
                decorations: &decorations
            )
        }

        if let envName = LaTeXDocumentIndexer.parseBeginEnvironment(trimmedLine) {
            if displayMathEnvironments.contains(envName) {
                let eqNum = docIndex.blockEquationNumbers[lineRange.location]
                return styleLaTeXDisplayMathBlock(
                    in: storage,
                    nsString: nsString,
                    fullLength: fullLength,
                    lineRange: lineRange,
                    contentRange: contentRange,
                    lineText: lineText,
                    trimmedLine: trimmedLine,
                    closeToken: "\\end{\(envName)}",
                    envName: envName,
                    equationNumber: eqNum,
                    isActiveLine: isActiveLine,
                    activeLineRange: activeLineRange,
                    selectedRange: selectedRange,
                    theme: theme,
                    effectiveBaseSize: effectiveBaseSize,
                    effectiveContainerWidth: effectiveContainerWidth,
                    focusMode: focusMode,
                    decorations: &decorations
                )
            }
            return tryStyleLaTeXEnvironmentBlock(
                envName: envName, in: storage, string: string, nsString: nsString,
                fullLength: fullLength, lineRange: lineRange, contentRange: contentRange,
                lineText: lineText, trimmedLine: trimmedLine, isActiveLine: isActiveLine,
                activeLineRange: activeLineRange, selectedRange: selectedRange, docIndex: docIndex,
                theme: theme, typography: typography, textAlignment: textAlignment, baseFont: baseFont,
                effectiveBaseSize: effectiveBaseSize, effectiveContainerWidth: effectiveContainerWidth,
                prettyMode: prettyMode, focusMode: focusMode, baseDirectoryURL: baseDirectoryURL,
                flow: flow, decorations: &decorations
            )
        }

        if let condAdv = tryStyleLaTeXConditionalBlock(
            in: storage, string: string, nsString: nsString, fullLength: fullLength,
            lineRange: lineRange, contentRange: contentRange, lineText: lineText, trimmedLine: trimmedLine,
            isActiveLine: isActiveLine, activeLineRange: activeLineRange, selectedRange: selectedRange,
            docIndex: docIndex, theme: theme, typography: typography, baseFont: baseFont,
            effectiveBaseSize: effectiveBaseSize, effectiveContainerWidth: effectiveContainerWidth,
            prettyMode: prettyMode, focusMode: focusMode, baseDirectoryURL: baseDirectoryURL,
            decorations: &decorations
        ) {
            return condAdv
        }

        if let macroAdv = tryStyleLaTeXMacroBlock(
            in: storage, string: string, nsString: nsString, fullLength: fullLength,
            lineRange: lineRange, contentRange: contentRange, lineText: lineText, trimmedLine: trimmedLine,
            isActiveLine: isActiveLine, activeLineRange: activeLineRange, selectedRange: selectedRange,
            docIndex: docIndex, theme: theme, typography: typography, baseFont: baseFont,
            effectiveBaseSize: effectiveBaseSize, effectiveContainerWidth: effectiveContainerWidth,
            prettyMode: prettyMode, focusMode: focusMode, baseDirectoryURL: baseDirectoryURL,
            decorations: &decorations
        ) {
            return macroAdv
        }

        return tryStyleSingleLineListOrFigureCommand(
            in: storage, string: string, nsString: nsString, lineRange: lineRange,
            contentRange: contentRange, lineText: lineText, trimmedLine: trimmedLine,
            isActiveLine: isActiveLine, docIndex: docIndex, theme: theme, typography: typography,
            baseFont: baseFont, effectiveBaseSize: effectiveBaseSize,
            effectiveContainerWidth: effectiveContainerWidth, prettyMode: prettyMode,
            dimFactor: dimFactor, baseDirectoryURL: baseDirectoryURL, decorations: &decorations
        )
    }

    private static func styleSectionLine(
        in storage: NSTextStorage,
        string: String,
        nsString: NSString,
        lineRange: NSRange,
        contentRange: NSRange,
        innerLocal: NSRange,
        secInfo: (level: Int, number: String, title: String, starred: Bool),
        lineNumber: Int,
        isActiveLine: Bool,
        docIndex: LaTeXDocumentIndex,
        theme: EditorTheme,
        typography: EditorTypographySettings,
        effectiveBaseSize: CGFloat,
        effectiveContainerWidth: CGFloat,
        prettyMode: Bool,
        dimFactor: CGFloat,
        baseDirectoryURL: URL?,
        headings: inout [OutlineHeading],
        decorations: inout [LineDecoration]
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

        styleLaTeXInlineContent(
            in: storage,
            string: string,
            nsString: nsString,
            range: innerRange,
            lineRange: lineRange,
            baseFont: headingFont,
            isActiveLine: isActiveLine,
            docIndex: docIndex,
            theme: theme,
            dimFactor: dimFactor,
            prettyMode: prettyMode,
            baseDirectoryURL: baseDirectoryURL,
            decorations: &decorations
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
}
