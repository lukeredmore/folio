import AppKit
import Foundation

public final class MarkdownLiveStyler {

    public static let collapsedTokenAttributeKey = NSAttributedString.Key("FolioCollapsedSyntaxToken")
    public static let inlineCodeFontAttributeKey = NSAttributedString.Key("FolioInlineCodeFont")
    /// Marks a source newline inside an inactive paragraph that renders as a space (CommonMark soft line break).
    public static let softLineBreakAttributeKey = NSAttributedString.Key("FolioSoftLineBreak")
    /// Marks an inactive inline math span (`$...$`) with its atomic layout metrics (`InlineMathLayoutInfo`).
    public static let inlineMathSpanAttributeKey = NSAttributedString.Key("FolioInlineMathSpan")
    /// Marks any inline math span (`$...$`, active or inactive) so AST link resolution skips math content.
    public static let inlineMathLatexAttributeKey = NSAttributedString.Key("FolioInlineMathLatex")
    /// Marks ranges (math, code, syntax tokens) where spellcheck squiggles must be suppressed.
    public static let noSpellCheckAttributeKey = NSAttributedString.Key("FolioNoSpellCheck")
    /// Stores a custom LaTeX foreground color (e.g. from `\color{...}` or colored macro blocks) so custom-drawn math and inline text inherit it.
    public static let customColorAttributeKey = NSAttributedString.Key("FolioCustomForegroundColor")
    /// Lines longer than this many UTF-16 units keep the base attributes. TextKit lays out a
    /// paragraph in time that grows faster than quadratically with its attribute runs, so styling
    /// a minified or one-line file (for example 18 MB of JSON with a link every 40 characters)
    /// hangs layout. The limit matches VS Code's `editor.maxTokenizationLineLength`.
    static let maxStyledLineLength = 20_000

    public struct InlineMathLayoutInfo: Hashable, Sendable {
        public let range: NSRange
        public let width: CGFloat
        public let ascent: CGFloat
        public let descent: CGFloat
        public let padding: CGFloat

        public init(
            range: NSRange,
            width: CGFloat,
            ascent: CGFloat,
            descent: CGFloat,
            padding: CGFloat = 3.0
        ) {
            self.range = range
            self.width = width
            self.ascent = ascent
            self.descent = descent
            self.padding = padding
        }

        public static func == (lhs: InlineMathLayoutInfo, rhs: InlineMathLayoutInfo) -> Bool {
            lhs.range.length == rhs.range.length
                && lhs.width == rhs.width
                && lhs.ascent == rhs.ascent
                && lhs.descent == rhs.descent
                && lhs.padding == rhs.padding
        }

        public func hash(into hasher: inout Hasher) {
            hasher.combine(range.length)
            hasher.combine(width)
            hasher.combine(ascent)
            hasher.combine(descent)
            hasher.combine(padding)
        }
    }

