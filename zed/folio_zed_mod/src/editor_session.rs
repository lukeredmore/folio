use crate::inlay_folding::{analyze_buffer_for_zed, ZedBlockDecoration, ZedFoldRange};
use crate::math_canvas::{build_gpui_math_canvas, GpuiMathCanvasDescriptor};
use crate::theme_sync::ZedThemeOverrides;
use folio_engine::markdown::{
    compute_newline_continuation, replace_code_fence_language, MarkdownBlockDecorationKind,
    NewlineAction, OutlineHeadingItem,
};
use folio_engine::stats::DocumentStats;
use std::ops::Range;

/// Snapshot of the Folio GPUI Mod's live WYSIWYG rendering state for a Zed Markdown buffer.
#[derive(Debug, Clone)]
pub struct FolioZedRenderFrame {
    pub folds: Vec<ZedFoldRange>,
    pub block_decorations: Vec<ZedBlockDecoration>,
    pub display_math_canvases: Vec<(Range<usize>, GpuiMathCanvasDescriptor)>,
    pub inline_math_canvases: Vec<(Range<usize>, GpuiMathCanvasDescriptor)>,
    pub outline: Vec<OutlineHeadingItem>,
    pub stats: DocumentStats,
    pub theme: ZedThemeOverrides,
}

/// Lightweight in-buffer WYSIWYG controller attached to a Zed `Editor` instance for `.md` / `.markdown` buffers.
/// Respects Zed's native dark/light appearance mode without overriding Zed's workspace tabs, sidebars, or theme system.
#[derive(Debug, Clone)]
pub struct FolioZedModSession {
    pub enabled: bool,
    pub is_dark: bool,
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
        }
    }

    /// Computes a complete `FolioZedRenderFrame` for Zed's `EditorElement::prepaint` and `paint`.
    pub fn evaluate_buffer(
        &self,
        buffer_text: &str,
        cursor_byte_range: Range<usize>,
    ) -> FolioZedRenderFrame {
        let theme = ZedThemeOverrides::for_appearance(self.is_dark);
        let sel_len = cursor_byte_range.end.saturating_sub(cursor_byte_range.start);
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
            };
        }

        let analysis = folio_engine::markdown::analyze_markdown_document(
            buffer_text,
            cursor_byte_range.start,
            false,
            false,
        );
        let (folds, block_decorations) =
            analyze_buffer_for_zed(buffer_text, cursor_byte_range, theme.is_dark);

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
        }
    }

    /// Intercepts `editor::actions::Newline` in Zed to provide smart list / task list continuation.
    pub fn on_editor_newline(&self, line_up_to_cursor: &str) -> NewlineAction {
        if !self.enabled {
            return NewlineAction::Default;
        }
        compute_newline_continuation(line_up_to_cursor)
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
