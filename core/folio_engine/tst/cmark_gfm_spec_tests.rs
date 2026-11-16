use folio_engine::markdown::{
    parse_cmark_gfm_ast, render_markdown_to_html, CmarkBlockKind, CmarkInlineKind,
};
use std::fs;
use std::path::PathBuf;

#[derive(Debug, Clone, PartialEq, Eq)]
struct UpstreamSpecExample {
    example: usize,
    section: String,
    start_line: usize,
    end_line: usize,
    extensions: Vec<String>,
    markdown: String,
    html: String,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum SpecParseState {
    Outside,
    Markdown,
    Html,
}

fn parse_upstream_spec_txt(spec_text: &str) -> Vec<UpstreamSpecExample> {
    const FENCE: &str = "````````````````````````````````";
    const OPEN_PREFIX: &str = "```````````````````````````````` example";

    let mut start_line = 0usize;
    let mut example_number = 0usize;
    let mut markdown_lines: Vec<&str> = Vec::new();
    let mut html_lines: Vec<&str> = Vec::new();
    let mut state = SpecParseState::Outside;
    let mut extensions: Vec<String> = Vec::new();
    let mut section = String::new();
    let mut examples = Vec::new();

    for (idx, raw_line) in spec_text.split_inclusive('\n').enumerate() {
        let line_number = idx + 1;
        let stripped = raw_line.trim();
        if let Some(after) = stripped.strip_prefix(OPEN_PREFIX) {
            state = SpecParseState::Markdown;
            extensions = after.split_whitespace().map(str::to_string).collect();
            continue;
        }
        if stripped == FENCE {
            state = SpecParseState::Outside;
            example_number += 1;
            if !extensions.iter().any(|ext| ext == "disabled") {
                examples.push(UpstreamSpecExample {
                    example: example_number,
                    section: section.clone(),
                    start_line,
                    end_line: line_number,
                    extensions: extensions.clone(),
                    markdown: markdown_lines.concat().replace('→', "\t"),
                    html: html_lines.concat().replace('→', "\t"),
                });
            }
            start_line = 0;
            markdown_lines.clear();
            html_lines.clear();
            continue;
        }
        match state {
            SpecParseState::Markdown if stripped == "." => state = SpecParseState::Html,
            SpecParseState::Html if stripped == "." => {}
            SpecParseState::Markdown => {
                if start_line == 0 {
                    start_line = line_number - 1;
                }
                markdown_lines.push(raw_line);
            }
            SpecParseState::Html => html_lines.push(raw_line),
            SpecParseState::Outside => {
                if let Some(heading) = parse_spec_heading(raw_line) {
                    section = heading.to_string();
                }
            }
        }
    }

    examples
}

fn parse_spec_heading(raw_line: &str) -> Option<&str> {
    let hashes = raw_line.bytes().take_while(|&b| b == b'#').count();
    if hashes > 0 && raw_line[hashes..].starts_with(' ') {
        Some(raw_line[hashes + 1..].trim())
    } else {
        None
    }
}

fn spec_file_path(filename: &str) -> PathBuf {
    let mut candidates = vec![
        PathBuf::from(format!("third_party/markdown_spec/{filename}")),
        PathBuf::from(format!("../../third_party/markdown_spec/{filename}")),
    ];
    if let Ok(test_srcdir) = std::env::var("TEST_SRCDIR") {
        let srcdir = PathBuf::from(&test_srcdir);
        if let Ok(entries) = fs::read_dir(&srcdir) {
            for entry in entries.flatten() {
                let p = entry.path();
                candidates.push(p.join(filename));
                candidates.push(p.join("third_party/markdown_spec").join(filename));
            }
        }
    }
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
