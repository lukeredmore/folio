use crate::canvas_builder::{
    append_task_checkbox_folds, block_decoration_to_canvas, math_descriptor_to_canvas,
};
use crate::editor_session::{FolioZedModSession, FolioZedRenderFrame};
use crate::extension_types::{
    pack_engine_rgba, pack_rgba, BlockDecoration, EditorDecorations, EditorHighlights,
    InlineFoldDecoration, RowHighlight, TextHighlight,
};
use crate::inlay_folding::ZedBlockDecoration;
use crate::text_navigation::snap_char_boundary_left;
use folio_engine::markdown::HtmlInlineTagKind;

#[derive(Debug, Clone)]
struct CachedRenderFrame {
    text: String,
    selection: std::ops::Range<usize>,
    enabled: bool,
    is_dark: bool,
    pretty_mode: bool,
    frame: FolioZedRenderFrame,
}

/// Zed `v0.8.0` Extension bridge for Folio's WYSIWYG Markdown engine.
#[derive(Debug, Clone, Default)]
pub struct FolioZedExtension {
    pub session: FolioZedModSession,
    cached_frame: Option<CachedRenderFrame>,
    evaluation_count: usize,
}

impl FolioZedExtension {
    pub fn new() -> Self {
        Self {
            session: FolioZedModSession::new(true),
            cached_frame: None,
            evaluation_count: 0,
        }
    }

    pub fn with_appearance(is_dark: bool) -> Self {
        Self {
            session: FolioZedModSession::new(is_dark),
            cached_frame: None,
            evaluation_count: 0,
        }
    }

    /// Number of full buffer evaluations performed (excluding back-to-back cache hits).
    pub fn evaluation_count(&self) -> usize {
        self.evaluation_count
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
        let pos = snap_char_boundary_left(&text, (cursor_offset as usize).min(text.len()));
        let cached = self.frame_for_buffer(text, pos..pos)?;
        Ok(build_editor_highlights(&cached.text, &cached.frame))
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
        let pos = snap_char_boundary_left(&text, (cursor_offset as usize).min(text.len()));
        let cached = self.frame_for_buffer(text, pos..pos)?;
        Ok(build_editor_decorations(&cached.text, pos, &cached.frame))
    }

    fn frame_for_buffer(
        &mut self,
        text: String,
        selection: std::ops::Range<usize>,
    ) -> Result<&CachedRenderFrame, String> {
        let needs_eval = self.cached_frame.as_ref().is_none_or(|cached| {
            cached.selection != selection
                || cached.enabled != self.session.enabled
                || cached.is_dark != self.session.is_dark
                || cached.pretty_mode != self.session.pretty_mode
                || cached.text != text
        });
        if needs_eval {
            let frame = self.session.evaluate_buffer(&text, selection.clone());
            self.evaluation_count = self.evaluation_count.wrapping_add(1);
            self.cached_frame = Some(CachedRenderFrame {
                text,
                selection,
                enabled: self.session.enabled,
                is_dark: self.session.is_dark,
                pretty_mode: self.session.pretty_mode,
                frame,
            });
        }
        self.cached_frame
            .as_ref()
            .ok_or_else(|| "missing cached render frame".to_string())
    }
}

fn compute_line_starts(text: &str) -> Vec<usize> {
    let mut starts = vec![0];
    for (idx, &byte) in text.as_bytes().iter().enumerate() {
        if byte == b'\n' {
            starts.push(idx + 1);
        }
    }
    starts
}

fn row_for_byte_offset(line_starts: &[usize], text_len: usize, byte_offset: usize) -> u32 {
    let clamped = byte_offset.min(text_len);
    line_starts
        .partition_point(|&start| start <= clamped)
        .saturating_sub(1) as u32
}

fn build_editor_highlights(text: &str, frame: &FolioZedRenderFrame) -> EditorHighlights {
    let mut text_highlights = Vec::new();
    let mut row_highlights = Vec::new();
    let line_starts = compute_line_starts(text);
    let text_len = text.len();
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
                let row = row_for_byte_offset(&line_starts, text_len, line_range.start);
                row_highlights.push(RowHighlight {
                    start_row: row,
                    end_row: row,
                    color: code_bg,
                    should_autoscroll: false,
                });
            }
            ZedBlockDecoration::BlockquoteBar { line_range, .. } => {
                let row = row_for_byte_offset(&line_starts, text_len, line_range.start);
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
                let row = row_for_byte_offset(&line_starts, text_len, line_range.start);
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
