use super::types::SyntaxTokenKind;

pub(crate) fn detect_emphasis_marker(bytes: &[u8], i: usize) -> Option<(usize, SyntaxTokenKind)> {
    let b0 = bytes[i];
    if !matches!(b0, b'*' | b'_' | b'~' | b'=') {
        return None;
    }
    if b0 == b'_' && i > 0 && bytes[i - 1].is_ascii_alphanumeric() {
        return None;
    }
    if i + 3 < bytes.len()
        && (b0 == b'*' || b0 == b'_')
        && bytes[i + 1] == b0
        && bytes[i + 2] == b0
        && !matches!(bytes[i + 3], b' ' | b'\t')
    {
        Some((3, SyntaxTokenKind::BoldMarker))
    } else if i + 2 < bytes.len()
        && bytes[i + 1] == b0
        && bytes[i + 2] != b0
        && !matches!(bytes[i + 2], b' ' | b'\t')
    {
        let k = match b0 {
            b'*' | b'_' => SyntaxTokenKind::BoldMarker,
            b'~' => SyntaxTokenKind::StrikethroughMarker,
            _ => SyntaxTokenKind::HighlightMarker,
        };
        Some((2, k))
    } else if (b0 == b'*' || b0 == b'_')
        && i + 1 < bytes.len()
        && bytes[i + 1] != b0
        && !matches!(bytes[i + 1], b' ' | b'\t')
    {
        Some((1, SyntaxTokenKind::ItalicMarker))
    } else {
        None
    }
}

pub(crate) fn is_ascii_punctuation_byte(b: u8) -> bool {
    matches!(
        b,
        b'!' | b'"'
            | b'#'
            | b'$'
            | b'%'
            | b'&'
            | b'\''
            | b'('
            | b')'
            | b'*'
            | b'+'
            | b','
            | b'-'
            | b'.'
            | b'/'
            | b':'
            | b';'
            | b'<'
            | b'='
            | b'>'
            | b'?'
            | b'@'
            | b'['
            | b'\\'
            | b']'
            | b'^'
            | b'_'
            | b'`'
            | b'{'
            | b'|'
            | b'}'
            | b'~'
    )
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum ClosingSearch {
    Found(usize),
    /// Stopped at another identical opener; a later search may still succeed.
    Blocked,
    /// Reached the end of the slice with no closer.
    Exhausted,
}

fn emphasis_marker_slot(marker: &str) -> usize {
    match marker {
        "*" => 0,
        "_" => 1,
        "**" => 2,
        "__" => 3,
        "***" => 4,
        "___" => 5,
        "~~" => 6,
        _ => 7,
    }
}

/// Finds the closing `marker` for an opener whose content starts at `from` in `line`.
/// Once a search for a marker reaches the end of the line with no closer, later searches for
/// that marker on the same line also fail, so they are skipped. This keeps lines with many
/// unmatched openers (e.g. `**a **a **a`) linear instead of quadratic.
pub(crate) fn find_closing_marker_cached(
    line: &str,
    from: usize,
    marker: &str,
    exhausted_from: &mut [usize; 8],
) -> Option<usize> {
    let slot = emphasis_marker_slot(marker);
    if from >= exhausted_from[slot] {
        return None;
    }
    match search_closing_marker(&line[from..], marker) {
        ClosingSearch::Found(rel) => Some(rel),
        ClosingSearch::Blocked => None,
        ClosingSearch::Exhausted => {
            exhausted_from[slot] = exhausted_from[slot].min(from);
            None
        }
    }
}

pub(crate) fn search_closing_marker(slice: &str, marker: &str) -> ClosingSearch {
    let bytes = slice.as_bytes();
    let mbytes = marker.as_bytes();
    let mlen = mbytes.len();
    let mut i = 0;
    let mut failed_tick_mask: u64 = 0;

    while i + mlen <= bytes.len() {
        if bytes[i] == b'\\' {
            i += 2;
            continue;
        }
        if bytes[i] == b'`' {
            i = skip_code_span_in_search(bytes, i, &mut failed_tick_mask);
            continue;
        }

        if &bytes[i..i + mlen] == mbytes {
            // For single-char emphasis (* or _), ensure it isn't part of a double marker (** or __)
            if mlen == 1 && i + 1 < bytes.len() && bytes[i + 1] == mbytes[0] {
                i += 2;
                continue;
            }
            if i == 0 || bytes[i - 1] == b' ' || bytes[i - 1] == b'\t' {
                if i > 0
                    && i + mlen < bytes.len()
                    && bytes[i + mlen] != b' '
                    && bytes[i + mlen] != b'\t'
                    && bytes[i + mlen] != mbytes[0]
                {
                    return ClosingSearch::Blocked;
                }
                i += 1;
                continue;
            }
            if mbytes[0] == b'_'
                && i + mlen < bytes.len()
                && bytes[i + mlen].is_ascii_alphanumeric()
            {
                i += 1;
                continue;
            }
            return ClosingSearch::Found(i);
        }
        i += 1;
    }
    ClosingSearch::Exhausted
}

fn skip_code_span_in_search(bytes: &[u8], mut i: usize, failed_tick_mask: &mut u64) -> usize {
    let mut tick_len = 0;
    while i < bytes.len() && bytes[i] == b'`' {
        tick_len += 1;
        i += 1;
    }
    if tick_len < 64 && (*failed_tick_mask & (1u64 << tick_len)) != 0 {
        return i;
    }
    let after_open = i;
    let mut found_close = false;
    while i < bytes.len() {
        if bytes[i] == b'`' {
            let mut c_len = 0;
            while i < bytes.len() && bytes[i] == b'`' {
                c_len += 1;
                i += 1;
            }
            if c_len == tick_len {
                found_close = true;
                break;
            }
        } else {
            i += 1;
        }
    }
    if !found_close {
        if tick_len < 64 {
            *failed_tick_mask |= 1u64 << tick_len;
        }
        return after_open;
    }
    i
}

/// For each `(` in `bytes`, the index of its matching `)` (`usize::MAX` when unmatched or not
/// a `(`). Backslash escapes are skipped.
pub(crate) fn match_parens(bytes: &[u8]) -> Vec<usize> {
    let mut matches = vec![usize::MAX; bytes.len()];
    let mut stack: Vec<usize> = Vec::new();
    let mut i = 0;
    while i < bytes.len() {
        match bytes[i] {
            b'\\' => {
                i += 2;
                continue;
            }
            b'(' => stack.push(i),
            b')' => {
                if let Some(open) = stack.pop() {
                    matches[open] = i;
                }
            }
            _ => {}
        }
        i += 1;
    }
    matches
}

pub(crate) fn parse_markdown_link_dest_and_title(raw: &str) -> (String, Option<String>) {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return (String::new(), None);
    }
    if let Some(after_angle) = trimmed.strip_prefix('<') {
        if let Some(close_angle) = after_angle.find('>') {
            let url = after_angle[..close_angle].to_string();
            let title = parse_optional_link_title(after_angle[close_angle + 1..].trim());
            return (url, title);
        }
    }
    if let Some(ws_idx) = trimmed.find(char::is_whitespace) {
        (
            trimmed[..ws_idx].to_string(),
            parse_optional_link_title(trimmed[ws_idx..].trim()),
        )
    } else {
        (trimmed.to_string(), None)
    }
}

