use std::fs;
use std::time::{SystemTime, UNIX_EPOCH};

use folio_zed_extension::{
    byte_offset_to_row, ensure_builtin_extension_installed, extract_zed_outline_symbols,
    FolioZedExtension, FolioZedModSession, EXTENSION_ID, EXTENSION_TOML, LANGUAGE_CONFIG_TOML,
    OUTLINE_SCM,
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
    let doc = "\
# Top Title

```python
# comment inside backtick fence
```

## Section A

~~~bash
# comment inside tilde fence
~~~

### Subsection A.1
";
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

#[test]
fn test_mid_codepoint_and_out_of_bounds_cursor_offsets_do_not_panic() {
    let mut ext = FolioZedExtension::new();
    let doc = "# Café 🦀 ∑ Heading\n- [ ] Task after multibyte line\n`code`\n";

    let e_acute_pos = doc.find('é').expect("é in doc");
    assert_eq!('é'.len_utf8(), 2);
    let crab_pos = doc.find('🦀').expect("crab in doc");
    assert_eq!('🦀'.len_utf8(), 4);
    let sum_pos = doc.find('∑').expect("sum in doc");
    assert_eq!('∑'.len_utf8(), 3);

    for bad_offset in [
        (e_acute_pos + 1) as u32,
        (crab_pos + 1) as u32,
        (crab_pos + 2) as u32,
        (crab_pos + 3) as u32,
        (sum_pos + 1) as u32,
        (sum_pos + 2) as u32,
        u32::MAX,
    ] {
        let highlights = ext
            .editor_highlights_for_buffer("Markdown".into(), doc.into(), bad_offset)
            .expect("highlights should succeed for arbitrary cursor_offset");
        let decorations = ext
            .editor_decorations_for_buffer("Markdown".into(), doc.into(), bad_offset)
            .expect("decorations should succeed for arbitrary cursor_offset");
        assert!(!highlights.text_highlights.is_empty());
        assert!(
            decorations
                .inline_folds
                .iter()
                .all(|fold| (fold.range.end as usize) <= doc.len()),
            "all fold ranges must stay within buffer byte bounds"
        );
    }

    // Mid-codepoint offset inside `🦀` on line 0 snaps to `crab_pos` on line 0, keeping line 0 revealed.
    let mid_crab = (crab_pos + 2) as u32;
    let evals_before = ext.evaluation_count();
    let _ = ext
        .editor_highlights_for_buffer("Markdown".into(), doc.into(), mid_crab)
        .unwrap();
    let evals_after_highlights = ext.evaluation_count();
    assert_eq!(evals_after_highlights, evals_before + 1);
    let decs_snapped = ext
        .editor_decorations_for_buffer("Markdown".into(), doc.into(), crab_pos as u32)
        .unwrap();
    assert_eq!(
        ext.evaluation_count(),
        evals_after_highlights,
        "mid-codepoint offset and snapped char boundary should share the cached frame"
    );
    let first_newline = doc.find('\n').unwrap() as u32;
    assert!(
        decs_snapped
            .inline_folds
            .iter()
            .all(|fold| fold.range.start >= first_newline),
        "active heading line with multibyte cursor must not fold its `#` marker"
    );
}

#[test]
fn test_non_ascii_selection_stats_use_utf16_offsets() {
    let session = FolioZedModSession::new(true);
    let doc = "café 🦀 naïve world";

    // Total UTF-16 code units: "café" (4) + " " (1) + "🦀" (2) + " " (1) + "naïve" (5) + " " (1) + "world" (5) = 19
    // Total UTF-8 bytes: 5 + 1 + 4 + 1 + 6 + 1 + 5 = 23
    assert_eq!(doc.len(), 23);

    let collapsed = session.evaluate_buffer(doc, 6..6);
    assert_eq!(collapsed.stats.characters, 19);
    assert_eq!(collapsed.stats.words, 3);
    assert_eq!(collapsed.stats.selected_characters, 0);
    assert_eq!(collapsed.stats.selected_words, 0);

    let cafe_end = "café".len();
    let cafe_frame = session.evaluate_buffer(doc, 0..cafe_end);
    assert_eq!(cafe_frame.stats.selected_characters, 4);
    assert_eq!(cafe_frame.stats.selected_words, 1);

    let crab_start = doc.find('🦀').unwrap();
    let crab_end = crab_start + '🦀'.len_utf8();
    let crab_frame = session.evaluate_buffer(doc, crab_start..crab_end);
    assert_eq!(crab_frame.stats.selected_characters, 2);
    assert_eq!(crab_frame.stats.selected_words, 0);

    let tail_start = doc.find("naïve").unwrap();
    let tail_frame = session.evaluate_buffer(doc, tail_start..doc.len());
    assert_eq!(
        tail_frame.stats.selected_characters, 11,
        "selection after multibyte UTF-8 characters must report exact UTF-16 code units"
    );
    assert_eq!(tail_frame.stats.selected_words, 2);
}

#[test]
fn test_back_to_back_buffer_calls_cache_frame_and_compute_multiline_rows() {
    let mut ext = FolioZedExtension::new();
    let lines = [
        "# Multiline café 🦀 doc", // row 0
        "",                        // row 1
        "> Quoted line one",       // row 2
        "> Quoted line two",       // row 3
        "",                        // row 4
        "| Name | Value |",        // row 5 (table header)
        "| ---- | ----- |",        // row 6 (table separator)
        "| αβγ  | `42`  |",        // row 7 (table body + inline code)
        "",                        // row 8
        "- [ ] First task",        // row 9
        "```rust",                 // row 10 (code fence header)
        "let x = 1;",              // row 11 (code fence body)
        "```",                     // row 12 (code fence end)
    ];
    let doc = format!("{}\n", lines.join("\n"));

    assert_eq!(ext.evaluation_count(), 0);
    let highlights = ext
        .editor_highlights_for_buffer("Markdown".into(), doc.clone(), 0)
        .unwrap();
    assert_eq!(ext.evaluation_count(), 1);

    let decorations = ext
        .editor_decorations_for_buffer("Markdown".into(), doc.clone(), 0)
        .unwrap();
    assert_eq!(
        ext.evaluation_count(),
        1,
        "back-to-back editor_decorations_for_buffer with identical text and cursor must reuse cached frame"
    );

    let highlighted_rows: Vec<u32> = highlights
        .row_highlights
        .iter()
        .map(|row| {
            assert_eq!(row.start_row, row.end_row);
            row.start_row
        })
        .collect();
    assert_eq!(
        highlighted_rows,
        vec![2, 3, 5, 10, 11, 12],
        "expected exact 0-based rows for blockquotes (2, 3), table header (5), and code fence (10..=12)"
    );

    let task_pos = doc.find("- [ ]").unwrap();
    assert_eq!(byte_offset_to_row(&doc, task_pos), 9);
    assert!(
        decorations
            .inline_folds
            .iter()
            .any(|fold| fold.placeholder_text == "☐"),
        "inactive row 9 task checkbox should fold on cursor row 0"
    );

    // Moving cursor onto row 9 invalidates the cache and reveals row 9's task checkbox.
    let active_task_decs = ext
        .editor_decorations_for_buffer("Markdown".into(), doc.clone(), task_pos as u32)
        .unwrap();
    assert_eq!(ext.evaluation_count(), 2);
    assert!(
        !active_task_decs
            .inline_folds
            .iter()
            .any(|fold| fold.placeholder_text == "☐"),
        "active row 9 must reveal raw `- [ ]` syntax instead of folding checkbox"
    );

    // Toggling session pretty_mode invalidates the cache even with identical text and cursor.
    ext.session.set_pretty_mode(false);
    let raw_decs = ext
        .editor_decorations_for_buffer("Markdown".into(), doc, 0)
        .unwrap();
    assert_eq!(ext.evaluation_count(), 3);
    assert!(raw_decs.inline_folds.is_empty());
}
