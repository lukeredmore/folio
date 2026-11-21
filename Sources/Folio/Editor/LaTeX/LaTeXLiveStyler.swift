import AppKit
@_exported import FolioModels
import Foundation

public enum LaTeXLiveStyler {

    public static func documentKind(for text: String, fileURL: URL? = nil) -> FolioDocumentKind {
        FolioDocumentKind.detect(for: text, fileURL: fileURL)
    }

    public static func isLaTeXOrBibTeXDocument(_ text: String, fileURL: URL? = nil) -> Bool {
        documentKind(for: text, fileURL: fileURL) != .markdown
    }

    @discardableResult
    public static func applyStyles(
        to storage: NSTextStorage,
        theme: EditorTheme,
        typography: EditorTypographySettings? = nil,
        textAlignment: NSTextAlignment = .natural,
        sourceCodeMode: Bool,
        prettyMode: Bool = true,
        focusMode: Bool,
        selectedRange: NSRange,
        containerWidth: CGFloat = 0,
        baseDirectoryURL: URL? = nil,
        fileURL: URL? = nil
    ) -> MarkdownDocumentAnalysis {
        let parameters = MarkdownStyleParameters(
            theme: theme, typography: typography ?? theme.typography, sourceCodeMode: sourceCodeMode, focusMode: focusMode,
            containerWidth: containerWidth, prettyMode: prettyMode, baseDirectoryURL: baseDirectoryURL, textAlignment: textAlignment,
            fileURL: fileURL
        )
        return applyStyles(to: storage, parameters: parameters, selectedRange: selectedRange)
    }

