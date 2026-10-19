//! Markdown source reflow (hard-wrap) for paragraphs.
//!
//! Rewraps CommonMark paragraph source lines to a target column width while keeping the
//! rendered output identical: container prefixes (`>`, list indentation) are preserved,
//! hard line breaks (trailing `  ` or `\`) are kept, inline constructs (code spans, math,
//! links, emphasis) are never split, and no line starts with text that would open a new block.

use crate::markdown::{parse_cmark_gfm_ast, CmarkBlockKind};

/// A paragraph rewrapped to a target width. Line numbers are 1-based and inclusive.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParagraphReflow {
    pub start_line: u32,
    pub end_line: u32,
    pub replacement: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum HardBreak {
    None,
    Spaces,
    Backslash,
}

/// Rewraps the paragraph that contains `line` (1-based). Returns `None` when the line is not
/// part of a paragraph that can be reflowed safely.
pub fn reflow_paragraph_at_line(
    markdown: &str,
    line: u32,
    width: usize,
) -> Option<ParagraphReflow> {
    if width == 0 || markdown.is_empty() {
        return None;
    }
    let lines: Vec<&str> = markdown.split('\n').collect();
    paragraph_spans(markdown)
        .into_iter()
        .find(|&(start, end, _)| start <= line && line <= end)
        .and_then(|(start, end, col)| reflow_span(&lines, start, end, col, width))
}

/// Rewraps every paragraph in the document.
pub fn reflow_markdown(markdown: &str, width: usize) -> String {
    if width == 0 || markdown.is_empty() {
        return markdown.to_string();
    }
    let lines: Vec<&str> = markdown.split('\n').collect();
    let mut edits: Vec<ParagraphReflow> = paragraph_spans(markdown)
        .into_iter()
        .filter_map(|(start, end, col)| reflow_span(&lines, start, end, col, width))
        .collect();
    if edits.is_empty() {
        return markdown.to_string();
    }
    edits.sort_by_key(|e| e.start_line);

    let mut out: Vec<String> = Vec::with_capacity(lines.len());
    let mut next = 1u32;
    for edit in edits {
        if edit.start_line < next {
            continue;
        }
        while next < edit.start_line {
            out.push(lines[(next - 1) as usize].to_string());
            next += 1;
        }
        out.push(edit.replacement);
        next = edit.end_line + 1;
    }
    while (next as usize) <= lines.len() {
        out.push(lines[(next - 1) as usize].to_string());
        next += 1;
    }
    out.join("\n")
}

/// Returns `(start_line, end_line, start_column)` for every paragraph block.
fn paragraph_spans(markdown: &str) -> Vec<(u32, u32, u32)> {
    parse_cmark_gfm_ast(markdown)
        .blocks
        .into_iter()
        .filter(|b| {
            b.kind == CmarkBlockKind::Paragraph && b.start_line > 0 && b.end_line >= b.start_line
        })
        .map(|b| (b.start_line, b.end_line, b.start_column.max(1)))
        .collect()
}

