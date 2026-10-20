use editor::{Editor, EditorElement};
use gpui::WindowScene;
use markdown_preview::{MarkdownPreviewElement, MarkdownPreviewView};

#[test]
fn test_zed_editor_preserves_untouched_source_mode_by_default() {
    let md = "# Heading 1\nSome **bold** text and $x^2 + y^2 = r^2$ inline.\n\n$$\n\\frac{1}{2\\pi}\n$$\n";
    let mut ed = Editor::new(md);
    ed.set_selection(0..0);

    let mut scene = WindowScene::new();
    EditorElement::prepaint(&mut ed);
    EditorElement::paint(&ed, &mut scene);

    assert!(
        ed.display_map.folds.is_empty(),
        "Source mode Editor must never inject DisplayMap folds"
    );
    assert_eq!(
        ed.display_map.render_visible_text(&ed.buffer_text),
        md,
        "Source mode Editor must preserve 100% raw Markdown source by default"
    );
}

#[test]
fn test_editable_markdown_preview_canvas_reveals_active_line_and_paints_math() {
    let md = "# Heading 1\nSome **bold** text and $x^2 + y^2 = r^2$ inline.\n\n$$\n\\frac{1}{2\\pi}\n$$\n";
    let ed = Editor::new(md);
    let mut preview = MarkdownPreviewView::new(ed);

    // 1. When cursor is at byte 0 (on "# Heading 1"), Heading 1 syntax is revealed on the canvas,
    //    while line 2 "**bold**" and display math "$$...$$" are rendered/typeset.
    preview.set_selection(0..0);
    let mut scene = WindowScene::new();
    MarkdownPreviewElement::prepaint(&mut preview);
    MarkdownPreviewElement::paint(&preview, &mut scene);

    let visible_when_line1_active = preview.render_canvas_visible_text();
    assert!(
        visible_when_line1_active.starts_with("# Heading 1"),
        "Active line in preview canvas must reveal raw '# ' syntax, got: {:?}",
        visible_when_line1_active
    );
    assert!(
        !visible_when_line1_active.contains("**bold**"),
        "Inactive line in preview canvas must collapse '**' delimiters, got: {:?}",
        visible_when_line1_active
    );
    assert!(
        !scene.quads.is_empty() && !scene.glyph_runs.is_empty(),
        "Inactive display math block in preview canvas must paint GPUI quads and glyph runs"
    );

    // 2. When cursor moves to line 2, line 1's '# ' collapses and line 2 reveals '**bold**'.
    let line2_pos = md.find("Some").unwrap();
    preview.set_selection(line2_pos..line2_pos);
    let mut scene2 = WindowScene::new();
    MarkdownPreviewElement::prepaint(&mut preview);
    MarkdownPreviewElement::paint(&preview, &mut scene2);

    let visible_when_line2_active = preview.render_canvas_visible_text();
    assert!(
        visible_when_line2_active.starts_with("Heading 1"),
        "Inactive heading line in preview canvas must collapse '# ' prefix, got: {:?}",
        visible_when_line2_active
    );
    assert!(
        visible_when_line2_active.contains("**bold**"),
        "Active line in preview canvas must reveal '**bold**' syntax tokens, got: {:?}",
        visible_when_line2_active
    );
    // Underlying source editor remains untouched raw markdown
    assert_eq!(preview.active_editor.buffer_text, md);
}

#[test]
fn test_editable_markdown_preview_smart_list_newline_checkbox_and_fence_language() {
    let mut preview = MarkdownPreviewView::new(Editor::new("1. First item"));
    let end = preview.active_editor.buffer_text.len();
    preview.set_selection(end..end);
    preview.insert_newline();
    assert_eq!(preview.active_editor.buffer_text, "1. First item\n2. ");

    // Pressing Enter again on the empty "2. " marker clears the list prefix
    preview.insert_newline();
    assert_eq!(preview.active_editor.buffer_text, "1. First item\n");

    // Task checkbox toggling & code fence language switching on the preview canvas
    preview.apply_source_edit("- [ ] Task item\n```rust\nlet x = 1;\n```\n".to_string(), 0..0);
    assert!(preview.toggle_task_checkbox(2));
    assert!(preview.active_editor.buffer_text.starts_with("- [x] Task item\n"));

    let fence_offset = preview.active_editor.buffer_text.find("```rust").unwrap();
    assert!(preview.set_code_fence_language(fence_offset, "python"));
    assert!(preview.active_editor.buffer_text.contains("```python\nlet x = 1;\n```\n"));

    preview.set_appearance_mode(false);
    MarkdownPreviewElement::prepaint(&mut preview);
    assert!(!preview.last_folio_frame.as_ref().unwrap().theme.is_dark);

    preview.set_appearance_mode(true);
    MarkdownPreviewElement::prepaint(&mut preview);
    assert!(preview.last_folio_frame.as_ref().unwrap().theme.is_dark);
}

