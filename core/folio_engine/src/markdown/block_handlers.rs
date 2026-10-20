use super::analyzer::{BlockScanState, LineContext};
use super::block_scanner::{
    is_closing_code_fence, is_horizontal_rule, is_list_item_line, parse_atx_heading_line,
    parse_blockquote_line, parse_opening_code_fence, parse_setext_underline,
};
use super::inline_scanner::scan_inline_spans;
use super::types::{
    MarkdownAnalysis, MarkdownBlockDecoration, MarkdownBlockDecorationKind, OutlineHeadingItem,
    SyntaxFoldSpan, SyntaxTokenKind,
};

pub(crate) fn handle_code_fence_line(
    state: &mut BlockScanState,
    ctx: &LineContext<'_>,
    out: &mut MarkdownAnalysis,
) -> bool {
    if !state.in_code_fence {
        if let Some((f_char, f_len, lang)) = parse_opening_code_fence(ctx.content_line) {
            state.in_code_fence = true;
            state.fence_marker_char = f_char;
            state.fence_marker_len = f_len;
            state.current_fence_lang = lang.clone();
            state.fence_start_offset = ctx.line_start;
            state.fence_start_line = ctx.line_number;
            state.fence_lines.clear();
            state.fence_active = ctx.effective_active;
            out.syntax_fold_spans.push(SyntaxFoldSpan {
                byte_range: ctx.line_start..ctx.content_end,
                kind: SyntaxTokenKind::CodeFenceDelimiter,
                is_revealed: ctx.effective_active,
            });
            out.block_decorations.push(MarkdownBlockDecoration {
                byte_range: ctx.line_start..ctx.line_end,
                line_number: ctx.line_number,
                kind: MarkdownBlockDecorationKind::CodeFenceStart { language: lang },
            });
            return true;
        }
        false
    } else {
        if ctx.effective_active {
            state.fence_active = true;
        }
        if is_closing_code_fence(
            ctx.content_line,
            state.fence_marker_char,
            state.fence_marker_len,
        ) {
            let finished_lang = state.current_fence_lang.to_ascii_lowercase();
            let body_source = state.fence_lines.join("\n");
            state.in_code_fence = false;
            state.current_fence_lang.clear();
            state.fence_lines.clear();
            out.syntax_fold_spans.push(SyntaxFoldSpan {
                byte_range: ctx.line_start..ctx.content_end,
                kind: SyntaxTokenKind::CodeFenceDelimiter,
                is_revealed: ctx.effective_active,
            });
            out.block_decorations.push(MarkdownBlockDecoration {
                byte_range: ctx.line_start..ctx.line_end,
                line_number: ctx.line_number,
                kind: MarkdownBlockDecorationKind::CodeFenceEnd,
            });
            emit_rich_code_fence_block(state, ctx, &finished_lang, body_source, out);
        } else {
            state.fence_lines.push(ctx.content_line.to_string());
            out.block_decorations.push(MarkdownBlockDecoration {
                byte_range: ctx.line_start..ctx.line_end,
                line_number: ctx.line_number,
                kind: MarkdownBlockDecorationKind::CodeFenceBody {
                    language: state.current_fence_lang.clone(),
                },
            });
        }
        true
    }
}

fn emit_rich_code_fence_block(
    state: &BlockScanState,
    ctx: &LineContext<'_>,
    finished_lang: &str,
    body_source: String,
    out: &mut MarkdownAnalysis,
) {
    if finished_lang == "mermaid" {
        let rendered = crate::mermaid::render_mermaid_to_svg(&body_source, ctx.is_dark);
        out.block_decorations.push(MarkdownBlockDecoration {
            byte_range: state.fence_start_offset..ctx.line_end,
            line_number: state.fence_start_line,
            kind: MarkdownBlockDecorationKind::MermaidBlock {
                source: body_source,
                svg: rendered.svg,
                width: rendered.width,
                height: rendered.height,
                is_active: state.fence_active,
            },
        });
    } else if finished_lang == "svg"
        || (finished_lang == "xml" && body_source.trim_start().starts_with("<svg"))
    {
        if let Some((norm_svg, w, h)) = crate::mermaid::normalize_svg_markup(&body_source) {
            out.block_decorations.push(MarkdownBlockDecoration {
                byte_range: state.fence_start_offset..ctx.line_end,
                line_number: state.fence_start_line,
                kind: MarkdownBlockDecorationKind::SvgBlock {
                    svg: norm_svg,
                    width: w,
                    height: h,
                    is_active: state.fence_active,
                },
            });
        }
    }
}

