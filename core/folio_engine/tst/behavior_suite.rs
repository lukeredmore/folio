#[path = "support/behavior_spec.rs"]
mod behavior_spec;

use std::ffi::{CStr, CString};

use behavior_spec::{join_cursor, load_spec_json, parse_flat_objects_in_section, split_cursor};
use folio_engine::ffi::{
    ot_engine_edit_heading_level_utf16, ot_engine_edit_newline_utf16,
    ot_engine_edit_symmetric_delimiter_utf16, ot_engine_edit_symmetric_delimiter_utf8,
    ot_engine_edit_task_checkbox_utf16, ot_engine_free_span_edit, OTSpanEditResult,
};
use folio_engine::{
    analyze_markdown_document, apply_newline_at_cursor, edit_newline, edit_set_heading_level,
    edit_symmetric_delimiter, edit_toggle_heading_level, edit_toggle_task_checkbox,
    set_heading_level_at_cursor, toggle_symmetric_delimiter, toggle_task_checkbox_at_cursor,
};

#[test]
fn test_shared_cursor_edit_behavior_specs() {
    let json = load_spec_json();
    let cases = parse_flat_objects_in_section(&json, "cursor_edit_cases");
    assert!(
        cases.len() >= 15,
        "Expected at least 15 shared cursor_edit_cases, found {}",
        cases.len()
    );

    for case in &cases {
        let id = &case["id"];
        let action = &case["action"];
        let (input_text, cursor_byte) = split_cursor(&case["input"]);
        let expected_annotated = &case["expected"];

        let (actual_text, actual_cursor) = match action.as_str() {
            "newline" => apply_newline_at_cursor(&input_text, cursor_byte),
            "toggle_delimiter" => {
                toggle_symmetric_delimiter(&input_text, cursor_byte, &case["delimiter"])
            }
            "set_heading_level" => {
                let level: u8 = case["level"].parse().unwrap();
                set_heading_level_at_cursor(&input_text, cursor_byte, level)
            }
            "toggle_task_checkbox" => toggle_task_checkbox_at_cursor(&input_text, cursor_byte),
            other => panic!("Unknown action {other:?} in case {id}"),
        };

        let span_edit = match action.as_str() {
            "newline" => edit_newline(&input_text, cursor_byte..cursor_byte),
            "toggle_delimiter" => {
                edit_symmetric_delimiter(&input_text, cursor_byte..cursor_byte, &case["delimiter"])
            }
            "set_heading_level" => {
                let level: u8 = case["level"].parse().unwrap();
                edit_set_heading_level(&input_text, cursor_byte..cursor_byte, level)
            }
            "toggle_task_checkbox" => {
                edit_toggle_task_checkbox(&input_text, cursor_byte..cursor_byte)
            }
            other => panic!("Unknown action {other:?} in case {id}"),
        };
        let (span_text, span_sel) = span_edit.apply(&input_text);
        assert_eq!(
            (span_text.as_str(), span_sel),
            (actual_text.as_str(), actual_cursor..actual_cursor),
            "SpanEdit disagreed with CursorEdit for case {id:?}"
        );

        let actual_annotated = join_cursor(&actual_text, actual_cursor);
        assert_eq!(
            &actual_annotated, expected_annotated,
            "Behavior spec failed for case {id:?} (action={action})"
        );
    }
}

#[test]
fn test_shared_fold_reveal_behavior_specs() {
    let json = load_spec_json();
    let cases = parse_flat_objects_in_section(&json, "fold_reveal_cases");
    assert!(!cases.is_empty(), "Expected shared fold_reveal_cases");

    for case in &cases {
        let id = &case["id"];
        let (input_text, cursor_byte) = split_cursor(&case["input"]);
        let expected_revealed: usize = case["expected_revealed_count"].parse().unwrap();
        let expected_folded_min: usize = case["expected_folded_min"].parse().unwrap();

        let analysis = analyze_markdown_document(&input_text, cursor_byte, false, false);
        let revealed_count = analysis
            .syntax_fold_spans
            .iter()
            .filter(|s| s.is_revealed)
            .count();
        let folded_count = analysis
            .syntax_fold_spans
            .iter()
            .filter(|s| !s.is_revealed)
            .count();

        assert_eq!(
            revealed_count, expected_revealed,
            "Case {id}: unexpected revealed span count"
        );
        assert!(
            folded_count >= expected_folded_min,
            "Case {id}: expected >= {expected_folded_min} folded spans, got {folded_count}"
        );
    }
}

#[test]
fn test_utf8_multibyte_delimiter_toggle_never_panics() {
    assert_eq!(
        toggle_symmetric_delimiter("café world", 5, "*"),
        ("*café* world".to_string(), 6)
    );
    assert_eq!(
        toggle_symmetric_delimiter("*café* world", 6, "*"),
        ("café world".to_string(), 5)
    );
    assert_eq!(
        toggle_symmetric_delimiter("café world", 4, "**"),
        ("**café** world".to_string(), 5)
    );
    assert_eq!(
        toggle_symmetric_delimiter("café  world", 6, "**"),
        ("café ** **world".replace(" ** **", " **** "), 8)
    );
    assert_eq!(
        toggle_symmetric_delimiter("🦀  ", 5, "=="),
        ("🦀 ==== ".to_string(), 7)
    );
}

