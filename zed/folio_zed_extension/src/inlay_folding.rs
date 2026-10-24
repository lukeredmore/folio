use folio_engine::markdown::{
    analyze_markdown_document_with_options, HtmlInlineTagKind, MarkdownBlockDecoration,
    MarkdownBlockDecorationKind as Kind, SyntaxFoldSpan, SyntaxTokenKind,
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
    HeadingRule { level: u8, line_range: Range<usize> },
    BlockquoteBar { nest_level: u8, line_range: Range<usize> },
    CodeFenceHeader {
        language: String,
        accent_rgba: (f32, f32, f32, f32),
        line_range: Range<usize>,
    },
    CodeFenceRow { is_end: bool, line_range: Range<usize> },
    InlineCodePill { span_range: Range<usize> },
    DisplayMathCard {
        latex: String,
        line_range: Range<usize>,
        is_active: bool,
        dim_factor: f32,
    },
    HorizontalRule { line_range: Range<usize> },
    TableRow {
        is_header: bool,
        is_separator: bool,
        columns: Vec<String>,
        line_range: Range<usize>,
    },
    ImageCard {
        alt: String,
        url: String,
        title: Option<String>,
        width: Option<u32>,
        height: Option<u32>,
        is_html: bool,
        is_active: bool,
        span_range: Range<usize>,
    },
    MermaidDiagramCard {
        source: String,
        svg: String,
        width: f32,
        height: f32,
        is_active: bool,
        line_range: Range<usize>,
    },
    SvgGraphicCard {
        svg: String,
        width: f32,
        height: f32,
        is_active: bool,
        line_range: Range<usize>,
    },
    HtmlInlineStyle {
        tag: HtmlInlineTagKind,
        content_range: Range<usize>,
        is_active: bool,
        span_range: Range<usize>,
    },
}

/// Computes Zed `FoldMap` fold ranges from Folio's active-line-aware syntax folding spans
/// and inline math / rich media block decorations.
pub fn compute_zed_folds(
    fold_spans: &[SyntaxFoldSpan],
    blocks: &[MarkdownBlockDecoration],
) -> Vec<ZedFoldRange> {
    let mut folds = Vec::new();
    for span in fold_spans {
        if span.is_revealed || span.kind == SyntaxTokenKind::InlineMathDollar {
            continue;
        }
        folds.push(ZedFoldRange {
            byte_range: span.byte_range.clone(),
            placeholder_text: String::new(),
            collapse_completely: true,
        });
    }
    for block in blocks {
        if let Kind::InlineMathRendered { latex, is_active: false, .. } = &block.kind {
            let summary = plain_text_summary(latex);
            folds.push(ZedFoldRange {
                byte_range: block.byte_range.clone(),
                placeholder_text: if summary.is_empty() { latex.clone() } else { summary },
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
    blocks
        .iter()
        .filter_map(|block| translate_single_block_decoration(block, is_dark))
        .collect()
}

fn translate_single_block_decoration(
    block: &MarkdownBlockDecoration,
    is_dark: bool,
) -> Option<ZedBlockDecoration> {
    use ZedBlockDecoration::*;
    let line_range = block.byte_range.clone();
    match &block.kind {
        Kind::HeadingUnderline { level } => {
            (*level <= 2).then_some(HeadingRule { level: *level as u8, line_range })
        }
        Kind::Blockquote { nest_level } => {
            Some(BlockquoteBar { nest_level: *nest_level as u8, line_range })
        }
        Kind::CodeFenceStart { language } => {
            let c = folio_engine::theme::language_accent_color(language, is_dark);
            Some(CodeFenceHeader {
                language: language.clone(),
                accent_rgba: (c.r as f32, c.g as f32, c.b as f32, c.a as f32),
                line_range,
            })
        }
        Kind::CodeFenceBody { .. } => Some(CodeFenceRow { is_end: false, line_range }),
        Kind::CodeFenceEnd => Some(CodeFenceRow { is_end: true, line_range }),
        Kind::InlineCode => Some(InlineCodePill { span_range: line_range }),
        Kind::MathBlockRendered { latex, is_active, dim_factor } => Some(DisplayMathCard {
            latex: latex.clone(),
            line_range,
            is_active: *is_active,
            dim_factor: *dim_factor as f32,
        }),
        Kind::InlineMathRendered { .. } => None,
        Kind::HorizontalRule => Some(HorizontalRule { line_range }),
        Kind::TableRow { is_header, is_separator, columns } => Some(TableRow {
            is_header: *is_header,
            is_separator: *is_separator,
            columns: columns.clone(),
            line_range,
        }),
        _ => translate_rich_media_decoration(&block.kind, line_range),
    }
}

fn translate_rich_media_decoration(
    kind: &Kind,
    range: Range<usize>,
) -> Option<ZedBlockDecoration> {
    use ZedBlockDecoration::*;
    match kind {
        Kind::Image { alt, url, title, width, height, is_html, is_active } => Some(ImageCard {
            alt: alt.clone(),
            url: url.clone(),
            title: title.clone(),
            width: *width,
            height: *height,
            is_html: *is_html,
            is_active: *is_active,
            span_range: range,
        }),
        Kind::MermaidBlock { source, svg, width, height, is_active } => Some(MermaidDiagramCard {
            source: source.clone(),
            svg: svg.clone(),
            width: *width,
            height: *height,
            is_active: *is_active,
            line_range: range,
        }),
        Kind::SvgBlock { svg, width, height, is_active } => Some(SvgGraphicCard {
            svg: svg.clone(),
            width: *width,
            height: *height,
            is_active: *is_active,
            line_range: range,
        }),
        Kind::HtmlInline { tag, content_range, is_active } => Some(HtmlInlineStyle {
            tag: *tag,
            content_range: content_range.clone(),
            is_active: *is_active,
            span_range: range,
        }),
        _ => None,
    }
}

/// Runs a full pass over a buffer snapshot and returns Zed folds and block decorations.
pub fn analyze_buffer_for_zed(
    text: &str,
    cursor_byte_range: Range<usize>,
    is_dark: bool,
) -> (Vec<ZedFoldRange>, Vec<ZedBlockDecoration>) {
    analyze_buffer_for_zed_with_options(text, cursor_byte_range, is_dark, true)
}

/// Runs a full pass over a buffer snapshot with explicit `pretty_mode` control.
pub fn analyze_buffer_for_zed_with_options(
    text: &str,
    cursor_byte_range: Range<usize>,
    is_dark: bool,
    pretty_mode: bool,
) -> (Vec<ZedFoldRange>, Vec<ZedBlockDecoration>) {
    let analysis = analyze_markdown_document_with_options(
        text,
        cursor_byte_range.start,
        false,
        false,
        pretty_mode,
        is_dark,
    );
    let folds = compute_zed_folds(&analysis.syntax_fold_spans, &analysis.block_decorations);
    let blocks = translate_block_decorations(&analysis.block_decorations, is_dark);
    (folds, blocks)
}