    /// Styles the document. `parameters` holds every input besides the text and selection, so
    /// the block style cache keys on it.
    @discardableResult
    static func applyStyles(to storage: NSTextStorage, parameters: MarkdownStyleParameters, selectedRange: NSRange) -> MarkdownDocumentAnalysis {
        let span = EditorPerfPhase.latexStyles.begin()
        defer { span.end() }
        let theme = parameters.theme
        let typography = parameters.typography
        let textAlignment = parameters.textAlignment
        let sourceCodeMode = parameters.sourceCodeMode
        let prettyMode = parameters.prettyMode
        let focusMode = parameters.focusMode
        let containerWidth = parameters.containerWidth
        let baseDirectoryURL = parameters.baseDirectoryURL
        let fileURL = parameters.fileURL
        let string = storage.string
        let nsString = string as NSString
        let fullLength = nsString.length
        let fullRange = NSRange(location: 0, length: fullLength)
        guard fullLength > 0 else {
            return MarkdownDocumentAnalysis(headings: [], decorations: [])
        }

        let wasSourceMode = storage.attribute(LaTeXBlockStyleCache.sourceModePassAttributeKey, at: 0, effectiveRange: nil) != nil
        let kind = documentKind(for: string, fileURL: fileURL)
        let effectiveContainerWidth: CGFloat = containerWidth > 200 ? containerWidth : typography.maxColumnWidth

        if kind == .bibtex {
            let effectiveBaseSize = theme.baseFontSize * typography.fontSizeScale
            let defaultParagraphStyle = NSMutableParagraphStyle()
            defaultParagraphStyle.alignment = textAlignment
            defaultParagraphStyle.lineHeightMultiple = typography.lineHeightMultiple
            defaultParagraphStyle.lineSpacing = max(0.0, typography.lineSpacing)
            defaultParagraphStyle.paragraphSpacing = max(4.0, typography.paragraphSpacing * 0.65)
            let baseFont =
                sourceCodeMode
                ? theme.codeFont(size: effectiveBaseSize)
                : theme.bodyFont(size: effectiveBaseSize)
            var baseAttributes: [NSAttributedString.Key: Any] = [
                .font: baseFont,
                .foregroundColor: theme.textNSColor,
                .paragraphStyle: defaultParagraphStyle,
                .kern: sourceCodeMode ? 0.0 : typography.characterSpacing,
                .backgroundColor: NSColor.clear,
                .underlineStyle: 0,
                .strikethroughStyle: 0,
                .baselineOffset: 0.0
            ]
            if sourceCodeMode {
                baseAttributes[LaTeXBlockStyleCache.sourceModePassAttributeKey] = true
            }
            LaTeXBlockStyleCache.invalidate()
            storage.beginEditing()
            storage.setAttributes(baseAttributes, range: fullRange)
            let bibResult = applyBibTeXStyles(
                to: storage,
                string: string,
                nsString: nsString,
                fullLength: fullLength,
                theme: theme,
                effectiveBaseSize: effectiveBaseSize,
                fileURL: fileURL
            )
            storage.endEditing()
            if wasSourceMode != sourceCodeMode {
                LaTeXBlockStyleCache.invalidateLayoutManagers(for: storage, fullRange: fullRange)
            }
            return bibResult
        }

        let (docIndex, docMacros) = LaTeXDocumentIndexer.cachedIndexAndMacros(
            string: string,
            nsString: nsString,
            baseDirectoryURL: baseDirectoryURL,
            fileURL: fileURL,
            sourceCodeMode: sourceCodeMode
        )
        LaTeXMathRenderer.setDocumentMacros(docMacros)

        let effectiveBaseSize =
            sourceCodeMode
            ? (theme.baseFontSize * typography.fontSizeScale)
            : docIndex.effectiveBaseFontSize(theme: theme, typography: typography)

        let defaultParagraphStyle = NSMutableParagraphStyle()
        defaultParagraphStyle.alignment = textAlignment
        defaultParagraphStyle.lineHeightMultiple =
            sourceCodeMode
            ? typography.lineHeightMultiple
            : docIndex.effectiveLineHeightMultiple(fallback: typography)
        defaultParagraphStyle.lineSpacing =
            sourceCodeMode
            ? max(0.0, typography.lineSpacing)
            : docIndex.effectiveLineSpacing(fallback: typography)
        defaultParagraphStyle.paragraphSpacing =
            sourceCodeMode
            ? max(4.0, typography.paragraphSpacing * 0.65)
            : 0.0
        defaultParagraphStyle.paragraphSpacingBefore = 0.0
        defaultParagraphStyle.firstLineHeadIndent =
            sourceCodeMode
            ? 0.0
            : docIndex.effectiveFirstLineIndent(baseSize: effectiveBaseSize)
        defaultParagraphStyle.headIndent = 0.0
        if !sourceCodeMode {
            defaultParagraphStyle.tailIndent = effectiveContainerWidth
        }

        let baseFont =
            sourceCodeMode
            ? docIndex.codeFont(size: effectiveBaseSize, fallbackTheme: theme)
            : docIndex.bodyFont(size: effectiveBaseSize, fallbackTheme: theme)

        var baseAttributes: [NSAttributedString.Key: Any] = [
            .font: baseFont,
            .foregroundColor: theme.textNSColor,
            .paragraphStyle: defaultParagraphStyle,
            .kern: sourceCodeMode ? 0.0 : typography.characterSpacing,
            .backgroundColor: NSColor.clear,
            .underlineStyle: 0,
            .strikethroughStyle: 0,
            .baselineOffset: 0.0
        ]
        if sourceCodeMode {
            baseAttributes[LaTeXBlockStyleCache.sourceModePassAttributeKey] = true
        } else if kind == .latex {
            baseAttributes[LaTeXBlockStyleCache.styledPassAttributeKey] = true
        }

        if sourceCodeMode {
            LaTeXBlockStyleCache.invalidate()
            let headings = extractLaTeXOutlineHeadings(docIndex: docIndex)
            let codeFont = docIndex.codeFont(size: effectiveBaseSize * 0.94, fallbackTheme: theme)
            storage.beginEditing()
            storage.setAttributes(baseAttributes, range: fullRange)
            storage.addAttribute(.font, value: codeFont, range: fullRange)
            MarkdownLiveStyler.highlightLaTeXSource(in: storage, range: fullRange, theme: theme, dimFactor: 1.0)
            storage.endEditing()
            LaTeXBlockStyleCache.invalidateLayoutManagers(for: storage, fullRange: fullRange)
            return MarkdownDocumentAnalysis(headings: headings, decorations: [])
        }

        if wasSourceMode {
            LaTeXBlockStyleCache.invalidate()
        }

        let safeCursorLoc = min(selectedRange.location, fullLength)
        let activeLineRange = nsString.lineRange(for: NSRange(location: safeCursorLoc, length: 0))

        let styleConfig = LaTeXBlockStyleCache.StyleConfig(parameters: parameters, documentStyle: docIndex.documentStyle)
        let session = LaTeXBlockStyleCache.prepareIncrementalSession(
            for: storage,
            config: styleConfig,
            string: string,
            nsString: nsString,
            docIndex: docIndex,
            docMacros: docMacros
        )

        storage.beginEditing()
        if session == nil {
            storage.setAttributes(baseAttributes, range: fullRange)
        }

        var pass = LaTeXStylePass(
            storage: storage,
            string: string,
            nsString: nsString,
            fullLength: fullLength,
            docIndex: docIndex,
            activeLineRange: activeLineRange,
            selectedRange: selectedRange,
            theme: theme,
            typography: typography,
            textAlignment: textAlignment,
            baseFont: baseFont,
            effectiveBaseSize: effectiveBaseSize,
            effectiveContainerWidth: effectiveContainerWidth,
            prettyMode: prettyMode,
            focusMode: focusMode,
            baseDirectoryURL: baseDirectoryURL,
            baseAttributes: baseAttributes,
            session: session
        )
        pass.run()

        storage.endEditing()
        if session == nil || wasSourceMode {
            LaTeXBlockStyleCache.invalidateLayoutManagers(for: storage, fullRange: fullRange)
        } else {
            for r in pass.pendingGlyphInvalidationRanges {
                LaTeXBlockStyleCache.invalidateLayoutManagers(for: storage, fullRange: r)
            }
        }
        LaTeXBlockStyleCache.saveSession(
            for: storage,
            config: styleConfig,
            string: string,
            nsString: nsString,
            docIndex: docIndex,
            docMacros: docMacros,
            blocks: pass.recordedBlocks
        )
        return MarkdownDocumentAnalysis(headings: pass.headings, decorations: pass.decorations)
    }

