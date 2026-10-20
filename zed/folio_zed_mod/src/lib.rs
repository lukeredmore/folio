pub mod editor_session;
pub mod inlay_folding;
pub mod math_canvas;
pub mod theme_sync;

pub use editor_session::{FolioZedModSession, FolioZedRenderFrame};
pub use folio_engine;
pub use folio_engine::markdown::{HtmlInlineTagKind, NewlineAction};
pub use inlay_folding::{
    analyze_buffer_for_zed, analyze_buffer_for_zed_with_options, compute_zed_folds,
    translate_block_decorations, ZedBlockDecoration, ZedFoldRange,
};
pub use math_canvas::{build_gpui_math_canvas, GpuiMathCanvasDescriptor, GpuiMathPrimitive};
pub use theme_sync::{ZedAppearanceMode, ZedThemeOverrides};
