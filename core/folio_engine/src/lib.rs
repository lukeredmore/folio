#![deny(warnings)]

pub mod ffi;
pub mod markdown;
pub mod math;
pub mod mermaid;
pub mod reflow;
pub mod stats;
pub mod theme;

pub use markdown::{
    analyze_markdown_document, analyze_markdown_document_with_options, apply_newline_at_cursor,
    compute_newline_continuation, parse_cmark_gfm_ast, render_gfm_to_html, render_markdown_to_html,
    replace_code_fence_language, set_heading_level_at_cursor, toggle_symmetric_delimiter,
    toggle_task_checkbox_at_cursor, CmarkAstAnalysis, CmarkBlockSpan, CmarkInlineSpan,
    HtmlInlineTagKind, MarkdownAnalysis, MarkdownBlockDecoration, MarkdownBlockDecorationKind,
    NewlineAction, OutlineHeadingItem, SyntaxFoldSpan, SyntaxTokenKind,
};
pub use math::{
    layout_latex, layout_math_node, parse_latex, plain_text_summary, MathDrawPrimitive,
    MathFontStyle, MathLayoutPlan, MathNode,
};
pub use mermaid::{
    detect_mermaid_kind, normalize_svg_markup, render_mermaid_to_svg, MermaidDiagramKind,
    MermaidRenderResult,
};
pub use reflow::{reflow_markdown, reflow_paragraph_at_line, ParagraphReflow};
pub use stats::DocumentStats;
pub use theme::{language_accent_color, RgbaColor, ThemeId, ThemeMetrics};
