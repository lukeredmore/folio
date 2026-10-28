import AppKit
import Foundation

extension MarkdownLiveStyler {

    static func styleTaskListLine(
        in storage: NSTextStorage,
        string: String,
        nsString: NSString,
        match: NSTextCheckingResult,
        lineRange: NSRange,
        lineNumber: Int,
        isActiveLine: Bool,
        baseFont: NSFont,
        baseColor: NSColor,
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
    ) -> CGFloat {
        let leadingWSRange = match.range(at: 1)
        let spaceAfterMarkerRange = match.range(at: 3)
        let boxRange = match.range(at: 4)
        let spaceAfterBoxRange = match.range(at: 5)
        let textRange = match.range(at: 6)
        let boxStr = nsString.substring(with: boxRange).lowercased()
        let isChecked = boxStr == "[x]"

        let indentCols = indentationColumnCount(nsString: nsString, range: leadingWSRange)
        let nestLevel = indentCols / 2
        let baseIndent: CGFloat = 10.0 + CGFloat(nestLevel) * 18.0
        let textIndent: CGFloat = baseIndent + 26.0

        let bulletPrefixRange = NSRange(
            location: leadingWSRange.location,
            length: NSMaxRange(spaceAfterMarkerRange) - leadingWSRange.location
        )
        styleSyntaxToken(
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
            collapseWhitespaceRange(in: storage, range: spaceAfterBoxRange)
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

        if multiLineParagraphLines.contains(lineNumber) && proseLineKinds[lineNumber] != nil {
            deferredProseInline.append(
                DeferredInlineStyle(
                    line: lineNumber, range: textRange, baseFont: baseFont, isActive: isActiveLine, dimFactor: dimFactor
                ))
        } else {
            styleInlineMarkdown(
                in: storage,
                string: string,
                range: textRange,
                lineRange: lineRange,
                baseFont: baseFont,
                isActiveLine: isActiveLine,
                theme: theme,
                dimFactor: dimFactor,
                normalizeWhitespace: !isActiveLine,
                prettyMode: prettyMode,
                baseDirectoryURL: baseDirectoryURL,
                decorations: &decorations
            )
        }

        return textIndent
    }

    static func styleStandardListLine(
        in storage: NSTextStorage,
        string: String,
        nsString: NSString,
        match: NSTextCheckingResult,
        lineRange: NSRange,
        contentRange: NSRange,
        lineNumber: Int,
        isActiveLine: Bool,
        baseFont: NSFont,
        baseColor: NSColor,
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
    ) -> CGFloat {
        let leadingWSRange = match.range(at: 1)
        let markerSymbolRange = match.range(at: 2)
        let postMarkerWSRange = match.range(at: 3)
        let bodyRange = match.range(at: 4)

        let indentCols = indentationColumnCount(nsString: nsString, range: leadingWSRange)
        let nestLevel = indentCols / 2
        let isOrdered = orderedListRegex.firstMatch(in: string, options: [], range: contentRange) != nil
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
                decorations.append(
                    LineDecoration(
                        lineRange: lineRange,
                        kind: .listBullet(range: markerSymbolRange, dimFactor: dimFactor)
                    ))
            }
            if leadingWSRange.length > 0 {
                collapseWhitespaceRange(in: storage, range: leadingWSRange)
            }
            if postMarkerWSRange.length > 0 {
                let desiredGap = max(4.0, markerAdvance - markerW)
                collapseWhitespaceRange(in: storage, range: postMarkerWSRange)
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

        if multiLineParagraphLines.contains(lineNumber) && proseLineKinds[lineNumber] != nil {
            deferredProseInline.append(
                DeferredInlineStyle(
                    line: lineNumber, range: bodyRange, baseFont: baseFont, isActive: isActiveLine, dimFactor: dimFactor
                ))
        } else {
            styleInlineMarkdown(
                in: storage,
                string: string,
                range: bodyRange,
                lineRange: lineRange,
                baseFont: baseFont,
                isActiveLine: isActiveLine,
                theme: theme,
                dimFactor: dimFactor,
                normalizeWhitespace: !isActiveLine,
                prettyMode: prettyMode,
                baseDirectoryURL: baseDirectoryURL,
                decorations: &decorations
            )
        }

        return textIndent
    }

    static func styleLinkReferenceDefinitionLine(
        in storage: NSTextStorage,
        refDefMatch: NSTextCheckingResult,
        contentRange: NSRange,
        isActiveLine: Bool,
        theme: EditorTheme,
        effectiveBaseSize: CGFloat,
        dimFactor: CGFloat
    ) {
        let labelRange = refDefMatch.range(at: 1)
        let destRange = refDefMatch.range(at: 2)
        let prefixLen = (labelRange.location - contentRange.location) + labelRange.length + 2 // includes `]:`
        let prefixRange = NSRange(location: contentRange.location, length: min(contentRange.length, prefixLen))

        storage.addAttributes(
            [
                .font: theme.codeFont(size: max(11.0, effectiveBaseSize * 0.86)),
                .foregroundColor: theme.markdownTokenNSColor.withAlphaComponent((isActiveLine ? 0.90 : 0.65) * dimFactor)
            ], range: prefixRange)
        storage.addAttributes(
            [
                .font: theme.codeFont(size: max(11.0, effectiveBaseSize * 0.86)),
                .foregroundColor: theme.linkNSColor.withAlphaComponent((isActiveLine ? 0.95 : 0.75) * dimFactor),
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ], range: destRange)
    }

    static func styleDefaultParagraphOrListContinuationLine(
        in storage: NSTextStorage,
        string: String,
        nsString: NSString,
        lineRange: NSRange,
        contentRange: NSRange,
        lineNumber: Int,
        isActiveLine: Bool,
        baseFont: NSFont,
        baseColor: NSColor,
        theme: EditorTheme,
        typography: EditorTypographySettings,
        effectiveContainerWidth: CGFloat,
        dimFactor: CGFloat,
        prettyMode: Bool,
        baseDirectoryURL: URL?,
        multiLineParagraphLines: Set<Int>,
        previousListTextIndent: inout CGFloat?,
        proseLineKinds: inout [Int: ProseLineKind],
        deferredProseInline: inout [DeferredInlineStyle],
        decorations: inout [LineDecoration]
    ) {
        if let listIndent = previousListTextIndent,
            let leadMatch = leadingSpaceRegex.firstMatch(in: string, options: [], range: contentRange),
            indentationColumnCount(nsString: nsString, range: leadMatch.range) >= 2
        {
            let leadW =
                isActiveLine && leadMatch.range.length > 0
                ? (nsString.substring(with: leadMatch.range) as NSString).size(withAttributes: [.font: baseFont]).width
                : 0.0
            if !isActiveLine && leadMatch.range.length > 0 {
                collapseWhitespaceRange(in: storage, range: leadMatch.range)
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
            previousListTextIndent = nil
        }

        proseLineKinds[lineNumber] = .paragraph
        if dimFactor < 1.0 {
            storage.addAttribute(.foregroundColor, value: baseColor.withAlphaComponent(dimFactor), range: contentRange)
        }

        if multiLineParagraphLines.contains(lineNumber) && proseLineKinds[lineNumber] != nil {
            deferredProseInline.append(
                DeferredInlineStyle(
                    line: lineNumber, range: contentRange, baseFont: baseFont, isActive: isActiveLine, dimFactor: dimFactor
                ))
        } else {
            styleInlineMarkdown(
                in: storage,
                string: string,
                range: contentRange,
                lineRange: lineRange,
                baseFont: baseFont,
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
}
