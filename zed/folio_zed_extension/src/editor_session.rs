use crate::inlay_folding::{analyze_buffer_for_zed_with_options, ZedBlockDecoration, ZedFoldRange};
use crate::math_canvas::{build_gpui_math_canvas, GpuiMathCanvasDescriptor};
use crate::theme_sync::ZedThemeOverrides;
use folio_engine::markdown::{
    analyze_markdown_document_with_options, compute_newline_continuation,
    replace_code_fence_language, MarkdownBlockDecorationKind, NewlineAction, OutlineHeadingItem,
};
use folio_engine::stats::DocumentStats;
use std::ops::Range;

/// Snapshot of the Folio Extension's live WYSIWYG rendering state for a Zed Markdown buffer.
#[derive(Debug, Clone)]
pub struct FolioZedRenderFrame {
    pub folds: Vec<ZedFoldRange>,
    pub block_decorations: Vec<ZedBlockDecoration>,
    pub display_math_canvases: Vec<(Range<usize>, GpuiMathCanvasDescriptor)>,
    pub inline_math_canvases: Vec<(Range<usize>, GpuiMathCanvasDescriptor)>,
    pub outline: Vec<OutlineHeadingItem>,
    pub stats: DocumentStats,
    pub theme: ZedThemeOverrides,
    pub pretty_mode: bool,
}

/// Lightweight in-buffer WYSIWYG controller for `.md` / `.markdown` buffers in Zed.
/// Respects Zed's native dark/light appearance mode without overriding Zed's workspace tabs, sidebars, or theme system.
#[derive(Debug, Clone)]
pub struct FolioZedModSession {
    pub enabled: bool,
    pub is_dark: bool,
    pub pretty_mode: bool,
}

impl Default for FolioZedModSession {
    fn default() -> Self {
        Self::new(true)
    }
}

impl FolioZedModSession {
    pub fn new(is_dark: bool) -> Self {
        Self {
            enabled: true,
            is_dark,
            pretty_mode: true,
        }
    }

    pub fn set_pretty_mode(&mut self, pretty_mode: bool) {
        self.pretty_mode = pretty_mode;
    }

    pub fn toggle_pretty_mode(&mut self) -> bool {
        self.pretty_mode = !self.pretty_mode;
        self.pretty_mode
    }

    /// Computes a complete `FolioZedRenderFrame` for Zed's editor highlights and decorations API.
    pub fn evaluate_buffer(
        &self,
        buffer_text: &str,
        cursor_byte_range: Range<usize>,
    ) -> FolioZedRenderFrame {
        let theme = ZedThemeOverrides::for_appearance(self.is_dark);
        let sel_len = cursor_byte_range
            .end
            .saturating_sub(cursor_byte_range.start);
        let stats = DocumentStats::compute(buffer_text, Some((cursor_byte_range.start, sel_len)));

        if !self.enabled {
            let raw_analysis = folio_engine::markdown::analyze_markdown_document(
                buffer_text,
                cursor_byte_range.start,
                true,
                false,
            );
            return FolioZedRenderFrame {
                folds: Vec::new(),
                block_decorations: Vec::new(),
                display_math_canvases: Vec::new(),
                inline_math_canvases: Vec::new(),
                outline: raw_analysis.headings,
                stats,
                theme,
                pretty_mode: self.pretty_mode,
            };
        }

        let analysis = analyze_markdown_document_with_options(
            buffer_text,
            cursor_byte_range.start,
            false,
            false,
            self.pretty_mode,
            theme.is_dark,
        );
        let (folds, block_decorations) = analyze_buffer_for_zed_with_options(
            buffer_text,
            cursor_byte_range,
            theme.is_dark,
            self.pretty_mode,
        );

        let mut display_math_canvases = Vec::new();
        for dec in &block_decorations {
            if let ZedBlockDecoration::DisplayMathCard {
                latex,
                line_range,
                is_active: false,
                ..
            } = dec
            {
                if !latex.is_empty() {
                    let canvas = build_gpui_math_canvas(latex, theme.base_font_size, true);
                    display_math_canvases.push((line_range.clone(), canvas));
                }
            }
        }

        let mut inline_math_canvases = Vec::new();
        for block in &analysis.block_decorations {
            if let MarkdownBlockDecorationKind::InlineMathRendered {
                latex,
                is_active: false,
                ..
            } = &block.kind
            {
                if !latex.is_empty() {
                    let canvas = build_gpui_math_canvas(latex, theme.base_font_size, false);
                    inline_math_canvases.push((block.byte_range.clone(), canvas));
                }
            }
        }

        FolioZedRenderFrame {
            folds,
            block_decorations,
            display_math_canvases,
            inline_math_canvases,
            outline: analysis.headings,
            stats,
            theme,
            pretty_mode: self.pretty_mode,
        }
    }