fn parse_optional_link_title(rest: &str) -> Option<String> {
    (rest.len() >= 2
        && ((rest.starts_with('"') && rest.ends_with('"'))
            || (rest.starts_with('\'') && rest.ends_with('\''))
            || (rest.starts_with('(') && rest.ends_with(')'))))
    .then(|| rest[1..rest.len() - 1].to_string())
}

pub(crate) fn extract_html_attr(attrs: &str, name: &str) -> Option<String> {
    let lower = attrs.to_ascii_lowercase();
    let pat_eq = format!("{}=", name.to_ascii_lowercase());
    let mut search_from = 0usize;
    while let Some(rel) = lower[search_from..].find(&pat_eq) {
        let pos = search_from + rel;
        let valid_prefix = pos == 0
            || lower.as_bytes()[pos - 1].is_ascii_whitespace()
            || lower.as_bytes()[pos - 1] == b'/';
        let val_start = pos + pat_eq.len();
        if valid_prefix && val_start < attrs.len() {
            let rest = attrs[val_start..].trim_start();
            if let Some(stripped) = rest.strip_prefix('"') {
                if let Some(end_q) = stripped.find('"') {
                    return Some(stripped[..end_q].to_string());
                }
            } else if let Some(stripped) = rest.strip_prefix('\'') {
                if let Some(end_q) = stripped.find('\'') {
                    return Some(stripped[..end_q].to_string());
                }
            } else {
                let end = rest
                    .find(|c: char| c.is_whitespace() || c == '/' || c == '>')
                    .unwrap_or(rest.len());
                if end > 0 {
                    return Some(rest[..end].to_string());
                }
            }
        }
        search_from = val_start;
    }
    None
}

pub(crate) fn find_paren_close(bytes: &[u8], start_idx: usize) -> Option<usize> {
    let mut p_depth = 1usize;
    let mut p_idx = start_idx;
    while p_idx < bytes.len() {
        if bytes[p_idx] == b'\\' {
            p_idx += 2;
            continue;
        }
        if bytes[p_idx] == b'(' {
            p_depth += 1;
        } else if bytes[p_idx] == b')' {
            p_depth -= 1;
            if p_depth == 0 {
                return Some(p_idx);
            }
        }
        p_idx += 1;
    }
    None
}
