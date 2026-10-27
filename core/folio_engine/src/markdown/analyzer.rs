use super::block_handlers::{
    handle_code_fence_line, handle_math_or_hr_or_heading, try_handle_setext_heading,
};
use super::block_scanner::parse_atx_heading_line;
use super::inline_scanner::scan_inline_spans;
use super::tables::{
    handle_blockquote_or_table, is_gfm_table_candidate_line, is_gfm_table_delimiter_row,
};
use super::types::{
    MarkdownAnalysis, MarkdownBlockDecoration, MarkdownBlockDecorationKind, OutlineHeadingItem,
    SyntaxFoldSpan, SyntaxTokenKind,
};

pub(crate) struct BlockScanState {
    pub in_code_fence: bool,
    pub fence_marker_char: u8,
    pub fence_marker_len: usize,
    pub current_fence_lang: String,
    pub fence_start_offset: usize,
    pub fence_start_line: usize,
    pub fence_lines: Vec<String>,
    pub fence_active: bool,
    pub in_svg_block: bool,
    pub svg_block_start_offset: usize,
    pub svg_block_start_line: usize,
    pub svg_block_lines: Vec<String>,
    pub svg_block_active: bool,
    pub in_math_block: bool,
    pub math_block_start_offset: usize,
    pub math_block_start_line: usize,
    pub math_block_lines: Vec<String>,
    pub math_block_active: bool,
    pub math_block_open_span_index: Option<usize>,
    pub in_table: bool,
    pub table_seen_separator: bool,
}

impl Default for BlockScanState {
    fn default() -> Self {
        Self {
            in_code_fence: false,
            fence_marker_char: b'`',
            fence_marker_len: 0,
            current_fence_lang: String::new(),
            fence_start_offset: 0,
            fence_start_line: 1,
            fence_lines: Vec::new(),
            fence_active: false,
            in_svg_block: false,
            svg_block_start_offset: 0,
            svg_block_start_line: 1,
            svg_block_lines: Vec::new(),
            svg_block_active: false,
            in_math_block: false,
            math_block_start_offset: 0,
            math_block_start_line: 1,
            math_block_lines: Vec::new(),
            math_block_active: false,
            math_block_open_span_index: None,
            in_table: false,
            table_seen_separator: false,
        }
    }
}

pub(crate) struct LineContext<'a> {
    pub content_line: &'a str,
    pub next_content_line: &'a str,
    pub line_start: usize,
    pub line_end: usize,
    pub content_end: usize,
    pub line_number: usize,
    pub effective_active: bool,
    pub dim_factor: f64,
    pub focus_mode: bool,
    pub is_dark: bool,
}

fn update_table_state(
    state: &mut BlockScanState,
    content_line: &str,
    next_content_line: &str,
) -> bool {
    let trimmed = content_line.trim();
    let is_table_start = !state.in_table
        && is_gfm_table_candidate_line(content_line)
        && !is_gfm_table_delimiter_row(content_line)
        && is_gfm_table_delimiter_row(next_content_line);
    let is_legacy_pipe_row =
        trimmed.starts_with('|') && trimmed.ends_with('|') && trimmed.len() >= 3;
    let is_table_line = if state.in_table {
        is_gfm_table_candidate_line(content_line)
    } else {
        is_table_start || is_legacy_pipe_row
    };
    if !is_table_line {
        state.in_table = false;
        state.table_seen_separator = false;
    }
    is_table_line
}

fn handle_svg_block_continuation(
    state: &mut BlockScanState,
    ctx: &LineContext<'_>,
    out: &mut MarkdownAnalysis,
) {
    if ctx.effective_active {
        state.svg_block_active = true;
    }
    state.svg_block_lines.push(ctx.content_line.to_string());
    if ctx.content_line.trim().contains("</svg>") {
        let raw_svg = state.svg_block_lines.join("\n");
        if let Some((norm_svg, w, h)) = crate::mermaid::normalize_svg_markup(&raw_svg) {
            out.syntax_fold_spans.push(SyntaxFoldSpan {
                byte_range: state.svg_block_start_offset..ctx.content_end,
                kind: SyntaxTokenKind::HtmlTag,
                is_revealed: state.svg_block_active,
            });
            out.block_decorations.push(MarkdownBlockDecoration {
                byte_range: state.svg_block_start_offset..ctx.line_end,
                line_number: state.svg_block_start_line,
                kind: MarkdownBlockDecorationKind::SvgBlock {
                    svg: norm_svg,
                    width: w,
                    height: h,
                    is_active: state.svg_block_active,
                },
            });
        }
        state.in_svg_block = false;
        state.svg_block_lines.clear();
    }
}