#[test]
fn test_folio_zed_extension_is_built_in_to_modded_zed_build() {
    let config_toml = MarkdownPreviewView::built_in_markdown_config_toml();
    let outline_scm = MarkdownPreviewView::built_in_markdown_outline_scm();
    assert!(
        config_toml.contains("start = \"$\", end = \"$\""),
        "Built-in Markdown config must include $ auto-closing bracket from folio_zed_extension"
    );
    assert!(
        outline_scm.contains("(section") && outline_scm.contains("(atx_heading") && outline_scm.contains("(setext_heading"),
        "Built-in Markdown outline.scm must include H1-H6 ATX and Setext heading queries"
    );

    let preview = MarkdownPreviewView::new(Editor::new("# Title\n\n## Section\n\n### Subsection\n"));
    let symbols = preview.extract_built_in_outline_symbols();
    assert_eq!(symbols.len(), 3);
    assert_eq!(symbols[0].text, "Title");
    assert_eq!(symbols[1].text, "Section");
    assert_eq!(symbols[2].text, "Subsection");
}

#[test]
fn test_zed_markdown_preview_rich_media_and_pretty_mode_toggle() {
    let md = concat!(
        "# Rich Media\n",
        "![Architecture](docs/arch.png)\n",
        "Press <kbd>Cmd+P</kbd> for <mark>Pretty</mark> mode.\n",
        "```mermaid\n",
        "flowchart LR\n",
        "    A[Source] --> B[Pretty]\n",
        "```\n",
        "<svg width=\"160\" height=\"80\"><rect width=\"160\" height=\"80\" fill=\"#4B6BFB\"/></svg>\n"
    );
    let mut preview = MarkdownPreviewView::new(Editor::new(md));
    preview.set_selection(0..0);

    let mut scene = WindowScene::new();
    MarkdownPreviewElement::prepaint(&mut preview);
    MarkdownPreviewElement::paint(&preview, &mut scene);

    assert!(preview.is_pretty_mode());
    let visible = preview.render_canvas_visible_text();
    // Inactive lines hide raw HTML tags and image syntax in pretty mode
    assert!(
        !visible.contains("<kbd>") && !visible.contains("</kbd>"),
        "Pretty mode should fold inactive HTML tags: {visible:?}"
    );
    assert!(
        !visible.contains("(docs/arch.png)"),
        "Pretty mode should fold inactive image URL syntax: {visible:?}"
    );
    assert!(
        !visible.contains("<svg") && !visible.contains("```mermaid"),
        "Pretty mode should fold inactive Mermaid fences and raw SVG tags: {visible:?}"
    );
    assert!(
        !scene.quads.is_empty() && !scene.glyph_runs.is_empty(),
        "Pretty mode should paint quads and labels for inactive images, Mermaid diagrams, and SVGs"
    );

    // Toggling pretty mode off reveals raw image syntax, HTML tags, Mermaid source, and SVG markup
    assert!(!preview.toggle_pretty_mode());
    assert!(!preview.is_pretty_mode());
    let raw_visible = preview.render_canvas_visible_text();
    assert!(raw_visible.contains("![Architecture](docs/arch.png)"));
    assert!(raw_visible.contains("<kbd>Cmd+P</kbd>"));
    assert!(raw_visible.contains("<mark>Pretty</mark>"));
    assert!(raw_visible.contains("flowchart LR\n    A[Source] --> B[Pretty]"));
    assert!(raw_visible.contains("<svg width=\"160\" height=\"80\">"));
}

