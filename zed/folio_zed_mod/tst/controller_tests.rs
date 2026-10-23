use folio_zed_mod::ffi::folio_zed_mod_free_string;
use folio_zed_mod::ffi_controller::{
    folio_zed_mod_cycle_code_block_language, folio_zed_mod_evaluate_keystroke,
    folio_zed_mod_extract_html_attr, folio_zed_mod_free_keystroke_decision,
    folio_zed_mod_free_source_edit, folio_zed_mod_percent_decode,
    folio_zed_mod_surrounding_code_span_delimiters,
};
use folio_zed_mod::{
    cycle_code_block_language, evaluate_markdown_keystroke, extract_html_attr, next_word_boundary,
    percent_decode_str, prev_word_boundary, surrounding_code_span_delimiters, toggle_heading_level,
    toggle_inline_delimiter, KeystrokeDecision, KeystrokeInput,
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
fn test_keystroke_controller_and_ffi_roundtrip() {
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

    unsafe {
        let key = "b";
        let res = folio_zed_mod_evaluate_keystroke(
            src.as_ptr(),
            src.len(),
            2,
            6,
            6,
            2,
            key.as_ptr(),
            key.len(),
            true,
            false,
            false,
            false,
            false,
        );
        assert_eq!(res.kind, 6);
        assert_eq!(res.range_start..res.range_end, 2..6);
        assert!(res.has_post_selection);
        assert_eq!(res.post_sel_start..res.post_sel_end, 4..8);
        let repl = std::ffi::CStr::from_ptr(res.replacement).to_str().unwrap();
        assert_eq!(repl, "**item**");
        folio_zed_mod_free_keystroke_decision(res);

        let code_src = "a `x` b";
        let delims = folio_zed_mod_surrounding_code_span_delimiters(
            code_src.as_ptr(),
            code_src.len(),
            3,
            4,
        );
        assert!(delims.valid);
        assert_eq!(delims.open_start..delims.open_end, 2..3);
        assert_eq!(delims.close_start..delims.close_end, 4..5);

        let block = "```rust\nx\n```";
        let lang = "rust";
        let edit = folio_zed_mod_cycle_code_block_language(
            block.as_ptr(),
            block.len(),
            0,
            block.len(),
            lang.as_ptr(),
            lang.len(),
        );
        assert!(edit.valid);
        folio_zed_mod_free_source_edit(edit);

        let tag = "<img src=\"a.svg\">";
        let attr = "src";
        let ptr = folio_zed_mod_extract_html_attr(
            tag.as_ptr(),
            tag.len(),
            attr.as_ptr(),
            attr.len(),
        );
        assert!(!ptr.is_null());
        folio_zed_mod_free_string(ptr);

        let enc = "%3Csvg%3E";
        let dec_ptr = folio_zed_mod_percent_decode(enc.as_ptr(), enc.len());
        assert!(!dec_ptr.is_null());
        folio_zed_mod_free_string(dec_ptr);
    }
}
