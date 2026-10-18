use editor::{Editor, EditorElement};
use gpui::WindowScene;

#[test]
fn test_patched_zed_editor_folds_markdown_and_paints_math_canvases() {
    let md = "# Heading 1\nSome **bold** text and $x^2 + y^2 = r^2$ inline.\n\n$$\n\\frac{1}{2\\pi}\n$$\n";
    let mut ed = Editor::new(md);

    // 1. When cursor is at byte 0 (on "# Heading 1"), Heading 1 syntax is NOT folded,
    //    while line 2 "**bold**" and display math "$$...$$" ARE folded/rendered.
    ed.set_selection(0..0);
    let mut scene = WindowScene::new();
    EditorElement::prepaint(&mut ed);
    EditorElement::paint(&ed, &mut scene);

    let visible_when_line1_active = ed.display_map.render_visible_text(&ed.buffer_text);
    assert!(
        visible_when_line1_active.starts_with("# Heading 1"),
        "Active line must keep raw '# ' syntax visible, got: {:?}",
        visible_when_line1_active
    );
    assert!(
        !visible_when_line1_active.contains("**bold**"),
        "Inactive line must collapse '**' delimiters, got: {:?}",
        visible_when_line1_active
    );
    assert!(
        !scene.quads.is_empty() && !scene.glyph_runs.is_empty(),
        "Inactive display math block must paint GPUI quads and glyph runs into Zed WindowScene"
    );

    // 2. When cursor moves to line 2, line 1's '# ' collapses!
    let line2_pos = md.find("Some").unwrap();
    ed.set_selection(line2_pos..line2_pos);
    let mut scene2 = WindowScene::new();
    EditorElement::prepaint(&mut ed);
    EditorElement::paint(&ed, &mut scene2);

    let visible_when_line2_active = ed.display_map.render_visible_text(&ed.buffer_text);
    assert!(
        visible_when_line2_active.starts_with("Heading 1"),
        "Inactive heading line must collapse '# ' prefix, got: {:?}",
        visible_when_line2_active
    );
    assert!(
        visible_when_line2_active.contains("**bold**"),
        "Active line must reveal '**bold**' syntax tokens, got: {:?}",
        visible_when_line2_active
    );
}

#[test]
fn test_patched_zed_editor_smart_list_newline_continuation() {
    let mut ed = Editor::new("1. First item");
    let end = ed.buffer_text.len();
    ed.set_selection(end..end);
    ed.insert_newline();
    assert_eq!(ed.buffer_text, "1. First item\n2. ");

    // Pressing Enter again on the empty "2. " marker clears the list prefix
    ed.insert_newline();
    assert_eq!(ed.buffer_text, "1. First item\n");
}

#[test]
fn test_patched_zed_editor_respects_zed_appearance_and_code_fence_language() {
    let md = "```rust\nlet x = 1;\n```\n";
    let mut ed = Editor::new(md);

    ed.set_appearance_mode(false);
    EditorElement::prepaint(&mut ed);
    assert!(!ed.last_opentype_frame.as_ref().unwrap().theme.is_dark);

    ed.set_appearance_mode(true);
    EditorElement::prepaint(&mut ed);
    assert!(ed.last_opentype_frame.as_ref().unwrap().theme.is_dark);

    assert!(ed.set_code_fence_language(0, "python"));
    assert_eq!(ed.buffer_text, "```python\nlet x = 1;\n```\n");
}