fn handle_math_block_continuation(
    state: &mut BlockScanState,
    ctx: &LineContext<'_>,
    out: &mut MarkdownAnalysis,
) {
    if ctx.effective_active {
        state.math_block_active = true;
    }
    if ctx.content_line.trim().starts_with("$$") {
        if let Some(open_idx) = state.math_block_open_span_index.take() {
            if let Some(open_span) = out.syntax_fold_spans.get_mut(open_idx) {
                open_span.is_revealed = state.math_block_active;
            }
        }
        out.syntax_fold_spans.push(SyntaxFoldSpan {
            byte_range: ctx.line_start..ctx.content_end,
            kind: SyntaxTokenKind::MathBlockDelimiter,
            is_revealed: state.math_block_active,
        });
        let latex = state.math_block_lines.join(" ").trim().to_string();
        out.block_decorations.push(MarkdownBlockDecoration {
            byte_range: state.math_block_start_offset..ctx.line_end,
            line_number: state.math_block_start_line,
            kind: MarkdownBlockDecorationKind::MathBlockRendered {
                latex,
                is_active: state.math_block_active,
                dim_factor: if ctx.focus_mode && !state.math_block_active {
                    0.30
                } else {
                    1.0
                },
            },
        });
        state.in_math_block = false;
        state.math_block_lines.clear();
    } else {
        state.math_block_lines.push(ctx.content_line.to_string());
    }
}

pub fn analyze_markdown_document(
    text: &str,
    cursor_byte_offset: usize,
    source_code_mode: bool,
    focus_mode: bool,
) -> MarkdownAnalysis {
    analyze_markdown_document_with_options(
        text,
        cursor_byte_offset,
        source_code_mode,
        focus_mode,
        true,
        true,
    )
}

pub fn analyze_markdown_document_with_options(
    text: &str,
    cursor_byte_offset: usize,
    source_code_mode: bool,
    focus_mode: bool,
    pretty_mode: bool,
    is_dark: bool,
) -> MarkdownAnalysis {
    if text.is_empty() {
        return MarkdownAnalysis::default();
    }

    let mut out = MarkdownAnalysis::default();
    let mut state = BlockScanState::default();

    let raw_lines: Vec<&str> = text.split_inclusive('\n').collect();
    let mut line_offsets: Vec<usize> = Vec::with_capacity(raw_lines.len());
    let mut acc = 0usize;
    for l in &raw_lines {
        line_offsets.push(acc);
        acc += l.len();
    }

    let mut idx = 0usize;
    while idx < raw_lines.len() {
        let raw_line = raw_lines[idx];
        let line_start = line_offsets[idx];
        let line_end = line_start + raw_line.len();
        let line_number = idx + 1;
        let content_line = raw_line.trim_end_matches(&['\r', '\n'][..]);
        let content_end = line_start + content_line.len();
        let is_active_line = cursor_byte_offset >= line_start && cursor_byte_offset <= content_end;
        let effective_active = is_active_line || !pretty_mode;
        let dim_factor = if focus_mode && !is_active_line {
            0.30
        } else {
            1.0
        };
        let next_content_line = raw_lines
            .get(idx + 1)
            .map(|l| l.trim_end_matches(&['\r', '\n'][..]))
            .unwrap_or("");

        let is_table_line = update_table_state(&mut state, content_line, next_content_line);

        if source_code_mode {
            if let Some((level, _, _, title)) = parse_atx_heading_line(content_line) {
                out.headings.push(OutlineHeadingItem {
                    level,
                    title: title.to_string(),
                    byte_offset: line_start,
                    line_number,
                });
            }
            idx += 1;
            continue;
        }

        let line_ctx = LineContext {
            content_line,
            next_content_line,
            line_start,
            line_end,
            content_end,
            line_number,
            effective_active,
            dim_factor,
            focus_mode,
            is_dark,
        };

        if process_single_line(
            &mut state,
            &line_ctx,
            is_table_line,
            raw_lines
                .get(idx + 1)
                .map(|l| (line_offsets[idx + 1], l.len())),
            cursor_byte_offset,
            &mut out,
        ) {
            idx += 2;
        } else {
            idx += 1;
        }
    }

    out
}

fn process_single_line(
    state: &mut BlockScanState,
    line_ctx: &LineContext<'_>,
    is_table_line: bool,
    next_line_span: Option<(usize, usize)>,
    cursor_byte_offset: usize,
    out: &mut MarkdownAnalysis,
) -> bool {
    if state.in_svg_block {
        handle_svg_block_continuation(state, line_ctx, out);
        return false;
    }
    if state.in_math_block {
        handle_math_block_continuation(state, line_ctx, out);
        return false;
    }
    if handle_code_fence_line(state, line_ctx, out)
        || handle_math_or_hr_or_heading(state, line_ctx, out)
    {
        return false;
    }
    if let Some((next_start, next_len)) = next_line_span {
        if try_handle_setext_heading(
            state,
            line_ctx,
            next_start,
            next_len,
            cursor_byte_offset,
            out,
        ) {
            return true;
        }
    }
    if !handle_blockquote_or_table(state, line_ctx, is_table_line, out) {
        scan_inline_spans(
            line_ctx.content_line,
            line_ctx.line_start,
            line_ctx.line_number,
            line_ctx.effective_active,
            line_ctx.dim_factor,
            &mut out.syntax_fold_spans,
            &mut out.block_decorations,
        );
    }
    false
}
