import AppKit
import FolioEngineFFI
import Foundation

extension LaTeXLiveStyler {

    static func styleLaTeXInlineContent(
        in storage: NSTextStorage,
        string: String,
        nsString: NSString,
        range: NSRange,
        lineRange: NSRange,
        baseFont: NSFont,
        isActiveLine: Bool,
        docIndex: LaTeXDocumentIndex,
        theme: EditorTheme,
        dimFactor: CGFloat,
        prettyMode: Bool,
        baseDirectoryURL: URL?,
        decorations: inout [LineDecoration]
    ) {
        guard range.length > 0 else { return }
        _ = (string, baseDirectoryURL)
        let fontSize = baseFont.pointSize

        // 1. Handle % comments (ignoring escaped \%)
        var effectiveRange = range
        if let commentStart = findUnescapedPercent(in: nsString, range: range) {
            let commentRange = NSRange(location: commentStart, length: NSMaxRange(range) - commentStart)
            storage.addAttribute(MKey.noSpellCheck, value: true, range: commentRange)
            let isWholeLineComment = nsString.substring(
                with: NSRange(location: range.location, length: commentStart - range.location)
            ).trimmingCharacters(in: .whitespaces).isEmpty

            if isActiveLine || !prettyMode {
                storage.addAttributes(
                    [
                        .font: docIndex.bodyFont(size: fontSize * 0.92, italic: true, fallbackTheme: theme),
                        .foregroundColor: theme.secondaryTextNSColor.withAlphaComponent(0.75 * dimFactor)
                    ], range: commentRange)
            } else {
                MarkdownLiveStyler.collapseWhitespaceRange(in: storage, range: commentRange)
                if isWholeLineComment {
                    let pStyle = NSMutableParagraphStyle()
                    pStyle.minimumLineHeight = 2.0; pStyle.maximumLineHeight = 2.0
                    pStyle.lineSpacing = 0; pStyle.paragraphSpacing = 0
                    storage.addAttributes(
                        [
                            .font: NSFont.systemFont(ofSize: 1.0),
                            .foregroundColor: NSColor.clear,
                            .paragraphStyle: pStyle
                        ], range: lineRange)
                }
            }
            effectiveRange = NSRange(location: range.location, length: max(0, commentStart - range.location))
        }
        guard effectiveRange.length > 0 else { return }
        let lineSub = nsString.substring(with: effectiveRange)
        guard lineSub.contains("\\") || lineSub.contains("$") || lineSub.contains("``") || lineSub.contains("''") else {
            return
        }

        guard let scanRes = lineSub.withCString({ ot_engine_scan_latex_inlines($0) }) else { return }
        defer { ot_engine_free_latex_inlines(scanRes) }
        let count = Int(scanRes.pointee.span_count)
        guard count > 0, let spansPtr = scanRes.pointee.spans else { return }
        let spans = UnsafeBufferPointer(start: spansPtr, count: count)
        let baseLoc = effectiveRange.location

        // Pass 1: Container & text-formatting spans in pre-order (Href, Url, SizeGroup, ColorGroup, StyleCmd)
        styleLaTeXContainerSpans(
            spans: spans, baseLoc: baseLoc, in: storage, nsString: nsString, baseFont: baseFont,
            fontSize: fontSize, isActiveLine: isActiveLine, prettyMode: prettyMode,
            docIndex: docIndex, theme: theme, dimFactor: dimFactor, decorations: &decorations
        )

        // Pass 2: Leaf spans (InlineMath, Cite, Ref, HiddenMeta, LogoCmd, TextBackslash, ProseMacro, TexQuote, EscapedChar)
        for idx in 0..<count {
            let sp = spans[idx]
            let fullRange = NSRange(location: baseLoc + Int(sp.full_loc), length: Int(sp.full_len))
            let openRange = NSRange(location: baseLoc + Int(sp.open_loc), length: Int(sp.open_len))
            let innerRange = NSRange(location: baseLoc + Int(sp.inner_loc), length: Int(sp.inner_len))
            let closeRange = NSRange(location: baseLoc + Int(sp.close_loc), length: Int(sp.close_len))
            let cmd = sp.cmd.map { String(cString: $0) } ?? ""
            let arg = sp.arg.map { String(cString: $0) } ?? ""

            switch sp.kind {
            case 1: // InlineMath
                styleInlineMathSpan(
                    in: storage, nsString: nsString, fullRange: fullRange, openRange: openRange,
                    innerRange: innerRange, closeRange: closeRange, latexStr: arg, fontSize: fontSize,
                    isActiveLine: isActiveLine, prettyMode: prettyMode, theme: theme,
                    dimFactor: dimFactor, decorations: &decorations
                )
            case 2: // Cite
                styleCiteSpan(
                    in: storage, nsString: nsString, fullRange: fullRange, rawKeysStr: arg,
                    baseFont: baseFont, fontSize: fontSize, isActiveLine: isActiveLine,
                    prettyMode: prettyMode, docIndex: docIndex, theme: theme,
                    dimFactor: dimFactor, decorations: &decorations
                )
            case 3: // Ref
                styleRefSpan(
                    in: storage, nsString: nsString, fullRange: fullRange, cmd: cmd, rawKey: arg,
                    baseFont: baseFont, fontSize: fontSize, isActiveLine: isActiveLine,
                    prettyMode: prettyMode, docIndex: docIndex, theme: theme,
                    dimFactor: dimFactor, decorations: &decorations
                )
            case 4: // HiddenMeta
                if !isActiveLine && prettyMode && cmd == "\\\\" && !arg.isEmpty,
                    let len = LaTeXLength.parse(arg)
                {
                    let extraPt = max(0.0, len.resolvedPoints(baseSize: fontSize))
                    if extraPt > 0,
                        let existing = storage.attribute(.paragraphStyle, at: lineRange.location, effectiveRange: nil) as? NSParagraphStyle,
                        let mutable = existing.mutableCopy() as? NSMutableParagraphStyle
                    {
                        mutable.paragraphSpacing = extraPt
                        storage.addAttribute(.paragraphStyle, value: mutable, range: lineRange)
                    }
                }
                MarkdownLiveStyler.styleSyntaxToken(
                    in: storage, range: fullRange, isActiveLine: isActiveLine || !prettyMode,
                    theme: theme, dimFactor: dimFactor
                )
            case 10, 11, 12, 13, 14:
                styleLaTeXLeafSymbolOrMacroSpan(
                    kind: sp.kind, cmd: cmd, fullRange: fullRange, openRange: openRange,
                    closeRange: closeRange, in: storage, nsString: nsString, baseFont: baseFont,
                    isActiveLine: isActiveLine, prettyMode: prettyMode, theme: theme,
                    dimFactor: dimFactor, decorations: &decorations
                )
            default:
                break
            }
        }
    }

