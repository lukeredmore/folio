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
            || trimmed.hasPrefix("@misc{") || trimmed.hasPrefix("@techreport{") || trimmed.hasPrefix("@phdthesis{") {
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
        let typography = typography ?? theme.typography
        let string = storage.string
        let nsString = string as NSString
        let fullLength = nsString.length
        let fullRange = NSRange(location: 0, length: fullLength)
        guard fullLength > 0 else {
            return MarkdownDocumentAnalysis(headings: [], decorations: [])
        }

        let effectiveBaseSize = theme.baseFontSize * typography.fontSizeScale
        let effectiveContainerWidth: CGFloat = containerWidth > 200 ? containerWidth : typography.maxColumnWidth

        let defaultParagraphStyle = NSMutableParagraphStyle()
        defaultParagraphStyle.alignment = textAlignment
        defaultParagraphStyle.lineHeightMultiple = typography.lineHeightMultiple
        defaultParagraphStyle.lineSpacing = max(0.0, typography.lineSpacing)
        defaultParagraphStyle.paragraphSpacing = max(4.0, typography.paragraphSpacing * 0.65)
        defaultParagraphStyle.paragraphSpacingBefore = 0.0
        defaultParagraphStyle.firstLineHeadIndent = 0.0
        defaultParagraphStyle.headIndent = 0.0
        if !sourceCodeMode {
            defaultParagraphStyle.tailIndent = effectiveContainerWidth
        }

        let baseFont = sourceCodeMode
            ? theme.codeFont(size: effectiveBaseSize)
            : theme.bodyFont(size: effectiveBaseSize)

        let wasSourceMode = storage.attribute(LaTeXBlockStyleCache.sourceModePassAttributeKey, at: 0, effectiveRange: nil) != nil
        let kind = documentKind(for: string, fileURL: fileURL)

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

        if kind == .bibtex {
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
            sourceCodeMode: sourceCodeMode
        )
        LaTeXMathRenderer.setDocumentMacros(docMacros)

        if sourceCodeMode {
            LaTeXBlockStyleCache.invalidate()
            let headings = extractLaTeXOutlineHeadings(docIndex: docIndex)
            let codeFont = theme.codeFont(size: effectiveBaseSize * 0.94)
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
            textAlignment: textAlignment,
            sourceCodeMode: sourceCodeMode,
            prettyMode: prettyMode,
            focusMode: focusMode,
            effectiveContainerWidth: effectiveContainerWidth,
            baseDirectoryURL: baseDirectoryURL
        )
        LaTeXBlockStyleCache.activeBaseAttributes = baseAttributes
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
        to storage: NSTextStorage,
        string: String,
        nsString: NSString,
        fullLength: Int,
        theme: EditorTheme,
        effectiveBaseSize: CGFloat,
        effectiveContainerWidth: CGFloat,
        fileURL: URL?
    ) -> MarkdownDocumentAnalysis {
        let codeFont = theme.codeFont(size: effectiveBaseSize * 0.92)
        let boldFont = NSFontManager.shared.convert(codeFont, toHaveTrait: .boldFontMask)
        let fullRange = NSRange(location: 0, length: fullLength)
        storage.addAttributes([
            .font: codeFont,
            MKey.noSpellCheck: true
        ], range: fullRange)

        let entries = LaTeXDocumentIndexer.parseBibTeXEntries(from: string, fileURL: fileURL)
        var headings: [OutlineHeading] = []
        var lineNum = 1
        var idx = 0
        var charToLine: [Int: Int] = [:]
        while idx < fullLength {
            let lr = nsString.lineRange(for: NSRange(location: idx, length: 0))
            charToLine[lr.location] = lineNum
            idx = NSMaxRange(lr)
            lineNum += 1
        }

        for entry in entries {
            let subtitle = entry.shortCitation
            let title = "@\(entry.entryType){\(entry.key)} — \(subtitle)"
            let line = charToLine[entry.characterLocation] ?? 1
            headings.append(OutlineHeading(
                level: 1,
                title: title,
                characterLocation: entry.characterLocation,
                lineNumber: line
            ))
        }

        LaTeXDocumentIndexer.bibEntryHeaderRegex.enumerateMatches(in: string, range: fullRange) { m, _, _ in
            guard let m = m else { return }
            storage.addAttributes([
                .font: boldFont,
                .foregroundColor: theme.linkNSColor
            ], range: m.range(at: 1))
            storage.addAttributes([
                .font: boldFont,
                .foregroundColor: theme.headingNSColor
            ], range: m.range(at: 2))
        }

        LaTeXDocumentIndexer.bibFieldRegex.enumerateMatches(in: string, range: fullRange) { m, _, _ in
            guard let m = m else { return }
            storage.addAttribute(.foregroundColor, value: theme.inlineCodeNSColor, range: m.range(at: 1))
        }

        _ = effectiveContainerWidth
        return MarkdownDocumentAnalysis(headings: headings, decorations: [])
    }

    enum MKey {
        static let collapsed = MarkdownLiveStyler.collapsedTokenAttributeKey
        static let noSpellCheck = MarkdownLiveStyler.noSpellCheckAttributeKey
        static let inlineMathSpan = MarkdownLiveStyler.inlineMathSpanAttributeKey
    }
}
