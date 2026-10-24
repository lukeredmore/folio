use folio_zed_extension::{FolioZedModSession, NewlineAction, ZedBlockDecoration};

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
        frame_line1
            .folds
            .iter()
            .any(|f| !f.placeholder_text.is_empty()),
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
    let updated_code = FolioZedModSession::set_code_fence_language(code_doc, 0, "rust").unwrap();
    assert_eq!(updated_code, "```rust\nprint(1)\n```\n");
}

#[test]
fn test_zed_mod_images_mermaid_svg_html_and_pretty_mode_toggle() {
    let mut session = FolioZedModSession::new(false);
    let doc = "# Heading\n\
        ![Chart](https://example.com/chart.png)\n\
        Press <kbd>Cmd+K</kbd> now.\n\
        ```mermaid\n\
        flowchart TD\n\
            A[Start] --> B[End]\n\
        ```\n\
        <svg viewBox=\"0 0 120 60\"><rect width=\"120\" height=\"60\"/></svg>\n";

    let pretty_frame = session.evaluate_buffer(doc, 0..0);
    assert!(pretty_frame.pretty_mode);
    assert!(pretty_frame
        .block_decorations
        .iter()
        .any(|d| matches!(d, ZedBlockDecoration::ImageCard { .. })));
    assert!(pretty_frame
        .block_decorations
        .iter()
        .any(|d| matches!(d, ZedBlockDecoration::MermaidDiagramCard { .. })));
    assert!(pretty_frame
        .block_decorations
        .iter()
        .any(|d| matches!(d, ZedBlockDecoration::SvgGraphicCard { .. })));
    assert!(pretty_frame
        .block_decorations
        .iter()
        .any(|d| matches!(d, ZedBlockDecoration::HtmlInlineStyle { .. })));
    assert!(!pretty_frame.folds.is_empty());

    assert!(!session.toggle_pretty_mode());
    let raw_frame = session.evaluate_buffer(doc, 0..0);
    assert!(!raw_frame.pretty_mode);
    assert!(
        raw_frame.folds.is_empty(),
        "Disabling pretty_mode must unfold all markdown/HTML syntax for raw editing"
    );
}
