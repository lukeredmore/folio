import AppKit
import FolioEngineFFI
import Foundation

public struct CmarkAstBlock: Equatable {
    public let kind: UInt32
    public let startLine: Int
    public let startColumn: Int
    public let endLine: Int
    public let endColumn: Int
    public let level: Int
    public let flags: UInt32
    public let info: String
}

public struct CmarkAstInline: Equatable {
    public let kind: UInt32
    public let startLine: Int
    public let startColumn: Int
    public let endLine: Int
    public let endColumn: Int
    public let url: String
    public let literal: String
}

public enum TableColumnAlignment: Equatable {
    case left
    case center
    case right
}

public enum BlockDecorationKind: Equatable {
    case headingUnderline(level: Int)
    case blockquote(nestLevel: Int)
    case codeFenceStart(language: String)
    case codeFenceBody
    case codeFenceEnd
    case mathBlockStart(isActive: Bool)
    case mathBlockBody(isActive: Bool)
    case mathBlockEnd(isActive: Bool)
    case mathBlockRendered(latex: String, fullBlockRange: NSRange, dimFactor: CGFloat)
    case mermaidBlockRendered(mermaidSource: String, fullBlockRange: NSRange, dimFactor: CGFloat)
    case svgBlockRendered(svgSource: String, fullBlockRange: NSRange, dimFactor: CGFloat)
    case imageRendered(
        url: String,
        alt: String,
        fullRange: NSRange,
        explicitWidth: CGFloat?,
        explicitHeight: CGFloat?,
        baseDirectoryURL: URL?,
        dimFactor: CGFloat
    )
    case inlineMathRendered(latex: String, range: NSRange, fontSize: CGFloat, dimFactor: CGFloat)
    case inlineCode(range: NSRange, fontSize: CGFloat, dimFactor: CGFloat)
    case kbdPill(range: NSRange, fontSize: CGFloat, dimFactor: CGFloat)
    case listBullet(range: NSRange, dimFactor: CGFloat)
    case horizontalRule
    case tableRow(
        isHeader: Bool,
        isSeparator: Bool,
        isFirstRow: Bool,
        isLastRow: Bool,
        bodyRowIndex: Int,
        tableOffsetX: CGFloat,
        tableWidth: CGFloat,
        columnDividers: [CGFloat]
    )
    case latexPreambleCard(
        title: String,
        subtitle: String,
        fullBlockRange: NSRange,
        dimFactor: CGFloat
    )
    case latexTheoremCard(
        header: String,
        isProof: Bool,
        showHeader: Bool,
        fullBlockRange: NSRange,
        dimFactor: CGFloat
    )
    case latexAbstractCard(
        showHeader: Bool,
        fullBlockRange: NSRange,
        dimFactor: CGFloat
    )
    case latexInputCard(
        path: String,
        resolvedURL: URL?,
        lineRange: NSRange,
        dimFactor: CGFloat
    )
    case latexEquationNumber(
        number: String,
        fullBlockRange: NSRange,
        dimFactor: CGFloat
    )
    case latexSectionBadge(
        number: String,
        level: Int,
        lineRange: NSRange,
        dimFactor: CGFloat
    )
    case latexInlinePill(
        label: String,
        tooltip: String?,
        targetLocation: Int?,
        targetURL: URL?,
        range: NSRange,
        fontSize: CGFloat,
        isCitation: Bool,
        dimFactor: CGFloat
    )
    case latexInlineText(
        text: String,
        font: NSFont,
        range: NSRange,
        dimFactor: CGFloat
    )
}

public struct LineDecoration: Equatable {
    public let lineRange: NSRange
    public let kind: BlockDecorationKind
}

public struct MarkdownDocumentAnalysis {
    public let headings: [OutlineHeading]
    public let decorations: [LineDecoration]
}

extension MarkdownLiveStyler {
    struct DeferredInlineStyle {
        let line: Int
        let range: NSRange
        let baseFont: NSFont
        let isActive: Bool
        let dimFactor: CGFloat
    }

    enum ProseLineKind: Equatable {
        case paragraph
        case listItem
        case blockquote(nestLevel: Int)
    }

    typealias LineRecord = (
        lineRange: NSRange,
        contentRange: NSRange,
        lineText: String,
        isActive: Bool,
        dimFactor: CGFloat
    )

    struct ParsedTableCell {
        let leadingDelimiterRange: NSRange // pipe (if any) + leading spaces before cell content
        let contentRange: NSRange          // trimmed cell text
        let trailingSpacesRange: NSRange   // trailing spaces before the next pipe
    }

    struct ParsedTableRow {
        let cells: [ParsedTableCell]
        let closingPipeRange: NSRange
    }

    /// Container context of a fenced code block nested in a list item.
    struct CodeFenceContainer {
        /// Leading spaces of the opening fence; stripped from each delimiter and body line.
        var strippedSpaces = 0
        /// Text indent (points) of the enclosing list item.
        var indent: CGFloat = 0
    }

    struct ScannedInlineCodeSpan {
        let fullRange: NSRange
        let openRange: NSRange
        let innerRange: NSRange
        let closeRange: NSRange
    }

