#[path = "../../../core/folio_engine/tst/support/behavior_spec.rs"]
mod behavior_spec;

use std::collections::BTreeMap;

use behavior_spec::{join_cursor, load_spec_json, parse_flat_objects_in_section, split_cursor};
use folio_zed_extension::{
    evaluate_markdown_keystroke, FolioZedModSession, KeystrokeDecision, KeystrokeInput,
};

fn keystroke_for_spec_case(case: &BTreeMap<String, String>) -> KeystrokeInput<'static> {
    let id = &case["id"];
    match case["action"].as_str() {
        "newline" => KeystrokeInput {
            key: "enter",
            platform: false,
            control: false,
            alt: false,
            shift: false,
            function: false,
        },
        "toggle_delimiter" => {
            let (key, shift) = match case["delimiter"].as_str() {
                "**" => ("b", false),
                "*" => ("i", false),
                "`" => ("e", false),
                "~~" => ("x", true),
                "==" => ("h", true),
                "$" => ("m", false),
                "$$" => ("m", true),
                other => panic!("Unsupported delimiter {other:?} in case {id}"),
            };
            KeystrokeInput {
                key,
                platform: true,
                control: false,
                alt: false,
                shift,
                function: false,
            }
        }
        "set_heading_level" => {
            let key = match case["level"].parse::<u8>().unwrap() {
                0 => "0",
                1 => "1",
                2 => "2",
                3 => "3",
                4 => "4",
                5 => "5",
                6 => "6",
                other => panic!("Unsupported heading level {other} in case {id}"),
            };
            KeystrokeInput {
                key,
                platform: true,
                control: false,
                alt: false,
                shift: false,
                function: false,
            }
        }
        "toggle_task_checkbox" => KeystrokeInput {
            key: "enter",
            platform: true,
            control: false,
            alt: false,
            shift: false,
            function: false,
        },
        other => panic!("Unknown action {other:?} in case {id}"),
    }
}

fn apply_keystroke_decision(
    source: &str,
    cursor_byte: usize,
    decision: KeystrokeDecision,
) -> (String, usize) {
    match decision {
        KeystrokeDecision::SourceEdit {
            edit_range,
            replacement,
            post_selection,
        } => {
            let default_caret = edit_range.start + replacement.len();
            let mut out =
                String::with_capacity(source.len() - edit_range.len() + replacement.len());
            out.push_str(&source[..edit_range.start]);
            out.push_str(&replacement);
            out.push_str(&source[edit_range.end..]);
            let caret = post_selection.map_or(default_caret, |sel| {
                assert_eq!(sel.start, sel.end, "expected collapsed caret after edit");
                sel.start
            });
            (out, caret)
        }
        KeystrokeDecision::HandledNoOp | KeystrokeDecision::Unhandled => {
            (source.to_string(), cursor_byte)
        }
        other => panic!("Unexpected KeystrokeDecision: {other:?}"),
    }
}

#[test]
fn test_zed_keystroke_controller_and_session_match_shared_cursor_edit_specs() {
    let json = load_spec_json();
    let cases = parse_flat_objects_in_section(&json, "cursor_edit_cases");
    assert!(
        cases.len() >= 15,
        "Expected at least 15 shared cursor_edit_cases, found {}",
        cases.len()
    );
    let session = FolioZedModSession::new(true);

    for case in &cases {
        let id = &case["id"];
        let action = &case["action"];
        let (input_text, cursor_byte) = split_cursor(&case["input"]);
        let expected_annotated = &case["expected"];

        let input = keystroke_for_spec_case(case);
        let decision = evaluate_markdown_keystroke(
            &input_text,
            cursor_byte..cursor_byte,
            cursor_byte,
            cursor_byte,
            &input,
        );
        let (keystroke_text, keystroke_cursor) =
            apply_keystroke_decision(&input_text, cursor_byte, decision);
        assert_eq!(
            &join_cursor(&keystroke_text, keystroke_cursor),
            expected_annotated,
            "Zed evaluate_markdown_keystroke failed shared behavior spec {id:?}"
        );

        let (session_text, session_cursor) = match action.as_str() {
            "newline" => session.apply_newline(&input_text, cursor_byte),
            "toggle_delimiter" => {
                session.toggle_symmetric_delimiter(&input_text, cursor_byte, &case["delimiter"])
            }
            "set_heading_level" => {
                let level: u8 = case["level"].parse().unwrap();
                session.set_heading_level(&input_text, cursor_byte, level)
            }
            "toggle_task_checkbox" => {
                session.toggle_task_checkbox_at_cursor(&input_text, cursor_byte)
            }
            other => panic!("Unknown action {other:?} in case {id}"),
        };
        assert_eq!(
            &join_cursor(&session_text, session_cursor),
            expected_annotated,
            "Zed FolioZedModSession failed shared behavior spec {id:?}"
        );
    }
}

#[test]
fn test_zed_mod_session_matches_shared_fold_reveal_specs() {
    let json = load_spec_json();
    let cases = parse_flat_objects_in_section(&json, "fold_reveal_cases");
    assert!(!cases.is_empty(), "Expected shared fold_reveal_cases");
    let session = FolioZedModSession::new(true);

    for case in &cases {
        let id = &case["id"];
        let (input_text, cursor_byte) = split_cursor(&case["input"]);
        let expected_folded_min: usize = case["expected_folded_min"].parse().unwrap();

        let frame = session.evaluate_buffer(&input_text, cursor_byte..cursor_byte);
        assert!(
            frame.folds.len() >= expected_folded_min,
            "Zed Extension case {id}: expected >= {expected_folded_min} folds, got {}",
            frame.folds.len()
        );
        assert!(
            frame
                .folds
                .iter()
                .all(|fold| !fold.byte_range.contains(&cursor_byte)),
            "Zed Extension case {id}: active cursor {cursor_byte} must not be folded"
        );
    }
}