    private static func styleInlineMathSpan(
        in storage: NSTextStorage, nsString: NSString, fullRange: NSRange, openRange: NSRange,
        innerRange: NSRange, closeRange: NSRange, latexStr: String, fontSize: CGFloat,
        isActiveLine: Bool, prettyMode: Bool, theme: EditorTheme, dimFactor: CGFloat,
        decorations: inout [LineDecoration]
    ) {
        storage.addAttribute(MKey.noSpellCheck, value: true, range: fullRange)
        if isActiveLine || !prettyMode {
            storage.addAttributes(
                [
                    .font: theme.codeFont(size: fontSize * 0.90),
                    .foregroundColor: theme.textNSColor.withAlphaComponent(dimFactor),
                    .backgroundColor: theme.codeBackgroundNSColor.withAlphaComponent(0.55 * dimFactor)
                ], range: innerRange)
            MarkdownLiveStyler.highlightLaTeXSource(in: storage, range: innerRange, theme: theme, dimFactor: dimFactor)
            MarkdownLiveStyler.styleSyntaxToken(in: storage, range: openRange, isActiveLine: true, theme: theme, dimFactor: dimFactor)
            MarkdownLiveStyler.styleSyntaxToken(in: storage, range: closeRange, isActiveLine: true, theme: theme, dimFactor: dimFactor)
        } else {
            let mathBox = LaTeXMathRenderer.layoutLatex(latexStr, baseFontSize: fontSize, isDisplayStyle: false)
            reserveAtomicInlineSpan(
                in: storage, nsString: nsString, fullRange: fullRange, width: max(4.0, mathBox.width + 2.0),
                ascent: mathBox.ascent, descent: mathBox.descent, verticalPadding: 3.0
            )
            decorations.append(
                LineDecoration(
                    lineRange: fullRange,
                    kind: .inlineMathRendered(latex: latexStr, range: fullRange, fontSize: fontSize, dimFactor: dimFactor)
                ))
        }
    }

