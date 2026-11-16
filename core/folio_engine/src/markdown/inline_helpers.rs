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

fn is_xml_name_start(b: u8) -> bool {
    b.is_ascii_alphabetic() || b == b'_' || b == b':'
}

fn is_xml_name_char(b: u8) -> bool {
    b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b':' | b'.')
}

/// Finds the first boundary-matched XML/HTML attribute `attr_name` in `input`,
/// skipping tag names (`<svg`) and quoted attribute values so hyphenated attributes
/// like `stroke-width="1.5"` or quoted text like `alt="width=10"` never match `width`.
/// Returns `(attr_start, val_start, val_end, attr_end)`.
pub(crate) fn find_xml_attr_span(
    input: &str,
    attr_name: &str,
) -> Option<(usize, usize, usize, usize)> {
    let bytes = input.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        let b = bytes[i];
        if b == b'"' || b == b'\'' {
            let after_open = i + 1;
            i = input[after_open..]
                .find(b as char)
                .map_or(bytes.len(), |rel| after_open + rel + 1);
            continue;
        }
        if !is_xml_name_start(b) {
            i += 1;
            continue;
        }
        let name_start = i;
        while i < bytes.len() && is_xml_name_char(bytes[i]) {
            i += 1;
        }
        let name_end = i;
        if name_start > 0 && bytes[name_start - 1] == b'<' {
            continue;
        }
        while i < bytes.len() && bytes[i].is_ascii_whitespace() {
            i += 1;
        }
        if bytes.get(i) != Some(&b'=') {
            continue;
        }
        i += 1;
        while i < bytes.len() && bytes[i].is_ascii_whitespace() {
            i += 1;
        }
        if i >= bytes.len() {
            break;
        }
        let (val_start, val_end, attr_end) = if bytes[i] == b'"' || bytes[i] == b'\'' {
            let quote = bytes[i] as char;
            let vs = i + 1;
            let end_q = input[vs..].find(quote)?;
            (vs, vs + end_q, vs + end_q + 1)
        } else {
            let vs = i;
            let rel_end = input[vs..]
                .find(|c: char| c.is_whitespace() || matches!(c, '>' | '/' | '"' | '\''))
                .unwrap_or(bytes.len() - vs);
            if rel_end == 0 {
                continue;
            }
            (vs, vs + rel_end, vs + rel_end)
        };
        if input[name_start..name_end].eq_ignore_ascii_case(attr_name) {
            return Some((name_start, val_start, val_end, attr_end));
        }
        i = attr_end;
    }
    None
}

pub fn extract_xml_attr<'a>(input: &'a str, attr_name: &str) -> Option<&'a str> {
    let (_, val_start, val_end, _) = find_xml_attr_span(input, attr_name)?;
    Some(&input[val_start..val_end])
}

pub(crate) fn remove_xml_attr(tag: &str, attr_name: &str) -> String {
    let mut out = tag.to_string();
    while let Some((attr_start, _, _, attr_end)) = find_xml_attr_span(&out, attr_name) {
        let mut remove_start = attr_start;
        while remove_start > 0 && out.as_bytes()[remove_start - 1].is_ascii_whitespace() {
            remove_start -= 1;
        }
        out.replace_range(remove_start..attr_end, "");
    }
    out
}

pub(crate) fn set_xml_attr(tag: &str, attr_name: &str, val: &str) -> String {
    if let Some((attr_start, _, _, attr_end)) = find_xml_attr_span(tag, attr_name) {
        return format!(
            r#"{}{attr_name}="{val}"{}"#,
            &tag[..attr_start],
            &tag[attr_end..]
        );
    }
    let pos = if tag.ends_with("/>") {
        tag.len() - 2
    } else if tag.ends_with('>') {
        tag.len() - 1
    } else {
        tag.len()
    };
    format!(r#"{} {attr_name}="{val}"{}"#, &tag[..pos], &tag[pos..])
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

/// For each index, the nearest valid closing `$` at or after it (`usize::MAX` if none).
/// A closer follows non-space and is not followed by a digit or `$` (Pandoc `tex_math_dollars`).
pub(crate) fn inline_math_next_closers(bytes: &[u8]) -> Vec<usize> {
    let mut next = vec![usize::MAX; bytes.len() + 1];
    for idx in (0..bytes.len()).rev() {
        let is_closer = idx > 0
            && bytes[idx] == b'$'
            && !matches!(bytes[idx - 1], b'\\' | b'$')
            && !bytes[idx - 1].is_ascii_whitespace()
            && !bytes
                .get(idx + 1)
                .is_some_and(|b| b.is_ascii_digit() || *b == b'$');
        next[idx] = if is_closer { idx } else { next[idx + 1] };
    }
    next
}
