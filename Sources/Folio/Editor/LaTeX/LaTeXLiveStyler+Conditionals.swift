import AppKit
import Foundation

extension LaTeXLiveStyler {

    static func parseIfDirective(_ trimmed: String, conditionals: [String: Bool]) -> Bool? {
        guard trimmed.hasPrefix("\\if"), !trimmed.hasPrefix("\\iff") else { return nil }
        let afterIf = trimmed.dropFirst(3)
        let nameChars = afterIf.prefix { ($0 >= "a" && $0 <= "z") || ($0 >= "A" && $0 <= "Z") || $0 == "@" }
        let condName = String(nameChars)
        guard !condName.isEmpty else { return nil }
        let remainder = afterIf.dropFirst(condName.count).trimmingCharacters(in: .whitespaces)
        guard remainder.isEmpty || remainder.hasPrefix("%") else { return nil }
        return conditionals[condName] ?? false
    }

    static func isElseDirective(_ trimmed: String) -> Bool {
        guard trimmed.hasPrefix("\\else") else { return false }
        let rem = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
        return rem.isEmpty || rem.hasPrefix("%")
    }

    static func isFiDirective(_ trimmed: String) -> Bool {
        guard trimmed.hasPrefix("\\fi") else { return false }
        let rem = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
        return rem.isEmpty || rem.hasPrefix("%")
    }

