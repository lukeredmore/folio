import AppKit
import Foundation

extension LaTeXLiveStyler {

    static let itemCommandRegex = try! NSRegularExpression(
        pattern: #"^([ \t]*)(\\item)(?:\[([^\]]*)\])?([ \t]+|$)(.*)$"#
    )
    static let includeGraphicsRegex = try! NSRegularExpression(
        pattern: #"^([ \t]*)\\includegraphics(?:\[([^\]]*)\])?\{([^}]+)\}[ \t]*$"#
    )
    static let captionCommandRegex = try! NSRegularExpression(
        pattern: #"^([ \t]*)(\\caption\*?\{)(.*)(\})[ \t]*$"#
    )
    static let tableRuleRegex = try! NSRegularExpression(
        pattern: #"^[ \t]*\\(?:hline|toprule|midrule|bottomrule|cline\{[^}]*\})[ \t]*$"#
    )

    static func styleStructuredEnvironmentLines(
        envName: String,
        envLines: [(lineRange: NSRange, contentRange: NSRange, text: String, isActive: Bool)],
        fullBlockRange: NSRange,
        isBlockActive: Bool,
        blockDim: CGFloat,
        in storage: NSTextStorage,
        string: String,
        nsString: NSString,
        docIndex: LaTeXDocumentIndex,
        theme: EditorTheme,
        typography: EditorTypographySettings,
        textAlignment: NSTextAlignment,
        baseFont: NSFont,
        effectiveBaseSize: CGFloat,
        effectiveContainerWidth: CGFloat,
        prettyMode: Bool,
        baseDirectoryURL: URL?,
        decorations: inout [LineDecoration]
    ) {
        let isAbstract = (envName == "abstract")
        let isQuote = (envName == "quote" || envName == "quotation")
        let isTheoremOrProof = !isAbstract && !isQuote
        let isItalicBody = italicTheoremEnvironments.contains(envName)
        let bodyFont = isItalicBody
            ? docIndex.bodyFont(size: effectiveBaseSize, italic: true, fallbackTheme: theme)
            : (isAbstract ? docIndex.bodyFont(size: effectiveBaseSize * 0.95, fallbackTheme: theme) : baseFont)
        let indent: CGFloat = isAbstract ? 28.0 : (isQuote ? 20.0 : 18.0)

        for (i, el) in envLines.enumerated() {
            let isFirst = (i == 0)
            let isLast = (i == envLines.count - 1 && envLines.count > 1)

            if (isFirst || isLast) && !el.isActive && prettyMode {
                let headerHeight: CGFloat = isFirst
                    ? (isAbstract ? 26.0 : (isTheoremOrProof ? 26.0 : 6.0))
                    : (envName == "proof" ? 10.0 : 6.0)
                let pStyle = NSMutableParagraphStyle()
                pStyle.minimumLineHeight = headerHeight
                pStyle.maximumLineHeight = headerHeight
                pStyle.lineSpacing = 0
                pStyle.paragraphSpacing = 0
                pStyle.tailIndent = effectiveContainerWidth
                storage.addAttributes([
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
            pStyle.tailIndent = isAbstract
                ? max(120.0, effectiveContainerWidth - 28.0)
                : effectiveContainerWidth

            storage.addAttributes([
                .font: bodyFont,
                .foregroundColor: (isQuote ? theme.blockquoteTextNSColor : theme.textNSColor).withAlphaComponent(blockDim),
                .paragraphStyle: pStyle
            ], range: el.lineRange)

            if (isFirst || isLast) && (el.isActive || !prettyMode) {
                storage.addAttribute(MKey.noSpellCheck, value: true, range: el.lineRange)
                MarkdownLiveStyler.highlightLaTeXSource(in: storage, range: el.contentRange, theme: theme, dimFactor: blockDim)
            } else {
                styleLaTeXInlineContent(
                    in: storage,
                    string: string,
                    nsString: nsString,
                    range: el.contentRange,
                    lineRange: el.lineRange,
                    baseFont: bodyFont,
                    isActiveLine: el.isActive,
                    docIndex: docIndex,
                    theme: theme,
                    dimFactor: blockDim,
                    prettyMode: prettyMode,
                    baseDirectoryURL: baseDirectoryURL,
                    decorations: &decorations
                )
            }

            if isQuote {
                decorations.append(LineDecoration(lineRange: el.lineRange, kind: .blockquote(nestLevel: 1)))
            }
        }

        let showHeader = !(envLines.first?.isActive ?? false) && prettyMode
        _ = isBlockActive
        if isAbstract {
            decorations.append(LineDecoration(
                lineRange: fullBlockRange,
                kind: .latexAbstractCard(showHeader: showHeader, fullBlockRange: fullBlockRange, dimFactor: blockDim)
            ))
        } else if isTheoremOrProof {
            let header = docIndex.blockTheoremHeaders[envLines[0].lineRange.location]?.header ?? envName.capitalized
            decorations.append(LineDecoration(
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

    static func tryStyleSingleLineListOrFigureCommand(
        in storage: NSTextStorage,
        string: String,
        nsString: NSString,
        lineRange: NSRange,
        contentRange: NSRange,
        lineText: String,
        trimmedLine: String,
        isActiveLine: Bool,
        docIndex: LaTeXDocumentIndex,
        theme: EditorTheme,
        typography: EditorTypographySettings,
        baseFont: NSFont,
        effectiveBaseSize: CGFloat,
        effectiveContainerWidth: CGFloat,
        prettyMode: Bool,
        dimFactor: CGFloat,
        baseDirectoryURL: URL?,
        decorations: inout [LineDecoration]
    ) -> (nextIndex: Int, lineDelta: Int)? {
        let lineLen = (lineText as NSString).length
        let localFull = NSRange(location: 0, length: lineLen)

        // 1. \end{itemize|enumerate|description|figure|table|center}
        if let endEnv = LaTeXDocumentIndexer.parseEndEnvironment(trimmedLine),
           foldOnlyWrapperEnvironments.contains(endEnv) {
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

        // 2. \hline, \toprule, \midrule, \bottomrule
        if (trimmedLine.hasPrefix("\\hline") || trimmedLine.hasPrefix("\\toprule")
            || trimmedLine.hasPrefix("\\midrule") || trimmedLine.hasPrefix("\\bottomrule")
            || trimmedLine.hasPrefix("\\cline")),
           tableRuleRegex.firstMatch(in: lineText, range: localFull) != nil {
            storage.addAttribute(MKey.noSpellCheck, value: true, range: lineRange)
            if !isActiveLine && prettyMode {
                MarkdownLiveStyler.collapseWhitespaceRange(in: storage, range: contentRange)
                decorations.append(LineDecoration(lineRange: lineRange, kind: .horizontalRule))
            } else {
                MarkdownLiveStyler.styleSyntaxToken(in: storage, range: contentRange, isActiveLine: true, theme: theme, dimFactor: dimFactor)
            }
            return (NSMaxRange(lineRange), 1)
        }

        // 3. \item or \item[...]
        if trimmedLine.hasPrefix("\\item"),
           let im = itemCommandRegex.firstMatch(in: lineText, range: localFull) {
            let itemTokenRange = NSRange(location: contentRange.location + im.range(at: 2).location, length: im.range(at: 2).length)
            let optLabelLocal = im.range(at: 3)
            let spaceRange = NSRange(location: contentRange.location + im.range(at: 4).location, length: im.range(at: 4).length)
            let bodyRange = NSRange(location: contentRange.location + im.range(at: 5).location, length: im.range(at: 5).length)

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

            if optLabelLocal.location != NSNotFound {
                let bracketFull = NSRange(
                    location: contentRange.location + optLabelLocal.location - 1,
                    length: optLabelLocal.length + 2
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

            styleLaTeXInlineContent(
                in: storage,
                string: string,
                nsString: nsString,
                range: bodyRange,
                lineRange: lineRange,
                baseFont: baseFont,
                isActiveLine: isActiveLine,
                docIndex: docIndex,
                theme: theme,
                dimFactor: dimFactor,
                prettyMode: prettyMode,
                baseDirectoryURL: baseDirectoryURL,
                decorations: &decorations
            )
            return (NSMaxRange(lineRange), 1)
        }

        // 4. \includegraphics[...]{path}
        if trimmedLine.hasPrefix("\\includegraphics"),
           let gm = includeGraphicsRegex.firstMatch(in: lineText, range: localFull) {
            let imgPath = (lineText as NSString).substring(with: gm.range(at: 3))
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
                storage.addAttributes([
                    .font: NSFont.systemFont(ofSize: 10.0),
                    .foregroundColor: NSColor.clear,
                    .paragraphStyle: pStyle
                ], range: lineRange)
                decorations.append(LineDecoration(
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

        // 5. \caption{...}
        if trimmedLine.hasPrefix("\\caption"),
           let cm = captionCommandRegex.firstMatch(in: lineText, range: localFull) {
            let openRange = NSRange(location: contentRange.location + cm.range(at: 2).location, length: cm.range(at: 2).length)
            let innerRange = NSRange(location: contentRange.location + cm.range(at: 3).location, length: cm.range(at: 3).length)
            let closeRange = NSRange(location: contentRange.location + cm.range(at: 4).location, length: cm.range(at: 4).length)
            let captionFont = docIndex.bodyFont(size: effectiveBaseSize * 0.90, italic: true, fallbackTheme: theme)
            let pStyle = NSMutableParagraphStyle()
            pStyle.alignment = .center
            pStyle.paragraphSpacingBefore = 4.0
            pStyle.paragraphSpacing = 8.0
            pStyle.tailIndent = effectiveContainerWidth
            storage.addAttributes([
                .font: captionFont,
                .foregroundColor: theme.secondaryTextNSColor.withAlphaComponent(dimFactor),
                .paragraphStyle: pStyle
            ], range: lineRange)
            MarkdownLiveStyler.styleSyntaxToken(in: storage, range: openRange, isActiveLine: isActiveLine, theme: theme, dimFactor: dimFactor)
            MarkdownLiveStyler.styleSyntaxToken(in: storage, range: closeRange, isActiveLine: isActiveLine, theme: theme, dimFactor: dimFactor)
            styleLaTeXInlineContent(
                in: storage,
                string: string,
                nsString: nsString,
                range: innerRange,
                lineRange: lineRange,
                baseFont: captionFont,
                isActiveLine: isActiveLine,
                docIndex: docIndex,
                theme: theme,
                dimFactor: dimFactor,
                prettyMode: prettyMode,
                baseDirectoryURL: baseDirectoryURL,
                decorations: &decorations
            )
            return (NSMaxRange(lineRange), 1)
        }

        return nil
    }
}
