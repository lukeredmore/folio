#![deny(warnings)]

pub mod canvas_builder;
pub mod editor_session;
pub mod extension_bridge;
pub mod extension_types;
pub mod inlay_folding;
pub mod keystroke_controller;
mod keystroke_helpers;
pub mod markdown_formatting;
pub mod math_canvas;
pub mod outline;
pub mod preview_bridge;
pub mod text_navigation;
pub mod theme_sync;

pub use canvas_builder::{
    append_task_checkbox_folds, block_decoration_to_canvas, math_descriptor_to_canvas,
};
pub use editor_session::{FolioZedModSession, FolioZedRenderFrame};
pub use extension_bridge::FolioZedExtension;
pub use extension_types::{
    byte_offset_to_row, pack_engine_rgba, pack_rgba, BlockDecoration, CanvasElement,
    CanvasGlyphRun, CanvasQuad, CanvasTextReplacement, EditorDecorations, EditorHighlights,
    InlineFoldDecoration, Range, RowHighlight, TextHighlight,
};
pub use folio_engine;
pub use folio_engine::markdown::{HtmlInlineTagKind, NewlineAction, OutlineHeadingItem};
pub use folio_engine::stats::DocumentStats;
pub use inlay_folding::{
    analyze_buffer_for_zed, analyze_buffer_for_zed_with_options, compute_zed_folds,
    translate_block_decorations, ZedBlockDecoration, ZedFoldRange,
};
pub use keystroke_controller::{
    evaluate_markdown_keystroke, KeystrokeDecision, KeystrokeInput,
};
pub use markdown_formatting::{
    cycle_code_block_language, toggle_heading_level, toggle_inline_delimiter,
};
pub use math_canvas::{
    build_gpui_math_canvas, GpuiMathCanvasDescriptor, GpuiMathPrimitive,
};
pub use outline::{
    ensure_builtin_extension_installed, extract_zed_outline_symbols, ZedOutlineSymbol,
    EXTENSION_ID, EXTENSION_TOML, LANGUAGE_CONFIG_TOML, OUTLINE_SCM,
};
pub use preview_bridge::{
    dispatch_preview_command, encode_keystroke_decision, encode_math_canvas,
};
pub use text_navigation::{
    extract_html_attr, next_word_boundary, percent_decode_str, prev_word_boundary,
    snap_char_boundary_left, snap_char_boundary_right, surrounding_code_span_delimiters,
    word_range_at,
};
pub use theme_sync::{ZedAppearanceMode, ZedThemeOverrides};
