use std::ops::Range;

use folio_engine::markdown::{
    edit_newline, edit_set_heading_level, edit_symmetric_delimiter, edit_toggle_heading_level,
    edit_toggle_task_checkbox, SpanEdit,
};

use crate::text_navigation::{
    next_word_boundary, prev_word_boundary, snap_char_boundary_left, snap_char_boundary_right,
    vertical_or_horizontal_cursor, word_range_at,
};

/// Normalized keystroke event parameters from GPUI or another host window.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct KeystrokeInput<'a> {
    pub key: &'a str,
    pub platform: bool,
    pub control: bool,
    pub alt: bool,
    pub shift: bool,
    pub function: bool,
}

/// High-level action produced by [`evaluate_markdown_keystroke`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum KeystrokeDecision {
    Unhandled,
    HandledNoOp,
    TogglePrettyMode,
    ClipboardCut(Range<usize>),
    ClipboardPaste(Range<usize>),
    SelectRange(Range<usize>),
    SourceEdit {
        edit_range: Range<usize>,
        replacement: String,
        post_selection: Option<Range<usize>>,
    },
}

/// Evaluate a keystroke inside an editable Folio Markdown view and return the resulting action.
#[must_use]
pub fn evaluate_markdown_keystroke(
    source: &str,
    selection: Range<usize>,
    head: usize,
    tail: usize,
    input: &KeystrokeInput<'_>,
) -> KeystrokeDecision {
    let sel_start = snap_char_boundary_left(source, selection.start);
    let sel_end = if selection.start == selection.end {
        sel_start
    } else {
        snap_char_boundary_right(source, selection.end).max(sel_start)
    };
    let cursor = snap_char_boundary_left(source, head);
    let tail = snap_char_boundary_left(source, tail);

    if input.platform || input.control {
        return handle_platform_shortcut(source, sel_start..sel_end, cursor, tail, input);
    }
    if input.alt && !input.function {
        return handle_alt_shortcut(source, sel_start..sel_end, cursor, tail, input);
    }
    if input.function {
        return KeystrokeDecision::Unhandled;
    }
    handle_plain_key(source, sel_start..sel_end, cursor, tail, input)
}

fn handle_platform_shortcut(
    source: &str,
    sel: Range<usize>,
    cursor: usize,
    tail: usize,
    input: &KeystrokeInput<'_>,
) -> KeystrokeDecision {
    if !input.alt {
        if let Some(decision) = handle_platform_format_shortcut(source, &sel, input) {
            return decision;
        }
    }
    let len = source.len();
    match input.key {
        "\\" if !input.alt && input.shift => KeystrokeDecision::TogglePrettyMode,
        "a" if !input.alt && !input.shift => KeystrokeDecision::SelectRange(0..len),
        "x" if !input.alt && !input.shift => {
            if sel.start < sel.end {
                KeystrokeDecision::ClipboardCut(sel)
            } else {
                KeystrokeDecision::HandledNoOp
            }
        }
        "v" if !input.alt && !input.shift => KeystrokeDecision::ClipboardPaste(sel),
        "left" if !input.alt => {
            let line_start = source[..cursor].rfind('\n').map_or(0, |idx| idx + 1);
            KeystrokeDecision::SelectRange(select_target(tail, line_start, input.shift))
        }
        "right" if !input.alt => {
            let line_end = source[cursor..].find('\n').map_or(len, |rel| cursor + rel);
            KeystrokeDecision::SelectRange(select_target(tail, line_end, input.shift))
        }
        "backspace" if !input.alt => {
            if sel.start < sel.end {
                delete_range(sel)
            } else {
                let line_start = source[..cursor].rfind('\n').map_or(0, |idx| idx + 1);
                if line_start < cursor {
                    delete_range(line_start..cursor)
                } else {
                    KeystrokeDecision::HandledNoOp
                }
            }
        }
        _ => KeystrokeDecision::Unhandled,
    }
}

fn handle_platform_format_shortcut(
    source: &str,
    sel: &Range<usize>,
    input: &KeystrokeInput<'_>,
) -> Option<KeystrokeDecision> {
    match input.key {
        "b" if !input.shift => Some(span_decision(edit_symmetric_delimiter(
            source,
            sel.clone(),
            "**",
        ))),
        "i" if !input.shift => Some(span_decision(edit_symmetric_delimiter(
            source,
            sel.clone(),
            "*",
        ))),
        "e" | "`" if !input.shift => Some(span_decision(edit_symmetric_delimiter(
            source,
            sel.clone(),
            "`",
        ))),
        "x" if input.shift => Some(span_decision(edit_symmetric_delimiter(
            source,
            sel.clone(),
            "~~",
        ))),
        "d" if !input.shift => Some(span_decision(edit_symmetric_delimiter(
            source,
            sel.clone(),
            "~~",
        ))),
        "h" if input.shift => Some(span_decision(edit_symmetric_delimiter(
            source,
            sel.clone(),
            "==",
        ))),
        "m" => {
            let delim = if input.shift { "$$" } else { "$" };
            Some(span_decision(edit_symmetric_delimiter(
                source,
                sel.clone(),
                delim,
            )))
        }
        "k" if !input.shift => Some(insert_markdown_link(source, sel)),
        "0" if !input.shift => Some(span_decision(edit_set_heading_level(
            source,
            sel.clone(),
            0,
        ))),
        "1" | "2" | "3" | "4" | "5" | "6" if !input.shift => {
            let level = input.key.as_bytes()[0] - b'0';
            Some(span_decision(edit_toggle_heading_level(
                source,
                sel.clone(),
                level,
            )))
        }
        "enter" if !input.shift => {
            let edit = edit_toggle_task_checkbox(source, sel.clone());
            Some(if edit.is_noop() {
                KeystrokeDecision::Unhandled
            } else {
                span_decision(edit)
            })
        }
        _ => None,
    }
}