#[test]
fn test_newline_empty_list_on_non_final_line_does_not_double_newline() {
    let edit = edit_newline("- \nnext", 2..2);
    assert_eq!(edit.replace_range, 0..2);
    assert_eq!(edit.replacement, "");
    assert_eq!(edit.new_selection, 0..0);
    assert_eq!(
        apply_newline_at_cursor("- \nnext", 2),
        ("\nnext".to_string(), 0)
    );
    assert_eq!(
        apply_newline_at_cursor("- a\n- [ ] \nnext", 10),
        ("- a\n\nnext".to_string(), 4)
    );
    assert_eq!(apply_newline_at_cursor("- ", 2), ("\n".to_string(), 1));
}

#[test]
fn test_span_edit_selection_wrapping_and_heading_toggling() {
    let wrap = edit_symmetric_delimiter("café world", 0..5, "**");
    assert_eq!(wrap.replace_range, 0..5);
    assert_eq!(wrap.replacement, "**café**");
    assert_eq!(wrap.new_selection, 2..7);
    assert_eq!(
        wrap.apply("café world"),
        ("**café** world".to_string(), 2..7)
    );

    let unwrap = edit_symmetric_delimiter("**café** world", 2..7, "**");
    assert_eq!(unwrap.replace_range, 0..9);
    assert_eq!(unwrap.replacement, "café");
    assert_eq!(unwrap.new_selection, 0..5);

    let mark = edit_symmetric_delimiter("mark this", 5..9, "==");
    assert_eq!(
        mark.apply("mark this"),
        ("mark ==this==".to_string(), 7..11)
    );

    let strike = edit_symmetric_delimiter("drop this", 5..9, "~~");
    assert_eq!(
        strike.apply("drop this"),
        ("drop ~~this~~".to_string(), 7..11)
    );

    let toggled_off = edit_toggle_heading_level("## Heading\nBody", 3..10, 2);
    assert_eq!(
        toggled_off.apply("## Heading\nBody"),
        ("Heading\nBody".to_string(), 0..7)
    );
    assert!(edit_set_heading_level("## Heading\nBody", 3..10, 2).is_noop());

    let nl_sel = edit_newline("Hello brave world", 5..11);
    assert_eq!(
        nl_sel.apply("Hello brave world"),
        ("Hello\n world".to_string(), 6..6)
    );

    let task = edit_toggle_task_checkbox("- [ ] Ship SpanEdit", 6..10);
    assert_eq!(
        task.apply("- [ ] Ship SpanEdit"),
        ("- [x] Ship SpanEdit".to_string(), 6..10)
    );
}

fn take_ffi_span(res: OTSpanEditResult) -> (String, usize, usize, usize, usize) {
    let repl = unsafe { CStr::from_ptr(res.replacement) }
        .to_str()
        .unwrap()
        .to_string();
    let tuple = (
        repl,
        res.replace_loc,
        res.replace_len,
        res.select_loc,
        res.select_len,
    );
    unsafe { ot_engine_free_span_edit(res) };
    tuple
}

#[test]
fn test_span_edit_c_ffi_utf8_and_utf16_parity() {
    let doc = "🦀 café\n- [ ] task";
    let c_doc = CString::new(doc).unwrap();
    let c_bold = CString::new("**").unwrap();

    // "🦀 " is 5 UTF-8 bytes and 3 UTF-16 code units; "café" is 5 UTF-8 bytes and 4 UTF-16 code units.
    let utf8_res = take_ffi_span(unsafe {
        ot_engine_edit_symmetric_delimiter_utf8(c_doc.as_ptr(), 5, 5, c_bold.as_ptr())
    });
    assert_eq!(utf8_res, ("**café**".to_string(), 5, 5, 7, 5));

    let utf16_res = take_ffi_span(unsafe {
        ot_engine_edit_symmetric_delimiter_utf16(c_doc.as_ptr(), 3, 4, c_bold.as_ptr())
    });
    assert_eq!(utf16_res, ("**café**".to_string(), 3, 4, 5, 4));

    let h_res =
        take_ffi_span(unsafe { ot_engine_edit_heading_level_utf16(c_doc.as_ptr(), 3, 4, 2, true) });
    assert_eq!(h_res, ("## ".to_string(), 0, 0, 6, 4));

    // Second line starts at UTF-16 offset 8 ("🦀 café\n" = 2 + 1 + 4 + 1 = 8).
    let cb_res =
        take_ffi_span(unsafe { ot_engine_edit_task_checkbox_utf16(c_doc.as_ptr(), 14, 0) });
    assert_eq!(cb_res, ("[x]".to_string(), 10, 3, 14, 0));

    let nl_res = take_ffi_span(unsafe { ot_engine_edit_newline_utf16(c_doc.as_ptr(), 18, 0) });
    assert_eq!(nl_res, ("\n- [ ] ".to_string(), 18, 0, 25, 0));
}