    static func evaluateConditionalsInTeX(_ text: String, conditionals: [String: Bool]) -> String {
        guard text.contains("\\if") else { return text }
        let rawLines = text.components(separatedBy: "\n")
        var output: [String] = []
        var stack: [(cond: Bool, inElse: Bool)] = []
        for rawLine in rawLines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if let val = parseIfDirective(trimmed, conditionals: conditionals) {
                stack.append((val, false))
                continue
            }
            if isElseDirective(trimmed), !stack.isEmpty {
                stack[stack.count - 1].inElse = true
                continue
            }
            if isFiDirective(trimmed), !stack.isEmpty {
                stack.removeLast()
                continue
            }
            let active = stack.allSatisfy { $0.inElse ? !$0.cond : $0.cond }
            if active {
                output.append(rawLine)
            }
        }
        return output.joined(separator: "\n")
    }

    static func styleCenterEnvironmentLines(
        envLines: [(lineRange: NSRange, contentRange: NSRange, text: String, isActive: Bool)],
        flow entryFlow: LaTeXFlowState = LaTeXFlowState(),
        fullBlockRange: NSRange,
        isBlockActive: Bool,
        blockDim: CGFloat,
        in storage: NSTextStorage,
        string: String,
        nsString: NSString,
        docIndex: LaTeXDocumentIndex,
        theme: EditorTheme,
        typography: EditorTypographySettings,
        baseFont: NSFont,
        effectiveBaseSize: CGFloat,
        effectiveContainerWidth: CGFloat,
        prettyMode: Bool,
        baseDirectoryURL: URL?,
        decorations: inout [LineDecoration]
    ) {
        var condStack: [(cond: Bool, inElse: Bool)] = []
        var collapsedLineRanges: [NSRange] = []
        let documentFontSize = docIndex.documentStyle.documentFontSizePt ?? 10
        var flow = entryFlow
        flow.apply([.beginEnvironment("center")], documentFontSize: documentFontSize)
        let wrappers = LaTeXLayoutCommands.flowWrapperEnvironments.union(["center"])

        for (i, el) in envLines.enumerated() {
            let isBoundary = (i == 0 || (i == envLines.count - 1 && envLines.count > 1))
            if isBoundary {
                styleDocumentBoundaryLineHelper(
                    in: storage, lineRange: el.lineRange, contentRange: el.contentRange,
                    isActive: el.isActive, prettyMode: prettyMode, theme: theme,
                    effectiveBaseSize: effectiveBaseSize, effectiveContainerWidth: effectiveContainerWidth,
                    dimFactor: blockDim
                )
                continue
            }
            let trimmed = el.text.trimmingCharacters(in: .whitespacesAndNewlines)
            var isDirective = false
            if let val = parseIfDirective(trimmed, conditionals: docIndex.documentStyle.conditionals) {
                condStack.append((val, false))
                isDirective = true
            } else if isElseDirective(trimmed), !condStack.isEmpty {
                condStack[condStack.count - 1].inElse = true
                isDirective = true
            } else if isFiDirective(trimmed), !condStack.isEmpty {
                condStack.removeLast()
                isDirective = true
            }
            let branchEnabled = condStack.allSatisfy { $0.inElse ? !$0.cond : $0.cond }
            let code = String(LaTeXFileFacts.stripComment(Substring(trimmed))).trimmingCharacters(in: .whitespaces)
            let layout = LaTeXLayoutLine.analyze(code, macros: docIndex.documentMacros, wrappers: wrappers)
            if branchEnabled && !isDirective && layout.isLayoutOnly && layout.drawsRule && !isBlockActive && prettyMode {
                MarkdownLiveStyler.collapseWhitespaceRange(in: storage, range: el.contentRange)
                storage.addAttribute(MKey.noSpellCheck, value: true, range: el.lineRange)
                decorations.append(LineDecoration(lineRange: el.lineRange, kind: .horizontalRule))
                continue
            }
            if branchEnabled && !isDirective && layout.isLayoutOnly {
                // Nested wrappers, font switches, and spacing print nothing; the switches style
                // the lines after them.
                flow.apply(layout.effects, documentFontSize: documentFontSize)
                isDirective = true
            }
            if isDirective || !branchEnabled {
                styleCollapsedOrDimmedConditionalLine(
                    in: storage, lineRange: el.lineRange, contentRange: el.contentRange,
                    isDirective: isDirective, isBlockActive: isBlockActive, prettyMode: prettyMode,
                    theme: theme, baseFont: baseFont, effectiveBaseSize: effectiveBaseSize,
                    effectiveContainerWidth: effectiveContainerWidth, dimFactor: blockDim
                )
                if !isBlockActive && prettyMode {
                    collapsedLineRanges.append(el.lineRange)
                }
                continue
            }

            let pStyle = NSMutableParagraphStyle()
            pStyle.alignment = .center
            pStyle.lineHeightMultiple = docIndex.effectiveLineHeightMultiple(fallback: typography)
            pStyle.lineSpacing = docIndex.effectiveLineSpacing(fallback: typography)
            pStyle.paragraphSpacing = max(3.0, typography.paragraphSpacing * 0.5)
            pStyle.tailIndent = effectiveContainerWidth
            let lineFont = flow.style == LaTeXProseStyle() ? baseFont : proseFont(for: flow.style, baseFont: baseFont, docIndex: docIndex, theme: theme)
            storage.addAttributes(
                [
                    .font: lineFont,
                    .foregroundColor: theme.textNSColor.withAlphaComponent(blockDim),
                    .paragraphStyle: pStyle
                ], range: el.lineRange)
            if !el.isActive && prettyMode {
                // Source indentation would push centered text off center.
                let indent = el.text.prefix { $0 == " " || $0 == "\t" }.utf16.count
                MarkdownLiveStyler.collapseWhitespaceRange(in: storage, range: NSRange(location: el.contentRange.location, length: indent))
            }
            styleLaTeXInlineContent(
                in: storage, string: string, nsString: nsString, range: el.contentRange,
                lineRange: el.lineRange, baseFont: lineFont, isActiveLine: el.isActive,
                docIndex: docIndex, theme: theme, dimFactor: blockDim, prettyMode: prettyMode,
                baseDirectoryURL: baseDirectoryURL, flowStyle: flow.style, decorations: &decorations
            )
            flow.apply(layout.effects, documentFontSize: documentFontSize)
        }
        collapseContiguousLineRuns(collapsedLineRanges, in: storage, nsString: nsString)
        LaTeXBlockStyleCache.pendingGlyphInvalidationRanges.append(fullBlockRange)
    }

    static func tryStyleLaTeXConditionalBlock(
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
        baseFont: NSFont,
        effectiveBaseSize: CGFloat,
        effectiveContainerWidth: CGFloat,
        prettyMode: Bool,
        focusMode: Bool,
        baseDirectoryURL: URL?,
        decorations: inout [LineDecoration]
    ) -> (nextIndex: Int, lineDelta: Int)? {
        guard let rootVal = parseIfDirective(trimmedLine, conditionals: docIndex.documentStyle.conditionals) else {
            return nil
        }
        var lines: [(lineRange: NSRange, contentRange: NSRange, text: String, trimmed: String, isActive: Bool)] = [
            (lineRange, contentRange, lineText, trimmedLine, isActiveLine)
        ]
        var depth = 1
        var scanIndex = NSMaxRange(lineRange)
        while scanIndex < fullLength && depth > 0 {
            let nextLR = nsString.lineRange(for: NSRange(location: scanIndex, length: 0))
            let nextCR = MarkdownLiveStyler.strippedLineContentRange(nsString: nsString, lineRange: nextLR)
            let nextText = nsString.substring(with: nextCR)
            let nextTrim = nextText.trimmingCharacters(in: .whitespacesAndNewlines)
            let nextAct = MarkdownLiveStyler.isLineActive(lineRange: nextLR, activeLineRange: activeLineRange, selectedRange: selectedRange)
            if parseIfDirective(nextTrim, conditionals: docIndex.documentStyle.conditionals) != nil {
                depth += 1
            } else if isFiDirective(nextTrim) {
                depth -= 1
            }
            lines.append((nextLR, nextCR, nextText, nextTrim, nextAct))
            scanIndex = NSMaxRange(nextLR)
        }
        let fullBlockRange = NSRange(location: lineRange.location, length: scanIndex - lineRange.location)
        if fullBlockRange.length > lineRange.length {
            LaTeXBlockStyleCache.resetAttributes(
                in: storage,
                range: NSRange(location: NSMaxRange(lineRange), length: fullBlockRange.length - lineRange.length)
            )
        }
        let isBlockActive = LaTeXBlockStyleCache.isBlockActive(range: fullBlockRange, activeLineRange: activeLineRange, selectedRange: selectedRange)
        let blockDim: CGFloat = (focusMode && !isBlockActive) ? 0.30 : 1.0
        var stack: [(cond: Bool, inElse: Bool)] = [(rootVal, false)]
        var collapsedRuns: [NSRange] = []

        for (i, cl) in lines.enumerated() {
            var isDirective = (i == 0)
            if i > 0 {
                if let nested = parseIfDirective(cl.trimmed, conditionals: docIndex.documentStyle.conditionals) {
                    stack.append((nested, false))
                    isDirective = true
                } else if isElseDirective(cl.trimmed), !stack.isEmpty {
                    stack[stack.count - 1].inElse = true
                    isDirective = true
                } else if isFiDirective(cl.trimmed), !stack.isEmpty {
                    stack.removeLast()
                    isDirective = true
                }
            }
            let enabled = stack.allSatisfy { $0.inElse ? !$0.cond : $0.cond }
            if isDirective || !enabled {
                styleCollapsedOrDimmedConditionalLine(
                    in: storage, lineRange: cl.lineRange, contentRange: cl.contentRange,
                    isDirective: isDirective, isBlockActive: isBlockActive, prettyMode: prettyMode,
                    theme: theme, baseFont: baseFont, effectiveBaseSize: effectiveBaseSize,
                    effectiveContainerWidth: effectiveContainerWidth, dimFactor: blockDim
                )
                if !isBlockActive && prettyMode {
                    collapsedRuns.append(cl.lineRange)
                }
            } else {
                styleLaTeXInlineContent(
                    in: storage, string: string, nsString: nsString, range: cl.contentRange,
                    lineRange: cl.lineRange, baseFont: baseFont, isActiveLine: cl.isActive,
                    docIndex: docIndex, theme: theme, dimFactor: blockDim, prettyMode: prettyMode,
                    baseDirectoryURL: baseDirectoryURL, decorations: &decorations
                )
            }
        }
        collapseContiguousLineRuns(collapsedRuns, in: storage, nsString: nsString)
        LaTeXBlockStyleCache.pendingGlyphInvalidationRanges.append(fullBlockRange)
        return (scanIndex, lines.count)
    }

    static func styleCollapsedOrDimmedConditionalLine(
        in storage: NSTextStorage,
        lineRange: NSRange,
        contentRange: NSRange,
        isDirective: Bool,
        isBlockActive: Bool,
        prettyMode: Bool,
        theme: EditorTheme,
        baseFont: NSFont,
        effectiveBaseSize: CGFloat,
        effectiveContainerWidth: CGFloat,
        dimFactor: CGFloat
    ) {
        storage.addAttribute(MKey.noSpellCheck, value: true, range: lineRange)
        if !isBlockActive && prettyMode {
            let pStyle = NSMutableParagraphStyle()
            pStyle.minimumLineHeight = 0.5
            pStyle.maximumLineHeight = 0.5
            pStyle.lineSpacing = 0
            pStyle.paragraphSpacing = 0
            pStyle.paragraphSpacingBefore = 0
            pStyle.tailIndent = effectiveContainerWidth
            MarkdownLiveStyler.collapseWhitespaceRange(in: storage, range: contentRange)
            storage.addAttributes(
                [
                    .font: NSFont.systemFont(ofSize: 0.1),
                    .foregroundColor: NSColor.clear,
                    .paragraphStyle: pStyle
                ], range: lineRange)
        } else {
            let font = isDirective ? theme.codeFont(size: effectiveBaseSize * 0.86) : baseFont
            let color =
                isDirective
                ? theme.markdownTokenNSColor.withAlphaComponent(0.85 * dimFactor)
                : theme.secondaryTextNSColor.withAlphaComponent(0.65 * dimFactor)
            storage.addAttributes([.font: font, .foregroundColor: color], range: contentRange)
        }
    }

    static func collapseContiguousLineRuns(_ ranges: [NSRange], in storage: NSTextStorage, nsString: NSString) {
        guard !ranges.isEmpty else { return }
        var runStart = ranges[0].location
        var runEnd = NSMaxRange(ranges[0])
        for r in ranges.dropFirst() {
            if r.location == runEnd {
                runEnd = NSMaxRange(r)
            } else {
                LaTeXBlockStyleCache.collapseInternalNewlines(
                    in: storage, nsString: nsString, range: NSRange(location: runStart, length: runEnd - runStart)
                )
                runStart = r.location
                runEnd = NSMaxRange(r)
            }
        }
        LaTeXBlockStyleCache.collapseInternalNewlines(
            in: storage, nsString: nsString, range: NSRange(location: runStart, length: runEnd - runStart)
        )
    }
}
