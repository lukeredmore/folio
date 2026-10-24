use folio_zed_extension::{
    cycle_code_block_language, dispatch_preview_command, evaluate_markdown_keystroke,
    extract_html_attr, next_word_boundary, percent_decode_str, prev_word_boundary,
    surrounding_code_span_delimiters, toggle_heading_level, toggle_inline_delimiter,
    KeystrokeDecision, KeystrokeInput,
};

#[test]
fn test_toggle_inline_delimiter_shortcuts() {
    let (range, repl, sel) = toggle_inline_delimiter("hello world", 0, 5, "**");
    assert_eq!(range, 0..5);
    assert_eq!(repl, "**hello**");
    assert_eq!(sel, 2..7);

    let (range, repl, sel) = toggle_inline_delimiter("**hello** world", 2, 7, "**");
    assert_eq!(range, 0..9);
    assert_eq!(repl, "hello");
    assert_eq!(sel, 0..5);

    let (range, repl, sel) = toggle_inline_delimiter("hello world", 2, 2, "*");
    assert_eq!(range, 0..5);
    assert_eq!(repl, "*hello*");
    assert_eq!(sel, 3..3);

    let (range, repl, sel) = toggle_inline_delimiter("*hello* world", 3, 3, "*");
    assert_eq!(range, 0..7);
    assert_eq!(repl, "hello");
    assert_eq!(sel, 2..2);

    let (range, repl, sel) = toggle_inline_delimiter("**bold**", 2, 6, "*");
    assert_eq!(range, 2..6);
    assert_eq!(repl, "*bold*");
    assert_eq!(sel, 3..7);
}

#[test]
fn test_heading_and_code_span_helpers() {
    let (range, repl, sel) = toggle_heading_level("Title\nBody", 2, 2);
    assert_eq!(range, 0..0);
    assert_eq!(repl, "## ");
    assert_eq!(sel, 5..5);

    let (range, repl, sel) = toggle_heading_level("## Title\nBody", 5, 2);
    assert_eq!(range, 0..3);
    assert_eq!(repl, "");
    assert_eq!(sel, 2..2);

    let src = "Use `cargo test` now";
    let (open, close) = surrounding_code_span_delimiters(src, &(5..15)).unwrap();
    assert_eq!(&src[open], "`");
    assert_eq!(&src[close], "`");

    let utf8_src = "Héllo 世界";
    let (range, repl, _) = toggle_inline_delimiter(utf8_src, 2, 2, "**");
    assert!(utf8_src.is_char_boundary(range.start));
    assert!(utf8_src.is_char_boundary(range.end));
    assert_eq!(repl, "**Héllo**");
}

#[test]
fn test_word_navigation_and_html_helpers() {
    let src = "hello_world foo";
    assert_eq!(next_word_boundary(src, 0), 11);
    assert_eq!(prev_word_boundary(src, 15), 12);
    assert_eq!(
        extract_html_attr("<img src=\"pic.png\" width='50%'/>", "src").as_deref(),
        Some("pic.png")
    );
    assert_eq!(
        extract_html_attr("<img src=\"pic.png\" width='50%'/>", "width").as_deref(),
        Some("50%")
    );
    assert_eq!(percent_decode_str("%3Csvg%20id%3D1%3E"), "<svg id=1>");

    let fenced = "```rust\nfn main() {}\n```";
    let (range, line) = cycle_code_block_language(fenced, 0..fenced.len(), "rust").unwrap();
    assert_eq!(range, 0..7);
    assert_eq!(line, "```python");
}

#[test]
fn test_keystroke_controller_and_preview_bridge_roundtrip() {
    let src = "- item 1";
    let enter_decision = evaluate_markdown_keystroke(
        src,
        8..8,
        8,
        8,
        &KeystrokeInput {
            key: "enter",
            platform: false,
            control: false,
            alt: false,
            shift: false,
            function: false,
        },
    );
    assert_eq!(
        enter_decision,
        KeystrokeDecision::SourceEdit {
            edit_range: 8..8,
            replacement: "\n- ".to_string(),
            post_selection: None,
        }
    );

    let res = dispatch_preview_command(
        "evaluate_keystroke",
        &[
            src.to_string(),
            "2".to_string(),
            "6".to_string(),
            "6".to_string(),
            "2".to_string(),
            "b".to_string(),
            "1".to_string(),
        ],
    )
    .unwrap();
    assert_eq!(res, "6\t2\t6\t1\t4\t8\n**item**");

    let delims = dispatch_preview_command(
        "surrounding_code_span_delimiters",
        &["a `x` b".to_string(), "3".to_string(), "4".to_string()],
    )
    .unwrap();
    assert_eq!(delims, "1\t2\t3\t4\t5");

    let block = "```rust\nx\n```";
    let edit = dispatch_preview_command(
        "cycle_code_block_language",
        &[
            block.to_string(),
            "0".to_string(),
            block.len().to_string(),
            "rust".to_string(),
        ],
    )
    .unwrap();
    assert_eq!(edit, "1\t0\t7\n```python");

    let attr = dispatch_preview_command(
        "extract_html_attr",
        &["<img src=\"a.svg\">".to_string(), "src".to_string()],
    )
    .unwrap();
    assert_eq!(attr, "1\na.svg");

    let dec = dispatch_preview_command("percent_decode", &["%3Csvg%3E".to_string()]).unwrap();
    assert_eq!(dec, "<svg>");

    let math = dispatch_preview_command(
        "build_math_canvas",
        &[
            "\\frac{a}{b}".to_string(),
            "16.0".to_string(),
            "1".to_string(),
        ],
    )
    .unwrap();
    assert!(math.contains("G\t"));
    assert!(math.contains("R\t"));
}
