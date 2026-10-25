import AppKit
import Foundation

extension LaTeXLiveStyler {

    private static let macroBlockOpenRegex = try! NSRegularExpression(
        pattern: #"^\s*\\([A-Za-z]+)(?:\[([^\]]*)\])?\s*\{"#
    )
    private static let macroColorRegex = try! NSRegularExpression(
        pattern: #"\\(?:text)?color\{([^}]+)\}"#
    )
    private static let macroBoldPrefixRegex = try! NSRegularExpression(
        pattern: #"\\textbf\{([^}]+)\}"#
    )
    private static let macroVspaceRegex = try! NSRegularExpression(
        pattern: #"\\vspace\*?\{([^}]+)\}"#
    )
    private static let macroSectionRegex = try! NSRegularExpression(
        pattern: #"\\(part|chapter|section|subsection|subsubsection)\*?\s*\{"#
    )

    private static let reservedMacroBlockNames: Set<String> = [
        "begin", "end", "section", "subsection", "subsubsection", "chapter", "part",
        "paragraph", "subparagraph", "title", "author", "date", "input", "include",
        "textbf", "textit", "emph", "underline", "texttt", "textsc", "footnote",
        "textcolor", "vspace", "hspace", "setlength", "definecolor", "newcommand",
        "renewcommand", "providecommand", "DeclareMathOperator", "item", "caption",
        "label", "ref", "eqref", "cite", "url", "href", "includegraphics"
    ]

    struct ResolvedMacroTemplate {
        let showsBody: Bool
        let color: NSColor?
        let prefixLabel: String?
        let vspacePoints: CGFloat?
        let headingLevel: Int?
    }

    static func analyzeMacroTemplate(
        def: LaTeXMacroDefinition, optArg: String?, docIndex: LaTeXDocumentIndex,
        theme: EditorTheme, effectiveBaseSize: CGFloat
    ) -> ResolvedMacroTemplate {
        var active = evaluateConditionalsInTeX(def.replacement, conditionals: docIndex.documentStyle.conditionals)
        if def.argCount >= 2 {
            active = active.replacingOccurrences(of: "#1", with: optArg ?? (def.defaultFirstArg ?? ""))
        }
        let bodyPlaceholder = "#\(def.argCount)"
        let showsBody = active.contains(bodyPlaceholder)
        let nsActive = active as NSString
        let fullRange = NSRange(location: 0, length: nsActive.length)

        var resolvedColor: NSColor?
        if let cm = macroColorRegex.firstMatch(in: active, range: fullRange) {
            resolvedColor = docIndex.resolveColor(named: nsActive.substring(with: cm.range(at: 1)), fallbackTheme: theme)
        }
        var prefixLabel: String?
        if showsBody, let bm = macroBoldPrefixRegex.firstMatch(in: active, range: fullRange),
           bm.range.location < nsActive.range(of: bodyPlaceholder).location {
            prefixLabel = nsActive.substring(with: bm.range(at: 1))
        }
        var vspacePt: CGFloat?
        macroVspaceRegex.enumerateMatches(in: active, range: fullRange) { m, _, _ in
            guard let m = m else { return }
            let rawLen = nsActive.substring(with: m.range(at: 1))
            if let parsed = LaTeXLength.parse(rawLen)?.resolvedPoints(baseSize: effectiveBaseSize) {
                vspacePt = max(vspacePt ?? 0.0, parsed)
            }
        }
        var headingLevel: Int?
        if showsBody, let sm = macroSectionRegex.firstMatch(in: active, range: fullRange) {
            let secCmd = nsActive.substring(with: sm.range(at: 1))
            headingLevel = LaTeXDocumentIndexer.sectionLevel(for: secCmd)
        }
        return ResolvedMacroTemplate(
            showsBody: showsBody, color: resolvedColor, prefixLabel: prefixLabel,
            vspacePoints: vspacePt, headingLevel: headingLevel
        )
    }