    static let headingRegex = try! NSRegularExpression(pattern: #"^( {0,3})(#{1,6})(?:([ \t]+)(.*?))?(?:(?<![ \t])[ \t]+#+[ \t]*)?$"#)
    static let setextH1Regex = try! NSRegularExpression(pattern: #"^ {0,3}=+[ \t]*$"#)
    static let setextH2Regex = try! NSRegularExpression(pattern: #"^ {0,3}-{2,}[ \t]*$"#)
    static let blockquoteRegex = try! NSRegularExpression(pattern: #"^(\s*>+[ \t]*)(.*)$"#)
    static let taskListRegex = try! NSRegularExpression(pattern: #"^([ \t]*)([-*+]|\d+[.)])([ \t]+)(\[[ xX]\])([ \t]+)(.*)$"#)
    static let unorderedListRegex = try! NSRegularExpression(pattern: #"^([ \t]*)([-*+])([ \t]+)(.+)$"#)
    static let orderedListRegex = try! NSRegularExpression(pattern: #"^([ \t]*)(\d+[.)])([ \t]+)(.+)$"#)
    static let hrRegex = try! NSRegularExpression(pattern: #"^ {0,3}(?:(?:-[ \t]*){3,}|(?:\*[ \t]*){3,}|(?:_[ \t]*){3,})$"#)
    static let codeFenceOpenRegex = try! NSRegularExpression(pattern: #"^ {0,3}(`{3,}|~{3,})([ \t]*[^`~\n]*)$"#)
    static let linkRefDefRegex = try! NSRegularExpression(pattern: #"^( {0,3}\[[^\]]+\]:)([ \t]*)(<?[^\s>]+>?)(?:([ \t]+)(["'(].*["')]))?[ \t]*$"#)

    // Inline regexes
    static let escapeRegex = try! NSRegularExpression(pattern: ##"\\([!\"#$%&'()*+,\-./:;<=>?@\[\\\]^_`{|}~])"##)
    static let htmlBrRegex = try! NSRegularExpression(pattern: #"<br\s*/?>"#, options: [.caseInsensitive])
    static let htmlImgTagRegex = try! NSRegularExpression(pattern: #"<img\b([^>]*?)/?>"#, options: [.caseInsensitive])
    static let htmlVideoTagRegex = try! NSRegularExpression(pattern: #"<video\b([^>]*?)(?:/>|>(.*?)</video\s*>)"#, options: [.caseInsensitive])
    static let htmlPairedTagRegex = try! NSRegularExpression(
        pattern: #"(<(kbd|u|ins|mark|sup|sub|b|strong|i|em|s|del|strike|code|summary)\b[^>]*>)(.*?)(</\2\s*>)"#,
        options: [.caseInsensitive]
    )
    static let htmlDetailsTagRegex = try! NSRegularExpression(pattern: #"</?details\b[^>]*>"#, options: [.caseInsensitive])
    static let htmlAttrRegex = try! NSRegularExpression(pattern: #"\b([a-zA-Z_-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+))"#)
    static let boldItalicRegex = try! NSRegularExpression(
        pattern:
            #"(?<!\*)\*\*\*(?!\*)(?=\S)((?:(?!\*\*\*)[\s\S])+?)(?<=\S)\*\*\*(?!\*)|(?<![\p{L}\p{N}_])___(?!_)(?=\S)((?:(?!___)[\s\S])+?)(?<=\S)___(?![\p{L}\p{N}_])"#
    )
    static let boldAsteriskRegex = try! NSRegularExpression(pattern: #"(?<!\*)\*\*(?!\*)(?=\S)((?:(?!\*\*)[\s\S])+?)(?<=\S)\*\*(?!\*)"#)
    static let boldUnderscoreRegex = try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}_])__(?!_)(?=\S)((?:(?!__)[\s\S])+?)(?<=\S)__(?![\p{L}\p{N}_])"#)
    static let italicAsteriskRegex = try! NSRegularExpression(pattern: #"(?<!\*)\*(?!\*)(?=\S)((?:[^\*]|\*\*(?=\S)[^\*]+?(?<=\S)\*\*)+?)(?<=\S)\*(?!\*)"#)
    static let italicUnderscoreRegex = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}_])_(?!_)(?=\S)((?:[^_]|__(?=\S)[^_]+?(?<=\S)__|(?<=[\p{L}\p{N}])_(?=[\p{L}\p{N}]))+?)(?<=\S)_(?![\p{L}\p{N}_])"#
    )
    static let strikeRegex = try! NSRegularExpression(pattern: #"(?<!~)(~~)(?!~)(?=\S)((?:(?!~~)[\s\S])+?)(?<=\S)(~~)(?!~)"#)
    static let highlightRegex = try! NSRegularExpression(pattern: #"(?<!=)(==)(?!=)(?=\S)((?:(?!==)[\s\S])+?)(?<=\S)(==)(?!=)"#)
    static let inlineMathRegex = try! NSRegularExpression(pattern: #"(?<!\$)(\$)(?!\$)(?=\S)([^\$\n]+?)(?<=\S)(?<!\$)(\$)(?![\$\d])"#)
    static let autolinkRegex = try! NSRegularExpression(pattern: #"(<)((?:https?://|mailto:)[^>\s]+|[a-zA-Z0-9._%+\-]+@(?:[a-zA-Z0-9\-]+\.)+[a-zA-Z]{2,})(>)"#)
    static let multiSpaceRegex = try! NSRegularExpression(pattern: #"[ \t]{2,}"#)
    static let leadingSpaceRegex = try! NSRegularExpression(pattern: #"^[ \t]+"#, options: [.anchorsMatchLines])
    static let trailingSpaceRegex = try! NSRegularExpression(pattern: #"[ \t]+$"#, options: [.anchorsMatchLines])
    static let latexCommandRegex = try! NSRegularExpression(pattern: #"\\[a-zA-Z]+|\\[^a-zA-Z\s]"#)
    static let latexBracesRegex = try! NSRegularExpression(pattern: #"[\{\}\^_]"#)

    private static let macroDefinitionKeywords: [String] = [
        "\\newcommand",
        "\\renewcommand",
        "\\providecommand",
        "\\DeclareMathOperator",
        "\\def",
        "environment{"
    ]

    @discardableResult
    public static func applyStyles(
        to storage: NSTextStorage,
        theme: EditorTheme,
        typography: EditorTypographySettings? = nil,
        sourceCodeMode: Bool,
        focusMode: Bool,
        selectedRange: NSRange,
        containerWidth: CGFloat = 0,
        prettyMode: Bool = true,
        baseDirectoryURL: URL? = nil,
        textAlignment: NSTextAlignment = .natural,
        fileURL: URL? = nil
    ) -> MarkdownDocumentAnalysis {
        let parameters = MarkdownStyleParameters(
            theme: theme,
            typography: typography ?? theme.typography,
            sourceCodeMode: sourceCodeMode,
            focusMode: focusMode,
            containerWidth: containerWidth,
            prettyMode: prettyMode,
            baseDirectoryURL: baseDirectoryURL,
            textAlignment: textAlignment,
            fileURL: fileURL
        )
        return styleDocument(storage, parameters: parameters, selectedRange: selectedRange).analysis
    }

    /// Restyles the whole document. Markdown documents styled outside source mode also get a
    /// record for `restyleIncrementally`.
    package static func styleDocument(
        _ storage: NSTextStorage,
        parameters: MarkdownStyleParameters,
        selectedRange: NSRange
    ) -> MarkdownStyleResult {
        let string = storage.string
        let nsString = string as NSString
        let fullRange = NSRange(location: 0, length: nsString.length)
        if LaTeXLiveStyler.isLaTeXOrBibTeXDocument(string, fileURL: parameters.fileURL) {
            let analysis = LaTeXLiveStyler.applyStyles(to: storage, parameters: parameters, selectedRange: selectedRange)
            return MarkdownStyleResult(analysis: analysis, record: nil, restyledRanges: [fullRange])
        }
        let span = EditorPerfPhase.applyStyles.begin()
        defer { span.end() }
        LaTeXBlockStyleCache.invalidate(for: storage)
        guard fullRange.length > 0 else {
            return MarkdownStyleResult(analysis: MarkdownDocumentAnalysis(headings: [], decorations: []), record: nil, restyledRanges: [])
        }

        let sourceCodeMode = parameters.sourceCodeMode
        let wasSourceMode = storage.attribute(LaTeXBlockStyleCache.sourceModePassAttributeKey, at: 0, effectiveRange: nil) != nil
        let wasLaTeX = storage.attribute(LaTeXBlockStyleCache.styledPassAttributeKey, at: 0, effectiveRange: nil) != nil
        let hasMacroKeywords = !sourceCodeMode && containsMacroKeywords(in: nsString, range: fullRange)
        let documentMacros = hasMacroKeywords ? LaTeXMacroExpander.extractDocumentMacros(from: string) : [:]
        LaTeXMathRenderer.setDocumentMacros(documentMacros)
        let ast = sourceCodeMode ? MarkdownStyleAST.empty : parseStyleAST(string)

        storage.beginEditing()
        let pass = MarkdownStylePass(
            storage: storage,
            string: string,
            nsString: nsString,
            parameters: parameters,
            selectedRange: selectedRange,
            ast: ast
        )
        storage.setAttributes(pass.baseAttributes, range: fullRange)
        pass.styleLines(from: 0, lineNumber: 1, to: fullRange.length)
        pass.finish()
        storage.endEditing()
        if wasSourceMode != sourceCodeMode || wasLaTeX {
            LaTeXBlockStyleCache.invalidateLayoutManagers(for: storage, fullRange: fullRange)
        }
        let record =
            sourceCodeMode
            ? nil
            : MarkdownStyleRecord(
                text: pass.nsString,
                parameters: parameters,
                selectedRange: selectedRange,
                ast: ast,
                documentMacros: documentMacros,
                hasMacroKeywords: hasMacroKeywords,
                macrosBalancedAtCheckpoints: areBracesBalancedAtCheckpoints(
                    in: pass.nsString,
                    checkpoints: pass.checkpoints,
                    hasMacroKeywords: hasMacroKeywords
                ),
                checkpoints: pass.checkpoints,
                decorations: pass.decorations,
                headings: pass.headings
            )
        return MarkdownStyleResult(analysis: pass.analysis, record: record, restyledRanges: [fullRange])
    }

    /// Macros that `\newcommand` and similar definitions anywhere in the document declare for math.
    static func documentMacros(in string: String, sourceCodeMode: Bool) -> [String: LaTeXMacroDefinition] {
        guard !sourceCodeMode else { return [:] }
        let nsString = string as NSString
        guard containsMacroKeywords(in: nsString, range: NSRange(location: 0, length: nsString.length)) else {
            return [:]
        }
        return LaTeXMacroExpander.extractDocumentMacros(from: string)
    }

    static func containsMacroKeywords(in text: NSString, range: NSRange) -> Bool {
        guard range.length > 0, text.range(of: "\\", options: .literal, range: range).location != NSNotFound else {
            return false
        }
        for keyword in macroDefinitionKeywords {
            if text.range(of: keyword, options: .literal, range: range).location != NSNotFound {
                return true
            }
        }
        return false
    }

    /// True when every checkpoint boundary has zero unclosed `{` braces (outside `%` comments),
    /// ensuring no macro definition in `text` spans across a checkpoint into a later paragraph.
    static func areBracesBalancedAtCheckpoints(
        in text: NSString,
        checkpoints: [MarkdownStyleCheckpoint],
        hasMacroKeywords: Bool
    ) -> Bool {
        guard hasMacroKeywords, !checkpoints.isEmpty else { return true }
        var depth = 0
        var inComment = false
        var cursor = 0
        for checkpoint in checkpoints {
            let boundary = NSMaxRange(checkpoint.lineRange)
            while cursor < boundary && cursor < text.length {
                let ch = text.character(at: cursor)
                if ch == 0x0A {
                    inComment = false
                    cursor += 1
                    continue
                }
                if inComment {
                    cursor += 1
                    continue
                }
                if ch == 0x5C {
                    cursor += 2
                    continue
                }
                if ch == 0x25 {
                    inComment = true
                    cursor += 1
                    continue
                }
                if ch == 0x7B {
                    depth += 1
                } else if ch == 0x7D {
                    depth = max(0, depth - 1)
                }
                cursor += 1
            }
            if depth != 0 {
                return false
            }
        }
        return true
    }

    static func parseStyleAST(_ string: String) -> MarkdownStyleAST {
        let parsed = parseSpecAST(string)
        return MarkdownStyleAST(blocks: parsed.blocks, inlines: parsed.inlines)
    }
}
