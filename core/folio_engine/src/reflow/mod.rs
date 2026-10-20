//! Markdown source reflow (hard-wrap) for paragraphs.
//!
//! Rewraps CommonMark paragraph source lines to a target column width while keeping the
//! rendered output identical: container prefixes (`>`, list indentation) are preserved,
//! hard line breaks (trailing `  ` or `\`) are kept, inline constructs (code spans, math,
//! links, emphasis) are never split, and no line starts with text that would open a new block.

pub mod protected;

use crate::markdown::{parse_cmark_gfm_ast, CmarkBlockKind};
use protected::split_words;

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

    let mut contents: Vec<&str> = Vec::with_capacity(src.len());
    contents.push(&first[col..]);
    for line in &src[1..] {
        contents.push(strip_container_prefix(line, quote_depth));
    }
    if contents.iter().any(|c| is_link_reference_definition(c)) {
        return None;
    }

    let segments = collect_hard_break_segments(&contents);
    let first_avail = width.saturating_sub(display_width(first_prefix)).max(1);
    let cont_avail = width.saturating_sub(display_width(&cont_prefix)).max(1);
    let out_lines = wrap_segments(&segments, first_avail, cont_avail);

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

fn collect_hard_break_segments(contents: &[&str]) -> Vec<(String, HardBreak)> {
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
    segments
}

fn wrap_segments(
    segments: &[(String, HardBreak)],
    first_avail: usize,
    cont_avail: usize,
) -> Vec<String> {
    let mut out_lines: Vec<String> = Vec::new();
    for (text, brk) in segments {
        let words = split_words(text, cont_avail);
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
        if *brk == HardBreak::Spaces {
            if let Some(l) = seg_lines.last_mut() {
                l.push_str("  ");
            }
        }
        out_lines.extend(seg_lines);
    }
    out_lines
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
    first == '[' && word.contains("]:")
}