    static func findMatchingCloseBrace(in nsString: NSString, openBraceLocation: Int, fullLength: Int) -> Int? {
        var depth = 1
        var idx = openBraceLocation + 1
        while idx < fullLength {
            let ch = nsString.character(at: idx)
            if ch == 0x5C { idx += 2; continue }
            if ch == 0x25 {
                while idx < fullLength && nsString.character(at: idx) != 0x0A { idx += 1 }
                continue
            }
            if ch == 0x7B { depth += 1 }
            else if ch == 0x7D {
                depth -= 1
                if depth == 0 { return idx }
            }
            idx += 1
        }
        return nil
    }

    static func tryStyleLaTeXMacroBlock(
        in storage: NSTextStorage, string: String, nsString: NSString, fullLength: Int,
        lineRange: NSRange, contentRange: NSRange, lineText: String, trimmedLine: String,
        isActiveLine: Bool, activeLineRange: NSRange, selectedRange: NSRange,
        docIndex: LaTeXDocumentIndex, theme: EditorTheme, typography: EditorTypographySettings,
        baseFont: NSFont, effectiveBaseSize: CGFloat, effectiveContainerWidth: CGFloat,
        prettyMode: Bool, focusMode: Bool, baseDirectoryURL: URL?,
        decorations: inout [LineDecoration]
    ) -> (nextIndex: Int, lineDelta: Int)? {
        let nsLine = lineText as NSString
        guard let openMatch = macroBlockOpenRegex.firstMatch(in: lineText, range: NSRange(location: 0, length: nsLine.length)) else {
            return nil
        }
        let cmdName = nsLine.substring(with: openMatch.range(at: 1))
        guard !reservedMacroBlockNames.contains(cmdName) else { return nil }
        let docMacros = LaTeXMathRenderer.currentDocumentMacros()
        guard let def = docMacros["\\\(cmdName)"], def.argCount >= 1, def.operatorText == nil else { return nil }
        let optArg = openMatch.range(at: 2).location != NSNotFound ? nsLine.substring(with: openMatch.range(at: 2)) : nil
        let openBraceLoc = contentRange.location + NSMaxRange(openMatch.range) - 1
        guard let closeBraceLoc = findMatchingCloseBrace(in: nsString, openBraceLocation: openBraceLoc, fullLength: fullLength) else {
            return nil
        }
        let tpl = analyzeMacroTemplate(def: def, optArg: optArg, docIndex: docIndex, theme: theme, effectiveBaseSize: effectiveBaseSize)

        if closeBraceLoc < NSMaxRange(lineRange) {
            let dimFactor: CGFloat = (focusMode && !isActiveLine) ? 0.30 : 1.0
            if !tpl.showsBody {
                styleCollapsedOrDimmedConditionalLine(
                    in: storage, lineRange: lineRange, contentRange: contentRange, isDirective: false,
                    isBlockActive: isActiveLine, prettyMode: prettyMode, theme: theme, baseFont: baseFont,
                    effectiveBaseSize: effectiveBaseSize, effectiveContainerWidth: effectiveContainerWidth, dimFactor: dimFactor
                )
                return (NSMaxRange(lineRange), 1)
            }
            let openRange = NSRange(location: contentRange.location, length: (openBraceLoc + 1) - contentRange.location)
            let innerRange = NSRange(location: openBraceLoc + 1, length: max(0, closeBraceLoc - (openBraceLoc + 1)))
            let closeRange = NSRange(location: closeBraceLoc, length: max(0, NSMaxRange(contentRange) - closeBraceLoc))
            var lineFont = baseFont
            if let level = tpl.headingLevel {
                lineFont = docIndex.headingFont(level: level, scale: typography.fontSizeScale, baseSize: effectiveBaseSize, fallbackTheme: theme)
                let pStyle = NSMutableParagraphStyle()
                pStyle.lineSpacing = max(2.0, typography.lineSpacing * 0.7)
                pStyle.paragraphSpacingBefore = level == 1 ? 16.0 : (level == 2 ? 12.0 : 8.0)
                pStyle.paragraphSpacing = level <= 2 ? 10.0 : 6.0
                pStyle.tailIndent = effectiveContainerWidth
                storage.addAttributes([
                    .font: lineFont,
                    .foregroundColor: (tpl.color ?? theme.headingNSColor).withAlphaComponent(dimFactor),
                    .paragraphStyle: pStyle
                ], range: lineRange)
                if level <= 2 && prettyMode && !isActiveLine {
                    decorations.append(LineDecoration(lineRange: lineRange, kind: .headingUnderline(level: level)))
                }
            }
            if let c = tpl.color { storage.addAttribute(MKey.customColor, value: c, range: lineRange) }
            styleLaTeXInlineContent(
                in: storage, string: string, nsString: nsString, range: innerRange, lineRange: lineRange,
                baseFont: lineFont, isActiveLine: isActiveLine, docIndex: docIndex, theme: theme,
                dimFactor: dimFactor, prettyMode: prettyMode, baseDirectoryURL: baseDirectoryURL, decorations: &decorations
            )
            if let c = tpl.color {
                MarkdownLiveStyler.applyAttributesToVisibleCharacters(
                    in: storage, range: innerRange, attributes: [.foregroundColor: c.withAlphaComponent(dimFactor)]
                )
            }
            styleMacroOpenLineOrSpan(
                in: storage, nsString: nsString, range: openRange, label: tpl.prefixLabel.map { "\($0) " },
                isInlinePrefix: true, isActive: isActiveLine, prettyMode: prettyMode, docIndex: docIndex,
                theme: theme, effectiveBaseSize: effectiveBaseSize, effectiveContainerWidth: effectiveContainerWidth,
                dimFactor: dimFactor, decorations: &decorations
            )
            MarkdownLiveStyler.styleSyntaxToken(in: storage, range: closeRange, isActiveLine: isActiveLine || !prettyMode, theme: theme, dimFactor: dimFactor)
            return (NSMaxRange(lineRange), 1)
        }

        let closeLineRange = nsString.lineRange(for: NSRange(location: closeBraceLoc, length: 0))
        let fullBlockRange = NSRange(location: lineRange.location, length: NSMaxRange(closeLineRange) - lineRange.location)
        var lineCount = 0
        var scanPos = fullBlockRange.location
        while scanPos < NSMaxRange(fullBlockRange) {
            scanPos = NSMaxRange(nsString.lineRange(for: NSRange(location: scanPos, length: 0)))
            lineCount += 1
        }
        LaTeXBlockStyleCache.resetAttributes(
            in: storage, range: NSRange(location: NSMaxRange(lineRange), length: fullBlockRange.length - lineRange.length)
        )
        let isBlockActive = LaTeXBlockStyleCache.isBlockActive(range: fullBlockRange, activeLineRange: activeLineRange, selectedRange: selectedRange)
        let blockDim: CGFloat = (focusMode && !isBlockActive) ? 0.30 : 1.0

        if !tpl.showsBody && !isBlockActive && prettyMode {
            let spaceH = max(1.0, tpl.vspacePoints ?? 54.0)
            let pStyle = NSMutableParagraphStyle()
            pStyle.minimumLineHeight = spaceH
            pStyle.maximumLineHeight = spaceH
            pStyle.lineSpacing = 0
            pStyle.paragraphSpacing = 0
            pStyle.paragraphSpacingBefore = 0
            pStyle.tailIndent = effectiveContainerWidth
            MarkdownLiveStyler.collapseWhitespaceRange(
                in: storage, range: NSRange(location: fullBlockRange.location, length: max(0, fullBlockRange.length - 1))
            )
            storage.addAttributes([
                .font: NSFont.systemFont(ofSize: 0.1), .foregroundColor: NSColor.clear,
                .paragraphStyle: pStyle, MKey.noSpellCheck: true
            ], range: fullBlockRange)
            LaTeXBlockStyleCache.collapseInternalNewlines(in: storage, nsString: nsString, range: fullBlockRange)
            LaTeXBlockStyleCache.pendingGlyphInvalidationRanges.append(fullBlockRange)
            return (NSMaxRange(fullBlockRange), lineCount)
        }

        if let c = tpl.color { storage.addAttribute(MKey.customColor, value: c, range: fullBlockRange) }
        styleMacroOpenLineOrSpan(
            in: storage, nsString: nsString, range: contentRange, label: tpl.prefixLabel,
            isInlinePrefix: false, isActive: isBlockActive, prettyMode: prettyMode, docIndex: docIndex,
            theme: theme, effectiveBaseSize: effectiveBaseSize, effectiveContainerWidth: effectiveContainerWidth,
            dimFactor: blockDim, decorations: &decorations
        )
        styleMacroInteriorLines(
            in: storage, string: string, nsString: nsString, interiorStart: NSMaxRange(lineRange),
            interiorEnd: closeLineRange.location, activeLineRange: activeLineRange, selectedRange: selectedRange,
            docIndex: docIndex, theme: theme, typography: typography, baseFont: baseFont,
            effectiveBaseSize: effectiveBaseSize, effectiveContainerWidth: effectiveContainerWidth,
            prettyMode: prettyMode, focusMode: focusMode, blockDim: blockDim, macroColor: tpl.color,
            baseDirectoryURL: baseDirectoryURL, decorations: &decorations
        )
        let closeCR = MarkdownLiveStyler.strippedLineContentRange(nsString: nsString, lineRange: closeLineRange)
        styleDocumentBoundaryLineHelper(
            in: storage, lineRange: closeLineRange, contentRange: closeCR, isActive: isBlockActive,
            prettyMode: prettyMode, theme: theme, effectiveBaseSize: effectiveBaseSize,
            effectiveContainerWidth: effectiveContainerWidth, dimFactor: blockDim
        )
        LaTeXBlockStyleCache.pendingGlyphInvalidationRanges.append(fullBlockRange)
        return (NSMaxRange(fullBlockRange), lineCount)
    }

