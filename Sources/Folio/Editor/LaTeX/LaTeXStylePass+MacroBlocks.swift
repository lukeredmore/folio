import AppKit
import FolioEngineFFI
import Foundation

extension LaTeXStylePass {

    private static let reservedMacroBlockNames: Set<String> = [
        "begin", "end", "section", "subsection", "subsubsection", "chapter", "part",
        "paragraph", "subparagraph", "title", "author", "date", "input", "include",
        "textbf", "textit", "emph", "underline", "texttt", "textsc", "footnote",
        "textcolor", "vspace", "hspace", "setlength", "definecolor", "newcommand",
        "renewcommand", "providecommand", "DeclareMathOperator", "item", "caption",
        "label", "ref", "eqref", "cite", "url", "href", "includegraphics"
    ]

    private static let multiLineProbeExcludedCommands: Set<String> = [
        "begin", "end", "item", "input", "include", "title", "author", "date", "caption", "includegraphics", "maketitle",
        "section", "subsection", "subsubsection", "chapter", "part", "paragraph", "subparagraph", "else", "fi"
    ]

    private static let multiLineBuiltinBoxes: Set<String> = [
        "makebox", "mbox", "fbox", "framebox", "parbox", "raisebox", "reflectbox"
    ]

    struct ResolvedMacroTemplate {
        let showsBody: Bool
        let color: NSColor?
        let prefixLabel: String?
        let vspacePoints: CGFloat?
        let headingLevel: Int?
        let suppressUnderline: Bool
        let isBold: Bool
        let isItalic: Bool

        var hasBlockFormatting: Bool {
            !showsBody || color != nil || prefixLabel != nil || vspacePoints != nil || headingLevel != nil || isBold || isItalic
        }
    }

    func analyzeMacroTemplate(def: LaTeXMacroDefinition, optArg: String?) -> ResolvedMacroTemplate {
        var active = Self.evaluateConditionalsInTeX(def.replacement, conditionals: docIndex.documentStyle.conditionals)
        var inferredFromSetter = false
        var suppressHeadingFromSetter = false
        if def.argCount == 1, def.parameterText == nil,
            let setterVar = Self.setterVariableTarget(in: active),
            let headerSnippet = findHeaderSnippet(forSetterVar: setterVar)
        {
            active = headerSnippet.replacingOccurrences(of: setterVar, with: "#1")
            inferredFromSetter = true
            suppressHeadingFromSetter = (setterVar == "\\@personalinfo")
        } else if def.argCount >= 2 {
            active = active.replacingOccurrences(of: "#1", with: optArg ?? (def.defaultFirstArg ?? ""))
        }
        let bodyPlaceholder = def.argCount >= 2 ? "#\(def.argCount)" : "#1"
        let analysis = active.withCString { activePtr in
            bodyPlaceholder.withCString { phPtr in
                ot_engine_analyze_macro_template(activePtr, phPtr)
            }
        }
        defer { ot_engine_free_macro_template_analysis(analysis) }

        let colorName = analysis.color_name.map { String(cString: $0) } ?? ""
        let resolvedColor: NSColor? =
            (colorName.isEmpty || suppressHeadingFromSetter)
            ? nil
            : docIndex.resolveColor(named: colorName, fallbackTheme: theme)

        let rawPrefix = analysis.prefix_label.map { String(cString: $0) } ?? ""
        let prefixLabel: String? =
            (rawPrefix.isEmpty || (!bodyPlaceholder.isEmpty && rawPrefix.contains(bodyPlaceholder)))
            ? nil
            : rawPrefix

        let vspaceArgs = analysis.vspace_args.map { String(cString: $0) } ?? ""
        var vspacePt: CGFloat?
        if !vspaceArgs.isEmpty {
            for rawLen in vspaceArgs.split(separator: ",") {
                if let parsed = LaTeXLength.parse(String(rawLen))?.resolvedPoints(baseSize: effectiveBaseSize) {
                    vspacePt = max(vspacePt ?? 0.0, parsed)
                }
            }
        }
        let headingLevel: Int? = (!suppressHeadingFromSetter && analysis.heading_level > 0) ? Int(analysis.heading_level) : nil
        let isItalic =
            analysis.shows_body && headingLevel == nil && !suppressHeadingFromSetter
            && (active.contains("\\textit{\(bodyPlaceholder)}") || active.contains("\\emph{\(bodyPlaceholder)}")
                || active.contains("\\itshape"))
        let isBold =
            analysis.shows_body && headingLevel == nil && !suppressHeadingFromSetter && prefixLabel == nil
            && (active.contains("\\textbf{\(bodyPlaceholder)}") || active.contains("\\bfseries"))

        return ResolvedMacroTemplate(
            showsBody: analysis.shows_body,
            color: resolvedColor,
            prefixLabel: prefixLabel,
            vspacePoints: vspacePt,
            headingLevel: headingLevel,
            suppressUnderline: inferredFromSetter,
            isBold: isBold,
            isItalic: isItalic
        )
    }