fn reflow_span(
    lines: &[&str],
    start: u32,
    end: u32,
    start_col: u32,
    width: usize,
) -> Option<ParagraphReflow> {
    if end as usize > lines.len() {
        return None;
    }
    let crlf = lines[(start - 1) as usize].ends_with('\r');
    let src: Vec<&str> = (start..=end)
        .map(|ln| lines[(ln - 1) as usize].trim_end_matches('\r'))
        .collect();

    let first = src[0];
    let col = (start_col - 1) as usize;
    if col > first.len() || !first.is_char_boundary(col) {
        return None;
    }
    let first_prefix = &first[..col];
    // Only reflow when the prefix is pure container syntax (indentation, `>`, list markers).
    if !first_prefix
        .chars()
        .all(|c| c.is_whitespace() || c == '>' || c.is_ascii_digit() || "-+*.)[]xX".contains(c))
    {
        return None;
    }
    let quote_depth = first_prefix.chars().filter(|&c| c == '>').count();
    let cont_prefix: String = first_prefix
        .chars()
        .map(|c| if c == '>' || c == '\t' { c } else { ' ' })
        .collect();

    // Collect line contents without container prefixes.
    let mut contents: Vec<&str> = Vec::with_capacity(src.len());
    contents.push(&first[col..]);
    for line in &src[1..] {
        contents.push(strip_container_prefix(line, quote_depth));
    }

    // Link reference definitions and setext-like content are not safe to rewrap.
    if contents.iter().any(|c| is_link_reference_definition(c)) {
        return None;
    }

    // Split into hard-break segments.
    let mut segments: Vec<(String, HardBreak)> = Vec::new();
    let mut current = String::new();
    let last = contents.len() - 1;
    for (i, raw) in contents.iter().enumerate() {
        let brk = if i == last {
            HardBreak::None
        } else {
            hard_break_kind(raw)
        };
        let piece = raw.trim();
        if !piece.is_empty() {
            if !current.is_empty() {
                current.push(' ');
            }
            current.push_str(piece);
        }
        if brk != HardBreak::None {
            segments.push((std::mem::take(&mut current), brk));
        }
    }
    segments.push((current, HardBreak::None));

    let first_avail = width.saturating_sub(display_width(first_prefix)).max(1);
    let cont_avail = width.saturating_sub(display_width(&cont_prefix)).max(1);

    let mut out_lines: Vec<String> = Vec::new();
    for (text, brk) in segments {
        let words = split_words(&text, cont_avail);
        let mut seg_lines: Vec<String> = Vec::new();
        let mut cur = String::new();
        let mut cur_len = 0usize;
        for word in words {
            let wlen = display_width(&word);
            let avail = if out_lines.is_empty() && seg_lines.is_empty() {
                first_avail
            } else {
                cont_avail
            };
            if cur.is_empty() {
                cur = word;
                cur_len = wlen;
                continue;
            }
            let fits = cur_len + 1 + wlen <= avail;
            let must_glue = starts_block(&word) || ends_with_hard_break_backslash(&cur);
            if fits || must_glue {
                cur.push(' ');
                cur.push_str(&word);
                cur_len += 1 + wlen;
            } else {
                seg_lines.push(std::mem::take(&mut cur));
                cur = word;
                cur_len = wlen;
            }
        }
        seg_lines.push(cur);
        if brk == HardBreak::Spaces {
            if let Some(l) = seg_lines.last_mut() {
                l.push_str("  ");
            }
        }
        out_lines.extend(seg_lines);
    }

    let eol = if crlf { "\r" } else { "" };
    let mut replacement = String::new();
    for (i, l) in out_lines.iter().enumerate() {
        if i > 0 {
            replacement.push_str(eol);
            replacement.push('\n');
            replacement.push_str(&cont_prefix);
        } else {
            replacement.push_str(first_prefix);
        }
        replacement.push_str(l);
    }
    if crlf {
        replacement.push('\r');
    }

    Some(ParagraphReflow {
        start_line: start,
        end_line: end,
        replacement,
    })
}

fn strip_container_prefix(line: &str, quote_depth: usize) -> &str {
    let mut s = line;
    for _ in 0..quote_depth {
        let t = s.trim_start_matches([' ', '\t']);
        if let Some(rest) = t.strip_prefix('>') {
            s = rest;
        } else {
            break;
        }
    }
    s
}

fn hard_break_kind(content: &str) -> HardBreak {
    if content.len() - content.trim_end_matches(' ').len() >= 2 {
        return HardBreak::Spaces;
    }
    if ends_with_hard_break_backslash(content) {
        return HardBreak::Backslash;
    }
    HardBreak::None
}

fn ends_with_hard_break_backslash(s: &str) -> bool {
    let n = s.chars().rev().take_while(|&c| c == '\\').count();
    n % 2 == 1
}

fn is_link_reference_definition(content: &str) -> bool {
    let t = content.trim_start();
    if !t.starts_with('[') {
        return false;
    }
    match t.find("]:") {
        Some(idx) => !t[1..idx].contains(']'),
        None => false,
    }
}

fn display_width(s: &str) -> usize {
    s.chars().map(|c| if c == '\t' { 4 } else { 1 }).sum()
}

/// Returns true when a line that starts with `word` would open a new block (and so end the
/// paragraph) or be misread as block syntax.
fn starts_block(word: &str) -> bool {
    let first = match word.chars().next() {
        Some(c) => c,
        None => return false,
    };
    if word.chars().all(|c| c == '#') && word.len() <= 6 {
        return true;
    }
    if word.chars().all(|c| c == first) && "-=*_+".contains(first) {
        return true;
    }
    let digits = word.chars().take_while(|c| c.is_ascii_digit()).count();
    if digits > 0 && digits <= 9 && word.len() == digits + 1 && word.ends_with(['.', ')']) {
        return true;
    }
    if first == '>' || first == '|' {
        return true;
    }
    if word.starts_with("```") || word.starts_with("~~~") || word.starts_with("$$") {
        return true;
    }
    if first == '<' {
        if let Some(c) = word.chars().nth(1) {
            if c.is_ascii_alphabetic() || c == '/' || c == '!' || c == '?' {
                return true;
            }
        }
    }
    if first == '[' && word.contains("]:") {
        return true;
    }
    false
}

