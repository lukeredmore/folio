pub mod analyzer;
pub(crate) mod block_handlers;
pub mod block_scanner;
pub mod cmark_ast;
pub mod cmark_sys;
pub mod editing;
pub(crate) mod html_inline;
pub mod inline_helpers;
pub mod inline_scanner;
pub mod newline;
pub mod tables;
pub mod types;

pub use analyzer::{analyze_markdown_document, analyze_markdown_document_with_options};
pub use cmark_ast::parse_cmark_gfm_ast;
pub use cmark_sys::{
    parse_upstream_spec_txt, render_gfm_to_html, render_markdown_to_html, DEFAULT_GFM_EXTENSIONS,
};
pub use editing::{
    apply_newline_at_cursor, set_heading_level_at_cursor, toggle_symmetric_delimiter,
    toggle_task_checkbox_at_cursor,
};
pub use newline::{compute_newline_continuation, replace_code_fence_language};
pub use tables::{
    is_gfm_table_candidate_line, is_gfm_table_delimiter_row, split_gfm_table_cells,
};
pub use types::{
    CmarkAstAnalysis, CmarkBlockKind, CmarkBlockSpan, CmarkInlineKind, CmarkInlineSpan,
    HtmlInlineTagKind, MarkdownAnalysis, MarkdownBlockDecoration, MarkdownBlockDecorationKind,
    NewlineAction, OutlineHeadingItem, SyntaxFoldSpan, SyntaxTokenKind, UpstreamSpecExample,
};
