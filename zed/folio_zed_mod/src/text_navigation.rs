use std::ops::Range;

/// Snap `offset` left to the nearest valid UTF-8 character boundary in `source`.
#[must_use]
pub fn snap_char_boundary_left(source: &str, offset: usize) -> usize {
    let mut idx = offset.min(source.len());
    while idx > 0 && !source.is_char_boundary(idx) {
        idx -= 1;
    }
    idx
}

/// Snap `offset` right to the nearest valid UTF-8 character boundary in `source`.
#[must_use]
pub fn snap_char_boundary_right(source: &str, offset: usize) -> usize {
    let len = source.len();
    let mut idx = offset.min(len);
    while idx < len && !source.is_char_boundary(idx) {
        idx += 1;
    }
    idx
}

/// Find the alphanumeric/underscore word range `(start, end)` surrounding `offset`.
#[must_use]
pub fn word_range_at(source: &str, offset: usize) -> Option<(usize, usize)> {
    if source.is_empty() || offset > source.len() {
        return None;
    }
    let offset = snap_char_boundary_left(source, offset);
    let is_word_char = |c: char| c.is_alphanumeric() || c == '_';
    let before = source[..offset].chars().next_back();
    let after = source[offset..].chars().next();
    if !before.is_some_and(is_word_char) && !after.is_some_and(is_word_char) {
        return None;
    }
    let mut start = offset;
    for (idx, ch) in source[..offset].char_indices().rev() {
        if is_word_char(ch) {
            start = idx;
        } else {
            break;
        }
    }
    let mut end = offset;
    for (rel_idx, ch) in source[offset..].char_indices() {
        if is_word_char(ch) {
            end = offset + rel_idx + ch.len_utf8();
        } else {
            break;
        }
    }
    (start < end).then_some((start, end))
}

/// Compute the previous word boundary before `cursor` (for `Alt+Left` / `Alt+Backspace`).
#[must_use]
pub fn prev_word_boundary(source: &str, cursor: usize) -> usize {
    let cursor = snap_char_boundary_left(source, cursor);
    if cursor == 0 {
        return 0;
    }
    let is_word = |c: char| c.is_alphanumeric() || c == '_';
    let mut idx = cursor;
    for (pos, ch) in source[..cursor].char_indices().rev() {
        if ch == '\n' {
            return if idx == cursor { pos } else { idx };
        }
        if !ch.is_whitespace() {
            idx = pos + ch.len_utf8();
            break;
        }
        idx = pos;
    }
    let prev_ch = source[..idx].chars().next_back();
    let target_is_word = prev_ch.is_some_and(is_word);
    for (pos, ch) in source[..idx].char_indices().rev() {
        if ch.is_whitespace() || is_word(ch) != target_is_word {
            return pos + ch.len_utf8();
        }
    }
    0
}

/// Compute the next word boundary after `cursor` (for `Alt+Right`).
#[must_use]
pub fn next_word_boundary(source: &str, cursor: usize) -> usize {
    let len = source.len();
    let cursor = snap_char_boundary_left(source, cursor);
    if cursor >= len {
        return len;
    }
    let is_word = |c: char| c.is_alphanumeric() || c == '_';
    let mut idx = cursor;
    for (rel, ch) in source[cursor..].char_indices() {
        let pos = cursor + rel;
        if ch == '\n' {
            return if idx == cursor { pos + 1 } else { pos };
        }
        if !ch.is_whitespace() {
            idx = pos;
            break;
        }
        idx = pos + ch.len_utf8();
    }
    if idx >= len {
        return len;
    }
    let first_ch = source[idx..].chars().next();
    let target_is_word = first_ch.is_some_and(is_word);
    for (rel, ch) in source[idx..].char_indices() {
        let pos = idx + rel;
        if ch.is_whitespace() || is_word(ch) != target_is_word {
            return pos;
        }
    }
    len
}

/// Locate the opening and closing backtick delimiter byte ranges around an inline code span's content range.
#[must_use]
pub fn surrounding_code_span_delimiters(
    source: &str,
    content_range: &Range<usize>,
) -> Option<(Range<usize>, Range<usize>)> {
    let bytes = source.as_bytes();
    if content_range.start > bytes.len() || content_range.end > bytes.len() {
        return None;
    }
    let mut open_start = content_range.start;
    if open_start > 0
        && content_range.end < bytes.len()
        && bytes[open_start - 1] == b' '
        && bytes[content_range.end] == b' '
        && open_start >= 2
        && bytes[open_start - 2] == b'`'
    {
        open_start -= 1;
    }
    while open_start > 0 && bytes[open_start - 1] == b'`' {
        open_start -= 1;
    }
    if open_start == content_range.start {
        return None;
    }
    let mut close_end = content_range.end;
    if close_end < bytes.len()
        && bytes[close_end] == b' '
        && close_end + 1 < bytes.len()
        && bytes[close_end + 1] == b'`'
    {
        close_end += 1;
    }
    let ticks_start = close_end;
    while close_end < bytes.len() && bytes[close_end] == b'`' {
        close_end += 1;
    }
    if close_end == ticks_start {
        return None;
    }
    Some((
        open_start..content_range.start,
        content_range.end..close_end,
    ))
}

/// Percent-decode a URL/data-URI payload string (`%XX` hex sequences).
#[must_use]
pub fn percent_decode_str(input: &str) -> String {
    let bytes = input.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let (Some(hi), Some(lo)) = (
                (bytes[i + 1] as char).to_digit(16),
                (bytes[i + 2] as char).to_digit(16),
            ) {
                if let Ok(byte) = u8::try_from((hi << 4) | lo) {
                    out.push(byte);
                    i += 3;
                    continue;
                }
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8(out).unwrap_or_else(|_| input.to_string())
}

/// Extract an HTML attribute value (quoted or unquoted) from a raw HTML tag string.
#[must_use]
pub fn extract_html_attr(tag: &str, attr_name: &str) -> Option<String> {
    let lower = tag.to_ascii_lowercase();
    let needle = format!("{attr_name}=");
    let start_idx = lower.find(&needle)?;
    let after = tag[start_idx + needle.len()..].trim_start();
    if let Some(quoted) = after.strip_prefix('"') {
        let end = quoted.find('"')?;
        Some(quoted[..end].to_string())
    } else if let Some(quoted) = after.strip_prefix('\'') {
        let end = quoted.find('\'')?;
        Some(quoted[..end].to_string())
    } else {
        let end = after
            .find(|c: char| c.is_whitespace() || c == '>' || c == '/')
            .unwrap_or(after.len());
        (end > 0).then(|| after[..end].to_string())
    }
}
