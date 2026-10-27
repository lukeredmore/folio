use super::html_inline::{try_scan_anchor_image, try_scan_inline_html_tag};
use super::inline_helpers::{
    detect_emphasis_marker, find_closing_marker_cached, inline_math_next_closers,
    is_ascii_punctuation_byte, match_parens, parse_markdown_link_dest_and_title,
};
use super::types::{
    MarkdownBlockDecoration, MarkdownBlockDecorationKind, SyntaxFoldSpan, SyntaxTokenKind,
};

pub(crate) struct InlineScanContext<'a> {
    pub line_slice: &'a str,
    pub base_offset: usize,
    pub line_number: usize,
    pub is_active_line: bool,
    pub dim_factor: f64,
    pub syntax_fold_spans: &'a mut Vec<SyntaxFoldSpan>,
    pub block_decorations: &'a mut Vec<MarkdownBlockDecoration>,
}

pub(crate) fn scan_inline_spans(
    line_slice: &str,
    base_offset: usize,
    line_number: usize,
    is_active_line: bool,
    dim_factor: f64,
    syntax_fold_spans: &mut Vec<SyntaxFoldSpan>,
    block_decorations: &mut Vec<MarkdownBlockDecoration>,
) {
    let mut ctx = InlineScanContext {
        line_slice,
        base_offset,
        line_number,
        is_active_line,
        dim_factor,
        syntax_fold_spans,
        block_decorations,
    };
    scan_inline_with_ctx(&mut ctx);
}

fn scan_inline_with_ctx(ctx: &mut InlineScanContext<'_>) {
    let bytes = ctx.line_slice.as_bytes();
    let mut i = 0;
    let mut failed_tick_mask: u64 = 0;
    let mut no_closing_dollar = false;
    let mut math_closers: Option<Vec<usize>> = None;
    let mut cached_bracket_paren: Option<Option<usize>> = None;
    let mut no_closing_angle = false;
    let mut exhausted_from = [usize::MAX; 8];
    let mut paren_matches: Option<Vec<usize>> = None;

    while i < bytes.len() {
        if bytes[i] == b'\\' && i + 1 < bytes.len() && is_ascii_punctuation_byte(bytes[i + 1]) {
            ctx.syntax_fold_spans.push(SyntaxFoldSpan {
                byte_range: (ctx.base_offset + i)..(ctx.base_offset + i + 1),
                kind: SyntaxTokenKind::LinkSyntax,
                is_revealed: ctx.is_active_line,
            });
            i += 2;
            continue;
        }

        if bytes[i] == b'`' {
            i = try_scan_code_span(ctx, i, &mut failed_tick_mask);
            continue;
        }

        if !no_closing_dollar && bytes[i] == b'$' && i + 1 < bytes.len() && bytes[i + 1] != b'$' {
            if let Some(next_i) =
                try_scan_inline_math(ctx, i, &mut math_closers, &mut no_closing_dollar)
            {
                i = next_i;
                continue;
            }
        }

        if let Some(next_i) = try_scan_emphasis_or_mark(ctx, i, &mut exhausted_from) {
            i = next_i;
            continue;
        }

        if let Some(next_i) = try_scan_anchor_image(ctx, i, &mut cached_bracket_paren) {
            i = next_i;
            continue;
        }

        if bytes[i] == b'[' || (bytes[i] == b'!' && i + 1 < bytes.len() && bytes[i + 1] == b'[') {
            if let Some(next_i) =
                try_scan_link_or_image(ctx, i, &mut cached_bracket_paren, &mut paren_matches)
            {
                i = next_i;
                continue;
            }
        }

        if !no_closing_angle && bytes[i] == b'<' {
            if let Some(next_i) = try_scan_autolink_or_html(ctx, i, &mut no_closing_angle) {
                i = next_i;
                continue;
            }
        }

        i += 1;
    }
}