    private static func styleMacroOpenLineOrSpan(
        in storage: NSTextStorage, nsString: NSString, range: NSRange, label: String?,
        isInlinePrefix: Bool, isActive: Bool, prettyMode: Bool, docIndex: LaTeXDocumentIndex,
        theme: EditorTheme, effectiveBaseSize: CGFloat, effectiveContainerWidth: CGFloat,
        dimFactor: CGFloat, decorations: inout [LineDecoration]
    ) {
        if !isActive && prettyMode, let label = label, !label.isEmpty {
            let boldFont = docIndex.bodyFont(size: effectiveBaseSize, bold: true, fallbackTheme: theme)
            let labelW = max(6.0, ceil((label as NSString).size(withAttributes: [.font: boldFont]).width))
            if !isInlinePrefix {
                let lr = nsString.lineRange(for: range)
                let pStyle = NSMutableParagraphStyle()
                pStyle.paragraphSpacingBefore = 4.0
                pStyle.paragraphSpacing = 2.0
                pStyle.tailIndent = effectiveContainerWidth
                storage.addAttribute(.paragraphStyle, value: pStyle, range: lr)
            }
            reserveAtomicInlineSpan(
                in: storage, nsString: nsString, fullRange: range, width: labelW,
                ascent: boldFont.ascender, descent: -boldFont.descender
            )
            decorations.append(LineDecoration(
                lineRange: range, kind: .latexInlineText(text: label, font: boldFont, range: range, dimFactor: dimFactor)
            ))
        } else if isInlinePrefix {
            MarkdownLiveStyler.styleSyntaxToken(in: storage, range: range, isActiveLine: isActive || !prettyMode, theme: theme, dimFactor: dimFactor)
        } else {
            let lr = nsString.lineRange(for: range)
            styleDocumentBoundaryLineHelper(
                in: storage, lineRange: lr, contentRange: range, isActive: isActive, prettyMode: prettyMode,
                theme: theme, effectiveBaseSize: effectiveBaseSize, effectiveContainerWidth: effectiveContainerWidth, dimFactor: dimFactor
            )
        }
    }

