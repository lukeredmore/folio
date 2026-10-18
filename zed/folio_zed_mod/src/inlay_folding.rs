use folio_engine::markdown::{
    analyze_markdown_document, MarkdownBlockDecoration, MarkdownBlockDecorationKind,
    SyntaxFoldSpan, SyntaxTokenKind,
};
use folio_engine::math::plain_text_summary;
use std::ops::Range;

/// Represents a DisplayMap fold range in Zed's `crates/editor/src/display_map/fold_map.rs`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ZedFoldRange {
    pub byte_range: Range<usize>,
    pub placeholder_text: String,
    pub collapse_completely: bool,
}

/// Represents a GPUI custom block or inline decoration attached to a buffer row in Zed's `Element::paint`.
#[derive(Debug, Clone, PartialEq)]
pub enum ZedBlockDecoration {
    HeadingRule {
        level: u8,
        line_range: Range<usize>,
    },
    BlockquoteBar {
        nest_level: u8,
        line_range: Range<usize>,
    },
    CodeFenceHeader {
        language: String,
        accent_rgba: (f32, f32, f32, f32),
        line_range: Range<usize>,
    },
    CodeFenceRow {
        is_end: bool,
        line_range: Range<usize>,
    },
    InlineCodePill {
        span_range: Range<usize>,
    },
    DisplayMathCard {
        latex: String,
        line_range: Range<usize>,
        is_active: bool,
        dim_factor: f32,
    },
    HorizontalRule {
        line_range: Range<usize>,
    },
    TableRow {
        is_header: bool,
        is_separator: bool,
        columns: Vec<String>,
        line_range: Range<usize>,
    },
}

/// Computes Zed `FoldMap` fold ranges from Folio's active-line-aware syntax folding spans
/// and inline math block decorations.
pub fn compute_zed_folds(
    fold_spans: &[SyntaxFoldSpan],
    blocks: &[MarkdownBlockDecoration],
) -> Vec<ZedFoldRange> {
    let mut folds = Vec::new();

    for span in fold_spans {
        if span.is_revealed {
            continue;
        }
        // InlineMathDollar is covered by the full InlineMathRendered fold below
        if span.kind == SyntaxTokenKind::InlineMathDollar {
            continue;
        }
        folds.push(ZedFoldRange {
            byte_range: span.byte_range.clone(),
            placeholder_text: String::new(),
            collapse_completely: true,
        });
    }

    for block in blocks {
        if let MarkdownBlockDecorationKind::InlineMathRendered {
            latex,
            is_active: false,
            ..
        } = &block.kind
        {
            let summary = plain_text_summary(latex);
            folds.push(ZedFoldRange {
                byte_range: block.byte_range.clone(),
                placeholder_text: if summary.is_empty() {
                    latex.clone()
                } else {
                    summary
                },
                collapse_completely: false,
            });
        }
    }

    folds.sort_by_key(|f| f.byte_range.start);
    folds
}

/// Translates core engine block decorations into Zed GPUI custom elements.
pub fn translate_block_decorations(
    blocks: &[MarkdownBlockDecoration],
    is_dark: bool,
) -> Vec<ZedBlockDecoration> {
    let mut out = Vec::with_capacity(blocks.len());
    for block in blocks {
        let range = block.byte_range.clone();
        match &block.kind {
            MarkdownBlockDecorationKind::HeadingUnderline { level } => {
                if *level <= 2 {
                    out.push(ZedBlockDecoration::HeadingRule {
                        level: *level as u8,
                        line_range: range,
                    });
                }
            }
            MarkdownBlockDecorationKind::Blockquote { nest_level } => {
                out.push(ZedBlockDecoration::BlockquoteBar {
                    nest_level: *nest_level as u8,
                    line_range: range,
                });
            }
            MarkdownBlockDecorationKind::CodeFenceStart { language } => {
                let c = folio_engine::theme::language_accent_color(language, is_dark);
                out.push(ZedBlockDecoration::CodeFenceHeader {
                    language: language.clone(),
                    accent_rgba: (c.r as f32, c.g as f32, c.b as f32, c.a as f32),
                    line_range: range,
                });
            }
            MarkdownBlockDecorationKind::CodeFenceBody { .. } => {
                out.push(ZedBlockDecoration::CodeFenceRow {
                    is_end: false,
                    line_range: range,
                });
            }
            MarkdownBlockDecorationKind::CodeFenceEnd => {
                out.push(ZedBlockDecoration::CodeFenceRow {
                    is_end: true,
                    line_range: range,
                });
            }
            MarkdownBlockDecorationKind::InlineCode => {
                out.push(ZedBlockDecoration::InlineCodePill { span_range: range });
            }
            MarkdownBlockDecorationKind::MathBlockRendered {
                latex,
                is_active,
                dim_factor,
            } => {
                out.push(ZedBlockDecoration::DisplayMathCard {
                    latex: latex.clone(),
                    line_range: range,
                    is_active: *is_active,
                    dim_factor: *dim_factor as f32,
                });
            }
            MarkdownBlockDecorationKind::InlineMathRendered { .. } => {}
            MarkdownBlockDecorationKind::HorizontalRule => {
                out.push(ZedBlockDecoration::HorizontalRule { line_range: range });
            }
            MarkdownBlockDecorationKind::TableRow {
                is_header,
                is_separator,
                columns,
            } => {
                out.push(ZedBlockDecoration::TableRow {
                    is_header: *is_header,
                    is_separator: *is_separator,
                    columns: columns.clone(),
                    line_range: range,
                });
            }
        }
    }
    out
}

/// Runs a full pass over a buffer snapshot and returns Zed folds and block decorations.
pub fn analyze_buffer_for_zed(
    text: &str,
    cursor_byte_range: Range<usize>,
    is_dark: bool,
) -> (Vec<ZedFoldRange>, Vec<ZedBlockDecoration>) {
    let analysis = analyze_markdown_document(text, cursor_byte_range.start, false, false);
    let folds = compute_zed_folds(&analysis.syntax_fold_spans, &analysis.block_decorations);
    let blocks = translate_block_decorations(&analysis.block_decorations, is_dark);
    (folds, blocks)
}