fn try_scan_code_span(
    ctx: &mut InlineScanContext<'_>,
    mut i: usize,
    failed_tick_mask: &mut u64,
) -> usize {
    let bytes = ctx.line_slice.as_bytes();
    let start = i;
    let mut tick_len = 0;
    while i < bytes.len() && bytes[i] == b'`' {
        tick_len += 1;
        i += 1;
    }
    if tick_len < 64 && (*failed_tick_mask & (1u64 << tick_len)) != 0 {
        return i;
    }
    let mut found_close = None;
    let mut search = i;
    while search < bytes.len() {
        if bytes[search] == b'`' {
            let close_start = search;
            let mut c_len = 0;
            while search < bytes.len() && bytes[search] == b'`' {
                c_len += 1;
                search += 1;
            }
            if c_len == tick_len {
                found_close = Some((close_start, search));
                break;
            }
        } else {
            search += 1;
        }
    }
    if let Some((close_start, close_end)) = found_close {
        ctx.syntax_fold_spans.push(SyntaxFoldSpan {
            byte_range: (ctx.base_offset + start)..(ctx.base_offset + start + tick_len),
            kind: SyntaxTokenKind::InlineCodeBackticks,
            is_revealed: ctx.is_active_line,
        });
        ctx.syntax_fold_spans.push(SyntaxFoldSpan {
            byte_range: (ctx.base_offset + close_start)..(ctx.base_offset + close_end),
            kind: SyntaxTokenKind::InlineCodeBackticks,
            is_revealed: ctx.is_active_line,
        });
        if close_start > start + tick_len {
            ctx.block_decorations.push(MarkdownBlockDecoration {
                byte_range: (ctx.base_offset + start + tick_len)..(ctx.base_offset + close_start),
                line_number: ctx.line_number,
                kind: MarkdownBlockDecorationKind::InlineCode,
            });
        }
        return close_end;
    }
    if tick_len < 64 {
        *failed_tick_mask |= 1u64 << tick_len;
    }
    i
}

fn try_scan_inline_math(
    ctx: &mut InlineScanContext<'_>,
    start: usize,
    math_closers: &mut Option<Vec<usize>>,
    no_closing_dollar: &mut bool,
) -> Option<usize> {
    let bytes = ctx.line_slice.as_bytes();
    let closers = math_closers.get_or_insert_with(|| inline_math_next_closers(bytes));
    let close_idx = closers[start + 2];
    if close_idx == usize::MAX {
        *no_closing_dollar = true;
        return None;
    }
    if bytes[start + 1].is_ascii_whitespace() {
        return None;
    }
    let latex = ctx.line_slice[start + 1..close_idx].to_string();
    ctx.syntax_fold_spans.push(SyntaxFoldSpan {
        byte_range: (ctx.base_offset + start)..(ctx.base_offset + start + 1),
        kind: SyntaxTokenKind::InlineMathDollar,
        is_revealed: ctx.is_active_line,
    });
    ctx.syntax_fold_spans.push(SyntaxFoldSpan {
        byte_range: (ctx.base_offset + close_idx)..(ctx.base_offset + close_idx + 1),
        kind: SyntaxTokenKind::InlineMathDollar,
        is_revealed: ctx.is_active_line,
    });
    ctx.block_decorations.push(MarkdownBlockDecoration {
        byte_range: (ctx.base_offset + start)..(ctx.base_offset + close_idx + 1),
        line_number: ctx.line_number,
        kind: MarkdownBlockDecorationKind::InlineMathRendered {
            latex,
            is_active: ctx.is_active_line,
            dim_factor: ctx.dim_factor,
        },
    });
    Some(close_idx + 1)
}

fn try_scan_emphasis_or_mark(
    ctx: &mut InlineScanContext<'_>,
    i: usize,
    exhausted_from: &mut [usize; 8],
) -> Option<usize> {
    let bytes = ctx.line_slice.as_bytes();
    let (mlen, kind) = detect_emphasis_marker(bytes, i)?;

    let marker = &ctx.line_slice[i..i + mlen];
    let rel_end = find_closing_marker_cached(ctx.line_slice, i + mlen, marker, exhausted_from)?;
    let close_start = i + mlen + rel_end;
    ctx.syntax_fold_spans.push(SyntaxFoldSpan {
        byte_range: (ctx.base_offset + i)..(ctx.base_offset + i + mlen),
        kind: kind.clone(),
        is_revealed: ctx.is_active_line,
    });
    ctx.syntax_fold_spans.push(SyntaxFoldSpan {
        byte_range: (ctx.base_offset + close_start)..(ctx.base_offset + close_start + mlen),
        kind,
        is_revealed: ctx.is_active_line,
    });
    scan_inline_spans(
        &ctx.line_slice[i + mlen..close_start],
        ctx.base_offset + i + mlen,
        ctx.line_number,
        ctx.is_active_line,
        ctx.dim_factor,
        ctx.syntax_fold_spans,
        ctx.block_decorations,
    );
    Some(close_start + mlen)
}