    private static func styleMacroInteriorLines(
        in storage: NSTextStorage, string: String, nsString: NSString, interiorStart: Int, interiorEnd: Int,
        activeLineRange: NSRange, selectedRange: NSRange, docIndex: LaTeXDocumentIndex, theme: EditorTheme,
        typography: EditorTypographySettings, baseFont: NSFont, effectiveBaseSize: CGFloat,
        effectiveContainerWidth: CGFloat, prettyMode: Bool, focusMode: Bool, blockDim: CGFloat,
        macroColor: NSColor?, baseDirectoryURL: URL?, decorations: inout [LineDecoration]
    ) {
        var cur = interiorStart
        while cur < interiorEnd {
            let curLR = nsString.lineRange(for: NSRange(location: cur, length: 0))
            let curCR = MarkdownLiveStyler.strippedLineContentRange(nsString: nsString, lineRange: curLR)
            let curText = nsString.substring(with: curCR)
            let curTrim = curText.trimmingCharacters(in: .whitespacesAndNewlines)
            let curAct = MarkdownLiveStyler.isLineActive(lineRange: curLR, activeLineRange: activeLineRange, selectedRange: selectedRange)
            if curTrim.isEmpty {
                let adv = styleLaTeXBlankLineBlock(
                    in: storage, nsString: nsString, fullLength: interiorEnd, lineRange: curLR,
                    isActiveLine: curAct, activeLineRange: activeLineRange, selectedRange: selectedRange,
                    docIndex: docIndex, typography: typography, effectiveBaseSize: effectiveBaseSize,
                    effectiveContainerWidth: effectiveContainerWidth, prettyMode: prettyMode
                )
                cur = min(interiorEnd, adv.nextIndex)
            } else if curTrim.hasPrefix("\\[") || curTrim.hasPrefix("$$") {
                let closeTok = curTrim.hasPrefix("\\[") ? "\\]" : "$$"
                let adv = styleLaTeXDisplayMathBlock(
                    in: storage, nsString: nsString, fullLength: interiorEnd, lineRange: curLR,
                    contentRange: curCR, lineText: curText, trimmedLine: curTrim, closeToken: closeTok,
                    envName: nil, equationNumber: nil, isActiveLine: curAct, activeLineRange: activeLineRange,
                    selectedRange: selectedRange, theme: theme, effectiveBaseSize: effectiveBaseSize,
                    effectiveContainerWidth: effectiveContainerWidth, focusMode: focusMode, decorations: &decorations
                )
                cur = min(interiorEnd, adv.nextIndex)
            } else {
                styleLaTeXInlineContent(
                    in: storage, string: string, nsString: nsString, range: curCR, lineRange: curLR,
                    baseFont: baseFont, isActiveLine: curAct, docIndex: docIndex, theme: theme,
                    dimFactor: blockDim, prettyMode: prettyMode, baseDirectoryURL: baseDirectoryURL, decorations: &decorations
                )
                if let c = macroColor {
                    MarkdownLiveStyler.applyAttributesToVisibleCharacters(
                        in: storage, range: curCR, attributes: [.foregroundColor: c.withAlphaComponent(blockDim)]
                    )
                }
                cur = NSMaxRange(curLR)
            }
        }
        if let c = macroColor, interiorEnd > interiorStart {
            let interiorRange = NSRange(location: interiorStart, length: interiorEnd - interiorStart)
            storage.addAttribute(MKey.customColor, value: c, range: interiorRange)
        }
    }
}