    /// Intercepts `editor::actions::Newline` in Zed to provide smart list / task list continuation.
    pub fn on_editor_newline(&self, line_up_to_cursor: &str) -> NewlineAction {
        if !self.enabled {
            return NewlineAction::Default;
        }
        compute_newline_continuation(line_up_to_cursor)
    }

    /// Applies smart newline continuation at `cursor_byte` on `buffer_text`.
    pub fn apply_newline(&self, buffer_text: &str, cursor_byte: usize) -> (String, usize) {
        if !self.enabled {
            let clamped = cursor_byte.min(buffer_text.len());
            let mut out = String::with_capacity(buffer_text.len() + 1);
            out.push_str(&buffer_text[..clamped]);
            out.push('\n');
            out.push_str(&buffer_text[clamped..]);
            return (out, clamped + 1);
        }
        folio_engine::markdown::apply_newline_at_cursor(buffer_text, cursor_byte)
    }

    /// Toggles a symmetric Markdown delimiter (`**`, `*`, `` ` ``, etc.) at `cursor_byte`.
    pub fn toggle_symmetric_delimiter(
        &self,
        buffer_text: &str,
        cursor_byte: usize,
        delimiter: &str,
    ) -> (String, usize) {
        folio_engine::markdown::toggle_symmetric_delimiter(buffer_text, cursor_byte, delimiter)
    }

    /// Sets the ATX heading level (`0..=6`) on the line containing `cursor_byte`.
    pub fn set_heading_level(
        &self,
        buffer_text: &str,
        cursor_byte: usize,
        level: u8,
    ) -> (String, usize) {
        folio_engine::markdown::set_heading_level_at_cursor(buffer_text, cursor_byte, level)
    }

    /// Toggles a task checkbox on the line containing `cursor_byte`.
    pub fn toggle_task_checkbox_at_cursor(
        &self,
        buffer_text: &str,
        cursor_byte: usize,
    ) -> (String, usize) {
        folio_engine::markdown::toggle_task_checkbox_at_cursor(buffer_text, cursor_byte)
    }

    /// Toggles a Markdown task checkbox `- [ ]` <-> `- [x]` at the given byte offset in the buffer.
    pub fn toggle_task_checkbox(buffer_text: &str, checkbox_byte_offset: usize) -> Option<String> {
        if checkbox_byte_offset + 3 > buffer_text.len() {
            return None;
        }
        let slice = &buffer_text[checkbox_byte_offset..checkbox_byte_offset + 3];
        let replacement = match slice {
            "[ ]" => "[x]",
            "[x]" | "[X]" => "[ ]",
            _ => return None,
        };
        let mut updated = String::with_capacity(buffer_text.len());
        updated.push_str(&buffer_text[..checkbox_byte_offset]);
        updated.push_str(replacement);
        updated.push_str(&buffer_text[checkbox_byte_offset + 3..]);
        Some(updated)
    }

    /// Replaces the language identifier on a fenced code block opening line (` ```lang `)
    /// when selected from the top-right language dropdown on a code fence card.
    pub fn set_code_fence_language(
        buffer_text: &str,
        fence_start_byte_offset: usize,
        new_language: &str,
    ) -> Option<String> {
        replace_code_fence_language(buffer_text, fence_start_byte_offset, new_language)
    }
}
