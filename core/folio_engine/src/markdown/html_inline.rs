use super::inline_helpers::{
    extract_html_attr, find_paren_close, parse_markdown_link_dest_and_title,
};
use super::inline_scanner::{scan_inline_spans, InlineScanContext};
use super::types::{
    HtmlInlineTagKind, MarkdownBlockDecoration, MarkdownBlockDecorationKind, SyntaxFoldSpan,
    SyntaxTokenKind,
};

pub(crate) fn try_scan_anchor_image(
    ctx: &mut InlineScanContext<'_>,
    i: usize,
    cached_bracket_paren: &mut Option<Option<usize>>,
) -> Option<usize> {
    let bytes = ctx.line_slice.as_bytes();
    if !(bytes[i] == b'[' && i + 2 < bytes.len() && bytes[i + 1] == b'!' && bytes[i + 2] == b'[') {
        return None;
    }
    let img_open = i + 2;
    let next_bp = match *cached_bracket_paren {
        Some(Some(pos)) if pos > img_open => Some(pos),
        Some(None) => None,
        _ => {
            let found = ctx.line_slice[img_open + 1..]
                .find("](")
                .map(|rel| img_open + 1 + rel);
            *cached_bracket_paren = Some(found);
            found
        }
    };
    let img_bracket_close = next_bp?;
    if bytes[img_open + 1..img_bracket_close].contains(&b'[') || img_bracket_close < img_open + 1 {
        return None;
    }
    let img_url_start = img_bracket_close + 2;
    let img_paren_close = find_paren_close(bytes, img_url_start)?;
    if !(img_paren_close + 2 < bytes.len()
        && bytes[img_paren_close + 1] == b']'
        && bytes[img_paren_close + 2] == b'(')
    {
        return None;
    }
    let outer_url_start = img_paren_close + 3;
    let outer_paren_close = find_paren_close(bytes, outer_url_start)?;

    ctx.syntax_fold_spans.push(SyntaxFoldSpan {
        byte_range: (ctx.base_offset + i)..(ctx.base_offset + img_open + 1),
        kind: SyntaxTokenKind::LinkSyntax,
        is_revealed: ctx.is_active_line,
    });
    ctx.syntax_fold_spans.push(SyntaxFoldSpan {
        byte_range: (ctx.base_offset + img_bracket_close)
            ..(ctx.base_offset + outer_paren_close + 1),
        kind: SyntaxTokenKind::LinkSyntax,
        is_revealed: ctx.is_active_line,
    });
    let alt = ctx.line_slice[img_open + 1..img_bracket_close].to_string();
    let (url, title) =
        parse_markdown_link_dest_and_title(&ctx.line_slice[img_url_start..img_paren_close]);
    ctx.block_decorations.push(MarkdownBlockDecoration {
        byte_range: (ctx.base_offset + i)..(ctx.base_offset + outer_paren_close + 1),
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
    Some(outer_paren_close + 1)
}

fn scan_html_img_tag(
    ctx: &mut InlineScanContext<'_>,
    tag_name: &str,
    attrs: &str,
    open_lt: usize,
    open_gt: usize,
) -> Option<usize> {
    let mut end_idx = open_gt + 1;
    let mut inner_slice = "";
    if tag_name == "video" {
        if let Some(close_rel) = ctx.line_slice[open_gt + 1..]
            .to_ascii_lowercase()
            .find("</video>")
        {
            inner_slice = &ctx.line_slice[open_gt + 1..open_gt + 1 + close_rel];
            end_idx = open_gt + 1 + close_rel + "</video>".len();
        }
    }
    let raw_src =
        extract_html_attr(attrs, "src").or_else(|| extract_html_attr(inner_slice, "src"))?;
    let src = raw_src.replace("&amp;", "&");
    let alt = extract_html_attr(attrs, "alt").unwrap_or_default();
    let title = extract_html_attr(attrs, "title");
    let width = extract_html_attr(attrs, "width")
        .and_then(|w| w.trim_end_matches("px").parse::<u32>().ok());
    let height = extract_html_attr(attrs, "height")
        .and_then(|h| h.trim_end_matches("px").parse::<u32>().ok());
    ctx.syntax_fold_spans.push(SyntaxFoldSpan {
        byte_range: (ctx.base_offset + open_lt)..(ctx.base_offset + end_idx),
        kind: SyntaxTokenKind::HtmlTag,
        is_revealed: ctx.is_active_line,
    });
    ctx.block_decorations.push(MarkdownBlockDecoration {
        byte_range: (ctx.base_offset + open_lt)..(ctx.base_offset + end_idx),
        line_number: ctx.line_number,
        kind: MarkdownBlockDecorationKind::Image {
            alt,
            url: src,
            title,
            width,
            height,
            is_html: true,
            is_active: ctx.is_active_line,
        },
    });
    Some(end_idx)
}

fn map_paired_html_tag(tag_name: &str) -> Option<HtmlInlineTagKind> {
    use HtmlInlineTagKind::{
        Bold, Code, Details, Italic, Kbd, Mark, Span, Strikethrough, Subscript, Summary,
        Superscript, Underline,
    };
    match tag_name {
        "kbd" => Some(Kbd),
        "u" | "ins" => Some(Underline),
        "s" | "del" | "strike" => Some(Strikethrough),
        "mark" => Some(Mark),
        "sup" => Some(Superscript),
        "sub" => Some(Subscript),
        "b" | "strong" => Some(Bold),
        "i" | "em" => Some(Italic),
        "code" => Some(Code),
        "details" => Some(Details),
        "summary" => Some(Summary),
        "span" => Some(Span),
        _ => None,
    }
}

fn scan_inline_svg_tag(
    ctx: &mut InlineScanContext<'_>,
    open_lt: usize,
    open_gt: usize,
) -> Option<usize> {
    let close_rel = ctx.line_slice[open_gt + 1..]
        .to_ascii_lowercase()
        .find("</svg>")?;
    let svg_end = open_gt + 1 + close_rel + "</svg>".len();
    let (norm_svg, w, h) = crate::mermaid::normalize_svg_markup(&ctx.line_slice[open_lt..svg_end])?;
    let span = (ctx.base_offset + open_lt)..(ctx.base_offset + svg_end);
    ctx.syntax_fold_spans.push(SyntaxFoldSpan {
        byte_range: span.clone(),
        kind: SyntaxTokenKind::HtmlTag,
        is_revealed: ctx.is_active_line,
    });
    ctx.block_decorations.push(MarkdownBlockDecoration {
        byte_range: span,
        line_number: ctx.line_number,
        kind: MarkdownBlockDecorationKind::SvgBlock {
            svg: norm_svg,
            width: w,
            height: h,
            is_active: ctx.is_active_line,
        },
    });
    Some(svg_end)
}

pub(crate) fn try_scan_inline_html_tag(
    ctx: &mut InlineScanContext<'_>,
    open_lt: usize,
    open_gt: usize,
) -> Option<usize> {
    let raw_inner = ctx.line_slice[open_lt + 1..open_gt].trim();
    if raw_inner.is_empty() {
        return None;
    }
    if let Some(closing_name) = raw_inner.strip_prefix('/') {
        if matches!(
            closing_name.trim().to_ascii_lowercase().as_str(),
            "details" | "summary"
        ) {
            ctx.syntax_fold_spans.push(SyntaxFoldSpan {
                byte_range: (ctx.base_offset + open_lt)..(ctx.base_offset + open_gt + 1),
                kind: SyntaxTokenKind::HtmlTag,
                is_revealed: ctx.is_active_line,
            });
            return Some(open_gt + 1);
        }
        return None;
    }

    let without_self_close = raw_inner.trim_end_matches('/').trim();
    let tag_end = without_self_close
        .find(char::is_whitespace)
        .unwrap_or(without_self_close.len());
    let tag_name = without_self_close[..tag_end].to_ascii_lowercase();
    let attrs = &without_self_close[tag_end..];

    match tag_name.as_str() {
        "img" | "video" => return scan_html_img_tag(ctx, &tag_name, attrs, open_lt, open_gt),
        "svg" => return scan_inline_svg_tag(ctx, open_lt, open_gt),
        "br" => {
            let span = (ctx.base_offset + open_lt)..(ctx.base_offset + open_gt + 1);
            ctx.syntax_fold_spans.push(SyntaxFoldSpan {
                byte_range: span.clone(),
                kind: SyntaxTokenKind::HtmlTag,
                is_revealed: ctx.is_active_line,
            });
            ctx.block_decorations.push(MarkdownBlockDecoration {
                byte_range: span.clone(),
                line_number: ctx.line_number,
                kind: MarkdownBlockDecorationKind::HtmlInline {
                    tag: HtmlInlineTagKind::LineBreak,
                    content_range: span,
                    is_active: ctx.is_active_line,
                },
            });
            return Some(open_gt + 1);
        }
        _ => {}
    }

    let inline_kind = map_paired_html_tag(&tag_name)?;
    scan_paired_html_tag(ctx, &tag_name, inline_kind, open_lt, open_gt)
}

fn scan_paired_html_tag(
    ctx: &mut InlineScanContext<'_>,
    tag_name: &str,
    inline_kind: HtmlInlineTagKind,
    open_lt: usize,
    open_gt: usize,
) -> Option<usize> {
    let close_pat = format!("</{tag_name}>");
    if let Some(close_rel) = ctx.line_slice[open_gt + 1..]
        .to_ascii_lowercase()
        .find(&close_pat)
    {
        let (content_start, content_end) = (open_gt + 1, open_gt + 1 + close_rel);
        let close_end = content_end + close_pat.len();
        for range in [
            (ctx.base_offset + open_lt)..(ctx.base_offset + open_gt + 1),
            (ctx.base_offset + content_end)..(ctx.base_offset + close_end),
        ] {
            ctx.syntax_fold_spans.push(SyntaxFoldSpan {
                byte_range: range,
                kind: SyntaxTokenKind::HtmlTag,
                is_revealed: ctx.is_active_line,
            });
        }
        ctx.block_decorations.push(MarkdownBlockDecoration {
            byte_range: (ctx.base_offset + open_lt)..(ctx.base_offset + close_end),
            line_number: ctx.line_number,
            kind: MarkdownBlockDecorationKind::HtmlInline {
                tag: inline_kind,
                content_range: (ctx.base_offset + content_start)..(ctx.base_offset + content_end),
                is_active: ctx.is_active_line,
            },
        });
        if inline_kind == HtmlInlineTagKind::Code && content_end > content_start {
            ctx.block_decorations.push(MarkdownBlockDecoration {
                byte_range: (ctx.base_offset + content_start)..(ctx.base_offset + content_end),
                line_number: ctx.line_number,
                kind: MarkdownBlockDecorationKind::InlineCode,
            });
        } else if content_end > content_start {
            scan_inline_spans(
                &ctx.line_slice[content_start..content_end],
                ctx.base_offset + content_start,
                ctx.line_number,
                ctx.is_active_line,
                ctx.dim_factor,
                ctx.syntax_fold_spans,
                ctx.block_decorations,
            );
        }
        return Some(close_end);
    }

    matches!(
        inline_kind,
        HtmlInlineTagKind::Details | HtmlInlineTagKind::Summary
    )
    .then(|| {
        ctx.syntax_fold_spans.push(SyntaxFoldSpan {
            byte_range: (ctx.base_offset + open_lt)..(ctx.base_offset + open_gt + 1),
            kind: SyntaxTokenKind::HtmlTag,
            is_revealed: ctx.is_active_line,
        });
        open_gt + 1
    })
}
