import AppKit
import Foundation

extension LaTeXLiveStyler {

    static let latexInlineMathRegex = try! NSRegularExpression(
        pattern: #"(?<!\\|\$)(\$)(?!\$)([^\$\n]+?)(?<!\\|\$)(\$)(?!\$)|(\\\()(.+?)(\\\))"#
    )
    static let latexCiteRegex = try! NSRegularExpression(
        pattern: #"\\(cite[pt]?|parencite|textcite|autocite)\*?(?:\[[^\]]*\])*\{([^}]+)\}"#
    )
    static let latexRefRegex = try! NSRegularExpression(
        pattern: #"\\(eqref|autoref|cref|Cref|ref|pageref)\{([^}]+)\}"#
    )
    static let latexHiddenMetaCmdRegex = try! NSRegularExpression(
        pattern: #"\\(?:label|bibliography|bibliographystyle|addbibresource|nocite)\{[^}]*\}|\\(?:centering|noindent|newpage|clearpage|tableofcontents)\b[ \t]*|\\\\(?:\[[^\]]*\])?"#
    )
    static let latexHrefRegex = try! NSRegularExpression(
        pattern: #"(\\href\{([^}]*)\}\{)([^{}]*(?:\{[^{}]*\}[^{}]*)*)(\})"#
    )
    static let latexUrlRegex = try! NSRegularExpression(
        pattern: #"(\\url\{)([^}]*)(\})"#
    )
    static let latexStyleCmdRegex = try! NSRegularExpression(
        pattern: #"(\\(textbf|textit|emph|underline|texttt|textsc|footnote|textrm|textsf)\{)([^{}]*(?:\{[^{}]*\}[^{}]*)*)(\})"#
    )
    static let latexLogoCmdRegex = try! NSRegularExpression(
        pattern: #"\\(LaTeX|TeX|today)(\{\})?"#
    )
    static let latexTextBackslashRegex = try! NSRegularExpression(
        pattern: #"\\(textbackslash(?:[ \t]+|\{\})?)"#
    )
    static let latexEscapedCharRegex = try! NSRegularExpression(
        pattern: #"\\([&%$#_{}])"#
    )

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
        _ = baseDirectoryURL
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
                let commentFont = docIndex.bodyFont(size: fontSize * 0.92, italic: true, fallbackTheme: theme)
                storage.addAttributes([
                    .font: commentFont,
                    .foregroundColor: theme.secondaryTextNSColor.withAlphaComponent(0.75 * dimFactor)
                ], range: commentRange)
            } else {
                MarkdownLiveStyler.collapseWhitespaceRange(in: storage, range: commentRange)
                if isWholeLineComment {
                    let pStyle = NSMutableParagraphStyle()
                    pStyle.minimumLineHeight = 2.0
                    pStyle.maximumLineHeight = 2.0
                    pStyle.lineSpacing = 0
                    pStyle.paragraphSpacing = 0
                    storage.addAttributes([
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
        let hasBackslash = lineSub.contains("\\")
        let hasDollar = lineSub.contains("$")
        let hasTeXQuotes = lineSub.contains("``") || lineSub.contains("''")
        guard hasBackslash || hasDollar || hasTeXQuotes else { return }

        var protectedRanges: [NSRange] = []
        let isProtected: (NSRange) -> Bool = { r in
            MarkdownLiveStyler.sortedRangesOverlap(protectedRanges, r)
        }

        // 2. Inline Math: $...$ and \(...\)
        if hasDollar || lineSub.contains("\\(") {
            latexInlineMathRegex.enumerateMatches(in: string, options: [], range: effectiveRange) { match, _, _ in
                guard let match = match else { return }
                let fullRange = match.range(at: 0)
                if isProtected(fullRange) { return }
                MarkdownLiveStyler.insertSortedRange(fullRange, into: &protectedRanges)
                storage.addAttribute(MKey.noSpellCheck, value: true, range: fullRange)

                let openRange = match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range(at: 4)
                let innerRange = match.range(at: 2).location != NSNotFound ? match.range(at: 2) : match.range(at: 5)
                let closeRange = match.range(at: 3).location != NSNotFound ? match.range(at: 3) : match.range(at: 6)
                let latexStr = nsString.substring(with: innerRange)

                if isActiveLine || !prettyMode {
                    let mathMono = theme.codeFont(size: fontSize * 0.90)
                    storage.addAttributes([
                        .font: mathMono,
                        .foregroundColor: theme.textNSColor.withAlphaComponent(dimFactor),
                        .backgroundColor: theme.codeBackgroundNSColor.withAlphaComponent(0.55 * dimFactor)
                    ], range: innerRange)
                    MarkdownLiveStyler.highlightLaTeXSource(in: storage, range: innerRange, theme: theme, dimFactor: dimFactor)
                    MarkdownLiveStyler.styleSyntaxToken(in: storage, range: openRange, isActiveLine: true, theme: theme, dimFactor: dimFactor)
                    MarkdownLiveStyler.styleSyntaxToken(in: storage, range: closeRange, isActiveLine: true, theme: theme, dimFactor: dimFactor)
                } else {
                    let mathBox = LaTeXMathRenderer.layoutLatex(latexStr, baseFontSize: fontSize, isDisplayStyle: false)
                    let targetWidth = max(4.0, mathBox.width + 2.0)
                    reserveAtomicInlineSpan(
                        in: storage,
                        nsString: nsString,
                        fullRange: fullRange,
                        width: targetWidth,
                        ascent: mathBox.ascent,
                        descent: mathBox.descent
                    )
                    decorations.append(LineDecoration(
                        lineRange: fullRange,
                        kind: .inlineMathRendered(latex: latexStr, range: fullRange, fontSize: fontSize, dimFactor: dimFactor)
                    ))
                }
            }
        }

        guard hasBackslash || hasTeXQuotes else { return }

        // 3. Citations (\cite{...}, \citep{...}, \citet{...})
        if lineSub.contains("cite") {
            latexCiteRegex.enumerateMatches(in: string, options: [], range: effectiveRange) { match, _, _ in
                guard let match = match, !isProtected(match.range) else { return }
                let fullRange = match.range
                MarkdownLiveStyler.insertSortedRange(fullRange, into: &protectedRanges)
                storage.addAttribute(MKey.noSpellCheck, value: true, range: fullRange)

                let rawKeys = nsString.substring(with: match.range(at: 2))
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }

                if isActiveLine || !prettyMode {
                    MarkdownLiveStyler.highlightLaTeXSource(in: storage, range: fullRange, theme: theme, dimFactor: dimFactor)
                } else {
                    var labels: [String] = []
                    var tooltips: [String] = []
                    var firstLoc: Int?
                    var firstURL: URL?
                    for k in rawKeys {
                        if let entry = docIndex.bibEntries[k] {
                            labels.append(entry.shortCitation)
                            let t = entry.title.isEmpty ? entry.key : "\(entry.author) (\(entry.year)) — \(entry.title)"
                            tooltips.append(t)
                            if firstLoc == nil { firstLoc = entry.characterLocation; firstURL = entry.fileURL }
                        } else {
                            labels.append(k)
                            tooltips.append("Citation key: \(k)")
                        }
                    }
                    let pillLabel = "[\(labels.joined(separator: "; "))]"
                    let pillFont = NSFont.systemFont(ofSize: max(10.5, fontSize * 0.82), weight: .medium)
                    let labelW = ceil((pillLabel as NSString).size(withAttributes: [.font: pillFont]).width) + 12.0
                    reserveAtomicInlineSpan(
                        in: storage,
                        nsString: nsString,
                        fullRange: fullRange,
                        width: labelW,
                        ascent: baseFont.ascender,
                        descent: -baseFont.descender
                    )
                    decorations.append(LineDecoration(
                        lineRange: fullRange,
                        kind: .latexInlinePill(
                            label: pillLabel,
                            tooltip: tooltips.joined(separator: "\n"),
                            targetLocation: firstLoc,
                            targetURL: firstURL,
                            range: fullRange,
                            fontSize: fontSize,
                            isCitation: true,
                            dimFactor: dimFactor
                        )
                    ))
                }
            }
        }

        // 4. Cross-references (\ref{...}, \eqref{...}, \autoref{...}, \cref{...})
        if lineSub.contains("ref") {
            latexRefRegex.enumerateMatches(in: string, options: [], range: effectiveRange) { match, _, _ in
                guard let match = match, !isProtected(match.range) else { return }
                let fullRange = match.range
                MarkdownLiveStyler.insertSortedRange(fullRange, into: &protectedRanges)
                storage.addAttribute(MKey.noSpellCheck, value: true, range: fullRange)

                let cmd = nsString.substring(with: match.range(at: 1))
                let key = nsString.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)

                if isActiveLine || !prettyMode {
                    MarkdownLiveStyler.highlightLaTeXSource(in: storage, range: fullRange, theme: theme, dimFactor: dimFactor)
                } else {
                    let info = docIndex.labels[key]
                    let num = info?.number ?? key
                    let pillLabel: String
                    switch cmd {
                    case "eqref":
                        pillLabel = "(\(num))"
                    case "autoref", "cref", "Cref":
                        pillLabel = "\(info?.kind ?? "Ref.") \(num)"
                    default:
                        pillLabel = num
                    }
                    let tooltip = info.map { "\($0.kind) \($0.number): \($0.title)" } ?? "Label: \(key)"
                    let pillFont = NSFont.systemFont(ofSize: max(10.5, fontSize * 0.82), weight: .medium)
                    let labelW = ceil((pillLabel as NSString).size(withAttributes: [.font: pillFont]).width) + 12.0
                    reserveAtomicInlineSpan(
                        in: storage,
                        nsString: nsString,
                        fullRange: fullRange,
                        width: labelW,
                        ascent: baseFont.ascender,
                        descent: -baseFont.descender
                    )
                    decorations.append(LineDecoration(
                        lineRange: fullRange,
                        kind: .latexInlinePill(
                            label: pillLabel,
                            tooltip: tooltip,
                            targetLocation: info?.characterLocation,
                            targetURL: nil,
                            range: fullRange,
                            fontSize: fontSize,
                            isCitation: false,
                            dimFactor: dimFactor
                        )
                    ))
                }
            }
        }

        // 5. Hidden metadata commands (\label{...}, \bibliography{...}, \centering, \noindent, \\[4pt])
        if lineSub.contains("\\label") || lineSub.contains("\\bib") || lineSub.contains("\\addbib")
            || lineSub.contains("\\nocite") || lineSub.contains("\\centering") || lineSub.contains("\\noindent")
            || lineSub.contains("\\newpage") || lineSub.contains("\\clearpage") || lineSub.contains("\\tableofcontents")
            || lineSub.contains("\\\\") {
            latexHiddenMetaCmdRegex.enumerateMatches(in: string, options: [], range: effectiveRange) { match, _, _ in
                guard let match = match, !isProtected(match.range) else { return }
                MarkdownLiveStyler.insertSortedRange(match.range, into: &protectedRanges)
                MarkdownLiveStyler.styleSyntaxToken(
                    in: storage,
                    range: match.range,
                    isActiveLine: isActiveLine || !prettyMode,
                    theme: theme,
                    dimFactor: dimFactor
                )
            }
        }

        // 6. Links (\href{url}{text}, \url{...}) and Text Formatting (\textbf, \textit, \emph, \texttt, etc.)
        styleLaTeXLinksAndTextCommands(
            in: storage,
            string: string,
            nsString: nsString,
            lineSub: lineSub,
            effectiveRange: effectiveRange,
            baseFont: baseFont,
            fontSize: fontSize,
            isActiveLine: isActiveLine,
            prettyMode: prettyMode,
            docIndex: docIndex,
            theme: theme,
            dimFactor: dimFactor,
            isProtected: isProtected,
            decorations: &decorations
        )
        _ = lineRange
    }
}
