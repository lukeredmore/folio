use std::fs;
use std::time::{SystemTime, UNIX_EPOCH};

use folio_zed_extension::{
    ensure_builtin_extension_installed, extract_zed_outline_symbols, FolioZedExtension,
    EXTENSION_ID, EXTENSION_TOML, LANGUAGE_CONFIG_TOML, OUTLINE_SCM,
};

#[test]
fn test_zed_extension_manifest_and_outline_queries_are_valid() {
    assert!(EXTENSION_TOML.contains("id = \"folio-markdown-outline\""));
    assert!(LANGUAGE_CONFIG_TOML.contains("grammar = \"markdown\""));
    assert!(OUTLINE_SCM.contains("(atx_heading"));
    assert!(OUTLINE_SCM.contains("@item"));
    assert!(OUTLINE_SCM.contains("@name"));
    assert!(OUTLINE_SCM.contains("@context"));
}

#[test]
fn test_ensure_builtin_extension_installed_is_idempotent() {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let temp_dir = std::env::temp_dir().join(format!("folio_zed_ext_test_{nanos}"));
    let installed_dir = temp_dir.join("installed");

    let first_install = ensure_builtin_extension_installed(&installed_dir)
        .expect("initial built-in extension install should succeed");
    assert!(first_install);

    let ext_dir = installed_dir.join(EXTENSION_ID);
    assert_eq!(
        fs::read_to_string(ext_dir.join("extension.toml")).unwrap(),
        EXTENSION_TOML
    );
    assert_eq!(
        fs::read_to_string(ext_dir.join("languages/markdown/config.toml")).unwrap(),
        LANGUAGE_CONFIG_TOML
    );
    assert_eq!(
        fs::read_to_string(ext_dir.join("languages/markdown/outline.scm")).unwrap(),
        OUTLINE_SCM
    );

    let second_install = ensure_builtin_extension_installed(&installed_dir)
        .expect("idempotent built-in extension check should succeed");
    assert!(!second_install);

    let _ = fs::remove_dir_all(&temp_dir);
}

#[test]
fn test_extract_zed_outline_symbols() {
    let doc = "# Top Title\n\n## Section A\n\n### Subsection A.1\n";
    let symbols = extract_zed_outline_symbols(doc);
    assert_eq!(symbols.len(), 3);
    assert_eq!(symbols[0].depth, 1);
    assert_eq!(symbols[0].context_marker, "#");
    assert_eq!(symbols[0].text, "Top Title");
    assert_eq!(symbols[1].depth, 2);
    assert_eq!(symbols[1].context_marker, "##");
    assert_eq!(symbols[1].text, "Section A");
    assert_eq!(symbols[2].depth, 3);
    assert_eq!(symbols[2].text, "Subsection A.1");
}

#[test]
fn test_editor_highlights_and_decorations_for_markdown_buffer() {
    let mut ext = FolioZedExtension::new();
    let doc = "# Title\n\
        Paragraph with `inline_code`, <mark>highlighted</mark>, and $\\frac{x}{y}$ math.\n\
        - [ ] Ship Zed extension\n\
        ```rust\n\
        fn main() {}\n\
        ```\n\
        $$\n\
        \\sum_{i=1}^n i\n\
        $$\n";

    let non_md_highlights = ext
        .editor_highlights_for_buffer("Rust".into(), doc.into(), 0)
        .unwrap();
    assert!(non_md_highlights.text_highlights.is_empty());
    assert!(non_md_highlights.row_highlights.is_empty());

    let highlights = ext
        .editor_highlights_for_buffer("Markdown".into(), doc.into(), 0)
        .unwrap();
    assert!(
        !highlights.text_highlights.is_empty(),
        "Expected inline code and HTML <mark> text highlights"
    );
    assert!(
        !highlights.row_highlights.is_empty(),
        "Expected fenced code block row highlights"
    );

    let decorations = ext
        .editor_decorations_for_buffer("Markdown".into(), doc.into(), 0)
        .unwrap();
    assert!(
        decorations
            .inline_folds
            .iter()
            .any(|f| f.render_canvas.is_some() && f.placeholder_text != "☐"),
        "Expected inline math fold with a 2D CanvasElement"
    );
    let checkbox_fold = decorations
        .inline_folds
        .iter()
        .find(|f| f.placeholder_text == "☐")
        .expect("Expected interactive task checkbox inline fold on inactive row");
    let click_rep = checkbox_fold
        .render_canvas
        .as_ref()
        .and_then(|c| c.click_replacement.as_ref())
        .expect("Task checkbox canvas must include click_replacement");
    assert_eq!(click_rep.replacement_text, "[x]");
    assert!(
        decorations.blocks.len() >= 2,
        "Expected display math card and code fence header/rule block decorations"
    );
}
