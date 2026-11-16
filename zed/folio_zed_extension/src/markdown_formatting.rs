use std::ops::Range;

use folio_engine::markdown::{
    edit_symmetric_delimiter, edit_toggle_heading_level, replace_code_fence_language,
};

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

/// Toggle inline Markdown delimiter (`**`, `*`, `` ` ``, `~~`, `==`, `$`, `$$`) around a selection or word under cursor.
/// Returns `(edit_range, replacement, post_selection)`.
#[must_use]
pub fn toggle_inline_delimiter(
    source: &str,
    sel_start: usize,
    sel_end: usize,
    delim: &str,
) -> (Range<usize>, String, Range<usize>) {
    let edit = edit_symmetric_delimiter(source, sel_start..sel_end, delim);
    (edit.replace_range, edit.replacement, edit.new_selection)
}

/// Toggle ATX heading prefix (`# ` .. `###### `) on the line containing `cursor`.
/// Returns `(edit_range, replacement, post_selection)`.
#[must_use]
pub fn toggle_heading_level(
    source: &str,
    cursor: usize,
    level: usize,
) -> (Range<usize>, String, Range<usize>) {
    let edit = edit_toggle_heading_level(source, cursor..cursor, u8::try_from(level).unwrap_or(0));
    (edit.replace_range, edit.replacement, edit.new_selection)
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