fn try_scan_link_or_image(
    ctx: &mut InlineScanContext<'_>,
    i: usize,
    cached_bracket_paren: &mut Option<Option<usize>>,
    paren_matches: &mut Option<Vec<usize>>,
) -> Option<usize> {
    let bytes = ctx.line_slice.as_bytes();
    let is_image = bytes[i] == b'!';
    let bracket_open = if is_image { i + 1 } else { i };
    let next_bp = match *cached_bracket_paren {
        Some(Some(pos)) if pos > bracket_open => Some(pos),
        Some(None) => None,
        _ => {
            let found = ctx.line_slice[bracket_open + 1..]
                .find("](")
                .map(|rel| bracket_open + 1 + rel);
            *cached_bracket_paren = Some(found);
            found
        }
    };
    let bracket_close = next_bp?;
    let has_inner_open = bytes[bracket_open + 1..bracket_close].contains(&b'[');
    if has_inner_open || bracket_close < bracket_open + 1 {
        return None;
    }
    let matches = paren_matches.get_or_insert_with(|| match_parens(bytes));
    let found_paren = Some(matches[bracket_close + 1]).filter(|&m| m != usize::MAX);
    let Some(paren_close) = found_paren else {
        *cached_bracket_paren = Some(
            ctx.line_slice
                .get(bracket_close + 2..)
                .and_then(|s| s.find("](").map(|rel| bracket_close + 2 + rel)),
        );
        return None;
    };
    ctx.syntax_fold_spans.push(SyntaxFoldSpan {
        byte_range: (ctx.base_offset + i)..(ctx.base_offset + bracket_open + 1),
        kind: SyntaxTokenKind::LinkSyntax,
        is_revealed: ctx.is_active_line,
    });
    if bracket_close > bracket_open + 1 && !is_image {
        scan_inline_spans(
            &ctx.line_slice[bracket_open + 1..bracket_close],
            ctx.base_offset + bracket_open + 1,
            ctx.line_number,
            ctx.is_active_line,
            ctx.dim_factor,
            ctx.syntax_fold_spans,
            ctx.block_decorations,
        );
    }
    ctx.syntax_fold_spans.push(SyntaxFoldSpan {
        byte_range: (ctx.base_offset + bracket_close)..(ctx.base_offset + paren_close + 1),
        kind: SyntaxTokenKind::LinkSyntax,
        is_revealed: ctx.is_active_line,
    });
    if is_image {
        let alt = ctx.line_slice[bracket_open + 1..bracket_close].to_string();
        let (url, title) =
            parse_markdown_link_dest_and_title(&ctx.line_slice[bracket_close + 2..paren_close]);
        ctx.block_decorations.push(MarkdownBlockDecoration {
            byte_range: (ctx.base_offset + i)..(ctx.base_offset + paren_close + 1),
            line_number: ctx.line_number,
            kind: MarkdownBlockDecorationKind::Image {
                alt,
                url,
                title,
                width: None,
                height: None,
                is_html: false,
                is_active: ctx.is_active_line,
            },
        });
    }
    Some(paren_close + 1)
}

fn try_scan_autolink_or_html(
    ctx: &mut InlineScanContext<'_>,
    i: usize,
    no_closing_angle: &mut bool,
) -> Option<usize> {
    let Some(rel_close) = ctx.line_slice[i + 1..].find('>') else {
        *no_closing_angle = true;
        return None;
    };
    let close_idx = i + 1 + rel_close;
    let inner = &ctx.line_slice[i + 1..close_idx];
    if (inner.starts_with("http://")
        || inner.starts_with("https://")
        || inner.starts_with("mailto:"))
        && !inner.contains(char::is_whitespace)
    {
        ctx.syntax_fold_spans.push(SyntaxFoldSpan {
            byte_range: (ctx.base_offset + i)..(ctx.base_offset + i + 1),
            kind: SyntaxTokenKind::LinkSyntax,
            is_revealed: ctx.is_active_line,
        });
        ctx.syntax_fold_spans.push(SyntaxFoldSpan {
            byte_range: (ctx.base_offset + close_idx)..(ctx.base_offset + close_idx + 1),
            kind: SyntaxTokenKind::LinkSyntax,
            is_revealed: ctx.is_active_line,
        });
        return Some(close_idx + 1);
    }

    try_scan_inline_html_tag(ctx, i, close_idx)
}