fn insert_markdown_link(source: &str, sel: &Range<usize>) -> KeystrokeDecision {
    let (target_start, target_end) = if sel.start < sel.end {
        (sel.start, sel.end)
    } else if let Some((ws, we)) = word_range_at(source, sel.start) {
        (ws, we)
    } else {
        (sel.start, sel.end)
    };
    let selected = &source[target_start..target_end];
    let replacement = format!("[{selected}]()");
    let url_cursor = target_start + 1 + selected.len() + 2;
    KeystrokeDecision::SourceEdit {
        edit_range: target_start..target_end,
        replacement,
        post_selection: Some(url_cursor..url_cursor),
    }
}

fn handle_alt_shortcut(
    source: &str,
    sel: Range<usize>,
    cursor: usize,
    tail: usize,
    input: &KeystrokeInput<'_>,
) -> KeystrokeDecision {
    match input.key {
        "left" => {
            let next_pos = prev_word_boundary(source, cursor);
            KeystrokeDecision::SelectRange(select_target(tail, next_pos, input.shift))
        }
        "right" => {
            let next_pos = next_word_boundary(source, cursor);
            KeystrokeDecision::SelectRange(select_target(tail, next_pos, input.shift))
        }
        "backspace" => {
            if sel.start < sel.end {
                delete_range(sel)
            } else if cursor > 0 {
                delete_range(prev_word_boundary(source, cursor)..cursor)
            } else {
                KeystrokeDecision::HandledNoOp
            }
        }
        _ => KeystrokeDecision::Unhandled,
    }
}

fn handle_plain_key(
    source: &str,
    sel: Range<usize>,
    cursor: usize,
    tail: usize,
    input: &KeystrokeInput<'_>,
) -> KeystrokeDecision {
    let len = source.len();
    match input.key {
        "backspace" => {
            if sel.start < sel.end {
                delete_range(sel)
            } else if cursor > 0 {
                let prev = source[..cursor]
                    .char_indices()
                    .next_back()
                    .map_or(0, |(idx, _)| idx);
                delete_range(prev..cursor)
            } else {
                KeystrokeDecision::HandledNoOp
            }
        }
        "delete" => {
            if sel.start < sel.end {
                delete_range(sel)
            } else if cursor < len {
                let next = source[cursor..]
                    .chars()
                    .next()
                    .map_or(len, |ch| cursor + ch.len_utf8());
                delete_range(cursor..next)
            } else {
                KeystrokeDecision::HandledNoOp
            }
        }
        "enter" => {
            let edit = edit_newline(source, sel);
            let default_caret = edit.replace_range.start + edit.replacement.len();
            let post_selection = (edit.new_selection != (default_caret..default_caret))
                .then_some(edit.new_selection);
            KeystrokeDecision::SourceEdit {
                edit_range: edit.replace_range,
                replacement: edit.replacement,
                post_selection,
            }
        }
        "tab" => handle_tab_key(source, sel, input.shift),
        "left" | "right" | "up" | "down" | "home" | "end" => {
            let next_pos =
                vertical_or_horizontal_cursor(source, &sel, cursor, input.key, input.shift);
            KeystrokeDecision::SelectRange(select_target(tail, next_pos, input.shift))
        }
        _ => KeystrokeDecision::Unhandled,
    }
}

fn handle_tab_key(source: &str, sel: Range<usize>, shift: bool) -> KeystrokeDecision {
    let len = source.len();
    let line_start = source[..sel.start].rfind('\n').map_or(0, |idx| idx + 1);
    let line_end = source[sel.end..]
        .find('\n')
        .map_or(len, |rel| sel.end + rel);
    let line_slice = &source[line_start..line_end];
    if shift {
        if line_slice.starts_with("  ") {
            KeystrokeDecision::SourceEdit {
                edit_range: line_start..(line_start + 2),
                replacement: String::new(),
                post_selection: None,
            }
        } else if line_slice.starts_with('\t') {
            KeystrokeDecision::SourceEdit {
                edit_range: line_start..(line_start + 1),
                replacement: String::new(),
                post_selection: None,
            }
        } else {
            KeystrokeDecision::HandledNoOp
        }
    } else {
        let trimmed = line_slice.trim_start();
        let is_list_line = trimmed.starts_with("- ")
            || trimmed.starts_with("* ")
            || trimmed.starts_with("+ ")
            || trimmed.starts_with("> ")
            || (trimmed.chars().take_while(char::is_ascii_digit).count() > 0
                && trimmed
                    .trim_start_matches(|c: char| c.is_ascii_digit())
                    .starts_with(". "));
        let target = if is_list_line {
            line_start..line_start
        } else {
            sel
        };
        KeystrokeDecision::SourceEdit {
            edit_range: target,
            replacement: "  ".to_string(),
            post_selection: None,
        }
    }
}

fn delete_range(edit_range: Range<usize>) -> KeystrokeDecision {
    KeystrokeDecision::SourceEdit {
        edit_range,
        replacement: String::new(),
        post_selection: None,
    }
}

fn span_decision(edit: SpanEdit) -> KeystrokeDecision {
    KeystrokeDecision::SourceEdit {
        edit_range: edit.replace_range,
        replacement: edit.replacement,
        post_selection: Some(edit.new_selection),
    }
}

const fn select_target(tail: usize, next_pos: usize, shift: bool) -> Range<usize> {
    if shift {
        tail..next_pos
    } else {
        next_pos..next_pos
    }
}
