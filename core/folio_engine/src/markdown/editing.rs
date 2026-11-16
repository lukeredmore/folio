use std::ops::Range;

use super::newline::compute_newline_continuation;
use super::types::NewlineAction;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SpanEdit {
    pub replace_range: Range<usize>,
    pub replacement: String,
    pub new_selection: Range<usize>,
}

impl SpanEdit {
    #[must_use]
    pub fn is_noop(&self) -> bool {
        self.replace_range.is_empty() && self.replacement.is_empty()
    }

    #[must_use]
    pub fn apply(&self, text: &str) -> (String, Range<usize>) {
        let start = snap_boundary_left(text, self.replace_range.start);
        let end = snap_boundary_right(text, self.replace_range.end).max(start);
        let mut out =
            String::with_capacity(text.len().saturating_sub(end - start) + self.replacement.len());
        out.push_str(&text[..start]);
        out.push_str(&self.replacement);
        out.push_str(&text[end..]);
        (out, self.new_selection.clone())
    }
}

fn snap_boundary_left(text: &str, offset: usize) -> usize {
    let mut idx = offset.min(text.len());
    while idx > 0 && !text.is_char_boundary(idx) {
        idx -= 1;
    }
    idx
}

fn snap_boundary_right(text: &str, offset: usize) -> usize {
    let len = text.len();
    let mut idx = offset.min(len);
    while idx < len && !text.is_char_boundary(idx) {
        idx += 1;
    }
    idx
}

fn snap_selection(text: &str, selection: Range<usize>) -> Range<usize> {
    let start = snap_boundary_left(text, selection.start);
    let end = if selection.start == selection.end {
        start
    } else {
        snap_boundary_right(text, selection.end).max(start)
    };
    start..end
}

fn word_span_at(text: &str, cursor: usize, delimiter: &str) -> Option<(usize, usize)> {
    let is_word = |ch: char| ch.is_alphanumeric() || (ch == '_' && delimiter != "_");
    let before = text[..cursor].chars().next_back();
    let after = text[cursor..].chars().next();
    if !before.is_some_and(is_word) && !after.is_some_and(is_word) {
        return None;
    }
    let mut start = cursor;
    for (idx, ch) in text[..cursor].char_indices().rev() {
        if is_word(ch) {
            start = idx;
        } else {
            break;
        }
    }
    let mut end = cursor;
    for (rel, ch) in text[cursor..].char_indices() {
        if is_word(ch) {
            end = cursor + rel + ch.len_utf8();
        } else {
            break;
        }
    }
    (start < end).then_some((start, end))
}

#[must_use]
pub fn edit_newline(text: &str, selection: Range<usize>) -> SpanEdit {
    let sel = snap_selection(text, selection);
    let line_start = text[..sel.start].rfind('\n').map_or(0, |pos| pos + 1);
    let line_up_to_cursor = &text[line_start..sel.start];

    match compute_newline_continuation(line_up_to_cursor) {
        NewlineAction::Default => {
            let new_pos = sel.start + 1;
            SpanEdit {
                replace_range: sel,
                replacement: "\n".to_string(),
                new_selection: new_pos..new_pos,
            }
        }
        NewlineAction::ClearEmptyListLine => {
            let line_end = text[sel.end..]
                .find('\n')
                .map_or(text.len(), |rel| sel.end + rel);
            if line_end < text.len() {
                let content_end = if line_end > line_start && text.as_bytes()[line_end - 1] == b'\r'
                {
                    line_end - 1
                } else {
                    line_end
                };
                SpanEdit {
                    replace_range: line_start..content_end,
                    replacement: String::new(),
                    new_selection: line_start..line_start,
                }
            } else {
                let new_pos = line_start + 1;
                SpanEdit {
                    replace_range: line_start..line_end,
                    replacement: "\n".to_string(),
                    new_selection: new_pos..new_pos,
                }
            }
        }
        NewlineAction::InsertPrefix(prefix) => {
            let replacement = format!("\n{prefix}");
            let new_pos = sel.start + replacement.len();
            SpanEdit {
                replace_range: sel,
                replacement,
                new_selection: new_pos..new_pos,
            }
        }
    }
}

