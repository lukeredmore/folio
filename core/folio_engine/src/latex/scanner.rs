/// Builds a lookup table mapping every byte offset `0..=text.len()` to its UTF-16 code unit offset.
pub fn build_byte_to_utf16_table(text: &str) -> Vec<usize> {
    let mut table = vec![0usize; text.len() + 1];
    let mut u16_pos = 0usize;
    for (byte_idx, ch) in text.char_indices() {
        table[byte_idx] = u16_pos;
        let ch_bytes = ch.len_utf8();
        let ch_u16 = ch.len_utf16();
        for b in 1..ch_bytes {
            table[byte_idx + b] = u16_pos;
        }
        u16_pos += ch_u16;
    }
    table[text.len()] = u16_pos;
    table
}

/// Finds the byte index of the first unescaped `%` comment character in `line`.
pub fn find_unescaped_percent_byte(line: &str) -> Option<usize> {
    let bytes = line.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' {
            let mut backslashes = 0usize;
            let mut p = i;
            while p > 0 && bytes[p - 1] == b'\\' {
                backslashes += 1;
                p -= 1;
            }
            if backslashes.is_multiple_of(2) {
                return Some(i);
            }
        }
        i += 1;
    }
    None
}

/// Skips horizontal ASCII whitespace (`' '` and `'\t'`) starting at `pos`.
pub fn skip_hspace(bytes: &[u8], mut pos: usize) -> usize {
    while pos < bytes.len() && (bytes[pos] == b' ' || bytes[pos] == b'\t') {
        pos += 1;
    }
    pos
}

/// Skips all ASCII whitespace starting at `pos`.
pub fn skip_ascii_ws(bytes: &[u8], mut pos: usize) -> usize {
    while pos < bytes.len() && bytes[pos].is_ascii_whitespace() {
        pos += 1;
    }
    pos
}

/// Reads an ASCII alphabetic control word after a leading `\` at `backslash_pos`.
/// Returns `(cmd_without_slash, end_byte)`.
pub fn read_control_word(text: &str, backslash_pos: usize) -> Option<(&str, usize)> {
    let bytes = text.as_bytes();
    if backslash_pos >= bytes.len() || bytes[backslash_pos] != b'\\' {
        return None;
    }
    let start = backslash_pos + 1;
    let mut end = start;
    while end < bytes.len() && bytes[end].is_ascii_alphabetic() {
        end += 1;
    }
    if end > start {
        Some((&text[start..end], end))
    } else {
        None
    }
}

/// Reads an ASCII alphabetic or `@` control word after `\` at `backslash_pos`.
pub fn read_control_word_with_at(text: &str, backslash_pos: usize) -> Option<(&str, usize)> {
    let bytes = text.as_bytes();
    if backslash_pos >= bytes.len() || bytes[backslash_pos] != b'\\' {
        return None;
    }
    let start = backslash_pos + 1;
    let mut end = start;
    while end < bytes.len() && (bytes[end].is_ascii_alphabetic() || bytes[end] == b'@') {
        end += 1;
    }
    if end > start {
        Some((&text[start..end], end))
    } else {
        None
    }
}

/// Reads a balanced `{...}` group starting at `open_brace_pos` (where `bytes[open_brace_pos] == b'{'`).
/// Returns `(inner_start_byte, inner_end_byte, after_close_byte)`.
pub fn read_balanced_braces(bytes: &[u8], open_brace_pos: usize) -> Option<(usize, usize, usize)> {
    if open_brace_pos >= bytes.len() || bytes[open_brace_pos] != b'{' {
        return None;
    }
    let mut depth = 1usize;
    let mut i = open_brace_pos + 1;
    while i < bytes.len() {
        if bytes[i] == b'\\' {
            i += 2;
            continue;
        }
        if bytes[i] == b'{' {
            depth += 1;
        } else if bytes[i] == b'}' {
            depth -= 1;
            if depth == 0 {
                return Some((open_brace_pos + 1, i, i + 1));
            }
        }
        i += 1;
    }
    None
}

/// Reads a `[...]` optional argument starting at `open_bracket_pos`.
/// Returns `(inner_start_byte, inner_end_byte, after_close_byte)`.
pub fn read_bracket_group(bytes: &[u8], open_bracket_pos: usize) -> Option<(usize, usize, usize)> {
    if open_bracket_pos >= bytes.len() || bytes[open_bracket_pos] != b'[' {
        return None;
    }
    let mut i = open_bracket_pos + 1;
    while i < bytes.len() {
        if bytes[i] == b'\\' {
            i += 2;
            continue;
        }
        if bytes[i] == b']' {
            return Some((open_bracket_pos + 1, i, i + 1));
        }
        i += 1;
    }
    None
}

/// Cleans TeX inline wrappers (`\textbf{...}`, `\LaTeX{}`, quotes, dashes, escaped chars) into plain text.
pub fn clean_tex_inline_text(raw: &str) -> String {
    let mut s = raw.to_string();
    let wrappers = [
        "\\textbf{",
        "\\textit{",
        "\\emph{",
        "\\texttt{",
        "\\textsc{",
        "\\underline{",
    ];
    for w in wrappers {
        while let Some(pos) = s.find(w) {
            s.replace_range(pos..(pos + w.len()), "");
            if let Some(last_brace) = s.rfind('}') {
                s.remove(last_brace);
            }
        }
    }
    s = s
        .replace("\\LaTeX{}", "LaTeX")
        .replace("\\LaTeX", "LaTeX")
        .replace("\\TeX{}", "TeX")
        .replace("\\TeX", "TeX")
        .replace("\\&", "&")
        .replace("\\%", "%")
        .replace("\\_", "_")
        .replace("\\#", "#")
        .replace("\\$", "$")
        .replace('~', " ")
        .replace("---", "—")
        .replace("--", "–")
        .replace("``", "“")
        .replace("''", "”");
    s.trim().to_string()
}