    private static func setterVariableTarget(in replacement: String) -> String? {
        let trimmed = LaTeXLexer.stripLineComment(replacement).trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["\\def", "\\gdef"] where trimmed.hasPrefix(prefix) {
            let rest = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            guard rest.hasPrefix("\\@") else { continue }
            let name = String(rest.prefix { $0 == "\\" || $0 == "@" || $0.isLetter })
            let afterName = rest.dropFirst(name.count).trimmingCharacters(in: .whitespaces)
            if afterName == "{#1}" {
                return name
            }
        }
        return nil
    }

    private func findHeaderSnippet(forSetterVar variable: String) -> String? {
        for def in docIndex.documentMacros.values where LaTeXLayoutLine.isHeaderBuilderMacro(def) {
            guard def.replacement.contains(variable) else { continue }
            for rawLine in def.replacement.components(separatedBy: "\n") where rawLine.contains(variable) {
                return rawLine
            }
        }
        return nil
    }

    private static func supportsMacroBlockShape(_ def: LaTeXMacroDefinition) -> Bool {
        def.operatorText == nil
            && def.parameterText == nil
            && (def.argCount == 1 || (def.argCount == 2 && def.defaultFirstArg != nil))
    }

    /// The end of a multi-line macro call that starts on the line, or nil. Lines that other
    /// stylers own, such as sections, environments, and block-shaped macros, are not probed.
    mutating func multiLineCallBlockEnd(
        lineRange: NSRange,
        contentRange: NSRange,
        lineText: String,
        trimmed: String,
        code: String
    ) -> Int? {
        guard code.contains("\\"), !trimmed.hasPrefix("$$"), !trimmed.hasPrefix("\\["),
            docIndex.lineSectionNumbers[lineRange.location] == nil
        else { return nil }
        let docMacros = docIndex.documentMacros
        if code.hasPrefix("\\") {
            let chars = Array(code)
            let (word, after) = LaTeXMacroExpander.readControlWord(chars, at: 0)
            let name = String(word.dropFirst())
            if Self.multiLineProbeExcludedCommands.contains(name) || name.hasPrefix("if") { return nil }
            var bodyStart = after < chars.count && chars[after] == "*" ? after + 1 : after
            var optArg: String?
            if let (parsedOpt, afterOption) = LaTeXMacroExpander.readBracketGroup(chars, at: bodyStart) {
                optArg = parsedOpt
                bodyStart = afterOption
            }
            if let def = docMacros[word], !Self.reservedMacroBlockNames.contains(name), Self.supportsMacroBlockShape(def) {
                if String(chars[bodyStart...]).trimmingCharacters(in: .whitespaces) == "{" {
                    return nil
                }
                let openCharIdx = LaTeXMacroExpander.skipSpaces(chars, from: bodyStart)
                if openCharIdx < chars.count && chars[openCharIdx] == "{" {
                    let leadingWS = lineText.utf16.prefix { $0 == 0x20 || $0 == 0x09 }.count
                    let openBraceLoc = contentRange.location + leadingWS + String(chars[0..<openCharIdx]).utf16.count
                    if let closeBraceLoc = LaTeXLexer.findMatchingCloseBrace(
                        in: nsString,
                        openBraceLocation: openBraceLoc,
                        fullLength: fullLength
                    ) {
                        if closeBraceLoc >= NSMaxRange(lineRange) {
                            let closeLineRange = nsString.lineRange(for: NSRange(location: closeBraceLoc, length: 0))
                            let closeCR = MarkdownLiveStyler.strippedLineContentRange(nsString: nsString, lineRange: closeLineRange)
                            let afterCloseRange = NSRange(
                                location: closeBraceLoc + 1,
                                length: max(0, NSMaxRange(closeCR) - (closeBraceLoc + 1))
                            )
                            let afterCloseCode =
                                afterCloseRange.length > 0
                                ? LaTeXLexer.stripLineComment(nsString.substring(with: afterCloseRange))
                                    .trimmingCharacters(in: .whitespaces)
                                : ""
                            if afterCloseCode.isEmpty {
                                let tpl = analyzeMacroTemplate(def: def, optArg: optArg)
                                let callSpan = NSRange(
                                    location: contentRange.location + leadingWS,
                                    length: (closeBraceLoc + 1) - (contentRange.location + leadingWS)
                                )
                                let callSource = LaTeXLexer.maskedComments(nsString.substring(with: callSpan))
                                let expandsAsInlineOrTransparent =
                                    LaTeXTransparentMacro.analyze(def, macros: docMacros) != nil
                                    || LaTeXProseMacroExpander.expandCall(source: callSource, macros: docMacros) != nil
                                if tpl.hasBlockFormatting || !expandsAsInlineOrTransparent {
                                    noteContext(NSRange(location: lineRange.location, length: NSMaxRange(closeLineRange) - lineRange.location))
                                    return nil
                                }
                            }
                        }
                    } else {
                        noteContext(NSRange(location: lineRange.location, length: fullLength - lineRange.location))
                        return nil
                    }
                }
            }
        }
        let probe = Self.probeMultiLineCall(lineRange: lineRange, nsString: nsString, macros: docMacros)
        if probe.contextEnd > NSMaxRange(lineRange) {
            noteContext(NSRange(location: lineRange.location, length: probe.contextEnd - lineRange.location))
        }
        return probe.blockEnd
    }