fn can_strip_surrounding_delimiter(
    text: &str,
    target_start: usize,
    target_end: usize,
    delimiter: &str,
) -> bool {
    let dlen = delimiter.len();
    let Some(before_start) = target_start.checked_sub(dlen) else {
        return false;
    };
    if text.get(before_start..target_start) != Some(delimiter)
        || text.get(target_end..(target_end + dlen)) != Some(delimiter)
    {
        return false;
    }
    if dlen == 1 {
        let ch = delimiter.as_bytes()[0];
        let before_count = text.as_bytes()[..target_start]
            .iter()
            .rev()
            .take_while(|&&b| b == ch)
            .count();
        let after_count = text.as_bytes()[target_end..]
            .iter()
            .take_while(|&&b| b == ch)
            .count();
        // Keep `**bold**` intact when toggling `*` so it wraps to `***bold***` instead of `*bold*`.
        return !(before_count == 2 && after_count == 2);
    }
    true
}

#[must_use]
pub fn edit_symmetric_delimiter(text: &str, selection: Range<usize>, delimiter: &str) -> SpanEdit {
    let sel = snap_selection(text, selection);
    let dlen = delimiter.len();
    if dlen == 0 {
        return SpanEdit {
            replace_range: sel.start..sel.start,
            replacement: String::new(),
            new_selection: sel,
        };
    }

    let (target_start, target_end) = if sel.start < sel.end {
        (sel.start, sel.end)
    } else if let Some(word) = word_span_at(text, sel.start, delimiter) {
        word
    } else {
        (sel.start, sel.end)
    };

    if can_strip_surrounding_delimiter(text, target_start, target_end, delimiter) {
        let inner = text[target_start..target_end].to_string();
        let new_start = target_start - dlen;
        let new_end = new_start + inner.len();
        let new_selection = if sel.start < sel.end {
            new_start..new_end
        } else {
            let pos = sel.start - dlen;
            pos..pos
        };
        return SpanEdit {
            replace_range: (target_start - dlen)..(target_end + dlen),
            replacement: inner,
            new_selection,
        };
    }

    let selected = &text[target_start..target_end];
    let doubled = format!("{delimiter}{delimiter}");
    let tripled = format!("{delimiter}{delimiter}{delimiter}");
    if selected.len() >= dlen * 2
        && selected.starts_with(delimiter)
        && selected.ends_with(delimiter)
        && (dlen != 1 || !selected.starts_with(&doubled) || selected.starts_with(&tripled))
    {
        let inner = selected[dlen..selected.len() - dlen].to_string();
        let new_end = target_start + inner.len();
        let new_selection = if sel.start < sel.end {
            target_start..new_end
        } else {
            let pos = sel.start.saturating_sub(dlen).clamp(target_start, new_end);
            pos..pos
        };
        return SpanEdit {
            replace_range: target_start..target_end,
            replacement: inner,
            new_selection,
        };
    }

    let replacement = format!("{delimiter}{selected}{delimiter}");
    let new_selection = if sel.start < sel.end {
        (target_start + dlen)..(target_end + dlen)
    } else {
        let pos = sel.start + dlen;
        pos..pos
    };
    SpanEdit {
        replace_range: target_start..target_end,
        replacement,
        new_selection,
    }
}

fn existing_heading_prefix(line: &str) -> (u8, usize) {
    let leading_ws = line.bytes().take_while(|&b| b == b' ').count().min(3);
    let after_ws = &line[leading_ws..];
    let hashes = after_ws.bytes().take_while(|&b| b == b'#').count();
    if (1..=6).contains(&hashes) {
        let spaces = after_ws[hashes..]
            .bytes()
            .take_while(|&b| b == b' ' || b == b'\t')
            .count();
        if spaces > 0 || after_ws.len() == hashes {
            return (hashes as u8, leading_ws + hashes + spaces);
        }
    }
    (0, 0)
}

fn edit_heading_impl(
    text: &str,
    selection: Range<usize>,
    level: u8,
    toggle_same_level: bool,
) -> SpanEdit {
    let sel = snap_selection(text, selection);
    let line_start = text[..sel.start].rfind('\n').map_or(0, |pos| pos + 1);
    let line_end = text[sel.start..]
        .find('\n')
        .map_or(text.len(), |rel| sel.start + rel);
    let line = &text[line_start..line_end];
    let (existing_level, old_prefix_len) = existing_heading_prefix(line);

    let target_level = if toggle_same_level && (1..=6).contains(&level) && existing_level == level {
        0
    } else if (1..=6).contains(&level) {
        level
    } else {
        0
    };
    let new_prefix = if target_level > 0 {
        format!("{} ", "#".repeat(usize::from(target_level)))
    } else {
        String::new()
    };
    if line[..old_prefix_len] == new_prefix {
        return SpanEdit {
            replace_range: sel.start..sel.start,
            replacement: String::new(),
            new_selection: sel,
        };
    }
    let new_prefix_len = new_prefix.len();

    let shift_pos = |pos: usize| -> usize {
        if pos <= line_start + old_prefix_len {
            line_start + new_prefix_len
        } else {
            pos - old_prefix_len + new_prefix_len
        }
    };
    let new_selection = shift_pos(sel.start)..shift_pos(sel.end);
    SpanEdit {
        replace_range: line_start..(line_start + old_prefix_len),
        replacement: new_prefix,
        new_selection,
    }
}

