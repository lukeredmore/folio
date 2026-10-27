use std::ops::Range;

use folio_engine::markdown::replace_code_fence_language;

use crate::text_navigation::{snap_char_boundary_left, snap_char_boundary_right, word_range_at};

const CODE_BLOCK_LANGUAGES: &[&str] = &[
    "rust",
    "python",
    "typescript",
    "javascript",
    "bash",
    "json",
    "markdown",
    "go",
    "sql",
    "c",
    "cpp",
    "html",
    "css",
    "yaml",
    "toml",
    "plain",
];

/// Toggle inline Markdown delimiter (`**`, `*`, `` ` ``, `~~`, `$`, `$$`) around a selection or word under cursor.
/// Returns `(edit_range, replacement, post_selection)`.
#[must_use]
pub fn toggle_inline_delimiter(
    source: &str,
    sel_start: usize,
    sel_end: usize,
    delim: &str,
) -> (Range<usize>, String, Range<usize>) {
    let dlen = delim.len();
    let was_collapsed = sel_start == sel_end;
    let sel_start = snap_char_boundary_left(source, sel_start);
    let sel_end = if was_collapsed {
        sel_start
    } else {
        snap_char_boundary_right(source, sel_end).max(sel_start)
    };
    let (target_start, target_end) = if sel_start < sel_end {
        (sel_start, sel_end)
    } else if let Some((ws, we)) = word_range_at(source, sel_start) {
        (ws, we)
    } else {
        (sel_start, sel_end)
    };

    let can_strip_surrounding = if target_start >= dlen
        && target_end + dlen <= source.len()
        && source.get((target_start - dlen)..target_start) == Some(delim)
        && source.get(target_end..(target_end + dlen)) == Some(delim)
    {
        if dlen == 1 {
            let ch = delim.as_bytes()[0];
            let before_count = source.as_bytes()[..target_start]
                .iter()
                .rev()
                .take_while(|&&b| b == ch)
                .count();
            let after_count = source.as_bytes()[target_end..]
                .iter()
                .take_while(|&&b| b == ch)
                .count();
            // If surrounded by exactly `**` (bold), pressing Cmd+I (`*`) should wrap to `***`
            // rather than corrupting `**bold**` into `*bold*`.
            !(before_count == 2 && after_count == 2)
        } else {
            true
        }
    } else {
        false
    };

    if can_strip_surrounding {
        let inner = source
            .get(target_start..target_end)
            .unwrap_or("")
            .to_string();
        let new_start = target_start - dlen;
        let new_end = new_start + inner.len();
        return (
            (target_start - dlen)..(target_end + dlen),
            inner,
            if sel_start < sel_end {
                new_start..new_end
            } else {
                let offset = sel_start.saturating_sub(dlen);
                offset..offset
            },
        );
    }

    let selected = source.get(target_start..target_end).unwrap_or("");
    if selected.starts_with(delim)
        && selected.ends_with(delim)
        && selected.len() >= dlen * 2
        && (dlen != 1
            || !selected.starts_with(&format!("{delim}{delim}"))
            || selected.starts_with(&format!("{delim}{delim}{delim}")))
    {
        let inner = selected[dlen..selected.len() - dlen].to_string();
        let new_end = target_start + inner.len();
        return (
            target_start..target_end,
            inner,
            if sel_start < sel_end {
                target_start..new_end
            } else {
                let offset = sel_start.saturating_sub(dlen).clamp(target_start, new_end);
                offset..offset
            },
        );
    }

    let replacement = format!("{delim}{selected}{delim}");
    let new_sel = if sel_start < sel_end {
        (target_start + dlen)..(target_end + dlen)
    } else if target_start < target_end {
        let offset = sel_start + dlen;
        offset..offset
    } else {
        (target_start + dlen)..(target_start + dlen)
    };
    (target_start..target_end, replacement, new_sel)
}

/// Toggle ATX heading prefix (`# ` .. `###### `) on the line containing `cursor`.
/// Returns `(edit_range, replacement, post_selection)`.
#[must_use]
pub fn toggle_heading_level(
    source: &str,
    cursor: usize,
    level: usize,
) -> (Range<usize>, String, Range<usize>) {
    let len = source.len();
    let cursor = snap_char_boundary_left(source, cursor);
    let line_start = source[..cursor].rfind('\n').map_or(0, |idx| idx + 1);
    let line_end = source[cursor..].find('\n').map_or(len, |rel| cursor + rel);
    let line = &source[line_start..line_end];
    let existing_hashes = line.bytes().take_while(|&b| b == b'#').count();
    let existing_ws = if existing_hashes > 0 {
        line[existing_hashes..]
            .bytes()
            .take_while(|&b| b == b' ' || b == b'\t')
            .count()
    } else {
        0
    };
    let old_prefix_len = if existing_hashes > 0 && existing_ws > 0 {
        existing_hashes + existing_ws
    } else {
        0
    };
    let new_prefix = if existing_hashes == level && old_prefix_len > 0 {
        String::new()
    } else {
        format!("{} ", "#".repeat(level))
    };
    let new_prefix_len = new_prefix.len();
    let new_cursor = if cursor <= line_start + old_prefix_len {
        line_start + new_prefix_len
    } else {
        (cursor + new_prefix_len).saturating_sub(old_prefix_len)
    };
    (
        line_start..(line_start + old_prefix_len),
        new_prefix,
        new_cursor..new_cursor,
    )
}

/// Cycle the opening fence language tag of a fenced code block at `block_range` to the next language.
/// Returns `(fence_line_range, updated_fence_line)`.
#[must_use]
pub fn cycle_code_block_language(
    source: &str,
    block_range: Range<usize>,
    current_lang: &str,
) -> Option<(Range<usize>, String)> {
    let current = {
        let s = current_lang.trim();
        if s.is_empty() {
            "plain"
        } else {
            s
        }
    };
    let next_idx = CODE_BLOCK_LANGUAGES
        .iter()
        .position(|&lang| lang.eq_ignore_ascii_case(current))
        .map_or(0, |idx| (idx + 1) % CODE_BLOCK_LANGUAGES.len());
    let next_lang = CODE_BLOCK_LANGUAGES[next_idx];
    let target_lang = if next_lang == "plain" { "" } else { next_lang };

    let block_slice = source.get(block_range.start..block_range.end)?;
    let rel_end = block_slice.find('\n').unwrap_or(block_slice.len());
    let fence_line_range = block_range.start..(block_range.start + rel_end);
    let fence_line = source.get(fence_line_range.clone())?;
    let updated_line = replace_code_fence_language(fence_line, 0, target_lang)?;
    let trimmed_line = updated_line.trim_end_matches('\n').to_string();
    Some((fence_line_range, trimmed_line))
}