fn try_handle_svg_start_line(
    state: &mut BlockScanState,
    ctx: &LineContext<'_>,
    trimmed: &str,
    out: &mut MarkdownAnalysis,
) -> bool {
    if !trimmed.starts_with("<svg") {
        return false;
    }
    if trimmed.contains("</svg>") {
        if let Some((norm_svg, w, h)) = crate::mermaid::normalize_svg_markup(trimmed) {
            out.syntax_fold_spans.push(SyntaxFoldSpan {
                byte_range: ctx.line_start..ctx.content_end,
                kind: SyntaxTokenKind::HtmlTag,
                is_revealed: ctx.effective_active,
            });
            out.block_decorations.push(MarkdownBlockDecoration {
                byte_range: ctx.line_start..ctx.line_end,
                line_number: ctx.line_number,
                kind: MarkdownBlockDecorationKind::SvgBlock {
                    svg: norm_svg,
                    width: w,
                    height: h,
                    is_active: ctx.effective_active,
                },
            });
            return true;
        }
        return false;
    }
    state.in_svg_block = true;
    state.svg_block_start_offset = ctx.line_start;
    state.svg_block_start_line = ctx.line_number;
    state.svg_block_active = ctx.effective_active;
    state.svg_block_lines.clear();
    state.svg_block_lines.push(ctx.content_line.to_string());
    true
}