/// Splits paragraph text into words at unprotected whitespace. Whitespace inside code spans,
/// math, links, inline HTML, and short emphasis spans is not a break opportunity.
fn split_words(text: &str, max_protected_span: usize) -> Vec<String> {
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
    let mut protect = |mask: &mut Vec<bool>, from: usize, to_inclusive: usize| {
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::markdown::render_gfm_to_html;

    fn assert_same_render(before: &str, after: &str) {
        let norm = |s: &str| {
            render_gfm_to_html(s)
                .split_whitespace()
                .collect::<Vec<_>>()
                .join(" ")
        };
        assert_eq!(
            norm(before),
            norm(after),
            "\nbefore:\n{before}\nafter:\n{after}"
        );
    }

    fn max_line(s: &str) -> usize {
        s.lines().map(|l| l.chars().count()).max().unwrap_or(0)
    }

    #[test]
    fn rewraps_plain_paragraph_to_width() {
        let md = "one two three four five six seven eight nine ten eleven twelve\nthirteen";
        let out = reflow_markdown(md, 20);
        assert!(max_line(&out) <= 20, "{out}");
        assert_eq!(
            out,
            "one two three four\nfive six seven eight\nnine ten eleven\ntwelve thirteen"
        );
        assert_same_render(md, &out);
    }

    #[test]
    fn joins_short_lines() {
        let md = "a\nb\nc\n\nnext";
        assert_eq!(reflow_markdown(md, 80), "a b c\n\nnext");
    }

    #[test]
    fn keeps_list_item_indentation() {
        let md = "- North Bed: a raised bed with drip irrigation, and a trellis for climbing\n  beans that depends on morning sun.\n- second item";
        let out = reflow_markdown(md, 40);
        for l in out.lines().filter(|l| !l.starts_with("- ")) {
            assert!(l.starts_with("  "), "{out}");
        }
        assert!(max_line(&out) <= 40, "{out}");
        assert_same_render(md, &out);
    }

    #[test]
    fn keeps_ordered_and_nested_blockquote_prefixes() {
        let md = "> 10. alpha beta gamma delta epsilon zeta eta theta iota kappa lambda\n> mu nu";
        let out = reflow_markdown(md, 30);
        for l in out.lines().skip(1) {
            assert!(l.starts_with(">    "), "{out}");
        }
        assert_same_render(md, &out);
    }

    #[test]
    fn never_splits_inline_code_links_or_math() {
        let md = "Watering schedule that runs the `herb timer program` of [Garden Helper Tool](https://example.com/a_b) and $a + b = c$ and **bold w** done";
        let out = reflow_markdown(md, 12);
        assert!(out.contains("`herb timer program`"), "{out}");
        assert!(
            out.contains("[Garden Helper Tool](https://example.com/a_b)"),
            "{out}"
        );
        assert!(out.contains("$a + b = c$"), "{out}");
        assert!(out.contains("**bold w**"), "{out}");
        assert_same_render(md, &out);
    }

    #[test]
    fn preserves_hard_breaks() {
        let md = "first line  \nsecond line\\\nthird line";
        let out = reflow_markdown(md, 80);
        assert_eq!(out, "first line  \nsecond line\\\nthird line");
        assert_same_render(md, &out);
    }

    #[test]
    fn never_starts_line_with_block_syntax() {
        let md = "aaaa bbbb - cccc 1. dddd # eeee > ffff --- gggg";
        for w in 4..20 {
            let out = reflow_markdown(md, w);
            assert_same_render(md, &out);
        }
    }

    #[test]
    fn leaves_code_blocks_headings_and_tables_alone() {
        let md = "# A very long heading that goes past the width\n\n```\ncode line that is very long indeed\n```\n\n| a | b |\n|---|---|\n| c | d |";
        assert_eq!(reflow_markdown(md, 10), md);
    }

    #[test]
    fn skips_link_reference_definitions() {
        let md = "[ref]: https://example.com\ntext that follows";
        assert_same_render(md, &reflow_markdown(md, 5));
    }

    #[test]
    fn reflow_paragraph_at_line_targets_one_paragraph() {
        let md = "a\nb\n\nc\nd";
        let r = reflow_paragraph_at_line(md, 5, 80).unwrap();
        assert_eq!(
            (r.start_line, r.end_line, r.replacement.as_str()),
            (4, 5, "c d")
        );
        assert!(reflow_paragraph_at_line(md, 3, 80).is_none());
    }

    #[test]
    fn task_list_continuation_stays_in_item() {
        let md = "- [ ] alpha beta gamma delta epsilon zeta eta theta iota kappa\n- [x] done";
        let out = reflow_markdown(md, 25);
        assert_same_render(md, &out);
    }
    #[test]
    fn wrapped_list_section_from_bug_report() {
        let md = "- [North Bed](beds/north.md): a raised bed with drip irrigation, and a trellis for climbing\n  beans that depends on morning sun. The trellis supports the peas in spring and the\n  `pole-beans` rotation in summer. The drip line runs from the rain barrel to every corner of the bed.\n- [Herb Spiral](beds/herb-spiral.md): the basil, thyme, and oregano plantings near the back door and the\n  watering schedule that runs the `herb-timer` program of\n  [GardenHelper](https://example.com). The schedule runs every morning with\n  the profile `GardenHelperWatering-<season>`, or `GardenHelperWatering-<custom-schedule-name>` for a\n  custom plan, without spaces in the name.";
        let out = reflow_markdown(md, 80);
        assert!(max_line(&out) <= 80, "{out}");
        assert_same_render(md, &out);
        assert_eq!(reflow_markdown(&out, 80), out, "reflow must be idempotent");
    }
}
