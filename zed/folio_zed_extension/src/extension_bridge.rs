use crate::canvas_builder::{
    append_task_checkbox_folds, block_decoration_to_canvas, math_descriptor_to_canvas,
};
use crate::editor_session::{FolioZedModSession, FolioZedRenderFrame};
use crate::extension_types::{
    byte_offset_to_row, pack_engine_rgba, pack_rgba, BlockDecoration, EditorDecorations,
    EditorHighlights, InlineFoldDecoration, RowHighlight, TextHighlight,
};
use crate::inlay_folding::ZedBlockDecoration;
use folio_engine::markdown::HtmlInlineTagKind;

/// Zed `v0.8.0` Extension bridge for Folio's WYSIWYG Markdown engine.
#[derive(Debug, Clone, Default)]
pub struct FolioZedExtension {
    pub session: FolioZedModSession,
}

impl FolioZedExtension {
    pub fn new() -> Self {
        Self {
            session: FolioZedModSession::new(true),
        }
    }

    pub fn with_appearance(is_dark: bool) -> Self {
        Self {
            session: FolioZedModSession::new(is_dark),
        }
    }

    pub fn is_markdown_language(language_name: &str) -> bool {
        matches!(
            language_name.trim().to_ascii_lowercase().as_str(),
            "markdown" | "markdown-inline" | "md" | "mdx"
        )
    }

    /// Implements Zed's `Extension::editor_highlights_for_buffer` (`v0.8.0`).
    pub fn editor_highlights_for_buffer(
        &mut self,
        language_name: String,
        text: String,
        cursor_offset: u32,
    ) -> Result<EditorHighlights, String> {
        if !Self::is_markdown_language(&language_name) {
            return Ok(EditorHighlights::default());
        }
        let pos = (cursor_offset as usize).min(text.len());
        let frame = self.session.evaluate_buffer(&text, pos..pos);
        Ok(build_editor_highlights(&text, &frame))
    }

    /// Implements Zed's `Extension::editor_decorations_for_buffer` (`v0.8.0`).
    pub fn editor_decorations_for_buffer(
        &mut self,
        language_name: String,
        text: String,
        cursor_offset: u32,
    ) -> Result<EditorDecorations, String> {
        if !Self::is_markdown_language(&language_name) {
            return Ok(EditorDecorations::default());
        }
        let pos = (cursor_offset as usize).min(text.len());
        let frame = self.session.evaluate_buffer(&text, pos..pos);
        Ok(build_editor_decorations(&text, pos, &frame))
    }
}

fn build_editor_highlights(text: &str, frame: &FolioZedRenderFrame) -> EditorHighlights {
    let mut text_highlights = Vec::new();
    let mut row_highlights = Vec::new();
    let code_bg = pack_engine_rgba(frame.theme.code_background);
    let inline_code_fg = pack_engine_rgba(frame.theme.inline_code_color);
    let quote_bg = pack_rgba(
        0.35,
        0.55,
        0.95,
        if frame.theme.is_dark { 0.08 } else { 0.06 },
    );

    for dec in &frame.block_decorations {
        match dec {
            ZedBlockDecoration::InlineCodePill { span_range } => {
                text_highlights.push(TextHighlight {
                    range: span_range.clone().into(),
                    color: Some(inline_code_fg),
                    background_color: Some(code_bg),
                    ..Default::default()
                });
            }
            ZedBlockDecoration::HtmlInlineStyle {
                tag, content_range, ..
            } => {
                text_highlights.push(TextHighlight {
                    range: content_range.clone().into(),
                    background_color: matches!(
                        tag,
                        HtmlInlineTagKind::Mark | HtmlInlineTagKind::Kbd
                    )
                    .then_some(code_bg),
                    underline: matches!(tag, HtmlInlineTagKind::Underline),
                    strikethrough: matches!(tag, HtmlInlineTagKind::Strikethrough),
                    ..Default::default()
                });
            }
            ZedBlockDecoration::CodeFenceHeader { line_range, .. }
            | ZedBlockDecoration::CodeFenceRow { line_range, .. } => {
                let row = byte_offset_to_row(text, line_range.start);
                row_highlights.push(RowHighlight {
                    start_row: row,
                    end_row: row,
                    color: code_bg,
                    should_autoscroll: false,
                });
            }
            ZedBlockDecoration::BlockquoteBar { line_range, .. } => {
                let row = byte_offset_to_row(text, line_range.start);
                row_highlights.push(RowHighlight {
                    start_row: row,
                    end_row: row,
                    color: quote_bg,
                    should_autoscroll: false,
                });
            }
            ZedBlockDecoration::TableRow {
                is_header: true,
                line_range,
                ..
            } => {
                let row = byte_offset_to_row(text, line_range.start);
                row_highlights.push(RowHighlight {
                    start_row: row,
                    end_row: row,
                    color: code_bg,
                    should_autoscroll: false,
                });
            }
            _ => {}
        }
    }
    EditorHighlights {
        text_highlights,
        row_highlights,
    }
}

fn build_editor_decorations(
    text: &str,
    cursor_byte: usize,
    frame: &FolioZedRenderFrame,
) -> EditorDecorations {
    let fg = pack_engine_rgba(frame.theme.text_color);
    let muted = pack_engine_rgba(frame.theme.secondary_text_color);
    let accent = pack_engine_rgba(frame.theme.link_color);
    let card_bg = pack_engine_rgba(frame.theme.code_background);

    let mut inline_folds: Vec<InlineFoldDecoration> = frame
        .folds
        .iter()
        .map(|fold| {
            let render_canvas = frame
                .inline_math_canvases
                .iter()
                .find(|(range, _)| *range == fold.byte_range)
                .map(|(_, desc)| math_descriptor_to_canvas(desc, fg, None));
            InlineFoldDecoration {
                range: fold.byte_range.clone().into(),
                placeholder_text: fold.placeholder_text.clone(),
                render_canvas,
            }
        })
        .collect();

    if frame.pretty_mode {
        append_task_checkbox_folds(text, cursor_byte, accent, muted, &mut inline_folds);
    }
    inline_folds.sort_by_key(|f| f.range.start);

    let mut blocks = Vec::new();
    for (range, desc) in &frame.display_math_canvases {
        blocks.push(BlockDecoration {
            anchor_offset: range.start as u32,
            above: false,
            height_rows: ((desc.total_height() / 22.0).ceil() as u8).clamp(2, 8),
            content: math_descriptor_to_canvas(desc, fg, Some((card_bg, muted))),
        });
    }
    for dec in &frame.block_decorations {
        if let Some(block) = block_decoration_to_canvas(dec, muted, card_bg, fg) {
            blocks.push(block);
        }
    }
    EditorDecorations {
        inline_folds,
        blocks,
    }
}
