import AppKit
import Foundation

public enum LaTeXLiveStyler {

    // MARK: - Document Type Detection

    public static func documentKind(for text: String, fileURL: URL? = nil) -> FolioDocumentKind {
        if let ext = fileURL?.pathExtension.lowercased(), !ext.isEmpty {
            if WorkspaceFileNode.latexExtensions.contains(ext) {
                return .latex
            }
            if WorkspaceFileNode.bibtexExtensions.contains(ext) {
                return .bibtex
            }
            if WorkspaceFileNode.markdownExtensions.contains(ext) {
                return .markdown
            }
        }
        let prefix = String(text.prefix(2000))
        if prefix.contains("\\documentclass") || prefix.contains("\\begin{document}") || prefix.contains("\\ProvidesPackage") {
            return .latex
        }
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("@article{") || trimmed.hasPrefix("@book{") || trimmed.hasPrefix("@inproceedings{")
            || trimmed.hasPrefix("@misc{") || trimmed.hasPrefix("@techreport{") || trimmed.hasPrefix("@phdthesis{")
        {
            return .bibtex
        }
        return .markdown
    }

    public static func isLaTeXOrBibTeXDocument(_ text: String, fileURL: URL? = nil) -> Bool {
        documentKind(for: text, fileURL: fileURL) != .markdown
    }

    // MARK: - Main Entry Point

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
        let span = EditorPerfPhase.latexStyles.begin()
        defer { span.end() }
        let typography = typography ?? theme.typography
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
                effectiveContainerWidth: effectiveContainerWidth,
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

        var headings: [OutlineHeading] = []
        var decorations: [LineDecoration] = []
        var recordedBlocks: [LaTeXBlockStyleCache.CachedBlock] = []

        let styleConfig = LaTeXBlockStyleCache.StyleConfig(
            theme: theme,
            typography: typography,
            documentStyle: docIndex.documentStyle,
            textAlignment: textAlignment,
            sourceCodeMode: sourceCodeMode,
            prettyMode: prettyMode,
            focusMode: focusMode,
            effectiveContainerWidth: effectiveContainerWidth,
            baseDirectoryURL: baseDirectoryURL
        )
        LaTeXBlockStyleCache.activeBaseAttributes = baseAttributes
        LaTeXBlockStyleCache.pendingGlyphInvalidationRanges.removeAll(keepingCapacity: true)
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

        styleLaTeXDocumentBody(
            in: storage,
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
            session: session,
            headings: &headings,
            decorations: &decorations,
            recordedBlocks: &recordedBlocks
        )

        storage.endEditing()
        if session == nil || wasSourceMode {
            LaTeXBlockStyleCache.invalidateLayoutManagers(for: storage, fullRange: fullRange)
        } else {
            for r in LaTeXBlockStyleCache.pendingGlyphInvalidationRanges {
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
            blocks: recordedBlocks
        )
        return MarkdownDocumentAnalysis(headings: headings, decorations: decorations)
    }

    // MARK: - BibTeX Document Styling

    private static func applyBibTeXStyles(
        to storage: NSTextStorage, string: String, nsString: NSString, fullLength: Int,
        theme: EditorTheme, effectiveBaseSize: CGFloat, effectiveContainerWidth: CGFloat, fileURL: URL?
    ) -> MarkdownDocumentAnalysis {
        let codeFont = theme.codeFont(size: effectiveBaseSize * 0.92)
        let boldFont = NSFontManager.shared.convert(codeFont, toHaveTrait: .boldFontMask)
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

        _ = effectiveContainerWidth
        return MarkdownDocumentAnalysis(headings: headings, decorations: [])
    }

    enum MKey {
        static let collapsed = MarkdownLiveStyler.collapsedTokenAttributeKey
        static let noSpellCheck = MarkdownLiveStyler.noSpellCheckAttributeKey
        static let inlineMathSpan = MarkdownLiveStyler.inlineMathSpanAttributeKey
        static let customColor = MarkdownLiveStyler.customColorAttributeKey
    }
}
