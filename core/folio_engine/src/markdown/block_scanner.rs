pub(crate) fn count_leading_spaces(line: &str) -> usize {
    line.bytes().take_while(|&b| b == b' ').count()
}

pub(crate) fn parse_opening_code_fence(line: &str) -> Option<(u8, usize, String)> {
    let leading = count_leading_spaces(line);
    if leading > 3 {
        return None;
    }
    let rest = &line[leading..];
    let first = *rest.as_bytes().first()?;
    if first != b'`' && first != b'~' {
        return None;
    }
    let fence_len = rest.bytes().take_while(|&b| b == first).count();
    if fence_len < 3 {
        return None;
    }
    let info = rest[fence_len..].trim();
    // CommonMark §4.5: info strings for backtick code blocks cannot contain backticks
    if first == b'`' && info.contains('`') {
        return None;
    }
    let lang = info.split_whitespace().next().unwrap_or("").to_string();
    Some((first, fence_len, lang))
}

pub(crate) fn is_closing_code_fence(line: &str, fence_char: u8, min_len: usize) -> bool {
    let leading = count_leading_spaces(line);
    if leading > 3 {
        return false;
    }
    let rest = &line[leading..];
    let count = rest.bytes().take_while(|&b| b == fence_char).count();
    if count < min_len {
        return false;
    }
    rest[count..].bytes().all(|b| b == b' ' || b == b'\t')
}

/// Parses a CommonMark ATX heading line (`#`..`######` with up to 3 leading spaces and optional closing `#`s).
/// Returns `(level, prefix_byte_len, optional_closing_byte_start, trimmed_title)`.
pub(crate) fn parse_atx_heading_line(line: &str) -> Option<(usize, usize, Option<usize>, &str)> {
    let leading = count_leading_spaces(line);
    if leading > 3 {
        return None;
    }
    let bytes = line.as_bytes();
    let mut hashes = 0;
    while leading + hashes < bytes.len() && bytes[leading + hashes] == b'#' {
        hashes += 1;
    }
    if !(1..=6).contains(&hashes) {
        return None;
    }
    let after_hashes = leading + hashes;
    if after_hashes == bytes.len() {
        return Some((hashes, after_hashes, None, ""));
    }
    let mut spaces = 0;
    while after_hashes + spaces < bytes.len()
        && (bytes[after_hashes + spaces] == b' ' || bytes[after_hashes + spaces] == b'\t')
    {
        spaces += 1;
    }
    if spaces == 0 {
        return None;
    }
    let prefix_len = after_hashes + spaces;
    let remainder = &line[prefix_len..];

    // Check for optional closing '#' sequence (preceded by whitespace, followed only by optional whitespace)
    let trimmed_end = remainder.trim_end_matches(&[' ', '\t'][..]);
    let r_bytes = trimmed_end.as_bytes();
    let mut end_hashes = 0;
    while end_hashes < r_bytes.len() && r_bytes[r_bytes.len() - 1 - end_hashes] == b'#' {
        end_hashes += 1;
    }
    let (title_slice, closing_start) = if end_hashes > 0 {
        let before_closing = r_bytes.len() - end_hashes;
        if before_closing == 0 {
            ("", Some(prefix_len))
        } else if r_bytes[before_closing - 1] == b' ' || r_bytes[before_closing - 1] == b'\t' {
            let mut ws_start = before_closing;
            while ws_start > 0 && (r_bytes[ws_start - 1] == b' ' || r_bytes[ws_start - 1] == b'\t')
            {
                ws_start -= 1;
            }
            (&trimmed_end[..ws_start], Some(prefix_len + ws_start))
        } else {
            (trimmed_end, None)
        }
    } else {
        (trimmed_end, None)
    };

    Some((hashes, prefix_len, closing_start, title_slice.trim()))
}

pub(crate) fn parse_setext_underline(line: &str) -> Option<usize> {
    let leading = count_leading_spaces(line);
    if leading > 3 {
        return None;
    }
    let trimmed = line[leading..].trim_end_matches(&[' ', '\t'][..]);
    if trimmed.is_empty() {
        return None;
    }
    if trimmed.bytes().all(|b| b == b'=') {
        Some(1)
    } else if trimmed.bytes().all(|b| b == b'-') && trimmed.len() >= 2 {
        Some(2)
    } else {
        None
    }
}

pub(crate) fn is_list_item_line(line: &str) -> bool {
    let trimmed = line.trim_start_matches(&[' ', '\t'][..]);
    let bytes = trimmed.as_bytes();
    if bytes.len() >= 2
        && (bytes[0] == b'-' || bytes[0] == b'*' || bytes[0] == b'+')
        && (bytes[1] == b' ' || bytes[1] == b'\t')
    {
        return true;
    }
    let digits = bytes.iter().take_while(|b| b.is_ascii_digit()).count();
    if (1..=9).contains(&digits)
        && bytes.len() > digits + 1
        && (bytes[digits] == b'.' || bytes[digits] == b')')
        && (bytes[digits + 1] == b' ' || bytes[digits + 1] == b'\t')
    {
        return true;
    }
    false
}

pub(crate) fn parse_blockquote_line(line: &str) -> Option<(usize, usize)> {
    let leading = count_leading_spaces(line);
    if leading > 3 {
        return None;
    }
    let bytes = line.as_bytes();
    let mut i = leading;
    let mut nest = 0;
    while i < bytes.len() {
        if bytes[i] == b'>' {
            nest += 1;
            i += 1;
            if i < bytes.len() && (bytes[i] == b' ' || bytes[i] == b'\t') {
                i += 1;
            }
        } else if nest > 0 && (bytes[i] == b' ' || bytes[i] == b'\t') {
            i += 1;
        } else {
            break;
        }
    }
    if nest > 0 {
        Some((nest, i))
    } else {
        None
    }
}

pub(crate) fn is_horizontal_rule(line: &str) -> bool {
    let leading = count_leading_spaces(line);
    if leading > 3 {
        return false;
    }
    let trimmed = line[leading..].trim();
    if trimmed.len() < 3 {
        return false;
    }
    let check_marker = |marker: char| -> bool {
        let count = trimmed.chars().filter(|&c| c == marker).count();
        count >= 3 && trimmed.chars().all(|c| c == marker || c == ' ' || c == '\t')
    };
    check_marker('-') || check_marker('*') || check_marker('_')
}
