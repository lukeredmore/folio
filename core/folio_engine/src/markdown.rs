use std::ops::Range;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum NewlineAction {
    Default,
    ClearEmptyListLine,
    InsertPrefix(String),
}

pub fn compute_newline_continuation(line_up_to_cursor: &str) -> NewlineAction {
    let bytes = line_up_to_cursor.as_bytes();
    let mut ws_end = 0;
    while ws_end < bytes.len() && (bytes[ws_end] == b' ' || bytes[ws_end] == b'\t') {
        ws_end += 1;
    }

    let after_ws = &line_up_to_cursor[ws_end..];

    // 1. Check unordered / task list: '-', '*', '+' followed by whitespace
    if let Some(first) = after_ws.chars().next() {
        if (first == '-' || first == '*' || first == '+')
            && after_ws[1..].starts_with(|c: char| c == ' ' || c == '\t')
        {
            let mut bullet_ws_end = 1;
            let after_b = after_ws.as_bytes();
            while bullet_ws_end < after_b.len()
                && (after_b[bullet_ws_end] == b' ' || after_b[bullet_ws_end] == b'\t')
            {
                bullet_ws_end += 1;
            }

            let after_bullet = &after_ws[bullet_ws_end..];

            // Check task list: [ ], [x], [X] followed by whitespace
            if after_bullet.len() >= 4 {
                let box_part = &after_bullet[..3];
                if (box_part == "[ ]" || box_part == "[x]" || box_part == "[X]")
                    && after_bullet[3..].starts_with(|c: char| c == ' ' || c == '\t')
                {
                    let mut box_ws_end = 3;
                    let ab_bytes = after_bullet.as_bytes();
                    while box_ws_end < ab_bytes.len()
                        && (ab_bytes[box_ws_end] == b' ' || ab_bytes[box_ws_end] == b'\t')
                    {
                        box_ws_end += 1;
                    }
                    let prefix_len = ws_end + bullet_ws_end + box_ws_end;
                    let prefix = &line_up_to_cursor[..prefix_len];
                    let remainder = line_up_to_cursor[prefix_len..].trim();
                    if remainder.is_empty() {
                        return NewlineAction::ClearEmptyListLine;
                    }
                    let unchecked = prefix.replace("[x]", "[ ]").replace("[X]", "[ ]");
                    return NewlineAction::InsertPrefix(unchecked);
                }
            }

            // Regular unordered list
            let prefix_len = ws_end + bullet_ws_end;
            let prefix = &line_up_to_cursor[..prefix_len];
            let remainder = line_up_to_cursor[prefix_len..].trim();
            if remainder.is_empty() {
                return NewlineAction::ClearEmptyListLine;
            }
            return NewlineAction::InsertPrefix(prefix.to_string());
        }
    }

    // 2. Check ordered list: digits + ". "
    let mut digit_end = 0;
    let aw_bytes = after_ws.as_bytes();
    while digit_end < aw_bytes.len() && aw_bytes[digit_end].is_ascii_digit() {
        digit_end += 1;
    }
    if digit_end > 0 && digit_end + 1 < aw_bytes.len() && aw_bytes[digit_end] == b'.' {
        let after_dot = &after_ws[digit_end + 1..];
        if after_dot.starts_with(|c: char| c == ' ' || c == '\t') {
            let mut dot_ws_end = 0;
            let ad_bytes = after_dot.as_bytes();
            while dot_ws_end < ad_bytes.len()
                && (ad_bytes[dot_ws_end] == b' ' || ad_bytes[dot_ws_end] == b'\t')
            {
                dot_ws_end += 1;
            }
            let prefix_len = ws_end + digit_end + 1 + dot_ws_end;
            let remainder = line_up_to_cursor[prefix_len..].trim();
            if remainder.is_empty() {
                return NewlineAction::ClearEmptyListLine;
            }
            let leading_space = &line_up_to_cursor[..ws_end];
            let digits_str = &after_ws[..digit_end];
            let next_num = digits_str.parse::<usize>().unwrap_or(1) + 1;
            return NewlineAction::InsertPrefix(format!("{}{}. ", leading_space, next_num));
        }
    }

    NewlineAction::Default
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OutlineHeadingItem {
    pub level: usize,
    pub title: String,
    pub byte_offset: usize,
    pub line_number: usize,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SyntaxTokenKind {
    HeadingHashes,
    BlockquoteMarker,
    CodeFenceDelimiter,
    MathBlockDelimiter,
    InlineCodeBackticks,
    InlineMathDollar,
    BoldMarker,
    ItalicMarker,
    StrikethroughMarker,
    HighlightMarker,
    LinkSyntax,
    TaskListMarker,
    HorizontalRule,
    TablePipeDelimiter,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SyntaxFoldSpan {
    pub byte_range: Range<usize>,
    pub kind: SyntaxTokenKind,
    pub is_revealed: bool,
}

#[derive(Debug, Clone, PartialEq)]
pub enum MarkdownBlockDecorationKind {
    HeadingUnderline { level: usize },
    Blockquote { nest_level: usize },
    CodeFenceStart { language: String },
    CodeFenceBody { language: String },
    CodeFenceEnd,
    InlineCode,
    MathBlockRendered {
        latex: String,
        is_active: bool,
        dim_factor: f64,
    },
    InlineMathRendered {
        latex: String,
        is_active: bool,
        dim_factor: f64,
    },
    HorizontalRule,
    TableRow {
        is_header: bool,
        is_separator: bool,
        columns: Vec<String>,
    },
}

/// Replaces the language identifier on a fenced code block opening line (` ```lang `)
/// starting at `fence_start_byte_offset` in `text`, returning the updated document string.
pub fn replace_code_fence_language(
    text: &str,
    fence_start_byte_offset: usize,
    new_language: &str,
) -> Option<String> {
    if fence_start_byte_offset >= text.len() {
        return None;
    }
    let rest = &text[fence_start_byte_offset..];
    let line_len = rest.find('\n').unwrap_or(rest.len());
    let raw_line = &rest[..line_len];
    let content_line = raw_line.trim_end_matches('\r');

    let ws_len = content_line.len() - content_line.trim_start().len();
    let after_ws = &content_line[ws_len..];
    if !after_ws.starts_with("```") {
        return None;
    }
    let tick_count = after_ws.bytes().take_while(|&b| b == b'`').count();
    let prefix = &content_line[..ws_len + tick_count];
    let normalized_lang = new_language.trim();

    let mut updated = String::with_capacity(text.len() + normalized_lang.len());
    updated.push_str(&text[..fence_start_byte_offset]);
    updated.push_str(prefix);
    updated.push_str(normalized_lang);
    updated.push_str(&raw_line[content_line.len()..]);
    updated.push_str(&rest[line_len..]);
    Some(updated)
}

#[derive(Debug, Clone, PartialEq)]
pub struct MarkdownBlockDecoration {
    pub byte_range: Range<usize>,
    pub line_number: usize,
    pub kind: MarkdownBlockDecorationKind,
}

#[derive(Debug, Clone, Default, PartialEq)]
pub struct MarkdownAnalysis {
    pub headings: Vec<OutlineHeadingItem>,
    pub syntax_fold_spans: Vec<SyntaxFoldSpan>,
    pub block_decorations: Vec<MarkdownBlockDecoration>,
}

pub fn analyze_markdown_document(
    text: &str,
    cursor_byte_offset: usize,
    source_code_mode: bool,
    focus_mode: bool,
) -> MarkdownAnalysis {
    if text.is_empty() {
        return MarkdownAnalysis::default();
    }

    let mut headings = Vec::new();
    let mut syntax_fold_spans: Vec<SyntaxFoldSpan> = Vec::new();
    let mut block_decorations = Vec::new();

    let mut in_code_fence = false;
    let mut current_fence_lang = String::new();
    let mut in_math_block = false;
    let mut math_block_start_offset = 0usize;
    let mut math_block_start_line = 1usize;
    let mut math_block_lines: Vec<String> = Vec::new();
    let mut math_block_active = false;
    let mut math_block_open_span_index: Option<usize> = None;
    let mut in_table = false;
    let mut table_seen_separator = false;

    let mut line_start = 0usize;
    let mut line_number = 1usize;

    for raw_line in text.split_inclusive('\n') {
        let line_end = line_start + raw_line.len();
        let content_line = raw_line.trim_end_matches(&['\r', '\n'][..]);
        let content_end = line_start + content_line.len();
        let is_active_line = cursor_byte_offset >= line_start && cursor_byte_offset <= content_end;
        let dim_factor = if focus_mode && !is_active_line {
            0.30
        } else {
            1.0
        };

        let trimmed = content_line.trim();
        let is_table_line = trimmed.starts_with('|') && trimmed.ends_with('|') && trimmed.len() >= 3;
        if !is_table_line {
            in_table = false;
            table_seen_separator = false;
        }

        if source_code_mode {
            if let Some((level, _prefix_len, title)) = parse_heading_line(content_line) {
                headings.push(OutlineHeadingItem {
                    level,
                    title: title.to_string(),
                    byte_offset: line_start,
                    line_number,
                });
            }
            line_start = line_end;
            line_number += 1;
            continue;
        }

        // Handle multi-line $$ math block continuation
        if in_math_block {
            if is_active_line {
                math_block_active = true;
            }
            if trimmed.starts_with("$$") {
                if let Some(open_idx) = math_block_open_span_index.take() {
                    if let Some(open_span) = syntax_fold_spans.get_mut(open_idx) {
                        open_span.is_revealed = math_block_active;
                    }
                }
                syntax_fold_spans.push(SyntaxFoldSpan {
                    byte_range: line_start..content_end,
                    kind: SyntaxTokenKind::MathBlockDelimiter,
                    is_revealed: math_block_active,
                });
                let latex = math_block_lines.join(" ").trim().to_string();
                block_decorations.push(MarkdownBlockDecoration {
                    byte_range: math_block_start_offset..line_end,
                    line_number: math_block_start_line,
                    kind: MarkdownBlockDecorationKind::MathBlockRendered {
                        latex,
                        is_active: math_block_active,
                        dim_factor: if focus_mode && !math_block_active {
                            0.30
                        } else {
                            1.0
                        },
                    },
                });
                in_math_block = false;
                math_block_lines.clear();
            } else {
                math_block_lines.push(content_line.to_string());
            }
            line_start = line_end;
            line_number += 1;
            continue;
        }

        // 1. Code Fence (```)
        if trimmed.starts_with("```") {
            syntax_fold_spans.push(SyntaxFoldSpan {
                byte_range: line_start..content_end,
                kind: SyntaxTokenKind::CodeFenceDelimiter,
                is_revealed: is_active_line,
            });
            if !in_code_fence {
                in_code_fence = true;
                let lang = trimmed.trim_start_matches('`').trim().to_string();
                current_fence_lang = lang.clone();
                block_decorations.push(MarkdownBlockDecoration {
                    byte_range: line_start..line_end,
                    line_number,
                    kind: MarkdownBlockDecorationKind::CodeFenceStart { language: lang },
                });
            } else {
                in_code_fence = false;
                current_fence_lang.clear();
                block_decorations.push(MarkdownBlockDecoration {
                    byte_range: line_start..line_end,
                    line_number,
                    kind: MarkdownBlockDecorationKind::CodeFenceEnd,
                });
            }
            line_start = line_end;
            line_number += 1;
            continue;
        }

        if in_code_fence {
            block_decorations.push(MarkdownBlockDecoration {
                byte_range: line_start..line_end,
                line_number,
                kind: MarkdownBlockDecorationKind::CodeFenceBody {
                    language: current_fence_lang.clone(),
                },
            });
            line_start = line_end;
            line_number += 1;
            continue;
        }

        // 2. Display Math Block ($$ ... $$)
        if trimmed.starts_with("$$") {
            let is_single_line = trimmed.len() > 4 && trimmed.ends_with("$$");
            if is_single_line {
                let inner = trimmed[2..trimmed.len() - 2].trim().to_string();
                syntax_fold_spans.push(SyntaxFoldSpan {
                    byte_range: line_start..content_end,
                    kind: SyntaxTokenKind::MathBlockDelimiter,
                    is_revealed: is_active_line,
                });
                block_decorations.push(MarkdownBlockDecoration {
                    byte_range: line_start..line_end,
                    line_number,
                    kind: MarkdownBlockDecorationKind::MathBlockRendered {
                        latex: inner,
                        is_active: is_active_line,
                        dim_factor,
                    },
                });
            } else {
                in_math_block = true;
                math_block_start_offset = line_start;
                math_block_start_line = line_number;
                math_block_active = is_active_line;
                math_block_lines.clear();
                let after = trimmed[2..].trim();
                if !after.is_empty() {
                    math_block_lines.push(after.to_string());
                }
                math_block_open_span_index = Some(syntax_fold_spans.len());
                syntax_fold_spans.push(SyntaxFoldSpan {
                    byte_range: line_start..content_end,
                    kind: SyntaxTokenKind::MathBlockDelimiter,
                    is_revealed: is_active_line,
                });
            }
            line_start = line_end;
            line_number += 1;
            continue;
        }

        // 3. Horizontal Rule
        if is_horizontal_rule(trimmed) {
            syntax_fold_spans.push(SyntaxFoldSpan {
                byte_range: line_start..content_end,
                kind: SyntaxTokenKind::HorizontalRule,
                is_revealed: is_active_line,
            });
            block_decorations.push(MarkdownBlockDecoration {
                byte_range: line_start..line_end,
                line_number,
                kind: MarkdownBlockDecorationKind::HorizontalRule,
            });
            line_start = line_end;
            line_number += 1;
            continue;
        }

        // 4. Heading (# .. ######)
        if let Some((level, prefix_len, title)) = parse_heading_line(content_line) {
            headings.push(OutlineHeadingItem {
                level,
                title: title.to_string(),
                byte_offset: line_start,
                line_number,
            });
            syntax_fold_spans.push(SyntaxFoldSpan {
                byte_range: line_start..(line_start + prefix_len),
                kind: SyntaxTokenKind::HeadingHashes,
                is_revealed: is_active_line,
            });
            if level <= 2 {
                block_decorations.push(MarkdownBlockDecoration {
                    byte_range: line_start..line_end,
                    line_number,
                    kind: MarkdownBlockDecorationKind::HeadingUnderline { level },
                });
            }
            scan_inline_spans(
                &content_line[prefix_len..],
                line_start + prefix_len,
                line_number,
                is_active_line,
                dim_factor,
                &mut syntax_fold_spans,
                &mut block_decorations,
            );
            line_start = line_end;
            line_number += 1;
            continue;
        }

        // 5. Blockquote (> ...)
        if let Some((nest_level, marker_len)) = parse_blockquote_line(content_line) {
            syntax_fold_spans.push(SyntaxFoldSpan {
                byte_range: line_start..(line_start + marker_len),
                kind: SyntaxTokenKind::BlockquoteMarker,
                is_revealed: is_active_line,
            });
            block_decorations.push(MarkdownBlockDecoration {
                byte_range: line_start..line_end,
                line_number,
                kind: MarkdownBlockDecorationKind::Blockquote { nest_level },
            });
            scan_inline_spans(
                &content_line[marker_len..],
                line_start + marker_len,
                line_number,
                is_active_line,
                dim_factor,
                &mut syntax_fold_spans,
                &mut block_decorations,
            );
            line_start = line_end;
            line_number += 1;
            continue;
        }

        // 6. Table Row (| col | col |)
        if is_table_line {
            let is_sep = trimmed
                .chars()
                .all(|c| matches!(c, '|' | '-' | ':' | ' ' | '\t'));
            let is_header = !in_table && !is_sep;
            in_table = true;
            if is_sep {
                table_seen_separator = true;
            }
            let cols: Vec<String> = trimmed[1..trimmed.len() - 1]
                .split('|')
                .map(|s| s.trim().to_string())
                .collect();
            block_decorations.push(MarkdownBlockDecoration {
                byte_range: line_start..line_end,
                line_number,
                kind: MarkdownBlockDecorationKind::TableRow {
                    is_header: is_header && !table_seen_separator,
                    is_separator: is_sep,
                    columns: cols,
                },
            });
            if !is_sep {
                scan_inline_spans(
                    content_line,
                    line_start,
                    line_number,
                    is_active_line,
                    dim_factor,
                    &mut syntax_fold_spans,
                    &mut block_decorations,
                );
            }
            line_start = line_end;
            line_number += 1;
            continue;
        }

        // Default paragraph / list line: scan inline formatting & math spans
        scan_inline_spans(
            content_line,
            line_start,
            line_number,
            is_active_line,
            dim_factor,
            &mut syntax_fold_spans,
            &mut block_decorations,
        );

        line_start = line_end;
        line_number += 1;
    }

    MarkdownAnalysis {
        headings,
        syntax_fold_spans,
        block_decorations,
    }
}

fn parse_heading_line(line: &str) -> Option<(usize, usize, &str)> {
    let bytes = line.as_bytes();
    let mut hashes = 0;
    while hashes < bytes.len() && bytes[hashes] == b'#' {
        hashes += 1;
    }
    if !(1..=6).contains(&hashes) {
        return None;
    }
    let mut spaces = 0;
    while hashes + spaces < bytes.len()
        && (bytes[hashes + spaces] == b' ' || bytes[hashes + spaces] == b'\t')
    {
        spaces += 1;
    }
    if spaces == 0 {
        return None;
    }
    let prefix_len = hashes + spaces;
    let title = line[prefix_len..].trim();
    if title.is_empty() {
        return None;
    }
    Some((hashes, prefix_len, title))
}

fn parse_blockquote_line(line: &str) -> Option<(usize, usize)> {
    let bytes = line.as_bytes();
    let mut i = 0;
    let mut nest = 0;
    while i < bytes.len() {
        if bytes[i] == b' ' || bytes[i] == b'\t' {
            i += 1;
        } else if bytes[i] == b'>' {
            nest += 1;
            i += 1;
        } else {
            break;
        }
    }
    if nest > 0 {
        Some((nest, i))
    } else {
        None
    }
}

fn is_horizontal_rule(trimmed: &str) -> bool {
    if trimmed.len() < 3 {
        return false;
    }
    let check_marker = |marker: char| -> bool {
        let count = trimmed.chars().filter(|&c| c == marker).count();
        count >= 3 && trimmed.chars().all(|c| c == marker || c == ' ' || c == '\t')
    };
    check_marker('-') || check_marker('*') || check_marker('_')
}

fn scan_inline_spans(
    line_slice: &str,
    base_offset: usize,
    line_number: usize,
    is_active_line: bool,
    dim_factor: f64,
    syntax_fold_spans: &mut Vec<SyntaxFoldSpan>,
    block_decorations: &mut Vec<MarkdownBlockDecoration>,
) {
    let bytes = line_slice.as_bytes();
    let mut i = 0;

    while i < bytes.len() {
        // 1. Multi-backtick CommonMark code spans (`code` or `` ` ``)
        if bytes[i] == b'`' {
            let start = i;
            let mut tick_len = 0;
            while i < bytes.len() && bytes[i] == b'`' {
                tick_len += 1;
                i += 1;
            }
            // Find matching closing run of exact length `tick_len`
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
                syntax_fold_spans.push(SyntaxFoldSpan {
                    byte_range: (base_offset + start)..(base_offset + start + tick_len),
                    kind: SyntaxTokenKind::InlineCodeBackticks,
                    is_revealed: is_active_line,
                });
                syntax_fold_spans.push(SyntaxFoldSpan {
                    byte_range: (base_offset + close_start)..(base_offset + close_end),
                    kind: SyntaxTokenKind::InlineCodeBackticks,
                    is_revealed: is_active_line,
                });
                if close_start > start + tick_len {
                    block_decorations.push(MarkdownBlockDecoration {
                        byte_range: (base_offset + start + tick_len)..(base_offset + close_start),
                        line_number,
                        kind: MarkdownBlockDecorationKind::InlineCode,
                    });
                }
                i = close_end;
                continue;
            }
            continue;
        }

        // 2. Inline Math ($...$)
        if bytes[i] == b'$' && (i + 1 < bytes.len() && bytes[i + 1] != b'$') {
            let start = i;
            let mut search = i + 1;
            let mut found_close = None;
            while search < bytes.len() {
                if bytes[search] == b'$' && bytes[search - 1] != b'\\' {
                    found_close = Some(search);
                    break;
                }
                search += 1;
            }
            if let Some(close_idx) = found_close {
                if close_idx > start + 1 {
                    let latex = line_slice[start + 1..close_idx].to_string();
                    syntax_fold_spans.push(SyntaxFoldSpan {
                        byte_range: (base_offset + start)..(base_offset + start + 1),
                        kind: SyntaxTokenKind::InlineMathDollar,
                        is_revealed: is_active_line,
                    });
                    syntax_fold_spans.push(SyntaxFoldSpan {
                        byte_range: (base_offset + close_idx)..(base_offset + close_idx + 1),
                        kind: SyntaxTokenKind::InlineMathDollar,
                        is_revealed: is_active_line,
                    });
                    block_decorations.push(MarkdownBlockDecoration {
                        byte_range: (base_offset + start)..(base_offset + close_idx + 1),
                        line_number,
                        kind: MarkdownBlockDecorationKind::InlineMathRendered {
                            latex,
                            is_active: is_active_line,
                            dim_factor,
                        },
                    });
                    i = close_idx + 1;
                    continue;
                }
            }
        }

        // 3. Bold (**text** or __text__)
        if i + 1 < bytes.len()
            && ((bytes[i] == b'*' && bytes[i + 1] == b'*')
                || (bytes[i] == b'_' && bytes[i + 1] == b'_'))
        {
            let marker = &line_slice[i..i + 2];
            if let Some(rel_end) = line_slice[i + 2..].find(marker) {
                if rel_end > 0 {
                    let close_start = i + 2 + rel_end;
                    syntax_fold_spans.push(SyntaxFoldSpan {
                        byte_range: (base_offset + i)..(base_offset + i + 2),
                        kind: SyntaxTokenKind::BoldMarker,
                        is_revealed: is_active_line,
                    });
                    syntax_fold_spans.push(SyntaxFoldSpan {
                        byte_range: (base_offset + close_start)..(base_offset + close_start + 2),
                        kind: SyntaxTokenKind::BoldMarker,
                        is_revealed: is_active_line,
                    });
                    i = close_start + 2;
                    continue;
                }
            }
        }

        // 4. Strikethrough (~~text~~)
        if i + 1 < bytes.len() && bytes[i] == b'~' && bytes[i + 1] == b'~' {
            if let Some(rel_end) = line_slice[i + 2..].find("~~") {
                if rel_end > 0 {
                    let close_start = i + 2 + rel_end;
                    syntax_fold_spans.push(SyntaxFoldSpan {
                        byte_range: (base_offset + i)..(base_offset + i + 2),
                        kind: SyntaxTokenKind::StrikethroughMarker,
                        is_revealed: is_active_line,
                    });
                    syntax_fold_spans.push(SyntaxFoldSpan {
                        byte_range: (base_offset + close_start)..(base_offset + close_start + 2),
                        kind: SyntaxTokenKind::StrikethroughMarker,
                        is_revealed: is_active_line,
                    });
                    i = close_start + 2;
                    continue;
                }
            }
        }

        // 5. Highlight (==text==)
        if i + 1 < bytes.len() && bytes[i] == b'=' && bytes[i + 1] == b'=' {
            if let Some(rel_end) = line_slice[i + 2..].find("==") {
                if rel_end > 0 {
                    let close_start = i + 2 + rel_end;
                    syntax_fold_spans.push(SyntaxFoldSpan {
                        byte_range: (base_offset + i)..(base_offset + i + 2),
                        kind: SyntaxTokenKind::HighlightMarker,
                        is_revealed: is_active_line,
                    });
                    syntax_fold_spans.push(SyntaxFoldSpan {
                        byte_range: (base_offset + close_start)..(base_offset + close_start + 2),
                        kind: SyntaxTokenKind::HighlightMarker,
                        is_revealed: is_active_line,
                    });
                    i = close_start + 2;
                    continue;
                }
            }
        }

        // 6. Italic (*text* or _text_)
        if (bytes[i] == b'*' || bytes[i] == b'_')
            && i + 1 < bytes.len()
            && bytes[i + 1] != bytes[i]
            && bytes[i + 1] != b' '
            && bytes[i + 1] != b'\t'
        {
            let delim = bytes[i];
            let prev_is_word = i > 0 && bytes[i - 1].is_ascii_alphanumeric();
            if !(delim == b'_' && prev_is_word) {
                let mut search = i + 1;
                let mut found_close = None;
                while search < bytes.len() {
                    if bytes[search] == delim
                        && bytes[search - 1] != b' '
                        && bytes[search - 1] != b'\t'
                        && (search + 1 >= bytes.len() || bytes[search + 1] != delim)
                    {
                        found_close = Some(search);
                        break;
                    }
                    search += 1;
                }
                if let Some(close_idx) = found_close {
                    if close_idx > i + 1 {
                        syntax_fold_spans.push(SyntaxFoldSpan {
                            byte_range: (base_offset + i)..(base_offset + i + 1),
                            kind: SyntaxTokenKind::ItalicMarker,
                            is_revealed: is_active_line,
                        });
                        syntax_fold_spans.push(SyntaxFoldSpan {
                            byte_range: (base_offset + close_idx)..(base_offset + close_idx + 1),
                            kind: SyntaxTokenKind::ItalicMarker,
                            is_revealed: is_active_line,
                        });
                        i = close_idx + 1;
                        continue;
                    }
                }
            }
        }

        // 7. Markdown Link [label](url)
        if bytes[i] == b'[' {
            if let Some(rel_bracket_close) = line_slice[i + 1..].find("](") {
                let bracket_close = i + 1 + rel_bracket_close;
                if bracket_close > i + 1 {
                    let url_start = bracket_close + 2;
                    if let Some(rel_paren_close) = line_slice[url_start..].find(')') {
                        let paren_close = url_start + rel_paren_close;
                        syntax_fold_spans.push(SyntaxFoldSpan {
                            byte_range: (base_offset + i)..(base_offset + i + 1),
                            kind: SyntaxTokenKind::LinkSyntax,
                            is_revealed: is_active_line,
                        });
                        syntax_fold_spans.push(SyntaxFoldSpan {
                            byte_range: (base_offset + bracket_close)..(base_offset + paren_close + 1),
                            kind: SyntaxTokenKind::LinkSyntax,
                            is_revealed: is_active_line,
                        });
                        i = paren_close + 1;
                        continue;
                    }
                }
            }
        }

        i += 1;
    }
}

