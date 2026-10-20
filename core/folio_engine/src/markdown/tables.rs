use super::analyzer::{BlockScanState, LineContext};
use super::block_scanner::parse_blockquote_line;
use super::inline_scanner::scan_inline_spans;
use super::types::{
    MarkdownAnalysis, MarkdownBlockDecoration, MarkdownBlockDecorationKind, SyntaxFoldSpan,
    SyntaxTokenKind,
};

/// Splits a GFM table row into cell strings, respecting:
/// - escaped pipes `\|`
/// - pipes inside inline code spans (`` `a | b` ``)
/// - pipes inside inline math spans (`$|x|$`)
pub fn split_gfm_table_cells(row: &str) -> Vec<String> {
    let trimmed = row.trim();
    if trimmed.is_empty() {
        return Vec::new();
    }
    let bytes = trimmed.as_bytes();
    let start = usize::from(bytes.first() == Some(&b'|'));
    let mut end = bytes.len();
    if end > start && bytes[end - 1] == b'|' {
        let mut backslashes = 0;
        let mut k = end - 1;
        while k > start && bytes[k - 1] == b'\\' {
            backslashes += 1;
            k -= 1;
        }
        if backslashes % 2 == 0 {
            end -= 1;
        }
    }

    let slice = &trimmed[start..end];
    let sbytes = slice.as_bytes();
    let mut cells = Vec::new();
    let mut cell_start = 0;
    let mut i = 0;

    while i < sbytes.len() {
        match sbytes[i] {
            b'\\' => i += 2,
            b'`' => i = skip_backtick_span(sbytes, i),
            b'$' => i = skip_dollar_span(sbytes, i),
            b'|' => {
                let raw_cell = &slice[cell_start..i];
                cells.push(unescape_table_cell(raw_cell.trim()));
                i += 1;
                cell_start = i;
            }
            _ => i += 1,
        }
    }

    let last_cell = &slice[cell_start..];
    cells.push(unescape_table_cell(last_cell.trim()));
    cells
}

fn skip_backtick_span(sbytes: &[u8], mut i: usize) -> usize {
    let mut tick_len = 0;
    while i < sbytes.len() && sbytes[i] == b'`' {
        tick_len += 1;
        i += 1;
    }
    let mut search = i;
    while search < sbytes.len() {
        if sbytes[search] == b'`' {
            let mut c_len = 0;
            while search < sbytes.len() && sbytes[search] == b'`' {
                c_len += 1;
                search += 1;
            }
            if c_len == tick_len {
                return search;
            }
        } else {
            search += 1;
        }
    }
    i
}

fn skip_dollar_span(sbytes: &[u8], mut i: usize) -> usize {
    i += 1;
    while i < sbytes.len() {
        if sbytes[i] == b'\\' {
            i += 2;
        } else if sbytes[i] == b'$' {
            return i + 1;
        } else {
            i += 1;
        }
    }
    i
}

fn unescape_table_cell(cell: &str) -> String {
    cell.replace("\\|", "|")
        .replace("<br/>", " ")
        .replace("<br />", " ")
        .replace("<br>", " ")
}

/// Checks if a line is a valid GFM table delimiter/separator row (`| :--- | :---: | ---: |`).
pub fn is_gfm_table_delimiter_row(line: &str) -> bool {
    let trimmed = line.trim();
    if !trimmed.contains('|') || !trimmed.contains('-') {
        return false;
    }
    let cells = split_gfm_table_cells(trimmed);
    if cells.is_empty() {
        return false;
    }
    cells.iter().all(|c| {
        let s = c.trim();
        if s.is_empty() {
            return false;
        }
        let s = s.strip_prefix(':').unwrap_or(s);
        let s = s.strip_suffix(':').unwrap_or(s);
        !s.is_empty() && s.bytes().all(|b| b == b'-')
    })
}

/// Checks if a line can be a GFM table row (contains at least one unescaped pipe outside code/math).
pub fn is_gfm_table_candidate_line(line: &str) -> bool {
    let trimmed = line.trim();
    if trimmed.is_empty() {
        return false;
    }
    if trimmed.starts_with('|') && trimmed.ends_with('|') && trimmed.len() >= 3 {
        return true;
    }
    let sbytes = trimmed.as_bytes();
    let mut i = 0;
    while i < sbytes.len() {
        match sbytes[i] {
            b'\\' => i += 2,
            b'`' => i = skip_backtick_span(sbytes, i),
            b'|' => return true,
            _ => i += 1,
        }
    }
    false
}

pub(crate) fn handle_blockquote_or_table(
    state: &mut BlockScanState,
    ctx: &LineContext<'_>,
    is_table_line: bool,
    out: &mut MarkdownAnalysis,
) -> bool {
    if let Some((nest_level, marker_len)) = parse_blockquote_line(ctx.content_line) {
        out.syntax_fold_spans.push(SyntaxFoldSpan {
            byte_range: ctx.line_start..(ctx.line_start + marker_len),
            kind: SyntaxTokenKind::BlockquoteMarker,
            is_revealed: ctx.effective_active,
        });
        out.block_decorations.push(MarkdownBlockDecoration {
            byte_range: ctx.line_start..ctx.line_end,
            line_number: ctx.line_number,
            kind: MarkdownBlockDecorationKind::Blockquote { nest_level },
        });
        scan_inline_spans(
            &ctx.content_line[marker_len..],
            ctx.line_start + marker_len,
            ctx.line_number,
            ctx.effective_active,
            ctx.dim_factor,
            &mut out.syntax_fold_spans,
            &mut out.block_decorations,
        );
        return true;
    }

    if is_table_line {
        let is_sep = is_gfm_table_delimiter_row(ctx.content_line);
        let is_header = !state.in_table && !is_sep;
        state.in_table = true;
        if is_sep {
            state.table_seen_separator = true;
        }
        let cols = split_gfm_table_cells(ctx.content_line);
        out.block_decorations.push(MarkdownBlockDecoration {
            byte_range: ctx.line_start..ctx.line_end,
            line_number: ctx.line_number,
            kind: MarkdownBlockDecorationKind::TableRow {
                is_header: is_header && !state.table_seen_separator,
                is_separator: is_sep,
                columns: cols,
            },
        });
        if !is_sep {
            scan_inline_spans(
                ctx.content_line,
                ctx.line_start,
                ctx.line_number,
                ctx.effective_active,
                ctx.dim_factor,
                &mut out.syntax_fold_spans,
                &mut out.block_decorations,
            );
        }
        return true;
    }

    false
}