    struct ScannedMarkdownLink {
        let isImage: Bool
        let fullRange: NSRange
        let openSyntaxRange: NSRange      // `[` or `![`
        let labelRange: NSRange           // `label`
        let trailingSyntaxRange: NSRange  // `](url)`
        let url: String
    }

    struct LanguageSyntaxProfile {
        let keywords: NSRegularExpression?
        let typesAndBuiltins: NSRegularExpression?
        let attributesOrMacros: NSRegularExpression?
        let comments: NSRegularExpression?
        let strings: NSRegularExpression
        let numbers: NSRegularExpression
        let functions: NSRegularExpression
        let keywordColorLight: NSColor
        let keywordColorDark: NSColor
    }

    /// Renders a Mermaid diagram source block (`flowchart`/`graph`, `sequenceDiagram`, `classDiagram`, `stateDiagram`, `pie`)
    /// into a self-contained SVG string via `folio_engine`.
    public static func renderMermaidSVG(_ source: String, isDark: Bool = false) -> String {
        return source.withCString { srcPtr in
            guard let resPtr = ot_engine_render_mermaid_svg(srcPtr, isDark) else { return "" }
            defer { ot_engine_free_mermaid_result(resPtr) }
            guard let svgPtr = resPtr.pointee.svg else { return "" }
            return String(cString: svgPtr)
        }
    }

    /// Sanitizes and normalizes an SVG markup snippet (adding `xmlns` and `viewBox` if missing) via `folio_engine`.
    public static func normalizeSVG(_ rawSVG: String) -> String {
        return rawSVG.withCString { svgPtr in
            guard let resPtr = ot_engine_normalize_svg(svgPtr) else { return "" }
            defer { ot_engine_free_mermaid_result(resPtr) }
            guard let outPtr = resPtr.pointee.svg else { return "" }
            return String(cString: outPtr)
        }
    }

    /// Renders Markdown to specification-compliant HTML using the upstream `cmark-gfm` parser in `folio_engine`.
    /// Pass `nil` for `extensions` to enable the default GitHub Flavored Markdown extensions
    /// (`table`, `strikethrough`, `autolink`, `tagfilter`, `tasklist`), or pass a custom list (e.g. `[]` for pure CommonMark).
    public static func renderHTML(_ markdown: String, extensions: [String]? = nil) -> String {
        return markdown.withCString { mdPtr in
            let htmlPtr: UnsafeMutablePointer<CChar>?
            if let extensions = extensions {
                let joined = extensions.joined(separator: " ")
                htmlPtr = joined.withCString { extPtr in
                    ot_engine_render_markdown_html(mdPtr, extPtr)
                }
            } else {
                htmlPtr = ot_engine_render_markdown_html(mdPtr, nil)
            }
            guard let validPtr = htmlPtr else { return "" }
            defer { ot_engine_free_string(validPtr) }
            return String(cString: validPtr)
        }
    }

    /// Parses Markdown into a CommonMark 0.31.2 + GFM 0.29.0 AST via `cmark-gfm` in `folio_engine`.
    public static func parseSpecAST(_ markdown: String) -> (blocks: [CmarkAstBlock], inlines: [CmarkAstInline]) {
        EditorPerfScope.recorder?.increment(.parse)
        let span = EditorPerfPhase.parse.begin()
        defer { span.end() }
        return markdown.withCString { mdPtr in
            guard let resPtr = ot_engine_parse_markdown_ast(mdPtr) else {
                return ([], [])
            }
            defer { ot_engine_free_markdown_ast(resPtr) }
            let res = resPtr.pointee

            var blocks: [CmarkAstBlock] = []
            if res.block_count > 0, let blocksBase = res.blocks {
                blocks.reserveCapacity(res.block_count)
                for i in 0..<res.block_count {
                    let b = blocksBase[i]
                    let info = b.info != nil ? String(cString: b.info) : ""
                    blocks.append(CmarkAstBlock(
                        kind: b.kind,
                        startLine: Int(b.start_line),
                        startColumn: Int(b.start_column),
                        endLine: Int(b.end_line),
                        endColumn: Int(b.end_column),
                        level: Int(b.level),
                        flags: b.flags,
                        info: info
                    ))
                }
            }

            var inlines: [CmarkAstInline] = []
            if res.inline_count > 0, let inlinesBase = res.inlines {
                inlines.reserveCapacity(res.inline_count)
                for i in 0..<res.inline_count {
                    let inl = inlinesBase[i]
                    let url = inl.url != nil ? String(cString: inl.url) : ""
                    let literal = inl.literal != nil ? String(cString: inl.literal) : ""
                    inlines.append(CmarkAstInline(
                        kind: inl.kind,
                        startLine: Int(inl.start_line),
                        startColumn: Int(inl.start_column),
                        endLine: Int(inl.end_line),
                        endColumn: Int(inl.end_column),
                        url: url,
                        literal: literal
                    ))
                }
            }

            return (blocks, inlines)
        }
    }
}
