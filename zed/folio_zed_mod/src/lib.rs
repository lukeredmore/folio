#![deny(warnings)]

pub mod editor_session;
pub mod ffi;
pub mod ffi_controller;
pub mod inlay_folding;
pub mod keystroke_controller;
mod keystroke_helpers;
pub mod markdown_formatting;
pub mod math_canvas;
pub mod text_navigation;
pub mod theme_sync;

pub use editor_session::{FolioZedModSession, FolioZedRenderFrame};
pub use folio_engine;
pub use folio_engine::markdown::{HtmlInlineTagKind, NewlineAction};
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
pub use math_canvas::{build_gpui_math_canvas, GpuiMathCanvasDescriptor, GpuiMathPrimitive};
pub use text_navigation::{
    extract_html_attr, next_word_boundary, percent_decode_str, prev_word_boundary,
    snap_char_boundary_left, snap_char_boundary_right, surrounding_code_span_delimiters,
    word_range_at,
};
pub use theme_sync::{ZedAppearanceMode, ZedThemeOverrides};