    private static func styleCiteSpan(
        in storage: NSTextStorage, nsString: NSString, fullRange: NSRange, rawKeysStr: String,
        baseFont: NSFont, fontSize: CGFloat, isActiveLine: Bool, prettyMode: Bool,
        docIndex: LaTeXDocumentIndex, theme: EditorTheme, dimFactor: CGFloat,
        decorations: inout [LineDecoration]
    ) {
        storage.addAttribute(MKey.noSpellCheck, value: true, range: fullRange)
        if isActiveLine || !prettyMode {
            MarkdownLiveStyler.highlightLaTeXSource(in: storage, range: fullRange, theme: theme, dimFactor: dimFactor)
            return
        }
        let rawKeys = rawKeysStr.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        var labels: [String] = [], tooltips: [String] = []
        var firstLoc: Int?, firstURL: URL?
        for k in rawKeys {
            if let entry = docIndex.bibEntries[k] {
                labels.append(entry.shortCitation)
                tooltips.append(entry.title.isEmpty ? entry.key : "\(entry.author) (\(entry.year)) — \(entry.title)")
                if firstLoc == nil { firstLoc = entry.characterLocation; firstURL = entry.fileURL }
            } else {
                labels.append(k); tooltips.append("Citation key: \(k)")
            }
        }
        let pillLabel = "[\(labels.joined(separator: "; "))]"
        let pillFont = NSFont.systemFont(ofSize: max(10.5, fontSize * 0.82), weight: .medium)
        let labelW = ceil((pillLabel as NSString).size(withAttributes: [.font: pillFont]).width) + 12.0
        reserveAtomicInlineSpan(in: storage, nsString: nsString, fullRange: fullRange, width: labelW, ascent: baseFont.ascender, descent: -baseFont.descender)
        decorations.append(
            LineDecoration(
                lineRange: fullRange,
                kind: .latexInlinePill(
                    label: pillLabel, tooltip: tooltips.joined(separator: "\n"),
                    targetLocation: firstLoc, targetURL: firstURL, range: fullRange,
                    fontSize: fontSize, isCitation: true, dimFactor: dimFactor
                )
            ))
    }

    private static func styleRefSpan(
        in storage: NSTextStorage, nsString: NSString, fullRange: NSRange, cmd: String,
        rawKey: String, baseFont: NSFont, fontSize: CGFloat, isActiveLine: Bool,
        prettyMode: Bool, docIndex: LaTeXDocumentIndex, theme: EditorTheme,
        dimFactor: CGFloat, decorations: inout [LineDecoration]
    ) {
        storage.addAttribute(MKey.noSpellCheck, value: true, range: fullRange)
        if isActiveLine || !prettyMode {
            MarkdownLiveStyler.highlightLaTeXSource(in: storage, range: fullRange, theme: theme, dimFactor: dimFactor)
            return
        }
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let info = docIndex.labels[key]
        let num = info?.number ?? key
        let pillLabel = (cmd == "eqref") ? "(\(num))" : (["autoref", "cref", "Cref"].contains(cmd) ? "\(info?.kind ?? "Ref.") \(num)" : num)
        let tooltip = info.map { "\($0.kind) \($0.number): \($0.title)" } ?? "Label: \(key)"
        let pillFont = NSFont.systemFont(ofSize: max(10.5, fontSize * 0.82), weight: .medium)
        let labelW = ceil((pillLabel as NSString).size(withAttributes: [.font: pillFont]).width) + 12.0
        reserveAtomicInlineSpan(in: storage, nsString: nsString, fullRange: fullRange, width: labelW, ascent: baseFont.ascender, descent: -baseFont.descender)
        decorations.append(
            LineDecoration(
                lineRange: fullRange,
                kind: .latexInlinePill(
                    label: pillLabel, tooltip: tooltip, targetLocation: info?.characterLocation,
                    targetURL: nil, range: fullRange, fontSize: fontSize, isCitation: false, dimFactor: dimFactor
                )
            ))
    }
}
