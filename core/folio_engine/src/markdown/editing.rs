use super::newline::compute_newline_continuation;
use super::types::NewlineAction;

/// Applies smart Enter/Return continuation at `cursor_byte_offset` in `text`,
/// returning `(updated_text, new_cursor_byte_offset)`.
pub fn apply_newline_at_cursor(text: &str, cursor_byte_offset: usize) -> (String, usize) {
    let cursor = cursor_byte_offset.min(text.len());
    let line_start = text[..cursor].rfind('\n').map_or(0, |pos| pos + 1);
    let line_up_to_cursor = &text[line_start..cursor];

    match compute_newline_continuation(line_up_to_cursor) {
        NewlineAction::Default => {
            let mut out = String::with_capacity(text.len() + 1);
            out.push_str(&text[..cursor]);
            out.push('\n');
            out.push_str(&text[cursor..]);
            (out, cursor + 1)
        }
        NewlineAction::ClearEmptyListLine => {
            let line_end = text[cursor..]
                .find('\n')
                .map_or(text.len(), |rel| cursor + rel);
            let mut out = String::with_capacity(text.len().saturating_add(1));
            out.push_str(&text[..line_start]);
            out.push('\n');
            out.push_str(&text[line_end..]);
            (out, line_start + 1)
        }
        NewlineAction::InsertPrefix(prefix) => {
            let mut out = String::with_capacity(text.len() + 1 + prefix.len());
            out.push_str(&text[..cursor]);
            out.push('\n');
            out.push_str(&prefix);
            out.push_str(&text[cursor..]);
            (out, cursor + 1 + prefix.len())
        }
    }
}

/// Toggles a symmetric inline delimiter (`**`, `*`, `~~`, `==`, `` ` ``, `$`) around the word
/// at `cursor_byte_offset` (or inserts an empty delimiter pair on whitespace).
/// Returns `(updated_text, new_cursor_byte_offset)`.
pub fn toggle_symmetric_delimiter(
    text: &str,
    cursor_byte_offset: usize,
    delimiter: &str,
) -> (String, usize) {
    let cursor = cursor_byte_offset.min(text.len());
    let dlen = delimiter.len();
    if dlen == 0 {
        return (text.to_string(), cursor);
    }

    let bytes = text.as_bytes();
    let mut word_start = cursor;
    while word_start > 0 && bytes[word_start - 1].is_ascii_alphanumeric() {
        word_start -= 1;
    }
    let mut word_end = cursor;
    while word_end < bytes.len() && bytes[word_end].is_ascii_alphanumeric() {
        word_end += 1;
    }

    // Empty word at cursor: toggle empty pair or insert empty pair
    if word_start == word_end {
        if cursor >= dlen
            && cursor + dlen <= text.len()
            && &text[cursor - dlen..cursor] == delimiter
            && &text[cursor..cursor + dlen] == delimiter
        {
            let mut out = String::with_capacity(text.len() - dlen * 2);
            out.push_str(&text[..cursor - dlen]);
            out.push_str(&text[cursor + dlen..]);
            return (out, cursor - dlen);
        }
        let mut out = String::with_capacity(text.len() + dlen * 2);
        out.push_str(&text[..cursor]);
        out.push_str(delimiter);
        out.push_str(delimiter);
        out.push_str(&text[cursor..]);
        return (out, cursor + dlen);
    }

    // Word already surrounded by `delimiter` -> unwrap it
    if word_start >= dlen
        && word_end + dlen <= text.len()
        && &text[word_start - dlen..word_start] == delimiter
        && &text[word_end..word_end + dlen] == delimiter
    {
        let mut out = String::with_capacity(text.len() - dlen * 2);
        out.push_str(&text[..word_start - dlen]);
        out.push_str(&text[word_start..word_end]);
        out.push_str(&text[word_end + dlen..]);
        return (out, cursor - dlen);
    }

    // Otherwise wrap `word_start..word_end` with `delimiter`
    let mut out = String::with_capacity(text.len() + dlen * 2);
    out.push_str(&text[..word_start]);
    out.push_str(delimiter);
    out.push_str(&text[word_start..word_end]);
    out.push_str(delimiter);
    out.push_str(&text[word_end..]);
    (out, cursor + dlen)
}

/// Sets the ATX heading level (`1..=6`, or `0` to convert to plain paragraph) on the line
/// containing `cursor_byte_offset`. Returns `(updated_text, new_cursor_byte_offset)`.
pub fn set_heading_level_at_cursor(
    text: &str,
    cursor_byte_offset: usize,
    level: u8,
) -> (String, usize) {
    let cursor = cursor_byte_offset.min(text.len());
    let line_start = text[..cursor].rfind('\n').map_or(0, |pos| pos + 1);
    let line_end = text[cursor..]
        .find('\n')
        .map_or(text.len(), |rel| cursor + rel);
    let line = &text[line_start..line_end];

    let leading_ws = line.bytes().take_while(|&b| b == b' ').count().min(3);
    let after_ws = &line[leading_ws..];
    let hashes = after_ws.bytes().take_while(|&b| b == b'#').count();
    let old_prefix_len = if (1..=6).contains(&hashes) {
        let spaces = after_ws[hashes..]
            .bytes()
            .take_while(|&b| b == b' ' || b == b'\t')
            .count();
        if spaces > 0 || after_ws.len() == hashes {
            leading_ws + hashes + spaces
        } else {
            0
        }
    } else {
        0
    };

    let content = &line[old_prefix_len..];
    let new_prefix = if (1..=6).contains(&level) {
        format!("{} ", "#".repeat(usize::from(level)))
    } else {
        String::new()
    };

    let mut out = String::with_capacity(text.len() + new_prefix.len());
    out.push_str(&text[..line_start]);
    out.push_str(&new_prefix);
    out.push_str(content);
    out.push_str(&text[line_end..]);

    let cursor_in_line = cursor - line_start;
    let new_cursor_in_line = if cursor_in_line <= old_prefix_len {
        new_prefix.len()
    } else {
        cursor_in_line - old_prefix_len + new_prefix.len()
    };
    (out, line_start + new_cursor_in_line)
}

/// Toggles a GFM task list checkbox (`[ ]` <-> `[x]`) on the line containing `cursor_byte_offset`.
pub fn toggle_task_checkbox_at_cursor(text: &str, cursor_byte_offset: usize) -> (String, usize) {
    let cursor = cursor_byte_offset.min(text.len());
    let line_start = text[..cursor].rfind('\n').map_or(0, |pos| pos + 1);
    let line_end = text[cursor..]
        .find('\n')
        .map_or(text.len(), |rel| cursor + rel);
    let line = &text[line_start..line_end];

    let updated_line = if let Some(idx) = line.find("[ ] ") {
        let mut s = line.to_string();
        s.replace_range(idx..idx + 3, "[x]");
        s
    } else if let Some(idx) = line.find("[x] ").or_else(|| line.find("[X] ")) {
        let mut s = line.to_string();
        s.replace_range(idx..idx + 3, "[ ]");
        s
    } else {
        return (text.to_string(), cursor);
    };

    let mut out = String::with_capacity(text.len());
    out.push_str(&text[..line_start]);
    out.push_str(&updated_line);
    out.push_str(&text[line_end..]);
    (out, cursor)
}
