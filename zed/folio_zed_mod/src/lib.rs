pub mod editor_session;
pub mod inlay_folding;
pub mod math_canvas;
pub mod theme_sync;

pub use editor_session::{FolioZedModSession, FolioZedRenderFrame};
pub use inlay_folding::{
    analyze_buffer_for_zed, compute_zed_folds, translate_block_decorations, ZedBlockDecoration,
    ZedFoldRange,
};
pub use math_canvas::{build_gpui_math_canvas, GpuiMathPrimitive, GpuiMathCanvasDescriptor};
pub use theme_sync::{ZedAppearanceMode, ZedThemeOverrides};

#[cfg(test)]
mod tests {
    use super::*;
    use folio_engine::markdown::NewlineAction;

    #[test]
    fn test_zed_mod_folds_inactive_lines_and_unfolds_active_line() {
        let session = FolioZedModSession::new(true);
        let doc = "# Heading One\nParagraph with **bold**, `code`, and $\\frac{a}{b}$ math.\n\n$$\n\\int_0^1 x^2 dx\n$$\n";

        // Cursor on line 1 ("# Heading One"): line 1 is active (not folded), line 2 and math block are folded
        let frame_line1 = session.evaluate_buffer(doc, 0..0);
        assert!(frame_line1.theme.is_dark);
        assert_eq!(frame_line1.outline.len(), 1);
        assert!(
            frame_line1.folds.iter().all(|f| f.byte_range.start >= 14),
            "Active line 1 must not have its '#' delimiter folded"
        );
        assert!(
            frame_line1.folds.iter().any(|f| !f.placeholder_text.is_empty()),
            "Inactive line 2 inline math should have a fallback fold replacement"
        );
        assert!(
            frame_line1
                .block_decorations
                .iter()
                .any(|d| matches!(d, ZedBlockDecoration::InlineCodePill { .. })),
            "Inline code span must produce an InlineCodePill decoration"
        );
        assert_eq!(
            frame_line1.display_math_canvases.len(),
            1,
            "Inactive display math block should produce a GPUI math canvas"
        );

        // Move cursor inside the display math block: math block becomes active and editable
        let math_pos = doc.find("\\int").unwrap();
        let frame_math_active = session.evaluate_buffer(doc, math_pos..math_pos);
        assert_eq!(
            frame_math_active.display_math_canvases.len(),
            0,
            "Active display math block should reveal raw LaTeX source instead of canvas overlay"
        );
    }

    #[test]
    fn test_zed_mod_checkbox_toggle_smart_newline_and_fence_language() {
        let session = FolioZedModSession::new(false);
        assert!(!session.evaluate_buffer("# Light Mode", 0..0).theme.is_dark);
        assert_eq!(
            session.on_editor_newline("- [x] Ship Bazel monorepo"),
            NewlineAction::InsertPrefix("- [ ] ".to_string())
        );

        let text = "- [ ] First item\n";
        let toggled = FolioZedModSession::toggle_task_checkbox(text, 2).unwrap();
        assert_eq!(toggled, "- [x] First item\n");

        let code_doc = "```python\nprint(1)\n```\n";
        let updated_code =
            FolioZedModSession::set_code_fence_language(code_doc, 0, "rust").unwrap();
        assert_eq!(updated_code, "```rust\nprint(1)\n```\n");
    }
}
