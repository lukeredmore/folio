use super::types::NewlineAction;

pub fn compute_newline_continuation(line_up_to_cursor: &str) -> NewlineAction {
    let bytes = line_up_to_cursor.as_bytes();
    let mut ws_end = 0;
    while ws_end < bytes.len() && (bytes[ws_end] == b' ' || bytes[ws_end] == b'\t') {
        ws_end += 1;
    }

    let after_ws = &line_up_to_cursor[ws_end..];

    // 1. Check unordered / task list: '-', '*', '+' followed by whitespace
    if let Some(first) = after_ws.chars().next() {
        if (first == '-' || first == '*' || first == '+')
            && after_ws[1..].starts_with([' ', '\t'])
        {
            return compute_unordered_or_task_newline(line_up_to_cursor, ws_end, after_ws);
        }
        // Check blockquote continuation: '>' followed by whitespace
        if first == '>' && after_ws[1..].starts_with([' ', '\t']) {
            let mut quote_ws_end = 1;
            let qb = after_ws.as_bytes();
            while quote_ws_end < qb.len()
                && (qb[quote_ws_end] == b' ' || qb[quote_ws_end] == b'\t')
            {
                quote_ws_end += 1;
            }
            let prefix_len = ws_end + quote_ws_end;
            let remainder = line_up_to_cursor[prefix_len..].trim();
            if remainder.is_empty() {
                return NewlineAction::ClearEmptyListLine;
            }
            return NewlineAction::InsertPrefix(line_up_to_cursor[..prefix_len].to_string());
        }
    }

    // 2. Check ordered list: digits + ("." or ")") + whitespace
    let mut digit_end = 0;
    let aw_bytes = after_ws.as_bytes();
    while digit_end < aw_bytes.len() && aw_bytes[digit_end].is_ascii_digit() {
        digit_end += 1;
    }
    if (1..=9).contains(&digit_end)
        && digit_end + 1 < aw_bytes.len()
        && (aw_bytes[digit_end] == b'.' || aw_bytes[digit_end] == b')')
    {
        let delim = aw_bytes[digit_end] as char;
        let after_dot = &after_ws[digit_end + 1..];
        if after_dot.starts_with([' ', '\t']) {
            let mut dot_ws_end = 0;
            let ad_bytes = after_dot.as_bytes();
            while dot_ws_end < ad_bytes.len()
                && (ad_bytes[dot_ws_end] == b' ' || ad_bytes[dot_ws_end] == b'\t')
            {
                dot_ws_end += 1;
            }
            let prefix_len = ws_end + digit_end + 1 + dot_ws_end;
            let remainder = line_up_to_cursor[prefix_len..].trim();
            if remainder.is_empty() {
                return NewlineAction::ClearEmptyListLine;
            }
            let leading_space = &line_up_to_cursor[..ws_end];
            let digits_str = &after_ws[..digit_end];
            let next_num = digits_str.parse::<usize>().unwrap_or(1) + 1;
            return NewlineAction::InsertPrefix(format!("{leading_space}{next_num}{delim} "));
        }
    }

    NewlineAction::Default
}

fn compute_unordered_or_task_newline(
    line_up_to_cursor: &str,
    ws_end: usize,
    after_ws: &str,
) -> NewlineAction {
    let mut bullet_ws_end = 1;
    let after_b = after_ws.as_bytes();
    while bullet_ws_end < after_b.len()
        && (after_b[bullet_ws_end] == b' ' || after_b[bullet_ws_end] == b'\t')
    {
        bullet_ws_end += 1;
    }

    let after_bullet = &after_ws[bullet_ws_end..];

    // Check task list: [ ], [x], [X] followed by whitespace
    if after_bullet.len() >= 4 {
        let box_part = &after_bullet[..3];
        if (box_part == "[ ]" || box_part == "[x]" || box_part == "[X]")
            && after_bullet[3..].starts_with([' ', '\t'])
        {
            let mut box_ws_end = 3;
            let ab_bytes = after_bullet.as_bytes();
            while box_ws_end < ab_bytes.len()
                && (ab_bytes[box_ws_end] == b' ' || ab_bytes[box_ws_end] == b'\t')
            {
                box_ws_end += 1;
            }
            let prefix_len = ws_end + bullet_ws_end + box_ws_end;
            let prefix = &line_up_to_cursor[..prefix_len];
            let remainder = line_up_to_cursor[prefix_len..].trim();
            if remainder.is_empty() {
                return NewlineAction::ClearEmptyListLine;
            }
            let unchecked = prefix.replace("[x]", "[ ]").replace("[X]", "[ ]");
            return NewlineAction::InsertPrefix(unchecked);
        }
    }

    // Regular unordered list
    let prefix_len = ws_end + bullet_ws_end;
    let prefix = &line_up_to_cursor[..prefix_len];
    let remainder = line_up_to_cursor[prefix_len..].trim();
    if remainder.is_empty() {
        return NewlineAction::ClearEmptyListLine;
    }
    NewlineAction::InsertPrefix(prefix.to_string())
}

/// Replaces the language identifier on a fenced code block opening line (` ```lang ` or ` ~~~lang `)
/// starting at `fence_start_byte_offset` in `text`, returning the updated document string.
pub fn replace_code_fence_language(
    text: &str,
    fence_start_byte_offset: usize,
    new_language: &str,
) -> Option<String> {
    if fence_start_byte_offset >= text.len() {
        return None;
    }
    let rest = &text[fence_start_byte_offset..];
    let line_len = rest.find('\n').unwrap_or(rest.len());
    let raw_line = &rest[..line_len];
    let content_line = raw_line.trim_end_matches('\r');

    let ws_len = content_line.len() - content_line.trim_start().len();
    let after_ws = &content_line[ws_len..];
    let fence_char = if after_ws.starts_with("```") {
        b'`'
    } else if after_ws.starts_with("~~~") {
        b'~'
    } else {
        return None;
    };
    let tick_count = after_ws.bytes().take_while(|&b| b == fence_char).count();
    let prefix = &content_line[..ws_len + tick_count];
    let normalized_lang = new_language.trim();

    let mut updated = String::with_capacity(text.len() + normalized_lang.len());
    updated.push_str(&text[..fence_start_byte_offset]);
    updated.push_str(prefix);
    updated.push_str(normalized_lang);
    updated.push_str(&raw_line[content_line.len()..]);
    updated.push_str(&rest[line_len..]);
    Some(updated)
}
