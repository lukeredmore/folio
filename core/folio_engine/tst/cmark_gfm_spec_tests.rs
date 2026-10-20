use folio_engine::markdown::{
    parse_cmark_gfm_ast, parse_upstream_spec_txt, render_markdown_to_html, CmarkBlockKind,
    CmarkInlineKind,
};
use std::fs;
use std::path::PathBuf;

fn spec_file_path(filename: &str) -> PathBuf {
    let candidates = [
        PathBuf::from(format!("third_party/markdown_spec/{filename}")),
        PathBuf::from(format!("../../third_party/markdown_spec/{filename}")),
    ];
    for c in &candidates {
        if c.exists() {
            return c.clone();
        }
    }
    panic!("Could not locate upstream spec file: {filename}");
}

#[test]
fn test_upstream_gfm_spec_txt_full_parity() {
    let spec_txt_path = spec_file_path("gfm_spec.txt");
    let spec_text =
        fs::read_to_string(&spec_txt_path).expect("Failed to read upstream gfm_spec.txt");
    let examples = parse_upstream_spec_txt(&spec_text);

    assert!(
        examples.len() >= 650,
        "Expected >= 650 upstream spec tests, got {}",
        examples.len()
    );

    let mut passed = 0usize;
    let mut failures = Vec::new();
    for ex in &examples {
        let ext_refs: Vec<&str> = ex.extensions.iter().map(|s| s.as_str()).collect();
        let actual_html = render_markdown_to_html(&ex.markdown, &ext_refs);
        if actual_html == ex.html {
            passed += 1;
        } else {
            failures.push(format!(
                "Example {} ({}, lines {}-{}):\nMarkdown:\n{:?}\nExpected HTML:\n{:?}\nActual HTML:\n{:?}",
                ex.example, ex.section, ex.start_line, ex.end_line, ex.markdown, ex.html, actual_html
            ));
        }
    }

    assert!(
        failures.is_empty(),
        "Failed {}/{} upstream GFM spec tests:\n{}",
        failures.len(),
        examples.len(),
        failures.join("\n\n")
    );
    assert_eq!(passed, examples.len());
}

#[test]
fn test_upstream_gfm_extensions_txt_full_parity() {
    let ext_txt_path = spec_file_path("gfm_extensions.txt");
    let ext_text =
        fs::read_to_string(&ext_txt_path).expect("Failed to read upstream gfm_extensions.txt");
    let examples = parse_upstream_spec_txt(&ext_text);
    assert!(
        examples.len() >= 25,
        "Expected >= 25 upstream extension tests, got {}",
        examples.len()
    );

    let default_exts = [
        "table",
        "strikethrough",
        "autolink",
        "tagfilter",
        "footnotes",
        "tasklist",
    ];

    for ex in &examples {
        let mut exts: Vec<&str> = default_exts.to_vec();
        for e in &ex.extensions {
            if !exts.contains(&e.as_str()) {
                exts.push(e.as_str());
            }
        }
        let actual_html = render_markdown_to_html(&ex.markdown, &exts);
        if ex.html.trim() != "<IGNORE>" {
            assert_eq!(
                actual_html, ex.html,
                "Failed upstream GFM extension example {} ({})",
                ex.example, ex.section
            );
        }
    }
}

#[test]
fn test_cmark_gfm_ast_extracts_reference_links_indented_code_and_tables() {
    let md = "\
Here is a [reference link][ref] and a [shortcut] link.

    let x = 42;
    # indented code, not a heading

| Col A | Col B |
| :--- | ---: |
| `x | y` | val |

- [x] Done task
- [ ] Open task

[ref]: https://example.com/ref
[shortcut]: https://example.com/short
";
    let ast = parse_cmark_gfm_ast(md);
    let links: Vec<_> = ast
        .inlines
        .iter()
        .filter(|i| i.kind == CmarkInlineKind::Link)
        .collect();
    assert_eq!(links.len(), 2);
    assert_eq!(links[0].url, "https://example.com/ref");
    assert_eq!(links[0].literal, "reference link");
    assert_eq!(links[1].url, "https://example.com/short");
    assert_eq!(links[1].literal, "shortcut");

    assert!(ast
        .blocks
        .iter()
        .any(|b| b.kind == CmarkBlockKind::CodeBlock && b.flags == 0));

    assert!(ast
        .blocks
        .iter()
        .any(|b| b.kind == CmarkBlockKind::Table && b.info == "lr" && b.level == 2));

    let tasks: Vec<_> = ast
        .blocks
        .iter()
        .filter(|b| b.kind == CmarkBlockKind::ListItem && (b.flags & 8) != 0)
        .collect();
    assert_eq!(tasks.len(), 2);
    assert_ne!(tasks[0].flags & 16, 0);
    assert_eq!(tasks[1].flags & 16, 0);
}
