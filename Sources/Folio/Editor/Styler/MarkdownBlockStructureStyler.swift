import AppKit
import Foundation

extension MarkdownLiveStyler {

    static func styleHorizontalRuleLine(
        in storage: NSTextStorage,
        lineRange: NSRange,
        contentRange: NSRange,
        isActiveLine: Bool,
        theme: EditorTheme,
        typography: EditorTypographySettings,
        effectiveContainerWidth: CGFloat,
        dimFactor: CGFloat,
        decorations: inout [LineDecoration]
    ) {
        decorations.append(LineDecoration(lineRange: lineRange, kind: .horizontalRule))
        let hrPara = NSMutableParagraphStyle()
        hrPara.minimumLineHeight = 28.0
        hrPara.maximumLineHeight = 28.0
        hrPara.paragraphSpacingBefore = 6.0 * typography.headingSpacingScale
        hrPara.paragraphSpacing = 6.0 * typography.headingSpacingScale
        hrPara.tailIndent = effectiveContainerWidth
        storage.addAttribute(.paragraphStyle, value: hrPara, range: lineRange)
        styleSyntaxToken(
            in: storage,
            range: contentRange,
            isActiveLine: isActiveLine,
            theme: theme,
            dimFactor: dimFactor
        )
    }

    static func styleATXHeadingLine(
        in storage: NSTextStorage,
        string: String,
        nsString: NSString,
        match: NSTextCheckingResult,
        lineRange: NSRange,
        contentRange: NSRange,
        lineNumber: Int,
        isActiveLine: Bool,
        theme: EditorTheme,
        typography: EditorTypographySettings,
        effectiveContainerWidth: CGFloat,
        dimFactor: CGFloat,
        prettyMode: Bool,
        baseDirectoryURL: URL?,
        headings: inout [OutlineHeading],
        decorations: inout [LineDecoration]
    ) {
        let leadingRange = match.range(at: 1)
        let hashesRange = match.range(at: 2)
        let spaceRange = match.range(at: 3)
        let titleRange = match.range(at: 4)
        let level = min(6, max(1, hashesRange.length))
        let titleText = titleRange.location != NSNotFound ? nsString.substring(with: titleRange) : ""

        if !titleText.isEmpty {
            headings.append(OutlineHeading(
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

        storage.addAttributes([
            .font: hFont,
            .foregroundColor: theme.headingNSColor.withAlphaComponent(dimFactor),
            .paragraphStyle: hPara,
            .kern: typography.headingCharacterSpacing
        ], range: lineRange)

        let prefixEnd = spaceRange.location != NSNotFound ? NSMaxRange(spaceRange) : NSMaxRange(hashesRange)
        let prefixRange = NSRange(location: leadingRange.location, length: prefixEnd - leadingRange.location)
        styleSyntaxToken(
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
                styleSyntaxToken(
                    in: storage,
                    range: NSRange(location: suffixStart, length: suffixLen),
                    isActiveLine: isActiveLine,
                    theme: theme,
                    dimFactor: dimFactor
                )
            }
        }

        if level <= 2 && typography.showHeadingUnderlines {
            decorations.append(LineDecoration(lineRange: lineRange, kind: .headingUnderline(level: level)))
        }

        if titleRange.location != NSNotFound && titleRange.length > 0 {
            styleInlineMarkdown(
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
                decorations: &decorations
            )
        }
    }

    static func styleBlockquoteLine(
        in storage: NSTextStorage,
        string: String,
        nsString: NSString,
        match: NSTextCheckingResult,
        lineRange: NSRange,
        lineNumber: Int,
        isActiveLine: Bool,
        theme: EditorTheme,
        typography: EditorTypographySettings,
        effectiveBaseSize: CGFloat,
        effectiveContainerWidth: CGFloat,
        dimFactor: CGFloat,
        prettyMode: Bool,
        baseDirectoryURL: URL?,
        multiLineParagraphLines: Set<Int>,
        proseLineKinds: inout [Int: ProseLineKind],
        deferredProseInline: inout [DeferredInlineStyle],
        decorations: inout [LineDecoration]
    ) {
        let markerRange = match.range(at: 1)
        let bodyRange = match.range(at: 2)
        let markerText = nsString.substring(with: markerRange)
        let nestLevel = max(1, markerText.filter { $0 == ">" }.count)

        decorations.append(LineDecoration(lineRange: lineRange, kind: .blockquote(nestLevel: nestLevel)))

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

        // Support ATX headings nested inside blockquotes (e.g. `> ### Note`)
        if bodyRange.length > 0,
           let innerHeading = headingRegex.firstMatch(in: string, options: [], range: bodyRange),
           innerHeading.range(at: 3).location != NSNotFound {
            let hLevel = min(6, max(1, innerHeading.range(at: 2).length))
            bqFont = theme.headingFont(level: hLevel, scale: typography.fontSizeScale)
            bqColor = theme.headingNSColor.withAlphaComponent(dimFactor)
            let innerPrefixEnd = NSMaxRange(innerHeading.range(at: 3))
            let innerPrefixRange = NSRange(location: bodyRange.location, length: innerPrefixEnd - bodyRange.location)
            inlineRange = innerHeading.range(at: 4)
            storage.addAttributes([
                .font: bqFont,
                .foregroundColor: bqColor,
                .paragraphStyle: bqPara,
                .kern: typography.headingCharacterSpacing
            ], range: lineRange)
            styleSyntaxToken(in: storage, range: innerPrefixRange, isActiveLine: isActiveLine, theme: theme, dimFactor: dimFactor)
        } else {
            proseLineKinds[lineNumber] = .blockquote(nestLevel: nestLevel)
            storage.addAttributes([
                .font: bqFont,
                .foregroundColor: bqColor,
                .paragraphStyle: bqPara,
                .kern: typography.characterSpacing
            ], range: lineRange)
        }

        styleSyntaxToken(
            in: storage,
            range: markerRange,
            isActiveLine: isActiveLine,
            theme: theme,
            dimFactor: dimFactor
        )

        if multiLineParagraphLines.contains(lineNumber) && proseLineKinds[lineNumber] != nil {
            deferredProseInline.append(DeferredInlineStyle(
                line: lineNumber, range: inlineRange, baseFont: bqFont, isActive: isActiveLine, dimFactor: dimFactor
            ))
        } else {
            styleInlineMarkdown(
                in: storage,
                string: string,
                range: inlineRange,
                lineRange: lineRange,
                baseFont: bqFont,
                isActiveLine: isActiveLine,
                theme: theme,
                dimFactor: dimFactor,
                normalizeWhitespace: !isActiveLine,
                prettyMode: prettyMode,
                baseDirectoryURL: baseDirectoryURL,
                decorations: &decorations
            )
        }
    }

    static func tryStyleSetextHeadingBlock(
        in storage: NSTextStorage,
        string: String,
        nsString: NSString,
        fullLength: Int,
        lineRange: NSRange,
        contentRange: NSRange,
        trimmedLine: String,
        lineNumber: Int,
        isActiveLine: Bool,
        activeLineRange: NSRange,
        selectedRange: NSRange,
        theme: EditorTheme,
        typography: EditorTypographySettings,
        effectiveContainerWidth: CGFloat,
        focusMode: Bool,
        prettyMode: Bool,
        baseDirectoryURL: URL?,
        headings: inout [OutlineHeading],
        decorations: inout [LineDecoration]
    ) -> Int? {
        let nextLineStart = NSMaxRange(lineRange)
        guard nextLineStart < fullLength else { return nil }
        let nextLR = nsString.lineRange(for: NSRange(location: nextLineStart, length: 0))
        let nextCR = strippedLineContentRange(nsString: nsString, lineRange: nextLR)
        guard nextCR.length > 0 else { return nil }

        let isSetextH1 = setextH1Regex.firstMatch(in: string, options: [], range: nextCR) != nil
        let isSetextH2 = !isSetextH1 && setextH2Regex.firstMatch(in: string, options: [], range: nextCR) != nil
        guard isSetextH1 || isSetextH2 else { return nil }

        let level = isSetextH1 ? 1 : 2
        let nextActive = isLineActive(lineRange: nextLR, activeLineRange: activeLineRange, selectedRange: selectedRange)
        let combinedActive = isActiveLine || nextActive
        let setextDim: CGFloat = (focusMode && !combinedActive) ? 0.30 : 1.0

        let titleText = trimmedLine
        if !titleText.isEmpty {
            headings.append(OutlineHeading(
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

        storage.addAttributes([
            .font: hFont,
            .foregroundColor: theme.headingNSColor.withAlphaComponent(setextDim),
            .paragraphStyle: hPara,
            .kern: typography.headingCharacterSpacing
        ], range: lineRange)

        if typography.showHeadingUnderlines {
            decorations.append(LineDecoration(lineRange: lineRange, kind: .headingUnderline(level: level)))
        }

        styleInlineMarkdown(
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
            decorations: &decorations
        )

        // Style or collapse the Setext underline row
        let underlinePara = NSMutableParagraphStyle()
        underlinePara.lineSpacing = 0.0
        underlinePara.paragraphSpacing = 0.0
        underlinePara.paragraphSpacingBefore = 0.0
        underlinePara.minimumLineHeight = combinedActive ? 20.0 : 1.0
        underlinePara.maximumLineHeight = combinedActive ? 20.0 : 1.0
        underlinePara.tailIndent = effectiveContainerWidth
        storage.addAttribute(.paragraphStyle, value: underlinePara, range: nextLR)
        styleSyntaxToken(in: storage, range: nextCR, isActiveLine: combinedActive, theme: theme, dimFactor: setextDim)

        return NSMaxRange(nextLR)
    }
}