    mutating func multiLineDefinitionEnd(lineRange: NSRange, code: String) -> Int? {
        guard code.hasPrefix("\\") else { return nil }
        let (word, _) = LaTeXMacroExpander.readControlWord(Array(code.prefix(40)), at: 0)
        guard LaTeXLayoutCommands.definitionCommands.contains(String(word.dropFirst())) else { return nil }
        let probe = Self.probeMultiLineDefinition(lineRange: lineRange, nsString: nsString)
        if probe.contextEnd > NSMaxRange(lineRange) {
            noteContext(NSRange(location: lineRange.location, length: probe.contextEnd - lineRange.location))
        }
        return probe.blockEnd
    }

    mutating func tryStyleMacroBlock(
        lineRange: NSRange,
        contentRange: NSRange,
        lineText: String,
        trimmedLine: String,
        lineNumber: Int,
        isActiveLine: Bool
    ) -> (nextIndex: Int, lineDelta: Int)? {
        guard trimmedLine.hasPrefix("\\") else { return nil }
        let cls = lineText.withCString { ot_engine_classify_latex_line($0) }
        defer { ot_engine_free_latex_line_classification(cls) }
        guard cls.kind == 5 else { return nil }
        let cmdName = cls.cmd.map { String(cString: $0) } ?? ""
        guard !Self.reservedMacroBlockNames.contains(cmdName) else { return nil }
        let docMacros = docIndex.documentMacros
        guard let def = docMacros["\\\(cmdName)"], Self.supportsMacroBlockShape(def) else { return nil }
        let optArg: String? = cls.has_opt_arg ? (cls.opt_arg.map { String(cString: $0) }) : nil
        let openBraceLoc = contentRange.location + Int(cls.open_len) - 1
        guard
            let closeBraceLoc = LaTeXLexer.findMatchingCloseBrace(
                in: nsString,
                openBraceLocation: openBraceLoc,
                fullLength: fullLength
            )
        else {
            noteContext(NSRange(location: lineRange.location, length: fullLength - lineRange.location))
            return nil
        }
        let tpl = analyzeMacroTemplate(def: def, optArg: optArg)

        if closeBraceLoc < NSMaxRange(lineRange) {
            let afterCloseRange = NSRange(location: closeBraceLoc + 1, length: max(0, NSMaxRange(contentRange) - (closeBraceLoc + 1)))
            let afterCloseCode =
                afterCloseRange.length > 0
                ? LaTeXLexer.stripLineComment(nsString.substring(with: afterCloseRange)).trimmingCharacters(in: .whitespaces)
                : ""
            if tpl.headingLevel == nil || !afterCloseCode.isEmpty {
                let callStart = contentRange.location + lineText.utf16.prefix { $0 == 0x20 || $0 == 0x09 }.count
                let callText = nsString.substring(with: NSRange(location: callStart, length: NSMaxRange(contentRange) - callStart))
                if LaTeXProseMacroExpander.expandCall(source: callText, macros: docMacros) != nil { return nil }
            }
            let dimFactor: CGFloat = (focusMode && !isActiveLine) ? 0.30 : 1.0
            if !tpl.showsBody {
                styleCollapsedOrDimmedConditionalLine(
                    lineRange: lineRange,
                    contentRange: contentRange,
                    isDirective: false,
                    isBlockActive: isActiveLine,
                    dimFactor: dimFactor
                )
                return (NSMaxRange(lineRange), 1)
            }
            let openRange = NSRange(location: contentRange.location, length: (openBraceLoc + 1) - contentRange.location)
            let innerRange = NSRange(location: openBraceLoc + 1, length: max(0, closeBraceLoc - (openBraceLoc + 1)))
            let closeRange = NSRange(location: closeBraceLoc, length: max(0, NSMaxRange(contentRange) - closeBraceLoc))
            let lineFont = applyMacroTemplateFontStyle(tpl, range: lineRange, isActive: isActiveLine, dimFactor: dimFactor)
            if let headingLevel = tpl.headingLevel, !tpl.suppressUnderline {
                let titleText = LaTeXDocumentIndexer.cleanTeXInlineText(nsString.substring(with: innerRange))
                if !titleText.isEmpty {
                    headings.append(
                        OutlineHeading(
                            level: headingLevel,
                            title: titleText,
                            characterLocation: lineRange.location,
                            lineNumber: lineNumber
                        ))
                }
            }
            if let c = tpl.color { storage.addAttribute(MKey.customColor, value: c, range: lineRange) }
            styleInlineContent(
                range: innerRange,
                lineRange: lineRange,
                lineFont: lineFont,
                isActiveLine: isActiveLine,
                dimFactor: dimFactor
            )
            if let c = tpl.color {
                MarkdownLiveStyler.applyAttributesToVisibleCharacters(
                    in: storage, range: innerRange, attributes: [.foregroundColor: c.withAlphaComponent(dimFactor)]
                )
            }
            styleMacroOpenLineOrSpan(
                range: openRange,
                label: tpl.prefixLabel.map { "\($0) " },
                isInlinePrefix: true,
                isActive: isActiveLine,
                dimFactor: dimFactor
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
        resetAttributes(range: NSRange(location: NSMaxRange(lineRange), length: fullBlockRange.length - lineRange.length))
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
            storage.addAttributes(
                [
                    .font: NSFont.systemFont(ofSize: 0.1),
                    .foregroundColor: NSColor.clear,
                    .paragraphStyle: pStyle,
                    MKey.noSpellCheck: true
                ], range: fullBlockRange)
            LaTeXBlockStyleCache.collapseInternalNewlines(in: storage, nsString: nsString, range: fullBlockRange)
            pendingGlyphInvalidationRanges.append(fullBlockRange)
            return (NSMaxRange(fullBlockRange), lineCount)
        }

        let lineFont = applyMacroTemplateFontStyle(tpl, range: fullBlockRange, isActive: isBlockActive, dimFactor: blockDim)
        if let c = tpl.color { storage.addAttribute(MKey.customColor, value: c, range: fullBlockRange) }

        let openPrefixRange = NSRange(location: contentRange.location, length: (openBraceLoc + 1) - contentRange.location)
        let openProseRange = NSRange(location: openBraceLoc + 1, length: max(0, NSMaxRange(contentRange) - (openBraceLoc + 1)))
        let hasOpenProse =
            openProseRange.length > 0
            && !LaTeXLexer.stripLineComment(nsString.substring(with: openProseRange))
                .trimmingCharacters(in: .whitespaces).isEmpty

        if hasOpenProse {
            styleInlineContent(
                range: openProseRange,
                lineRange: lineRange,
                lineFont: lineFont,
                isActiveLine: isActiveLine,
                dimFactor: blockDim
            )
            if let c = tpl.color {
                MarkdownLiveStyler.applyAttributesToVisibleCharacters(
                    in: storage, range: openProseRange, attributes: [.foregroundColor: c.withAlphaComponent(blockDim)]
                )
            }
            styleMacroOpenLineOrSpan(
                range: openPrefixRange,
                label: tpl.prefixLabel.map { "\($0) " },
                isInlinePrefix: true,
                isActive: isBlockActive,
                dimFactor: blockDim
            )
        } else {
            styleMacroOpenLineOrSpan(
                range: contentRange,
                label: tpl.prefixLabel,
                isInlinePrefix: false,
                isActive: isBlockActive,
                dimFactor: blockDim
            )
        }

        styleMacroInteriorLines(
            interiorStart: NSMaxRange(lineRange),
            interiorEnd: closeLineRange.location,
            lineFont: lineFont,
            blockDim: blockDim,
            macroColor: tpl.color
        )

        let closeCR = MarkdownLiveStyler.strippedLineContentRange(nsString: nsString, lineRange: closeLineRange)
        let closeBeforeBrace = NSRange(location: closeCR.location, length: max(0, closeBraceLoc - closeCR.location))
        let closeAfterBrace = NSRange(location: closeBraceLoc + 1, length: max(0, NSMaxRange(closeCR) - (closeBraceLoc + 1)))
        let hasCloseBeforeProse =
            closeBeforeBrace.length > 0
            && !nsString.substring(with: closeBeforeBrace).trimmingCharacters(in: .whitespaces).isEmpty
        let hasCloseAfterProse =
            closeAfterBrace.length > 0
            && !LaTeXLexer.stripLineComment(nsString.substring(with: closeAfterBrace))
                .trimmingCharacters(in: .whitespaces).isEmpty

        if !hasCloseBeforeProse && !hasCloseAfterProse {
            styleBoundaryLine(
                lineRange: closeLineRange,
                contentRange: closeCR,
                isActive: isBlockActive,
                dimFactor: blockDim
            )
        } else {
            let closeLineActive = MarkdownLiveStyler.isLineActive(
                lineRange: closeLineRange,
                activeLineRange: activeLineRange,
                selectedRange: selectedRange
            )
            if closeBeforeBrace.length > 0 {
                styleInlineContent(
                    range: closeBeforeBrace,
                    lineRange: closeLineRange,
                    lineFont: lineFont,
                    isActiveLine: closeLineActive,
                    dimFactor: blockDim
                )
                if let c = tpl.color {
                    MarkdownLiveStyler.applyAttributesToVisibleCharacters(
                        in: storage, range: closeBeforeBrace, attributes: [.foregroundColor: c.withAlphaComponent(blockDim)]
                    )
                }
            }
            let braceRange = NSRange(location: closeBraceLoc, length: 1)
            MarkdownLiveStyler.styleSyntaxToken(
                in: storage,
                range: braceRange,
                isActiveLine: isBlockActive || !prettyMode,
                theme: theme,
                dimFactor: blockDim
            )
            if closeAfterBrace.length > 0 {
                styleInlineContent(
                    range: closeAfterBrace,
                    lineRange: closeLineRange,
                    lineFont: baseFont,
                    isActiveLine: closeLineActive,
                    dimFactor: blockDim
                )
            }
        }

        pendingGlyphInvalidationRanges.append(fullBlockRange)
        return (NSMaxRange(fullBlockRange), lineCount)
    }

    private mutating func applyMacroTemplateFontStyle(
        _ tpl: ResolvedMacroTemplate,
        range: NSRange,
        isActive: Bool,
        dimFactor: CGFloat
    ) -> NSFont {
        if let level = tpl.headingLevel {
            let lineFont = docIndex.headingFont(level: level, scale: typography.fontSizeScale, baseSize: effectiveBaseSize, fallbackTheme: theme)
            let pStyle = NSMutableParagraphStyle()
            pStyle.lineSpacing = max(2.0, typography.lineSpacing * 0.7)
            pStyle.paragraphSpacingBefore = level == 1 ? 16.0 : (level == 2 ? 12.0 : 8.0)
            pStyle.paragraphSpacing = level <= 2 ? 10.0 : 6.0
            pStyle.tailIndent = effectiveContainerWidth
            storage.addAttributes(
                [
                    .font: lineFont,
                    .foregroundColor: (tpl.color ?? theme.headingNSColor).withAlphaComponent(dimFactor),
                    .paragraphStyle: pStyle
                ], range: range)
            if level <= 2 && !tpl.suppressUnderline && prettyMode && !isActive {
                decorations.append(LineDecoration(lineRange: range, kind: .headingUnderline(level: level)))
            }
            return lineFont
        }
        guard tpl.isBold || tpl.isItalic else { return baseFont }
        var font = baseFont
        if tpl.isBold { font = FontGDEFSanitizer.convert(font, toHaveTrait: .boldFontMask) }
        if tpl.isItalic { font = FontGDEFSanitizer.convert(font, toHaveTrait: .italicFontMask) }
        storage.addAttribute(.font, value: font, range: range)
        return font
    }

    private mutating func styleMacroOpenLineOrSpan(
        range: NSRange,
        label: String?,
        isInlinePrefix: Bool,
        isActive: Bool,
        dimFactor: CGFloat
    ) {
        if !isActive && prettyMode, let label, !label.isEmpty {
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
            Self.reserveAtomicInlineSpan(
                in: storage,
                nsString: nsString,
                fullRange: range,
                width: labelW,
                ascent: boldFont.ascender,
                descent: -boldFont.descender
            )
            decorations.append(
                LineDecoration(
                    lineRange: range,
                    kind: .latexInlineText(text: label, font: boldFont, range: range, dimFactor: dimFactor)
                ))
        } else if isInlinePrefix {
            MarkdownLiveStyler.styleSyntaxToken(in: storage, range: range, isActiveLine: isActive || !prettyMode, theme: theme, dimFactor: dimFactor)
        } else {
            let lr = nsString.lineRange(for: range)
            styleBoundaryLine(lineRange: lr, contentRange: range, isActive: isActive, dimFactor: dimFactor)
        }
    }

    private mutating func styleMacroInteriorLines(
        interiorStart: Int,
        interiorEnd: Int,
        lineFont: NSFont,
        blockDim: CGFloat,
        macroColor: NSColor?
    ) {
        var cur = interiorStart
        while cur < interiorEnd {
            let curLR = nsString.lineRange(for: NSRange(location: cur, length: 0))
            let curCR = MarkdownLiveStyler.strippedLineContentRange(nsString: nsString, lineRange: curLR)
            let curText = nsString.substring(with: curCR)
            let curTrim = curText.trimmingCharacters(in: .whitespacesAndNewlines)
            let curAct = MarkdownLiveStyler.isLineActive(lineRange: curLR, activeLineRange: activeLineRange, selectedRange: selectedRange)
            if curTrim.isEmpty {
                let adv = styleBlankLineBlock(lineRange: curLR, isActiveLine: curAct, limit: interiorEnd)
                cur = min(interiorEnd, adv.nextIndex)
            } else if curTrim.hasPrefix("%") {
                let adv = styleCommentBlock(lineRange: curLR, contentRange: curCR, isActiveLine: curAct, limit: interiorEnd)
                cur = min(interiorEnd, adv.nextIndex)
            } else if curTrim.hasPrefix("\\[") || curTrim.hasPrefix("$$") {
                let closeTok = curTrim.hasPrefix("\\[") ? "\\]" : "$$"
                let adv = styleDisplayMathBlock(
                    lineRange: curLR,
                    contentRange: curCR,
                    lineText: curText,
                    trimmedLine: curTrim,
                    closeToken: closeTok,
                    envName: nil,
                    equationNumber: nil,
                    isActiveLine: curAct,
                    limit: interiorEnd
                )
                cur = min(interiorEnd, adv.nextIndex)
            } else {
                if !curAct && prettyMode {
                    let indent = curText.utf16.prefix { $0 == 0x20 || $0 == 0x09 }.count
                    if indent > 0 {
                        MarkdownLiveStyler.collapseWhitespaceRange(
                            in: storage, range: NSRange(location: curCR.location, length: indent)
                        )
                    }
                }
                styleInlineContent(
                    range: curCR,
                    lineRange: curLR,
                    lineFont: lineFont,
                    isActiveLine: curAct,
                    dimFactor: blockDim
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

    mutating func styleDefinitionBlock(_ blockRange: NSRange) -> (nextIndex: Int, lineDelta: Int) {
        let firstLine = nsString.lineRange(for: NSRange(location: blockRange.location, length: 0))
        if blockRange.length > firstLine.length {
            resetAttributes(range: NSRange(location: NSMaxRange(firstLine), length: blockRange.length - firstLine.length))
        }
        let isActive = LaTeXBlockStyleCache.isBlockActive(range: blockRange, activeLineRange: activeLineRange, selectedRange: selectedRange)
        let dimFactor: CGFloat = (focusMode && !isActive) ? 0.30 : 1.0
        var scan = blockRange.location
        var count = 0
        while scan < NSMaxRange(blockRange) {
            let lineRange = nsString.lineRange(for: NSRange(location: scan, length: 0))
            styleBoundaryLine(
                lineRange: lineRange,
                contentRange: MarkdownLiveStyler.strippedLineContentRange(nsString: nsString, lineRange: lineRange),
                isActive: isActive,
                dimFactor: dimFactor
            )
            scan = NSMaxRange(lineRange)
            count += 1
        }
        if !isActive && prettyMode {
            LaTeXBlockStyleCache.collapseInternalNewlines(in: storage, nsString: nsString, range: blockRange)
        }
        pendingGlyphInvalidationRanges.append(blockRange)
        return (NSMaxRange(blockRange), count)
    }

    mutating func styleMultiLineCallBlock(
        _ blockRange: NSRange,
        lineFont: NSFont,
        flow: LaTeXFlowState
    ) -> (nextIndex: Int, lineDelta: Int) {
        let firstLine = nsString.lineRange(for: NSRange(location: blockRange.location, length: 0))
        if blockRange.length > firstLine.length {
            resetAttributes(range: NSRange(location: NSMaxRange(firstLine), length: blockRange.length - firstLine.length))
        }
        var lines: [NSRange] = []
        var scan = blockRange.location
        while scan < NSMaxRange(blockRange) {
            let lineRange = nsString.lineRange(for: NSRange(location: scan, length: 0))
            lines.append(lineRange)
            scan = NSMaxRange(lineRange)
        }
        let isActive = LaTeXBlockStyleCache.isBlockActive(range: blockRange, activeLineRange: activeLineRange, selectedRange: selectedRange)
        let dimFactor: CGFloat = (focusMode && !isActive) ? 0.30 : 1.0
        pendingGlyphInvalidationRanges.append(blockRange)
        if isActive || !prettyMode {
            for lineRange in lines {
                styleInlineContent(
                    range: MarkdownLiveStyler.strippedLineContentRange(nsString: nsString, lineRange: lineRange),
                    lineRange: lineRange,
                    lineFont: lineFont,
                    isActiveLine: true,
                    dimFactor: dimFactor,
                    flow: flow
                )
            }
            return (NSMaxRange(blockRange), lines.count)
        }
        storage.addAttribute(.font, value: lineFont, range: blockRange)
        for (index, lineRange) in lines.enumerated() where index > 0 {
            let newline = NSRange(location: lineRange.location - 1, length: 1)
            storage.addAttribute(MarkdownLiveStyler.softLineBreakAttributeKey, value: true, range: newline)
            var indentEnd = lineRange.location
            while indentEnd < NSMaxRange(lineRange) {
                let ch = nsString.character(at: indentEnd)
                guard ch == 0x20 || ch == 0x09 else { break }
                indentEnd += 1
            }
            MarkdownLiveStyler.collapseWhitespaceRange(in: storage, range: NSRange(location: lineRange.location, length: indentEnd - lineRange.location))
        }
        let firstContent = MarkdownLiveStyler.strippedLineContentRange(nsString: nsString, lineRange: lines[0])
        let lastContent = MarkdownLiveStyler.strippedLineContentRange(nsString: nsString, lineRange: lines[lines.count - 1])
        let content = NSRange(location: firstContent.location, length: NSMaxRange(lastContent) - firstContent.location)
        styleInlineContent(
            range: content,
            lineRange: blockRange,
            lineFont: lineFont,
            isActiveLine: false,
            dimFactor: dimFactor,
            flow: flow
        )
        for lineRange in lines.dropFirst() {
            let newline = lineRange.location - 1
            if storage.attribute(MKey.inlineMathSpan, at: newline, effectiveRange: nil) != nil {
                storage.addAttribute(MKey.collapsed, value: true, range: NSRange(location: newline, length: 1))
            }
        }
        return (NSMaxRange(blockRange), lines.count)
    }

    static func probeMultiLineCall(
        lineRange: NSRange,
        nsString: NSString,
        macros: [String: LaTeXMacroDefinition]
    ) -> LaTeXLiveStyler.MultiLineCallProbe {
        let lineContent = MarkdownLiveStyler.strippedLineContentRange(nsString: nsString, lineRange: lineRange)
        let none = LaTeXLiveStyler.MultiLineCallProbe(blockEnd: nil, contextEnd: NSMaxRange(lineRange))
        guard lineContent.length > 0, nsString.range(of: "\\", options: [], range: lineContent).location != NSNotFound else { return none }
        let lineText = LaTeXLexer.maskedComments(nsString.substring(with: lineContent))
        let lineChars = Array(lineText)
        let starts = callStarts(in: lineChars, macros: macros)
        guard starts.contains(where: { needsFollowingLines(lineChars, call: $0, macros: macros) }) else { return none }

        let window = probeWindow(from: lineRange.location, nsString: nsString)
        let windowText = LaTeXLexer.maskedComments(nsString.substring(with: window))
        let chars = Array(windowText)
        var offsets = [0]
        offsets.reserveCapacity(chars.count + 1)
        for ch in chars { offsets.append(offsets[offsets.count - 1] + ch.utf16.count) }
        var lastCharacter = lineContent.location + lineContent.length - lineRange.location
        var index = 0
        var calls = starts
        while index < calls.count {
            let call = calls[index]
            index += 1
            guard let end = callEnd(chars, call: call, macros: macros) else { continue }
            let endOffset = offsets[end]
            guard endOffset > lastCharacter else { continue }
            let previousLast = lastCharacter
            let callLastLine = nsString.lineRange(for: NSRange(location: window.location + endOffset - 1, length: 0))
            let callLastContent = MarkdownLiveStyler.strippedLineContentRange(nsString: nsString, lineRange: callLastLine)
            lastCharacter = NSMaxRange(callLastContent) - window.location
            let tailStart = offsets.firstIndex { $0 >= max(endOffset, previousLast) } ?? chars.count
            let tailEnd = offsets.firstIndex { $0 >= lastCharacter } ?? chars.count
            if tailStart < tailEnd {
                calls += callStarts(in: Array(chars[0..<tailEnd]), macros: macros, from: tailStart)
            }
        }
        let contentEnd = lineContent.location + lineContent.length
        guard window.location + lastCharacter > contentEnd else {
            return LaTeXLiveStyler.MultiLineCallProbe(blockEnd: nil, contextEnd: windowContextEnd(window, nsString: nsString))
        }
        let lastLine = nsString.lineRange(for: NSRange(location: window.location + lastCharacter - 1, length: 0))
        return LaTeXLiveStyler.MultiLineCallProbe(blockEnd: NSMaxRange(lastLine), contextEnd: windowContextEnd(window, nsString: nsString))
    }

    static func probeMultiLineDefinition(lineRange: NSRange, nsString: NSString) -> LaTeXLiveStyler.MultiLineCallProbe {
        let none = LaTeXLiveStyler.MultiLineCallProbe(blockEnd: nil, contextEnd: NSMaxRange(lineRange))
        let window = probeWindow(from: lineRange.location, nsString: nsString)
        let chars = Array(LaTeXLexer.maskedComments(nsString.substring(with: window)))
        let start = LaTeXMacroExpander.skipSpaces(chars, from: 0)
        guard start < chars.count, chars[start] == "\\" else { return none }
        let command = LaTeXLayoutLine.readCommand(chars, at: start, macros: [:])
        guard command.isLayout, command.end > start else {
            return LaTeXLiveStyler.MultiLineCallProbe(blockEnd: nil, contextEnd: windowContextEnd(window, nsString: nsString))
        }
        let endOffset = String(chars[0..<command.end]).utf16.count
        let lastLine = nsString.lineRange(for: NSRange(location: window.location + endOffset - 1, length: 0))
        let rest = NSRange(location: window.location + endOffset, length: NSMaxRange(lastLine) - window.location - endOffset)
        let restText = LaTeXLexer.maskedComments(nsString.substring(with: rest)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard NSMaxRange(lastLine) > NSMaxRange(lineRange), restText.isEmpty else {
            return LaTeXLiveStyler.MultiLineCallProbe(blockEnd: nil, contextEnd: windowContextEnd(window, nsString: nsString))
        }
        return LaTeXLiveStyler.MultiLineCallProbe(blockEnd: NSMaxRange(lastLine), contextEnd: windowContextEnd(window, nsString: nsString))
    }

    private struct CallStart {
        let position: Int
        let afterName: Int
        let definition: LaTeXMacroDefinition?
        let builtin: String?
    }

    private static func callStarts(in chars: [Character], macros: [String: LaTeXMacroDefinition], from start: Int = 0) -> [CallStart] {
        var result: [CallStart] = []
        var idx = start
        while idx < chars.count {
            guard chars[idx] == "\\", idx + 1 < chars.count else {
                idx += 1
                continue
            }
            guard chars[idx + 1].isLetter else {
                idx += 2
                continue
            }
            let (word, after) = LaTeXMacroExpander.readControlWord(chars, at: idx)
            let hasStar = after < chars.count && chars[after] == "*"
            let name = String(word.dropFirst())
            if let (def, consumesStar) = LaTeXProseMacroExpander.definition(forCall: name + (hasStar ? "*" : ""), in: macros),
                def.argCount > 0 || def.parameterText != nil
            {
                result.append(CallStart(position: idx, afterName: consumesStar ? after + 1 : after, definition: def, builtin: nil))
            } else if multiLineBuiltinBoxes.contains(name) {
                result.append(CallStart(position: idx, afterName: after, definition: nil, builtin: name))
            }
            idx = after
        }
        return result
    }

    private static func needsFollowingLines(_ chars: [Character], call: CallStart, macros: [String: LaTeXMacroDefinition]) -> Bool {
        guard let end = callEnd(chars, call: call, macros: macros) else { return true }
        return call.definition?.parameterText != nil && end >= chars.count
    }

    private static func callEnd(_ chars: [Character], call: CallStart, macros: [String: LaTeXMacroDefinition]) -> Int? {
        if let def = call.definition {
            guard let (spans, end) = LaTeXMacroExpander.readArgumentSpans(for: def, in: chars, from: call.afterName) else { return nil }
            var visibleEnd = end
            while visibleEnd > call.afterName && chars[visibleEnd - 1].isWhitespace { visibleEnd -= 1 }
            return max(visibleEnd, spans.compactMap { $0.raw?.upperBound }.max() ?? visibleEnd)
        }
        var idx = call.afterName
        var end: Int?
        while true {
            let probe = LaTeXMacroExpander.skipSpaces(chars, from: idx)
            if let (_, after) = LaTeXMacroExpander.readBracketGroup(chars, at: probe) {
                idx = after
            } else if let (_, after) = LaTeXMacroExpander.readBracedGroup(chars, at: probe) {
                idx = after
                end = after
            } else if probe < chars.count && chars[probe] == "{" {
                return nil
            } else {
                return end
            }
        }
    }

    private static func probeWindow(from start: Int, nsString: NSString) -> NSRange {
        var end = start
        var lines = 0
        while end < nsString.length && lines < LaTeXLiveStyler.MultiLineCallLimits.maxLines {
            let lineRange = nsString.lineRange(for: NSRange(location: end, length: 0))
            let content = MarkdownLiveStyler.strippedLineContentRange(nsString: nsString, lineRange: lineRange)
            if lines > 0 && nsString.substring(with: content).trimmingCharacters(in: .whitespaces).isEmpty { break }
            guard NSMaxRange(lineRange) - start <= LaTeXLiveStyler.MultiLineCallLimits.maxCharacters || lines == 0 else { break }
            end = NSMaxRange(lineRange)
            lines += 1
        }
        return NSRange(location: start, length: end - start)
    }

    private static func windowContextEnd(_ window: NSRange, nsString: NSString) -> Int {
        guard NSMaxRange(window) < nsString.length else { return NSMaxRange(window) }
        return NSMaxRange(nsString.lineRange(for: NSRange(location: NSMaxRange(window), length: 0)))
    }
}
