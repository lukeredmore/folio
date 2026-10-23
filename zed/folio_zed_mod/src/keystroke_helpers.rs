use std::ops::Range;

use folio_engine::markdown::{compute_newline_continuation, NewlineAction};

use crate::keystroke_controller::KeystrokeDecision;

pub(crate) fn handle_enter_key(source: &str, sel: Range<usize>) -> KeystrokeDecision {
    let len = source.len();
    let line_start = source[..sel.start].rfind('\n').map_or(0, |idx| idx + 1);
    let line_up_to_cursor = &source[line_start..sel.start];
    match compute_newline_continuation(line_up_to_cursor) {
        NewlineAction::InsertPrefix(prefix) => KeystrokeDecision::SourceEdit {
            edit_range: sel,
            replacement: format!("\n{prefix}"),
            post_selection: None,
        },
        NewlineAction::ClearEmptyListLine => {
            let line_end = source[sel.end..]
                .find('\n')
                .map_or(len, |rel| sel.end + rel);
            KeystrokeDecision::SourceEdit {
                edit_range: line_start..line_end,
                replacement: String::new(),
                post_selection: None,
            }
        }
        NewlineAction::Default => KeystrokeDecision::SourceEdit {
            edit_range: sel,
            replacement: "\n".to_string(),
            post_selection: None,
        },
    }
}

pub(crate) fn handle_tab_key(source: &str, sel: Range<usize>, shift: bool) -> KeystrokeDecision {
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

pub(crate) fn vertical_or_horizontal_cursor(
    source: &str,
    sel: &Range<usize>,
    cursor: usize,
    key: &str,
    shift: bool,
) -> usize {
    let len = source.len();
    match key {
        "left" => {
            if !shift && sel.start < sel.end {
                sel.start
            } else if cursor > 0 {
                source[..cursor]
                    .char_indices()
                    .next_back()
                    .map_or(0, |(idx, _)| idx)
            } else {
                0
            }
        }
        "right" => {
            if !shift && sel.start < sel.end {
                sel.end
            } else if cursor < len {
                source[cursor..]
                    .chars()
                    .next()
                    .map_or(len, |ch| cursor + ch.len_utf8())
            } else {
                len
            }
        }
        "up" => {
            let line_start = source[..cursor].rfind('\n').map_or(0, |idx| idx + 1);
            let col = cursor - line_start;
            if line_start == 0 {
                0
            } else {
                let prev_line_end = line_start - 1;
                let prev_line_start = source[..prev_line_end].rfind('\n').map_or(0, |idx| idx + 1);
                let prev_len = prev_line_end - prev_line_start;
                let mut target = prev_line_start + col.min(prev_len);
                while target > prev_line_start && !source.is_char_boundary(target) {
                    target -= 1;
                }
                target
            }
        }
        "down" => {
            let line_start = source[..cursor].rfind('\n').map_or(0, |idx| idx + 1);
            let col = cursor - line_start;
            let line_end = source[cursor..].find('\n').map_or(len, |rel| cursor + rel);
            if line_end >= len {
                len
            } else {
                let next_line_start = line_end + 1;
                let next_line_end = source[next_line_start..]
                    .find('\n')
                    .map_or(len, |rel| next_line_start + rel);
                let next_len = next_line_end - next_line_start;
                let mut target = next_line_start + col.min(next_len);
                while target > next_line_start && !source.is_char_boundary(target) {
                    target -= 1;
                }
                target
            }
        }
        "home" => source[..cursor].rfind('\n').map_or(0, |idx| idx + 1),
        "end" => source[cursor..].find('\n').map_or(len, |rel| cursor + rel),
        _ => cursor,
    }
}
