//! Protected inline span scanners for paragraph reflow (`split_words`).
//!
//! Ensures inline code spans, math spans, links, inline HTML, and short emphasis spans
//! are never broken across lines during hard-wrap reflow.

/// Splits paragraph text into words at unprotected whitespace. Whitespace inside code spans,
/// math, links, inline HTML, and short emphasis spans is not a break opportunity.
pub fn split_words(text: &str, max_protected_span: usize) -> Vec<String> {
    let chars: Vec<char> = text.chars().collect();
    let protected = protected_mask(&chars, max_protected_span);
    let mut words = Vec::new();
    let mut cur = String::new();
    for (i, &c) in chars.iter().enumerate() {
        if c.is_whitespace() && !protected[i] {
            if !cur.is_empty() {
                words.push(std::mem::take(&mut cur));
            }
        } else {
            cur.push(c);
        }
    }
    if !cur.is_empty() {
        words.push(cur);
    }
    words
}

fn protected_mask(chars: &[char], max_emphasis_span: usize) -> Vec<bool> {
    let n = chars.len();
    let mut mask = vec![false; n];
    let protect = |mask: &mut Vec<bool>, from: usize, to_inclusive: usize| {
        for m in mask.iter_mut().take(to_inclusive + 1).skip(from) {
            *m = true;
        }
    };
    let mut i = 0usize;
    while i < n {
        let c = chars[i];
        match c {
            '\\' => {
                i += 2;
                continue;
            }
            '`' => {
                let run = count_run(chars, i, '`');
                if let Some(close) = find_backtick_close(chars, i + run, run) {
                    protect(&mut mask, i, close + run - 1);
                    i = close + run;
                } else {
                    i += run;
                }
                continue;
            }
            '$' => {
                if let Some(close) = find_math_close(chars, i) {
                    protect(&mut mask, i, close);
                    i = close + 1;
                    continue;
                }
            }
            '!' | '[' => {
                let open = if c == '!' { i + 1 } else { i };
                if open < n && chars[open] == '[' {
                    if let Some(end) = find_link_end(chars, open) {
                        protect(&mut mask, i, end);
                        i = end + 1;
                        continue;
                    }
                }
            }
            '<' => {
                if i + 1 < n && (chars[i + 1].is_ascii_alphabetic() || chars[i + 1] == '/') {
                    if let Some(rel) = chars[i + 1..].iter().position(|&ch| ch == '>' || ch == '<')
                    {
                        let close = i + 1 + rel;
                        if chars[close] == '>' {
                            protect(&mut mask, i, close);
                            i = close + 1;
                            continue;
                        }
                    }
                }
            }
            '*' | '_' | '~' | '=' => {
                let run = count_run(chars, i, c);
                if let Some(close) = find_emphasis_close(chars, i, run, c) {
                    if close + run - i <= max_emphasis_span {
                        protect(&mut mask, i, close + run - 1);
                    }
                }
                i += run;
                continue;
            }
            _ => {}
        }
        i += 1;
    }
    mask
}

fn count_run(chars: &[char], from: usize, ch: char) -> usize {
    chars[from..].iter().take_while(|&&c| c == ch).count()
}

fn find_backtick_close(chars: &[char], from: usize, run: usize) -> Option<usize> {
    let mut j = from;
    while j < chars.len() {
        if chars[j] == '`' {
            let r = count_run(chars, j, '`');
            if r == run {
                return Some(j);
            }
            j += r;
        } else {
            j += 1;
        }
    }
    None
}

fn find_math_close(chars: &[char], open: usize) -> Option<usize> {
    let n = chars.len();
    let double = open + 1 < n && chars[open + 1] == '$';
    let body_start = open + if double { 2 } else { 1 };
    if body_start >= n || chars[body_start].is_whitespace() {
        return None;
    }
    let mut j = body_start;
    while j < n {
        match chars[j] {
            '\\' => j += 2,
            '$' => {
                if double {
                    if j + 1 < n && chars[j + 1] == '$' {
                        return Some(j + 1);
                    }
                    return None;
                }
                if chars[j - 1].is_whitespace() || (j + 1 < n && chars[j + 1] == '$') {
                    return None;
                }
                return Some(j);
            }
            _ => j += 1,
        }
    }
    None
}

/// Finds the end of `[label](dest)`, `[label][ref]`, or `[label]` starting at `open` (`[`).
fn find_link_end(chars: &[char], open: usize) -> Option<usize> {
    let n = chars.len();
    let close = find_matching(chars, open, '[', ']')?;
    if close + 1 < n {
        match chars[close + 1] {
            '(' => return find_matching(chars, close + 1, '(', ')'),
            '[' => return find_matching(chars, close + 1, '[', ']'),
            _ => {}
        }
    }
    Some(close)
}

fn find_matching(chars: &[char], open: usize, o: char, c: char) -> Option<usize> {
    let mut depth = 0i32;
    let mut j = open;
    while j < chars.len() {
        let ch = chars[j];
        if ch == '\\' {
            j += 2;
            continue;
        }
        if ch == '`' {
            let run = count_run(chars, j, '`');
            if let Some(cl) = find_backtick_close(chars, j + run, run) {
                j = cl + run;
                continue;
            }
            j += run;
            continue;
        }
        if ch == o {
            depth += 1;
        } else if ch == c {
            depth -= 1;
            if depth == 0 {
                return Some(j);
            }
        }
        j += 1;
    }
    None
}

fn find_emphasis_close(chars: &[char], open: usize, run: usize, ch: char) -> Option<usize> {
    let n = chars.len();
    if (ch == '~' || ch == '=') && run != 2 {
        return None;
    }
    let after = open + run;
    if after >= n || chars[after].is_whitespace() {
        return None;
    }
    if ch == '_' && open > 0 && chars[open - 1].is_alphanumeric() {
        return None;
    }
    let mut j = after;
    while j < n {
        let cj = chars[j];
        if cj == '\\' {
            j += 2;
            continue;
        }
        if cj == '`' {
            let r = count_run(chars, j, '`');
            if let Some(cl) = find_backtick_close(chars, j + r, r) {
                j = cl + r;
                continue;
            }
            j += r;
            continue;
        }
        if cj == ch {
            let r = count_run(chars, j, ch);
            let prev_ok = !chars[j - 1].is_whitespace();
            let next_ok = ch != '_' || j + r >= n || !chars[j + r].is_alphanumeric();
            if r == run && prev_ok && next_ok {
                return Some(j);
            }
            j += r;
            continue;
        }
        j += 1;
    }
    None
}
