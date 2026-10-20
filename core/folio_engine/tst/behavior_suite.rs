use folio_engine::{
    analyze_markdown_document, apply_newline_at_cursor, set_heading_level_at_cursor,
    toggle_symmetric_delimiter, toggle_task_checkbox_at_cursor,
};
use std::collections::BTreeMap;
use std::fs;
use std::path::PathBuf;

const CURSOR_MARKER: &str = "ˇ";

fn load_spec_json() -> String {
    let candidates = [
        PathBuf::from("tst/specs/editor_behaviors.json"),
        PathBuf::from("../../tst/specs/editor_behaviors.json"),
    ];
    for c in &candidates {
        if c.exists() {
            return fs::read_to_string(c).expect("Failed to read editor_behaviors.json");
        }
    }
    panic!("Could not locate tst/specs/editor_behaviors.json");
}

fn split_cursor(annotated: &str) -> (String, usize) {
    let pos = annotated
        .find(CURSOR_MARKER)
        .unwrap_or_else(|| panic!("Missing cursor marker {CURSOR_MARKER:?} in {annotated:?}"));
    let mut clean = String::with_capacity(annotated.len() - CURSOR_MARKER.len());
    clean.push_str(&annotated[..pos]);
    clean.push_str(&annotated[pos + CURSOR_MARKER.len()..]);
    (clean, pos)
}

fn join_cursor(text: &str, cursor_byte: usize) -> String {
    let mut out = String::with_capacity(text.len() + CURSOR_MARKER.len());
    out.push_str(&text[..cursor_byte]);
    out.push_str(CURSOR_MARKER);
    out.push_str(&text[cursor_byte..]);
    out
}

fn unescape_json_str(raw: &str) -> String {
    let mut out = String::new();
    let mut chars = raw.chars();
    while let Some(c) = chars.next() {
        if c == '\\' {
            match chars.next() {
                Some('n') => out.push('\n'),
                Some('r') => out.push('\r'),
                Some('t') => out.push('\t'),
                Some('"') => out.push('"'),
                Some('\\') => out.push('\\'),
                Some(other) => {
                    out.push('\\');
                    out.push(other);
                }
                None => out.push('\\'),
            }
        } else {
            out.push(c);
        }
    }
    out
}

fn parse_flat_objects_in_section(
    json: &str,
    section_key: &str,
) -> Vec<BTreeMap<String, String>> {
    let needle = format!("\"{section_key}\"");
    let start = json.find(&needle).expect("Missing section in spec JSON");
    let bracket_open = json[start..].find('[').unwrap() + start;
    let mut depth = 0i32;
    let mut bracket_close = bracket_open;
    let mut in_str = false;
    let mut prev_backslash = false;
    for (idx, ch) in json[bracket_open..].char_indices() {
        if in_str {
            if ch == '"' && !prev_backslash {
                in_str = false;
            }
            prev_backslash = ch == '\\' && !prev_backslash;
            continue;
        }
        match ch {
            '"' => in_str = true,
            '[' => depth += 1,
            ']' => {
                depth -= 1;
                if depth == 0 {
                    bracket_close = bracket_open + idx;
                    break;
                }
            }
            _ => {}
        }
    }

    let array_slice = &json[bracket_open + 1..bracket_close];
    let mut objects = Vec::new();
    let mut cur_start = None;
    for (idx, ch) in array_slice.char_indices() {
        if in_str {
            if ch == '"' && !prev_backslash {
                in_str = false;
            }
            prev_backslash = ch == '\\' && !prev_backslash;
            continue;
        }
        match ch {
            '"' => in_str = true,
            '{' => cur_start = Some(idx + 1),
            '}' => {
                if let Some(s) = cur_start.take() {
                    objects.push(parse_kv_fields(&array_slice[s..idx]));
                }
            }
            _ => {}
        }
    }
    objects
}

fn parse_kv_fields(obj_body: &str) -> BTreeMap<String, String> {
    let mut map = BTreeMap::new();
    for raw_line in obj_body.lines() {
        let line = raw_line.trim().trim_end_matches(',');
        if line.is_empty() {
            continue;
        }
        if let Some((k_part, v_part)) = line.split_once(':') {
            let key = k_part.trim().trim_matches('"').to_string();
            let val_trimmed = v_part.trim();
            let val = if val_trimmed.starts_with('"') && val_trimmed.ends_with('"') {
                unescape_json_str(&val_trimmed[1..val_trimmed.len() - 1])
            } else {
                val_trimmed.to_string()
            };
            map.insert(key, val);
        }
    }
    map
}

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
                let delim = &case["delimiter"];
                toggle_symmetric_delimiter(&input_text, cursor_byte, delim)
            }
            "set_heading_level" => {
                let level: u8 = case["level"].parse().unwrap();
                set_heading_level_at_cursor(&input_text, cursor_byte, level)
            }
            "toggle_task_checkbox" => toggle_task_checkbox_at_cursor(&input_text, cursor_byte),
            other => panic!("Unknown action {other:?} in case {id}"),
        };

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
    assert_eq!(cases.len(), 2);

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