    enum MKey {
        static let collapsed = MarkdownLiveStyler.collapsedTokenAttributeKey
        static let noSpellCheck = MarkdownLiveStyler.noSpellCheckAttributeKey
        static let inlineMathSpan = MarkdownLiveStyler.inlineMathSpanAttributeKey
        static let customColor = MarkdownLiveStyler.customColorAttributeKey
    }

    /// Bounds on a macro call whose arguments continue on later lines.
    enum MultiLineCallLimits {
        static let maxLines = 40
        static let maxCharacters = 4_000
    }

    /// The result of looking for a multi-line macro call that starts on a line.
    struct MultiLineCallProbe: Equatable {
        let blockEnd: Int?
        let contextEnd: Int
    }

    static func probeMultiLineCall(
        lineRange: NSRange,
        nsString: NSString,
        macros: [String: LaTeXMacroDefinition]
    ) -> MultiLineCallProbe {
        LaTeXStylePass.probeMultiLineCall(lineRange: lineRange, nsString: nsString, macros: macros)
    }

    static func maskedComments(_ text: String) -> String {
        LaTeXLexer.maskedComments(text)
    }

    static func isIndexOnlyLine(_ trimmed: String) -> Bool {
        LaTeXStylePass.isIndexOnlyLine(trimmed)
    }

    static func richTextLineStep(_ lines: [[LaTeXInlineRichRun]]) -> CGFloat {
        LaTeXStylePass.richTextLineStep(lines)
    }

