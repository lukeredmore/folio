use std::ops::Range;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum NewlineAction {
    Default,
    ClearEmptyListLine,
    InsertPrefix(String),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OutlineHeadingItem {
    pub level: usize,
    pub title: String,
    pub byte_offset: usize,
    pub line_number: usize,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SyntaxTokenKind {
    HeadingHashes,
    BlockquoteMarker,
    CodeFenceDelimiter,
    MathBlockDelimiter,
    InlineCodeBackticks,
    InlineMathDollar,
    BoldMarker,
    ItalicMarker,
    StrikethroughMarker,
    HighlightMarker,
    LinkSyntax,
    TaskListMarker,
    HorizontalRule,
    TablePipeDelimiter,
    HtmlTag,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HtmlInlineTagKind {
    Kbd,
    Underline,
    Strikethrough,
    Mark,
    Superscript,
    Subscript,
    Bold,
    Italic,
    Code,
    LineBreak,
    Details,
    Summary,
    Span,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SyntaxFoldSpan {
    pub byte_range: Range<usize>,
    pub kind: SyntaxTokenKind,
    pub is_revealed: bool,
}

#[derive(Debug, Clone, PartialEq)]
pub enum MarkdownBlockDecorationKind {
    HeadingUnderline { level: usize },
    Blockquote { nest_level: usize },
    CodeFenceStart { language: String },
    CodeFenceBody { language: String },
    CodeFenceEnd,
    InlineCode,
    MathBlockRendered {
        latex: String,
        is_active: bool,
        dim_factor: f64,
    },
    InlineMathRendered {
        latex: String,
        is_active: bool,
        dim_factor: f64,
    },
    HorizontalRule,
    TableRow {
        is_header: bool,
        is_separator: bool,
        columns: Vec<String>,
    },
    Image {
        alt: String,
        url: String,
        title: Option<String>,
        width: Option<u32>,
        height: Option<u32>,
        is_html: bool,
        is_active: bool,
    },
    MermaidBlock {
        source: String,
        svg: String,
        width: f32,
        height: f32,
        is_active: bool,
    },
    SvgBlock {
        svg: String,
        width: f32,
        height: f32,
        is_active: bool,
    },
    HtmlInline {
        tag: HtmlInlineTagKind,
        content_range: Range<usize>,
        is_active: bool,
    },
}

#[derive(Debug, Clone, PartialEq)]
pub struct MarkdownBlockDecoration {
    pub byte_range: Range<usize>,
    pub line_number: usize,
    pub kind: MarkdownBlockDecorationKind,
}

#[derive(Debug, Clone, Default, PartialEq)]
pub struct MarkdownAnalysis {
    pub headings: Vec<OutlineHeadingItem>,
    pub syntax_fold_spans: Vec<SyntaxFoldSpan>,
    pub block_decorations: Vec<MarkdownBlockDecoration>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u32)]
pub enum CmarkBlockKind {
    Heading = 1,
    CodeBlock = 2,
    ThematicBreak = 3,
    BlockQuote = 4,
    ListItem = 5,
    Table = 6,
    HtmlBlock = 7,
    Paragraph = 8,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CmarkBlockSpan {
    pub kind: CmarkBlockKind,
    pub start_line: u32,
    pub start_column: u32,
    pub end_line: u32,
    pub end_column: u32,
    pub level: u32,
    pub flags: u32,
    pub info: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u32)]
pub enum CmarkInlineKind {
    Emphasis = 1,
    Strong = 2,
    Code = 3,
    Strikethrough = 4,
    Link = 5,
    Image = 6,
    HtmlInline = 7,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CmarkInlineSpan {
    pub kind: CmarkInlineKind,
    pub start_line: u32,
    pub start_column: u32,
    pub end_line: u32,
    pub end_column: u32,
    pub url: String,
    pub literal: String,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct CmarkAstAnalysis {
    pub blocks: Vec<CmarkBlockSpan>,
    pub inlines: Vec<CmarkInlineSpan>,
}

/// Parses an upstream `spec.txt` or `extensions.txt` file (from `github/cmark-gfm` or `commonmark-spec`)
/// directly into its constituent specification test examples (`markdown`, `html`, `example`, `section`, `extensions`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UpstreamSpecExample {
    pub example: usize,
    pub section: String,
    pub start_line: usize,
    pub end_line: usize,
    pub extensions: Vec<String>,
    pub markdown: String,
    pub html: String,
}