#[must_use]
pub fn edit_set_heading_level(text: &str, selection: Range<usize>, level: u8) -> SpanEdit {
    edit_heading_impl(text, selection, level, false)
}

#[must_use]
pub fn edit_toggle_heading_level(text: &str, selection: Range<usize>, level: u8) -> SpanEdit {
    edit_heading_impl(text, selection, level, true)
}

#[must_use]
pub fn edit_toggle_task_checkbox(text: &str, selection: Range<usize>) -> SpanEdit {
    let sel = snap_selection(text, selection);
    let line_start = text[..sel.start].rfind('\n').map_or(0, |pos| pos + 1);
    let line_end = text[sel.start..]
        .find('\n')
        .map_or(text.len(), |rel| sel.start + rel);
    let line = &text[line_start..line_end];

    let found = if let Some(idx) = line.find("[ ] ") {
        Some((idx, "[x]"))
    } else if let Some(idx) = line.find("[x] ").or_else(|| line.find("[X] ")) {
        Some((idx, "[ ]"))
    } else if line.ends_with("[ ]") && line.len() >= 5 {
        Some((line.len() - 3, "[x]"))
    } else if (line.ends_with("[x]") || line.ends_with("[X]")) && line.len() >= 5 {
        Some((line.len() - 3, "[ ]"))
    } else {
        None
    };

    if let Some((idx, new_box)) = found {
        let box_start = line_start + idx;
        SpanEdit {
            replace_range: box_start..(box_start + 3),
            replacement: new_box.to_string(),
            new_selection: sel,
        }
    } else {
        SpanEdit {
            replace_range: sel.start..sel.start,
            replacement: String::new(),
            new_selection: sel,
        }
    }
}

/// Applies smart Enter/Return continuation at `cursor_byte_offset` in `text`,
/// returning `(updated_text, new_cursor_byte_offset)`.
pub fn apply_newline_at_cursor(text: &str, cursor_byte_offset: usize) -> (String, usize) {
    let (updated, sel) = edit_newline(text, cursor_byte_offset..cursor_byte_offset).apply(text);
    (updated, sel.start)
}

/// Toggles a symmetric inline delimiter (`**`, `*`, `~~`, `==`, `` ` ``, `$`) around the word
/// at `cursor_byte_offset` (or inserts an empty delimiter pair on whitespace).
/// Returns `(updated_text, new_cursor_byte_offset)`.
pub fn toggle_symmetric_delimiter(
    text: &str,
    cursor_byte_offset: usize,
    delimiter: &str,
) -> (String, usize) {
    let (updated, sel) =
        edit_symmetric_delimiter(text, cursor_byte_offset..cursor_byte_offset, delimiter)
            .apply(text);
    (updated, sel.start)
}

/// Sets the ATX heading level (`1..=6`, or `0` to convert to plain paragraph) on the line
/// containing `cursor_byte_offset`. Returns `(updated_text, new_cursor_byte_offset)`.
pub fn set_heading_level_at_cursor(
    text: &str,
    cursor_byte_offset: usize,
    level: u8,
) -> (String, usize) {
    let (updated, sel) =
        edit_set_heading_level(text, cursor_byte_offset..cursor_byte_offset, level).apply(text);
    (updated, sel.start)
}

/// Toggles a GFM task list checkbox (`[ ]` <-> `[x]`) on the line containing `cursor_byte_offset`.
pub fn toggle_task_checkbox_at_cursor(text: &str, cursor_byte_offset: usize) -> (String, usize) {
    let (updated, sel) =
        edit_toggle_task_checkbox(text, cursor_byte_offset..cursor_byte_offset).apply(text);
    (updated, sel.start)
}