pub(crate) fn handle_math_or_hr_or_heading(
    state: &mut BlockScanState,
    ctx: &LineContext<'_>,
    out: &mut MarkdownAnalysis,
) -> bool {
    let trimmed = ctx.content_line.trim();
    if try_handle_svg_start_line(state, ctx, trimmed, out) {
        return true;
    }

    if let Some(after_open) = trimmed.strip_prefix("$$") {
        if !after_open.is_empty() && after_open != "$$" && after_open.ends_with("$$") {
            let inner = after_open[..after_open.len() - 2].trim().to_string();
            out.syntax_fold_spans.push(SyntaxFoldSpan {
                byte_range: ctx.line_start..ctx.content_end,
                kind: SyntaxTokenKind::MathBlockDelimiter,
                is_revealed: ctx.effective_active,
            });
            out.block_decorations.push(MarkdownBlockDecoration {
                byte_range: ctx.line_start..ctx.line_end,
                line_number: ctx.line_number,
                kind: MarkdownBlockDecorationKind::MathBlockRendered {
                    latex: inner,
                    is_active: ctx.effective_active,
                    dim_factor: ctx.dim_factor,
                },
            });
        } else {
            state.in_math_block = true;
            state.math_block_start_offset = ctx.line_start;
            state.math_block_start_line = ctx.line_number;
            state.math_block_active = ctx.effective_active;
            state.math_block_lines.clear();
            if !after_open.trim().is_empty() {
                state.math_block_lines.push(after_open.trim().to_string());
            }
            state.math_block_open_span_index = Some(out.syntax_fold_spans.len());
            out.syntax_fold_spans.push(SyntaxFoldSpan {
                byte_range: ctx.line_start..ctx.content_end,
                kind: SyntaxTokenKind::MathBlockDelimiter,
                is_revealed: ctx.effective_active,
            });
        }
        return true;
    }

    if !state.in_table && is_horizontal_rule(ctx.content_line) {
        out.syntax_fold_spans.push(SyntaxFoldSpan {
            byte_range: ctx.line_start..ctx.content_end,
            kind: SyntaxTokenKind::HorizontalRule,
            is_revealed: ctx.effective_active,
        });
        out.block_decorations.push(MarkdownBlockDecoration {
            byte_range: ctx.line_start..ctx.line_end,
            line_number: ctx.line_number,
            kind: MarkdownBlockDecorationKind::HorizontalRule,
        });
        return true;
    }

    let Some((level, prefix_len, closing_start, title)) = parse_atx_heading_line(ctx.content_line)
    else {
        return false;
    };
    out.headings.push(OutlineHeadingItem {
        level,
        title: title.to_string(),
        byte_offset: ctx.line_start,
        line_number: ctx.line_number,
    });
    out.syntax_fold_spans.push(SyntaxFoldSpan {
        byte_range: ctx.line_start..(ctx.line_start + prefix_len),
        kind: SyntaxTokenKind::HeadingHashes,
        is_revealed: ctx.effective_active,
    });
    if let Some(close_idx) =
        closing_start.filter(|&c| c > prefix_len && c < ctx.content_line.len())
    {
        out.syntax_fold_spans.push(SyntaxFoldSpan {
            byte_range: (ctx.line_start + close_idx)..ctx.content_end,
            kind: SyntaxTokenKind::HeadingHashes,
            is_revealed: ctx.effective_active,
        });
    }
    if level <= 2 {
        out.block_decorations.push(MarkdownBlockDecoration {
            byte_range: ctx.line_start..ctx.line_end,
            line_number: ctx.line_number,
            kind: MarkdownBlockDecorationKind::HeadingUnderline { level },
        });
    }
    let scan_end = closing_start.unwrap_or(ctx.content_line.len());
    if scan_end > prefix_len {
        scan_inline_spans(
            &ctx.content_line[prefix_len..scan_end],
            ctx.line_start + prefix_len,
            ctx.line_number,
            ctx.effective_active,
            ctx.dim_factor,
            &mut out.syntax_fold_spans,
            &mut out.block_decorations,
        );
    }
    true
}

pub(crate) fn try_handle_setext_heading(
    state: &BlockScanState,
    ctx: &LineContext<'_>,
    next_start: usize,
    next_raw_len: usize,
    cursor_byte_offset: usize,
    out: &mut MarkdownAnalysis,
) -> bool {
    let trimmed = ctx.content_line.trim();
    if trimmed.is_empty()
        || state.in_table
        || parse_blockquote_line(ctx.content_line).is_some()
        || is_list_item_line(ctx.content_line)
        || is_horizontal_rule(ctx.content_line)
    {
        return false;
    }
    let Some(setext_level) = parse_setext_underline(ctx.next_content_line) else {
        return false;
    };
    let next_end = next_start + next_raw_len;
    let next_content_end = next_start + ctx.next_content_line.len();
    let setext_active = ctx.effective_active
        || (cursor_byte_offset >= next_start && cursor_byte_offset <= next_content_end);

    out.headings.push(OutlineHeadingItem {
        level: setext_level,
        title: trimmed.to_string(),
        byte_offset: ctx.line_start,
        line_number: ctx.line_number,
    });
    out.syntax_fold_spans.push(SyntaxFoldSpan {
        byte_range: next_start..next_content_end,
        kind: SyntaxTokenKind::HeadingHashes,
        is_revealed: setext_active,
    });
    out.block_decorations.push(MarkdownBlockDecoration {
        byte_range: ctx.line_start..next_end,
        line_number: ctx.line_number,
        kind: MarkdownBlockDecorationKind::HeadingUnderline {
            level: setext_level,
        },
    });
    scan_inline_spans(
        ctx.content_line,
        ctx.line_start,
        ctx.line_number,
        setext_active,
        ctx.dim_factor,
        &mut out.syntax_fold_spans,
        &mut out.block_decorations,
    );
    true
}