    private static func extractLaTeXOutlineHeadings(docIndex: LaTeXDocumentIndex) -> [OutlineHeading] {
        let sortedLocs = docIndex.lineSectionNumbers.keys.sorted()
        var result: [OutlineHeading] = []
        for (i, loc) in sortedLocs.enumerated() {
            guard let info = docIndex.lineSectionNumbers[loc] else { continue }
            let display = info.number.isEmpty ? info.title : "\(info.number) \(info.title)"
            result.append(
                OutlineHeading(
                    level: info.level,
                    title: display,
                    characterLocation: loc,
                    lineNumber: i + 1
                ))
        }
        return result
    }

    private static func applyBibTeXStyles(
        to storage: NSTextStorage,
        string: String,
        nsString: NSString,
        fullLength: Int,
        theme: EditorTheme,
        effectiveBaseSize: CGFloat,
        fileURL: URL?
    ) -> MarkdownDocumentAnalysis {
        let codeFont = theme.codeFont(size: effectiveBaseSize * 0.92)
        let boldFont = FontGDEFSanitizer.convert(codeFont, toHaveTrait: .boldFontMask)
        let fullRange = NSRange(location: 0, length: fullLength)
        storage.addAttributes([.font: codeFont, MKey.noSpellCheck: true], range: fullRange)

        let entries = LaTeXDocumentIndexer.parseBibTeXEntries(from: string, fileURL: fileURL)
        var headings: [OutlineHeading] = []
        var lineNum = 1
        var idx = 0
        var charToLine: [Int: Int] = [:]
        while idx < fullLength {
            let lr = nsString.lineRange(for: NSRange(location: idx, length: 0))
            charToLine[lr.location] = lineNum
            let lineStr = nsString.substring(with: lr) as NSString
            let lineLen = lineStr.length
            var p = 0
            while p < lineLen && (lineStr.character(at: p) == 0x20 || lineStr.character(at: p) == 0x09) { p += 1 }
            if p < lineLen {
                let firstCh = lineStr.character(at: p)
                if firstCh == 0x40 {
                    let braceRange = lineStr.range(of: "{", options: [], range: NSRange(location: p + 1, length: lineLen - (p + 1)))
                    if braceRange.location != NSNotFound && braceRange.location > p + 1 {
                        let typeEnd = braceRange.location
                        let commaRange = lineStr.range(of: ",", options: [], range: NSRange(location: typeEnd + 1, length: lineLen - (typeEnd + 1)))
                        if commaRange.location != NSNotFound && commaRange.location > typeEnd + 1 {
                            storage.addAttributes(
                                [.font: boldFont, .foregroundColor: theme.linkNSColor], range: NSRange(location: lr.location + p, length: typeEnd - p))
                            storage.addAttributes(
                                [.font: boldFont, .foregroundColor: theme.headingNSColor],
                                range: NSRange(location: lr.location + typeEnd + 1, length: commaRange.location - (typeEnd + 1)))
                        }
                    }
                } else if (firstCh >= 0x41 && firstCh <= 0x5A) || (firstCh >= 0x61 && firstCh <= 0x7A) {
                    var nameEnd = p + 1
                    while nameEnd < lineLen {
                        let c = lineStr.character(at: nameEnd)
                        if (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F { nameEnd += 1 } else { break }
                    }
                    var eqPos = nameEnd
                    while eqPos < lineLen && (lineStr.character(at: eqPos) == 0x20 || lineStr.character(at: eqPos) == 0x09) { eqPos += 1 }
                    if eqPos < lineLen && lineStr.character(at: eqPos) == 0x3D {
                        storage.addAttribute(.foregroundColor, value: theme.inlineCodeNSColor, range: NSRange(location: lr.location + p, length: nameEnd - p))
                    }
                }
            }
            idx = NSMaxRange(lr)
            lineNum += 1
        }

        for entry in entries {
            let title = "@\(entry.entryType){\(entry.key)} — \(entry.shortCitation)"
            let line = charToLine[entry.characterLocation] ?? 1
            headings.append(OutlineHeading(level: 1, title: title, characterLocation: entry.characterLocation, lineNumber: line))
        }

        return MarkdownDocumentAnalysis(headings: headings, decorations: [])
    }
}
