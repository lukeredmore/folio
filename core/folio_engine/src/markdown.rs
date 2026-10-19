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

    // 2. Check ordered list: digits + ("." or ")") + whitespace
    let mut digit_end = 0;
    let aw_bytes = after_ws.as_bytes();
    while digit_end < aw_bytes.len() && aw_bytes[digit_end].is_ascii_digit() {
        digit_end += 1;
    }
    if (1..=9).contains(&digit_end)
        && digit_end + 1 < aw_bytes.len()
        && (aw_bytes[digit_end] == b'.' || aw_bytes[digit_end] == b')')
    {
        let delim = aw_bytes[digit_end] as char;
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
            return NewlineAction::InsertPrefix(format!("{}{}{delim} ", leading_space, next_num));
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

/// Replaces the language identifier on a fenced code block opening line (` ```lang ` or ` ~~~lang `)
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
    let fence_char = if after_ws.starts_with("```") {
        b'`'
    } else if after_ws.starts_with("~~~") {
        b'~'
    } else {
        return None;
    };
    let tick_count = after_ws.bytes().take_while(|&b| b == fence_char).count();
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
    let start = if bytes.first() == Some(&b'|') { 1 } else { 0 };
    let mut end = bytes.len();
    if end > start && bytes[end - 1] == b'|' {
        // Check that trailing pipe is not escaped (`\|`)
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
            b'\\' => {
                i += 2;
            }
            b'`' => {
                let mut tick_len = 0;
                while i < sbytes.len() && sbytes[i] == b'`' {
                    tick_len += 1;
                    i += 1;
                }
                let mut search = i;
                let mut closed = None;
                while search < sbytes.len() {
                    if sbytes[search] == b'`' {
                        let mut c_len = 0;
                        while search < sbytes.len() && sbytes[search] == b'`' {
                            c_len += 1;
                            search += 1;
                        }
                        if c_len == tick_len {
                            closed = Some(search);
                            break;
                        }
                    } else {
                        search += 1;
                    }
                }
                if let Some(after_close) = closed {
                    i = after_close;
                }
            }
            b'$' => {
                i += 1;
                while i < sbytes.len() {
                    if sbytes[i] == b'\\' {
                        i += 2;
                    } else if sbytes[i] == b'$' {
                        i += 1;
                        break;
                    } else {
                        i += 1;
                    }
                }
            }
            b'|' => {
                let raw_cell = &slice[cell_start..i];
                cells.push(unescape_table_cell(raw_cell.trim()));
                i += 1;
                cell_start = i;
            }
            _ => {
                i += 1;
            }
        }
    }

    let last_cell = &slice[cell_start..];
    cells.push(unescape_table_cell(last_cell.trim()));
    cells
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
    // Check if there is at least one unescaped pipe outside backticks
    let sbytes = trimmed.as_bytes();
    let mut i = 0;
    while i < sbytes.len() {
        match sbytes[i] {
            b'\\' => i += 2,
            b'`' => {
                let mut tick_len = 0;
                while i < sbytes.len() && sbytes[i] == b'`' {
                    tick_len += 1;
                    i += 1;
                }
                while i < sbytes.len() {
                    if sbytes[i] == b'`' {
                        let mut c_len = 0;
                        while i < sbytes.len() && sbytes[i] == b'`' {
                            c_len += 1;
                            i += 1;
                        }
                        if c_len == tick_len {
                            break;
                        }
                    } else {
                        i += 1;
                    }
                }
            }
            b'|' => return true,
            _ => i += 1,
        }
    }
    false
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
    let mut fence_marker_char: u8 = b'`';
    let mut fence_marker_len: usize = 0;
    let mut current_fence_lang = String::new();

    let mut in_math_block = false;
    let mut math_block_start_offset = 0usize;
    let mut math_block_start_line = 1usize;
    let mut math_block_lines: Vec<String> = Vec::new();
    let mut math_block_active = false;
    let mut math_block_open_span_index: Option<usize> = None;

    let mut in_table = false;
    let mut table_seen_separator = false;

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
        let dim_factor = if focus_mode && !is_active_line {
            0.30
        } else {
            1.0
        };

        let trimmed = content_line.trim();

        // Determine if this line starts or continues a GFM table
        let next_content_line = raw_lines
            .get(idx + 1)
            .map(|l| l.trim_end_matches(&['\r', '\n'][..]))
            .unwrap_or("");
        let is_table_start = !in_table
            && is_gfm_table_candidate_line(content_line)
            && !is_gfm_table_delimiter_row(content_line)
            && is_gfm_table_delimiter_row(next_content_line);
        let is_legacy_pipe_row =
            trimmed.starts_with('|') && trimmed.ends_with('|') && trimmed.len() >= 3;
        let is_table_line = if in_table {
            is_gfm_table_candidate_line(content_line)
        } else {
            is_table_start || is_legacy_pipe_row
        };
        if !is_table_line {
            in_table = false;
            table_seen_separator = false;
        }

        if source_code_mode {
            if let Some((level, _prefix_len, _closing_start, title)) =
                parse_atx_heading_line(content_line)
            {
                headings.push(OutlineHeadingItem {
                    level,
                    title: title.to_string(),
                    byte_offset: line_start,
                    line_number,
                });
            }
            idx += 1;
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
            idx += 1;
            continue;
        }

        // 1. CommonMark Fenced Code Block (``` or ~~~ with up to 3 leading spaces)
        if !in_code_fence {
            if let Some((f_char, f_len, lang)) = parse_opening_code_fence(content_line) {
                in_code_fence = true;
                fence_marker_char = f_char;
                fence_marker_len = f_len;
                current_fence_lang = lang.clone();
                syntax_fold_spans.push(SyntaxFoldSpan {
                    byte_range: line_start..content_end,
                    kind: SyntaxTokenKind::CodeFenceDelimiter,
                    is_revealed: is_active_line,
                });
                block_decorations.push(MarkdownBlockDecoration {
                    byte_range: line_start..line_end,
                    line_number,
                    kind: MarkdownBlockDecorationKind::CodeFenceStart { language: lang },
                });
                idx += 1;
                continue;
            }
        } else {
            if is_closing_code_fence(content_line, fence_marker_char, fence_marker_len) {
                in_code_fence = false;
                current_fence_lang.clear();
                syntax_fold_spans.push(SyntaxFoldSpan {
                    byte_range: line_start..content_end,
                    kind: SyntaxTokenKind::CodeFenceDelimiter,
                    is_revealed: is_active_line,
                });
                block_decorations.push(MarkdownBlockDecoration {
                    byte_range: line_start..line_end,
                    line_number,
                    kind: MarkdownBlockDecorationKind::CodeFenceEnd,
                });
            } else {
                block_decorations.push(MarkdownBlockDecoration {
                    byte_range: line_start..line_end,
                    line_number,
                    kind: MarkdownBlockDecorationKind::CodeFenceBody {
                        language: current_fence_lang.clone(),
                    },
                });
            }
            idx += 1;
            continue;
        }

        // 2. Display Math Block ($$ ... $$)
        if trimmed.starts_with("$$") {
            let is_single_line = trimmed.len() >= 4 && trimmed != "$$" && trimmed.ends_with("$$");
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
            idx += 1;
            continue;
        }

        // 3. Thematic Break / Horizontal Rule (CommonMark §4.1)
        if !in_table && is_horizontal_rule(content_line) {
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
            idx += 1;
            continue;
        }

        // 4. ATX Heading (# .. ######, CommonMark §4.2)
        if let Some((level, prefix_len, closing_start, title)) =
            parse_atx_heading_line(content_line)
        {
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
            if let Some(close_idx) = closing_start {
                if close_idx > prefix_len && close_idx < content_line.len() {
                    syntax_fold_spans.push(SyntaxFoldSpan {
                        byte_range: (line_start + close_idx)..content_end,
                        kind: SyntaxTokenKind::HeadingHashes,
                        is_revealed: is_active_line,
                    });
                }
            }
            if level <= 2 {
                block_decorations.push(MarkdownBlockDecoration {
                    byte_range: line_start..line_end,
                    line_number,
                    kind: MarkdownBlockDecorationKind::HeadingUnderline { level },
                });
            }
            let scan_end = closing_start.unwrap_or(content_line.len());
            if scan_end > prefix_len {
                scan_inline_spans(
                    &content_line[prefix_len..scan_end],
                    line_start + prefix_len,
                    line_number,
                    is_active_line,
                    dim_factor,
                    &mut syntax_fold_spans,
                    &mut block_decorations,
                );
            }
            idx += 1;
            continue;
        }

        // 4b. Setext Heading (Paragraph line followed by === or ---, CommonMark §4.3)
        if !trimmed.is_empty()
            && !in_table
            && parse_blockquote_line(content_line).is_none()
            && !is_list_item_line(content_line)
            && !is_horizontal_rule(content_line)
        {
            if let Some(setext_level) = parse_setext_underline(next_content_line) {
                let next_start = line_offsets[idx + 1];
                let next_raw = raw_lines[idx + 1];
                let next_end = next_start + next_raw.len();
                let next_content_end = next_start + next_content_line.len();
                let setext_active = is_active_line
                    || (cursor_byte_offset >= next_start && cursor_byte_offset <= next_content_end);

                headings.push(OutlineHeadingItem {
                    level: setext_level,
                    title: trimmed.to_string(),
                    byte_offset: line_start,
                    line_number,
                });
                syntax_fold_spans.push(SyntaxFoldSpan {
                    byte_range: next_start..next_content_end,
                    kind: SyntaxTokenKind::HeadingHashes,
                    is_revealed: setext_active,
                });
                block_decorations.push(MarkdownBlockDecoration {
                    byte_range: line_start..next_end,
                    line_number,
                    kind: MarkdownBlockDecorationKind::HeadingUnderline {
                        level: setext_level,
                    },
                });
                scan_inline_spans(
                    content_line,
                    line_start,
                    line_number,
                    setext_active,
                    dim_factor,
                    &mut syntax_fold_spans,
                    &mut block_decorations,
                );
                idx += 2;
                continue;
            }
        }

        // 5. Blockquote (> ..., CommonMark §5.1)
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
            idx += 1;
            continue;
        }

        // 6. GFM Table Row (| col | col |)
        if is_table_line {
            let is_sep = is_gfm_table_delimiter_row(content_line);
            let is_header = !in_table && !is_sep;
            in_table = true;
            if is_sep {
                table_seen_separator = true;
            }
            let cols = split_gfm_table_cells(content_line);
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
            idx += 1;
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

        idx += 1;
    }

    MarkdownAnalysis {
        headings,
        syntax_fold_spans,
        block_decorations,
    }
}

fn count_leading_spaces(line: &str) -> usize {
    line.bytes().take_while(|&b| b == b' ').count()
}

fn parse_opening_code_fence(line: &str) -> Option<(u8, usize, String)> {
    let leading = count_leading_spaces(line);
    if leading > 3 {
        return None;
    }
    let rest = &line[leading..];
    let first = *rest.as_bytes().first()?;
    if first != b'`' && first != b'~' {
        return None;
    }
    let fence_len = rest.bytes().take_while(|&b| b == first).count();
    if fence_len < 3 {
        return None;
    }
    let info = rest[fence_len..].trim();
    // CommonMark §4.5: info strings for backtick code blocks cannot contain backticks
    if first == b'`' && info.contains('`') {
        return None;
    }
    let lang = info.split_whitespace().next().unwrap_or("").to_string();
    Some((first, fence_len, lang))
}

fn is_closing_code_fence(line: &str, fence_char: u8, min_len: usize) -> bool {
    let leading = count_leading_spaces(line);
    if leading > 3 {
        return false;
    }
    let rest = &line[leading..];
    let count = rest.bytes().take_while(|&b| b == fence_char).count();
    if count < min_len {
        return false;
    }
    rest[count..].bytes().all(|b| b == b' ' || b == b'\t')
}

/// Parses a CommonMark ATX heading line (`#`..`######` with up to 3 leading spaces and optional closing `#`s).
/// Returns `(level, prefix_byte_len, optional_closing_byte_start, trimmed_title)`.
fn parse_atx_heading_line(line: &str) -> Option<(usize, usize, Option<usize>, &str)> {
    let leading = count_leading_spaces(line);
    if leading > 3 {
        return None;
    }
    let bytes = line.as_bytes();
    let mut hashes = 0;
    while leading + hashes < bytes.len() && bytes[leading + hashes] == b'#' {
        hashes += 1;
    }
    if !(1..=6).contains(&hashes) {
        return None;
    }
    let after_hashes = leading + hashes;
    if after_hashes == bytes.len() {
        return Some((hashes, after_hashes, None, ""));
    }
    let mut spaces = 0;
    while after_hashes + spaces < bytes.len()
        && (bytes[after_hashes + spaces] == b' ' || bytes[after_hashes + spaces] == b'\t')
    {
        spaces += 1;
    }
    if spaces == 0 {
        return None;
    }
    let prefix_len = after_hashes + spaces;
    let remainder = &line[prefix_len..];

    // Check for optional closing '#' sequence (preceded by whitespace, followed only by optional whitespace)
    let trimmed_end = remainder.trim_end_matches(&[' ', '\t'][..]);
    let r_bytes = trimmed_end.as_bytes();
    let mut end_hashes = 0;
    while end_hashes < r_bytes.len() && r_bytes[r_bytes.len() - 1 - end_hashes] == b'#' {
        end_hashes += 1;
    }
    let (title_slice, closing_start) = if end_hashes > 0 {
        let before_closing = r_bytes.len() - end_hashes;
        if before_closing == 0 {
            ("", Some(prefix_len))
        } else if r_bytes[before_closing - 1] == b' ' || r_bytes[before_closing - 1] == b'\t' {
            let mut ws_start = before_closing;
            while ws_start > 0 && (r_bytes[ws_start - 1] == b' ' || r_bytes[ws_start - 1] == b'\t')
            {
                ws_start -= 1;
            }
            (&trimmed_end[..ws_start], Some(prefix_len + ws_start))
        } else {
            (trimmed_end, None)
        }
    } else {
        (trimmed_end, None)
    };

    Some((hashes, prefix_len, closing_start, title_slice.trim()))
}

fn parse_setext_underline(line: &str) -> Option<usize> {
    let leading = count_leading_spaces(line);
    if leading > 3 {
        return None;
    }
    let trimmed = line[leading..].trim_end_matches(&[' ', '\t'][..]);
    if trimmed.is_empty() {
        return None;
    }
    if trimmed.bytes().all(|b| b == b'=') {
        Some(1)
    } else if trimmed.bytes().all(|b| b == b'-') && trimmed.len() >= 2 {
        Some(2)
    } else {
        None
    }
}

fn is_list_item_line(line: &str) -> bool {
    let trimmed = line.trim_start_matches(&[' ', '\t'][..]);
    let bytes = trimmed.as_bytes();
    if bytes.len() >= 2
        && (bytes[0] == b'-' || bytes[0] == b'*' || bytes[0] == b'+')
        && (bytes[1] == b' ' || bytes[1] == b'\t')
    {
        return true;
    }
    let digits = bytes.iter().take_while(|b| b.is_ascii_digit()).count();
    if (1..=9).contains(&digits)
        && bytes.len() > digits + 1
        && (bytes[digits] == b'.' || bytes[digits] == b')')
        && (bytes[digits + 1] == b' ' || bytes[digits + 1] == b'\t')
    {
        return true;
    }
    false
}

fn parse_blockquote_line(line: &str) -> Option<(usize, usize)> {
    let leading = count_leading_spaces(line);
    if leading > 3 {
        return None;
    }
    let bytes = line.as_bytes();
    let mut i = leading;
    let mut nest = 0;
    while i < bytes.len() {
        if bytes[i] == b'>' {
            nest += 1;
            i += 1;
            if i < bytes.len() && (bytes[i] == b' ' || bytes[i] == b'\t') {
                i += 1;
            }
        } else if nest > 0 && (bytes[i] == b' ' || bytes[i] == b'\t') {
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

fn is_horizontal_rule(line: &str) -> bool {
    let leading = count_leading_spaces(line);
    if leading > 3 {
        return false;
    }
    let trimmed = line[leading..].trim();
    if trimmed.len() < 3 {
        return false;
    }
    let check_marker = |marker: char| -> bool {
        let count = trimmed.chars().filter(|&c| c == marker).count();
        count >= 3 && trimmed.chars().all(|c| c == marker || c == ' ' || c == '\t')
    };
    check_marker('-') || check_marker('*') || check_marker('_')
}

fn is_ascii_punctuation_byte(b: u8) -> bool {
    matches!(
        b,
        b'!' | b'"'
            | b'#'
            | b'$'
            | b'%'
            | b'&'
            | b'\''
            | b'('
            | b')'
            | b'*'
            | b'+'
            | b','
            | b'-'
            | b'.'
            | b'/'
            | b':'
            | b';'
            | b'<'
            | b'='
            | b'>'
            | b'?'
            | b'@'
            | b'['
            | b'\\'
            | b']'
            | b'^'
            | b'_'
            | b'`'
            | b'{'
            | b'|'
            | b'}'
            | b'~'
    )
}

fn find_unprotected_closing_marker(slice: &str, marker: &str) -> Option<usize> {
    let bytes = slice.as_bytes();
    let mbytes = marker.as_bytes();
    let mlen = mbytes.len();
    let mut i = 0;
    let mut failed_tick_mask: u64 = 0;

    while i + mlen <= bytes.len() {
        if bytes[i] == b'\\' {
            i += 2;
            continue;
        }
        // Skip inline code spans so markers inside backticks never close outer emphasis
        if bytes[i] == b'`' {
            let mut tick_len = 0;
            while i < bytes.len() && bytes[i] == b'`' {
                tick_len += 1;
                i += 1;
            }
            if tick_len < 64 && (failed_tick_mask & (1u64 << tick_len)) != 0 {
                continue;
            }
            let after_open = i;
            let mut found_close = false;
            while i < bytes.len() {
                if bytes[i] == b'`' {
                    let mut c_len = 0;
                    while i < bytes.len() && bytes[i] == b'`' {
                        c_len += 1;
                        i += 1;
                    }
                    if c_len == tick_len {
                        found_close = true;
                        break;
                    }
                } else {
                    i += 1;
                }
            }
            if !found_close {
                if tick_len < 64 {
                    failed_tick_mask |= 1u64 << tick_len;
                }
                i = after_open;
            }
            continue;
        }

        if &bytes[i..i + mlen] == mbytes {
            // For single-char emphasis (* or _), ensure it isn't part of a double marker (** or __)
            if mlen == 1 && i + 1 < bytes.len() && bytes[i + 1] == mbytes[0] {
                i += 2;
                continue;
            }
            // If preceded by whitespace, cannot be a closing marker; if also followed by non-whitespace,
            // it is another identical opening marker so abort early to keep repeated unmatched openers O(N).
            if i == 0 || bytes[i - 1] == b' ' || bytes[i - 1] == b'\t' {
                if i > 0
                    && i + mlen < bytes.len()
                    && bytes[i + mlen] != b' '
                    && bytes[i + mlen] != b'\t'
                    && bytes[i + mlen] != mbytes[0]
                {
                    return None;
                }
                i += 1;
                continue;
            }
            // CommonMark intraword rule for '_' / '__': cannot close if followed by alphanumeric
            if mbytes[0] == b'_'
                && i + mlen < bytes.len()
                && bytes[i + mlen].is_ascii_alphanumeric()
            {
                i += 1;
                continue;
            }
            return Some(i);
        }
        i += 1;
    }
    None
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
    let mut failed_tick_mask: u64 = 0;
    let mut no_closing_dollar = false;
    let mut cached_bracket_paren: Option<Option<usize>> = None;
    let mut no_closing_angle = false;

    while i < bytes.len() {
        // 0. Backslash Escape (\*, \_, \`, \|, \[, etc., CommonMark §2.4)
        if bytes[i] == b'\\' && i + 1 < bytes.len() && is_ascii_punctuation_byte(bytes[i + 1]) {
            syntax_fold_spans.push(SyntaxFoldSpan {
                byte_range: (base_offset + i)..(base_offset + i + 1),
                kind: SyntaxTokenKind::LinkSyntax,
                is_revealed: is_active_line,
            });
            i += 2;
            continue;
        }

        // 1. Multi-backtick CommonMark code spans (`code` or `` ` ``, CommonMark §6.1)
        if bytes[i] == b'`' {
            let start = i;
            let mut tick_len = 0;
            while i < bytes.len() && bytes[i] == b'`' {
                tick_len += 1;
                i += 1;
            }
            if tick_len < 64 && (failed_tick_mask & (1u64 << tick_len)) != 0 {
                continue;
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
            if tick_len < 64 {
                failed_tick_mask |= 1u64 << tick_len;
            }
            continue;
        }

        // 2. Inline Math ($...$)
        if !no_closing_dollar && bytes[i] == b'$' && (i + 1 < bytes.len() && bytes[i + 1] != b'$') {
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
            } else {
                no_closing_dollar = true;
            }
        }

        // 3. Bold+Italic (***text*** or ___text___)
        if i + 3 < bytes.len()
            && ((bytes[i] == b'*' && bytes[i + 1] == b'*' && bytes[i + 2] == b'*')
                || (bytes[i] == b'_' && bytes[i + 1] == b'_' && bytes[i + 2] == b'_'))
            && bytes[i + 3] != b' '
            && bytes[i + 3] != b'\t'
        {
            let delim = bytes[i];
            let prev_is_word = i > 0 && bytes[i - 1].is_ascii_alphanumeric();
            if !(delim == b'_' && prev_is_word) {
                let marker = &line_slice[i..i + 3];
                if let Some(rel_end) = find_unprotected_closing_marker(&line_slice[i + 3..], marker)
                {
                    let close_start = i + 3 + rel_end;
                    syntax_fold_spans.push(SyntaxFoldSpan {
                        byte_range: (base_offset + i)..(base_offset + i + 3),
                        kind: SyntaxTokenKind::BoldMarker,
                        is_revealed: is_active_line,
                    });
                    syntax_fold_spans.push(SyntaxFoldSpan {
                        byte_range: (base_offset + close_start)..(base_offset + close_start + 3),
                        kind: SyntaxTokenKind::BoldMarker,
                        is_revealed: is_active_line,
                    });
                    scan_inline_spans(
                        &line_slice[i + 3..close_start],
                        base_offset + i + 3,
                        line_number,
                        is_active_line,
                        dim_factor,
                        syntax_fold_spans,
                        block_decorations,
                    );
                    i = close_start + 3;
                    continue;
                }
            }
        }

        // 4. Bold (**text** or __text__)
        if i + 2 < bytes.len()
            && ((bytes[i] == b'*' && bytes[i + 1] == b'*')
                || (bytes[i] == b'_' && bytes[i + 1] == b'_'))
            && bytes[i + 2] != bytes[i]
            && bytes[i + 2] != b' '
            && bytes[i + 2] != b'\t'
        {
            let delim = bytes[i];
            let prev_is_word = i > 0 && bytes[i - 1].is_ascii_alphanumeric();
            if !(delim == b'_' && prev_is_word) {
                let marker = &line_slice[i..i + 2];
                if let Some(rel_end) = find_unprotected_closing_marker(&line_slice[i + 2..], marker)
                {
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
                    scan_inline_spans(
                        &line_slice[i + 2..close_start],
                        base_offset + i + 2,
                        line_number,
                        is_active_line,
                        dim_factor,
                        syntax_fold_spans,
                        block_decorations,
                    );
                    i = close_start + 2;
                    continue;
                }
            }
        }

        // 5. Strikethrough (~~text~~)
        if i + 2 < bytes.len()
            && bytes[i] == b'~'
            && bytes[i + 1] == b'~'
            && bytes[i + 2] != b' '
            && bytes[i + 2] != b'\t'
        {
            if let Some(rel_end) = find_unprotected_closing_marker(&line_slice[i + 2..], "~~") {
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
                scan_inline_spans(
                    &line_slice[i + 2..close_start],
                    base_offset + i + 2,
                    line_number,
                    is_active_line,
                    dim_factor,
                    syntax_fold_spans,
                    block_decorations,
                );
                i = close_start + 2;
                continue;
            }
        }

        // 6. Highlight (==text==)
        if i + 2 < bytes.len()
            && bytes[i] == b'='
            && bytes[i + 1] == b'='
            && bytes[i + 2] != b' '
            && bytes[i + 2] != b'\t'
        {
            if let Some(rel_end) = find_unprotected_closing_marker(&line_slice[i + 2..], "==") {
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
                scan_inline_spans(
                    &line_slice[i + 2..close_start],
                    base_offset + i + 2,
                    line_number,
                    is_active_line,
                    dim_factor,
                    syntax_fold_spans,
                    block_decorations,
                );
                i = close_start + 2;
                continue;
            }
        }

        // 7. Italic (*text* or _text_)
        if (bytes[i] == b'*' || bytes[i] == b'_')
            && i + 1 < bytes.len()
            && bytes[i + 1] != bytes[i]
            && bytes[i + 1] != b' '
            && bytes[i + 1] != b'\t'
        {
            let delim = bytes[i];
            let prev_is_word = i > 0 && bytes[i - 1].is_ascii_alphanumeric();
            if !(delim == b'_' && prev_is_word) {
                let marker = &line_slice[i..i + 1];
                if let Some(rel_end) = find_unprotected_closing_marker(&line_slice[i + 1..], marker)
                {
                    let close_idx = i + 1 + rel_end;
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
                    scan_inline_spans(
                        &line_slice[i + 1..close_idx],
                        base_offset + i + 1,
                        line_number,
                        is_active_line,
                        dim_factor,
                        syntax_fold_spans,
                        block_decorations,
                    );
                    i = close_idx + 1;
                    continue;
                }
            }
        }

        // 8. Markdown Image ![alt](url) or Link [label](url)
        if bytes[i] == b'[' || (bytes[i] == b'!' && i + 1 < bytes.len() && bytes[i + 1] == b'[') {
            let bracket_open = if bytes[i] == b'!' { i + 1 } else { i };
            let next_bp = match cached_bracket_paren {
                Some(Some(pos)) if pos > bracket_open => Some(pos),
                Some(None) => None,
                _ => {
                    let found = line_slice[bracket_open + 1..]
                        .find("](")
                        .map(|rel| bracket_open + 1 + rel);
                    cached_bracket_paren = Some(found);
                    found
                }
            };
            if let Some(bracket_close) = next_bp {
                // If there is another unescaped '[' inside (bracket_open + 1)..bracket_close,
                // let that later '[' match this `](` instead of scanning quadratically.
                let has_inner_open = bytes[bracket_open + 1..bracket_close].contains(&b'[');
                if !has_inner_open && bracket_close >= bracket_open + 1 {
                    let url_start = bracket_close + 2;
                    let mut p_depth = 1usize;
                    let mut p_idx = url_start;
                    let mut found_paren = None;
                    while p_idx < bytes.len() {
                        if bytes[p_idx] == b'\\' {
                            p_idx += 2;
                            continue;
                        }
                        if bytes[p_idx] == b'(' {
                            p_depth += 1;
                        } else if bytes[p_idx] == b')' {
                            p_depth -= 1;
                            if p_depth == 0 {
                                found_paren = Some(p_idx);
                                break;
                            }
                        }
                        p_idx += 1;
                    }
                    if let Some(paren_close) = found_paren {
                        syntax_fold_spans.push(SyntaxFoldSpan {
                            byte_range: (base_offset + i)..(base_offset + bracket_open + 1),
                            kind: SyntaxTokenKind::LinkSyntax,
                            is_revealed: is_active_line,
                        });
                        if bracket_close > bracket_open + 1 {
                            scan_inline_spans(
                                &line_slice[bracket_open + 1..bracket_close],
                                base_offset + bracket_open + 1,
                                line_number,
                                is_active_line,
                                dim_factor,
                                syntax_fold_spans,
                                block_decorations,
                            );
                        }
                        syntax_fold_spans.push(SyntaxFoldSpan {
                            byte_range: (base_offset + bracket_close)
                                ..(base_offset + paren_close + 1),
                            kind: SyntaxTokenKind::LinkSyntax,
                            is_revealed: is_active_line,
                        });
                        i = paren_close + 1;
                        continue;
                    } else {
                        // This `](` had no closing `)`, invalidate cache past `bracket_close`
                        cached_bracket_paren = line_slice
                            .get(bracket_close + 2..)
                            .and_then(|s| s.find("](").map(|rel| bracket_close + 2 + rel))
                            .into();
                    }
                }
            }
        }

        // 9. Autolinks (<https://...> or <mailto:...>, CommonMark §6.5)
        if !no_closing_angle && bytes[i] == b'<' {
            if let Some(rel_close) = line_slice[i + 1..].find('>') {
                let inner = &line_slice[i + 1..i + 1 + rel_close];
                if (inner.starts_with("http://")
                    || inner.starts_with("https://")
                    || inner.starts_with("mailto:"))
                    && !inner.contains(char::is_whitespace)
                {
                    let close_idx = i + 1 + rel_close;
                    syntax_fold_spans.push(SyntaxFoldSpan {
                        byte_range: (base_offset + i)..(base_offset + i + 1),
                        kind: SyntaxTokenKind::LinkSyntax,
                        is_revealed: is_active_line,
                    });
                    syntax_fold_spans.push(SyntaxFoldSpan {
                        byte_range: (base_offset + close_idx)..(base_offset + close_idx + 1),
                        kind: SyntaxTokenKind::LinkSyntax,
                        is_revealed: is_active_line,
                    });
                    i = close_idx + 1;
                    continue;
                }
            } else {
                no_closing_angle = true;
            }
        }

        i += 1;
    }
}

// ============================================================================
// Upstream cmark-gfm Specification Parser & AST / HTML Renderer
// ============================================================================

use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_int, c_void};
use std::sync::Once;

#[repr(C)]
struct CmarkMem {
    calloc: unsafe extern "C" fn(usize, usize) -> *mut c_void,
    realloc: unsafe extern "C" fn(*mut c_void, usize) -> *mut c_void,
    free: unsafe extern "C" fn(*mut c_void),
}

enum CmarkParser {}
enum CmarkNode {}
enum CmarkIter {}
enum CmarkSyntaxExtension {}
enum CmarkLlist {}

const CMARK_OPT_DEFAULT: c_int = 0;
const CMARK_OPT_FOOTNOTES: c_int = 1 << 13;
const CMARK_OPT_UNSAFE: c_int = 1 << 17;

const CMARK_EVENT_DONE: c_int = 1;
const CMARK_EVENT_ENTER: c_int = 2;

const CMARK_ORDERED_LIST: c_int = 2;

extern "C" {
    fn cmark_gfm_core_extensions_ensure_registered();
    fn cmark_get_default_mem_allocator() -> *mut CmarkMem;
    fn cmark_parser_new(options: c_int) -> *mut CmarkParser;
    fn cmark_parser_free(parser: *mut CmarkParser);
    fn cmark_find_syntax_extension(name: *const c_char) -> *mut CmarkSyntaxExtension;
    fn cmark_parser_attach_syntax_extension(
        parser: *mut CmarkParser,
        extension: *mut CmarkSyntaxExtension,
    ) -> c_int;
    fn cmark_parser_feed(parser: *mut CmarkParser, buffer: *const c_char, len: usize);
    fn cmark_parser_finish(parser: *mut CmarkParser) -> *mut CmarkNode;
    fn cmark_parser_get_syntax_extensions(parser: *mut CmarkParser) -> *mut CmarkLlist;
    fn cmark_render_html(
        root: *mut CmarkNode,
        options: c_int,
        extensions: *mut CmarkLlist,
    ) -> *mut c_char;
    fn cmark_node_free(node: *mut CmarkNode);
    fn cmark_iter_new(root: *mut CmarkNode) -> *mut CmarkIter;
    fn cmark_iter_free(iter: *mut CmarkIter);
    fn cmark_iter_next(iter: *mut CmarkIter) -> c_int;
    fn cmark_iter_get_node(iter: *mut CmarkIter) -> *mut CmarkNode;
    fn cmark_node_get_type_string(node: *mut CmarkNode) -> *const c_char;
    fn cmark_node_get_literal(node: *mut CmarkNode) -> *const c_char;
    fn cmark_node_get_heading_level(node: *mut CmarkNode) -> c_int;
    fn cmark_node_get_list_type(node: *mut CmarkNode) -> c_int;
    fn cmark_node_get_list_start(node: *mut CmarkNode) -> c_int;
    fn cmark_node_get_fence_info(node: *mut CmarkNode) -> *const c_char;
    fn cmark_node_get_fenced(
        node: *mut CmarkNode,
        length: *mut c_int,
        offset: *mut c_int,
        character: *mut c_char,
    ) -> c_int;
    fn cmark_node_get_url(node: *mut CmarkNode) -> *const c_char;
    fn cmark_node_get_start_line(node: *mut CmarkNode) -> c_int;
    fn cmark_node_get_start_column(node: *mut CmarkNode) -> c_int;
    fn cmark_node_get_end_line(node: *mut CmarkNode) -> c_int;
    fn cmark_node_get_end_column(node: *mut CmarkNode) -> c_int;
    fn cmark_node_first_child(node: *mut CmarkNode) -> *mut CmarkNode;
    fn cmark_node_next(node: *mut CmarkNode) -> *mut CmarkNode;
    fn cmark_node_parent(node: *mut CmarkNode) -> *mut CmarkNode;
    fn cmark_gfm_extensions_get_table_columns(node: *mut CmarkNode) -> u16;
    fn cmark_gfm_extensions_get_table_alignments(node: *mut CmarkNode) -> *const u8;
    fn cmark_gfm_extensions_get_tasklist_item_checked(node: *mut CmarkNode) -> bool;
}

static CMARK_INIT: Once = Once::new();

fn ensure_cmark_gfm_initialized() {
    CMARK_INIT.call_once(|| unsafe {
        cmark_gfm_core_extensions_ensure_registered();
    });
}

pub const DEFAULT_GFM_EXTENSIONS: &[&str] = &[
    "table",
    "strikethrough",
    "autolink",
    "tagfilter",
    "tasklist",
];

/// Renders Markdown to HTML using the upstream `cmark-gfm` specification parser
/// with the requested GFM syntax extensions.
pub fn render_markdown_to_html(markdown: &str, extensions: &[&str]) -> String {
    ensure_cmark_gfm_initialized();
    unsafe {
        let mut options = CMARK_OPT_DEFAULT | CMARK_OPT_UNSAFE;
        for &ext in extensions {
            if ext == "footnotes" {
                options |= CMARK_OPT_FOOTNOTES;
            }
        }
        let parser = cmark_parser_new(options);
        if parser.is_null() {
            return String::new();
        }
        for &ext_name in extensions {
            if ext_name == "footnotes" || ext_name.is_empty() {
                continue;
            }
            if let Ok(c_name) = CString::new(ext_name) {
                let ext = cmark_find_syntax_extension(c_name.as_ptr());
                if !ext.is_null() {
                    cmark_parser_attach_syntax_extension(parser, ext);
                }
            }
        }
        cmark_parser_feed(parser, markdown.as_ptr() as *const c_char, markdown.len());
        let doc = cmark_parser_finish(parser);
        let syntax_exts = cmark_parser_get_syntax_extensions(parser);
        let html_ptr = cmark_render_html(doc, options, syntax_exts);
        let html = if html_ptr.is_null() {
            String::new()
        } else {
            let s = CStr::from_ptr(html_ptr).to_string_lossy().into_owned();
            let mem = cmark_get_default_mem_allocator();
            if !mem.is_null() {
                ((*mem).free)(html_ptr as *mut c_void);
            }
            s
        };
        cmark_node_free(doc);
        cmark_parser_free(parser);
        html
    }
}

/// Renders GitHub Flavored Markdown (with all 5 standard GFM extensions enabled) to HTML.
pub fn render_gfm_to_html(markdown: &str) -> String {
    render_markdown_to_html(markdown, DEFAULT_GFM_EXTENSIONS)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u32)]
pub enum CmarkBlockKind {
    Heading = 1,
    CodeBlock = 2,
    ThematicBreak = 3,
    BlockQuote = 4,
    ListItem = 5,
    Table = 6,
    HtmlBlock = 7,
    Paragraph = 8,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CmarkBlockSpan {
    pub kind: CmarkBlockKind,
    pub start_line: u32,
    pub start_column: u32,
    pub end_line: u32,
    pub end_column: u32,
    pub level: u32,
    pub flags: u32,
    pub info: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u32)]
pub enum CmarkInlineKind {
    Emphasis = 1,
    Strong = 2,
    Code = 3,
    Strikethrough = 4,
    Link = 5,
    Image = 6,
    HtmlInline = 7,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CmarkInlineSpan {
    pub kind: CmarkInlineKind,
    pub start_line: u32,
    pub start_column: u32,
    pub end_line: u32,
    pub end_column: u32,
    pub url: String,
    pub literal: String,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct CmarkAstAnalysis {
    pub blocks: Vec<CmarkBlockSpan>,
    pub inlines: Vec<CmarkInlineSpan>,
}

unsafe fn collect_node_plain_text(node: *mut CmarkNode, out: &mut String) {
    if node.is_null() {
        return;
    }
    let lit = cmark_node_get_literal(node);
    if !lit.is_null() {
        out.push_str(&CStr::from_ptr(lit).to_string_lossy());
    }
    let mut child = cmark_node_first_child(node);
    while !child.is_null() {
        collect_node_plain_text(child, out);
        child = cmark_node_next(child);
    }
}

/// Parses Markdown using `cmark-gfm` and extracts all CommonMark + GFM block and inline spans,
/// including 4-space indented code blocks, Setext headings, GFM tables, and resolved reference links.
pub fn parse_cmark_gfm_ast(markdown: &str) -> CmarkAstAnalysis {
    ensure_cmark_gfm_initialized();
    let mut blocks = Vec::new();
    let mut inlines = Vec::new();
    if markdown.is_empty() {
        return CmarkAstAnalysis { blocks, inlines };
    }

    let raw_lines: Vec<&str> = markdown.lines().collect();

    unsafe {
        let options = CMARK_OPT_DEFAULT | CMARK_OPT_UNSAFE | CMARK_OPT_FOOTNOTES;
        let parser = cmark_parser_new(options);
        if parser.is_null() {
            return CmarkAstAnalysis { blocks, inlines };
        }
        for &ext_name in DEFAULT_GFM_EXTENSIONS {
            if let Ok(c_name) = CString::new(ext_name) {
                let ext = cmark_find_syntax_extension(c_name.as_ptr());
                if !ext.is_null() {
                    cmark_parser_attach_syntax_extension(parser, ext);
                }
            }
        }
        cmark_parser_feed(parser, markdown.as_ptr() as *const c_char, markdown.len());
        let doc = cmark_parser_finish(parser);
        let iter = cmark_iter_new(doc);

        loop {
            let ev = cmark_iter_next(iter);
            if ev == CMARK_EVENT_DONE {
                break;
            }
            if ev != CMARK_EVENT_ENTER {
                continue;
            }
            let node = cmark_iter_get_node(iter);
            if node.is_null() {
                continue;
            }
            let type_ptr = cmark_node_get_type_string(node);
            if type_ptr.is_null() {
                continue;
            }
            let type_str = CStr::from_ptr(type_ptr).to_str().unwrap_or("");
            let start_line = cmark_node_get_start_line(node).max(0) as u32;
            let start_column = cmark_node_get_start_column(node).max(0) as u32;
            let end_line = cmark_node_get_end_line(node).max(0) as u32;
            let end_column = cmark_node_get_end_column(node).max(0) as u32;

            match type_str {
                "heading" => {
                    let level = cmark_node_get_heading_level(node).max(1) as u32;
                    let mut is_setext = end_line > start_line;
                    if !is_setext && start_line > 0 {
                        if let Some(src_line) = raw_lines.get((start_line - 1) as usize) {
                            if !src_line.trim_start().starts_with('#') {
                                is_setext = true;
                            }
                        }
                    }
                    let mut title = String::new();
                    collect_node_plain_text(node, &mut title);
                    blocks.push(CmarkBlockSpan {
                        kind: CmarkBlockKind::Heading,
                        start_line,
                        start_column,
                        end_line,
                        end_column,
                        level,
                        flags: if is_setext { 2 } else { 0 },
                        info: title,
                    });
                }
                "code_block" => {
                    let mut fence_len: c_int = 0;
                    let mut fence_offset: c_int = 0;
                    let mut fence_char: c_char = 0;
                    let is_fenced =
                        cmark_node_get_fenced(node, &mut fence_len, &mut fence_offset, &mut fence_char)
                            != 0;
                    let info_ptr = cmark_node_get_fence_info(node);
                    let info = if info_ptr.is_null() {
                        String::new()
                    } else {
                        CStr::from_ptr(info_ptr)
                            .to_string_lossy()
                            .split_whitespace()
                            .next()
                            .unwrap_or("")
                            .to_string()
                    };
                    blocks.push(CmarkBlockSpan {
                        kind: CmarkBlockKind::CodeBlock,
                        start_line,
                        start_column,
                        end_line,
                        end_column,
                        level: fence_len.max(0) as u32,
                        flags: if is_fenced { 1 } else { 0 },
                        info,
                    });
                }
                "thematic_break" => {
                    blocks.push(CmarkBlockSpan {
                        kind: CmarkBlockKind::ThematicBreak,
                        start_line,
                        start_column,
                        end_line,
                        end_column,
                        level: 0,
                        flags: 0,
                        info: String::new(),
                    });
                }
                "block_quote" => {
                    let mut depth = 1u32;
                    let mut p = cmark_node_parent(node);
                    while !p.is_null() {
                        let p_type = cmark_node_get_type_string(p);
                        if !p_type.is_null() && CStr::from_ptr(p_type).to_str() == Ok("block_quote")
                        {
                            depth += 1;
                        }
                        p = cmark_node_parent(p);
                    }
                    blocks.push(CmarkBlockSpan {
                        kind: CmarkBlockKind::BlockQuote,
                        start_line,
                        start_column,
                        end_line,
                        end_column,
                        level: depth,
                        flags: 0,
                        info: String::new(),
                    });
                }
                "item" | "tasklist" => {
                    let is_task = type_str == "tasklist";
                    let task_checked = if is_task {
                        cmark_gfm_extensions_get_tasklist_item_checked(node)
                    } else {
                        false
                    };
                    let parent = cmark_node_parent(node);
                    let is_ordered =
                        !parent.is_null() && cmark_node_get_list_type(parent) == CMARK_ORDERED_LIST;
                    let mut item_num = if is_ordered {
                        cmark_node_get_list_start(parent).max(0) as u32
                    } else {
                        0
                    };
                    if is_ordered && !parent.is_null() {
                        let mut sib = cmark_node_first_child(parent);
                        while !sib.is_null() && sib != node {
                            item_num += 1;
                            sib = cmark_node_next(sib);
                        }
                    }
                    let mut flags = 0u32;
                    if is_ordered {
                        flags |= 4;
                    }
                    if is_task {
                        flags |= 8;
                    }
                    if task_checked {
                        flags |= 16;
                    }
                    blocks.push(CmarkBlockSpan {
                        kind: CmarkBlockKind::ListItem,
                        start_line,
                        start_column,
                        end_line,
                        end_column,
                        level: item_num,
                        flags,
                        info: String::new(),
                    });
                }
                "table" => {
                    let cols = cmark_gfm_extensions_get_table_columns(node) as usize;
                    let align_ptr = cmark_gfm_extensions_get_table_alignments(node);
                    let mut align_str = String::with_capacity(cols);
                    if !align_ptr.is_null() && cols > 0 {
                        let slice = std::slice::from_raw_parts(align_ptr, cols);
                        for &b in slice {
                            let ch = match b {
                                b'l' => 'l',
                                b'c' => 'c',
                                b'r' => 'r',
                                _ => 'n',
                            };
                            align_str.push(ch);
                        }
                    }
                    blocks.push(CmarkBlockSpan {
                        kind: CmarkBlockKind::Table,
                        start_line,
                        start_column,
                        end_line,
                        end_column,
                        level: cols as u32,
                        flags: 0,
                        info: align_str,
                    });
                }
                "html_block" => {
                    blocks.push(CmarkBlockSpan {
                        kind: CmarkBlockKind::HtmlBlock,
                        start_line,
                        start_column,
                        end_line,
                        end_column,
                        level: 0,
                        flags: 0,
                        info: String::new(),
                    });
                }
                "paragraph" => {
                    blocks.push(CmarkBlockSpan {
                        kind: CmarkBlockKind::Paragraph,
                        start_line,
                        start_column,
                        end_line,
                        end_column,
                        level: 0,
                        flags: 0,
                        info: String::new(),
                    });
                }
                "emph" => {
                    inlines.push(CmarkInlineSpan {
                        kind: CmarkInlineKind::Emphasis,
                        start_line,
                        start_column,
                        end_line,
                        end_column,
                        url: String::new(),
                        literal: String::new(),
                    });
                }
                "strong" => {
                    inlines.push(CmarkInlineSpan {
                        kind: CmarkInlineKind::Strong,
                        start_line,
                        start_column,
                        end_line,
                        end_column,
                        url: String::new(),
                        literal: String::new(),
                    });
                }
                "code" => {
                    let lit_ptr = cmark_node_get_literal(node);
                    let lit = if lit_ptr.is_null() {
                        String::new()
                    } else {
                        CStr::from_ptr(lit_ptr).to_string_lossy().into_owned()
                    };
                    inlines.push(CmarkInlineSpan {
                        kind: CmarkInlineKind::Code,
                        start_line,
                        start_column,
                        end_line,
                        end_column,
                        url: String::new(),
                        literal: lit,
                    });
                }
                "strikethrough" => {
                    inlines.push(CmarkInlineSpan {
                        kind: CmarkInlineKind::Strikethrough,
                        start_line,
                        start_column,
                        end_line,
                        end_column,
                        url: String::new(),
                        literal: String::new(),
                    });
                }
                "link" | "image" => {
                    let url_ptr = cmark_node_get_url(node);
                    let url = if url_ptr.is_null() {
                        String::new()
                    } else {
                        CStr::from_ptr(url_ptr).to_string_lossy().into_owned()
                    };
                    let mut label = String::new();
                    collect_node_plain_text(node, &mut label);
                    inlines.push(CmarkInlineSpan {
                        kind: if type_str == "image" {
                            CmarkInlineKind::Image
                        } else {
                            CmarkInlineKind::Link
                        },
                        start_line,
                        start_column,
                        end_line,
                        end_column,
                        url,
                        literal: label,
                    });
                }
                "html_inline" => {
                    let lit_ptr = cmark_node_get_literal(node);
                    let lit = if lit_ptr.is_null() {
                        String::new()
                    } else {
                        CStr::from_ptr(lit_ptr).to_string_lossy().into_owned()
                    };
                    inlines.push(CmarkInlineSpan {
                        kind: CmarkInlineKind::HtmlInline,
                        start_line,
                        start_column,
                        end_line,
                        end_column,
                        url: String::new(),
                        literal: lit,
                    });
                }
                _ => {}
            }
        }

        cmark_iter_free(iter);
        cmark_node_free(doc);
        cmark_parser_free(parser);
    }

    CmarkAstAnalysis { blocks, inlines }
}

/// Parses an upstream `spec.txt` or `extensions.txt` file (from `github/cmark-gfm` or `commonmark-spec`)
/// directly into its constituent specification test examples (`markdown`, `html`, `example`, `section`, `extensions`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UpstreamSpecExample {
    pub example: usize,
    pub section: String,
    pub start_line: usize,
    pub end_line: usize,
    pub extensions: Vec<String>,
    pub markdown: String,
    pub html: String,
}

pub fn parse_upstream_spec_txt(spec_text: &str) -> Vec<UpstreamSpecExample> {
    let mut line_number = 0usize;
    let mut start_line = 0usize;
    let mut example_number = 0usize;
    let mut markdown_lines: Vec<String> = Vec::new();
    let mut html_lines: Vec<String> = Vec::new();
    let mut state = 0u8; // 0 = prose, 1 = markdown input, 2 = expected html
    let mut extensions: Vec<String> = Vec::new();
    let mut headertext = String::new();
    let mut tests = Vec::new();

    let fence_prefix = "````````````````````````````````";

    for raw_line in spec_text.split_inclusive('\n') {
        line_number += 1;
        let stripped = raw_line.trim();
        if let Some(after) = stripped.strip_prefix(&format!("{} example", fence_prefix)) {
            state = 1;
            extensions = after.split_whitespace().map(|s| s.to_string()).collect();
        } else if stripped == fence_prefix {
            state = 0;
            example_number += 1;
            let end_line = line_number;
            if !extensions.iter().any(|e| e == "disabled") {
                tests.push(UpstreamSpecExample {
                    example: example_number,
                    section: headertext.clone(),
                    start_line,
                    end_line,
                    extensions: extensions.clone(),
                    markdown: markdown_lines.concat().replace('→', "\t"),
                    html: html_lines.concat().replace('→', "\t"),
                });
            }
            start_line = 0;
            markdown_lines.clear();
            html_lines.clear();
        } else if stripped == "." && (state == 1 || state == 2) {
            state = 2;
        } else if state == 1 {
            if start_line == 0 {
                start_line = line_number - 1;
            }
            markdown_lines.push(raw_line.to_string());
        } else if state == 2 {
            html_lines.push(raw_line.to_string());
        } else if state == 0 && raw_line.starts_with('#') {
            let hashes = raw_line.bytes().take_while(|&b| b == b'#').count();
            if raw_line[hashes..].starts_with(' ') {
                headertext = raw_line[hashes + 1..].trim().to_string();
            }
        }
    }

    tests
}

#[cfg(test)]
mod commonmark_gfm_conformance_tests {
    use super::*;
    use std::fs;
    use std::path::PathBuf;

    fn spec_file_path(filename: &str) -> PathBuf {
        let candidates = [
            PathBuf::from(format!("third_party/markdown_spec/{}", filename)),
            PathBuf::from(format!("../../third_party/markdown_spec/{}", filename)),
        ];
        for c in &candidates {
            if c.exists() {
                return c.clone();
            }
        }
        panic!("Could not locate upstream spec file: {}", filename);
    }

    #[test]
    fn test_upstream_gfm_spec_txt_full_parity() {
        let spec_txt_path = spec_file_path("gfm_spec.txt");
        let spec_text =
            fs::read_to_string(&spec_txt_path).expect("Failed to read upstream gfm_spec.txt");
        let examples = parse_upstream_spec_txt(&spec_text);

        // Upstream github/cmark-gfm 0.29.0.gfm.13 has 670 active examples in test/spec.txt
        assert!(
            examples.len() >= 650,
            "Expected >= 650 upstream spec tests, got {}",
            examples.len()
        );

        let mut passed = 0usize;
        let mut failures = Vec::new();
        for ex in &examples {
            let ext_refs: Vec<&str> = ex.extensions.iter().map(|s| s.as_str()).collect();
            let actual_html = render_markdown_to_html(&ex.markdown, &ext_refs);
            if actual_html == ex.html {
                passed += 1;
            } else {
                failures.push(format!(
                    "Example {} ({}, lines {}-{}):\nMarkdown:\n{:?}\nExpected HTML:\n{:?}\nActual HTML:\n{:?}",
                    ex.example, ex.section, ex.start_line, ex.end_line, ex.markdown, ex.html, actual_html
                ));
            }
        }

        assert!(
            failures.is_empty(),
            "Failed {}/{} upstream GFM spec tests:\n{}",
            failures.len(),
            examples.len(),
            failures.join("\n\n")
        );
        assert_eq!(passed, examples.len());
    }

    #[test]
    fn test_upstream_gfm_extensions_txt_full_parity() {
        let ext_txt_path = spec_file_path("gfm_extensions.txt");
        let ext_text =
            fs::read_to_string(&ext_txt_path).expect("Failed to read upstream gfm_extensions.txt");
        let examples = parse_upstream_spec_txt(&ext_text);
        assert!(
            examples.len() >= 25,
            "Expected >= 25 upstream extension tests, got {}",
            examples.len()
        );

        let default_exts = [
            "table",
            "strikethrough",
            "autolink",
            "tagfilter",
            "footnotes",
            "tasklist",
        ];

        for ex in &examples {
            let mut exts: Vec<&str> = default_exts.to_vec();
            for e in &ex.extensions {
                if !exts.contains(&e.as_str()) {
                    exts.push(e.as_str());
                }
            }
            let actual_html = render_markdown_to_html(&ex.markdown, &exts);
            if ex.html.trim() != "<IGNORE>" {
                assert_eq!(
                    actual_html, ex.html,
                    "Failed upstream GFM extension example {} ({})",
                    ex.example, ex.section
                );
            }
        }
    }

    #[test]
    fn test_cmark_gfm_ast_extracts_reference_links_indented_code_and_tables() {
        let md = "\
Here is a [reference link][ref] and a [shortcut] link.

    let x = 42;
    # indented code, not a heading

| Col A | Col B |
| :--- | ---: |
| `x | y` | val |

- [x] Done task
- [ ] Open task

[ref]: https://example.com/ref
[shortcut]: https://example.com/short
";
        let ast = parse_cmark_gfm_ast(md);
        // Should have 2 resolved links from reference definitions
        let links: Vec<_> = ast
            .inlines
            .iter()
            .filter(|i| i.kind == CmarkInlineKind::Link)
            .collect();
        assert_eq!(links.len(), 2);
        assert_eq!(links[0].url, "https://example.com/ref");
        assert_eq!(links[0].literal, "reference link");
        assert_eq!(links[1].url, "https://example.com/short");
        assert_eq!(links[1].literal, "shortcut");

        // Should have an indented code block (flags == 0)
        assert!(ast
            .blocks
            .iter()
            .any(|b| b.kind == CmarkBlockKind::CodeBlock && b.flags == 0));

        // Should have a table with alignments "lr"
        assert!(ast
            .blocks
            .iter()
            .any(|b| b.kind == CmarkBlockKind::Table && b.info == "lr" && b.level == 2));

        // Should have 2 task list items (one checked, one unchecked)
        let tasks: Vec<_> = ast
            .blocks
            .iter()
            .filter(|b| b.kind == CmarkBlockKind::ListItem && (b.flags & 8) != 0)
            .collect();
        assert_eq!(tasks.len(), 2);
        assert_ne!(tasks[0].flags & 16, 0);
        assert_eq!(tasks[1].flags & 16, 0);
    }

    #[test]
    fn test_commonmark_atx_headings_indentation_and_closing_hashes() {
        let md = "   # Indented H1\n## Heading with closing hashes ###   \n### Keep # hash\n";
        let analysis = analyze_markdown_document(md, 999, false, false);
        assert_eq!(analysis.headings.len(), 3);
        assert_eq!(analysis.headings[0].level, 1);
        assert_eq!(analysis.headings[0].title, "Indented H1");
        assert_eq!(analysis.headings[1].level, 2);
        assert_eq!(analysis.headings[1].title, "Heading with closing hashes");
        assert_eq!(analysis.headings[2].level, 3);
        assert_eq!(analysis.headings[2].title, "Keep # hash");
    }

    #[test]
    fn test_commonmark_setext_headings() {
        let md = "Setext Heading 1\n================\n\nSetext Heading 2\n----------------\n";
        let analysis = analyze_markdown_document(md, 999, false, false);
        assert_eq!(analysis.headings.len(), 2);
        assert_eq!(analysis.headings[0].level, 1);
        assert_eq!(analysis.headings[0].title, "Setext Heading 1");
        assert_eq!(analysis.headings[1].level, 2);
        assert_eq!(analysis.headings[1].title, "Setext Heading 2");
    }

    #[test]
    fn test_commonmark_intraword_underscores_and_code_protection() {
        let md = "Identifier foo_bar_baz and `FUNCTIONS_EMAIL_CREDENTIALS_JSON` and _real italic_.\n";
        let analysis = analyze_markdown_document(md, 999, false, false);
        let italic_folds: Vec<_> = analysis
            .syntax_fold_spans
            .iter()
            .filter(|s| s.kind == SyntaxTokenKind::ItalicMarker)
            .collect();
        assert_eq!(italic_folds.len(), 2);
        assert_eq!(&md[italic_folds[0].byte_range.clone()], "_");
        assert_eq!(&md[italic_folds[1].byte_range.clone()], "_");
    }

    #[test]
    fn test_nested_bold_link_with_inline_code() {
        let md = "| **[`architecture/`](./architecture/README.md)** | System design |\n";
        let analysis = analyze_markdown_document(md, 999, false, false);
        assert!(analysis
            .syntax_fold_spans
            .iter()
            .any(|s| s.kind == SyntaxTokenKind::BoldMarker));
        assert!(analysis
            .syntax_fold_spans
            .iter()
            .any(|s| s.kind == SyntaxTokenKind::LinkSyntax));
        assert!(analysis
            .syntax_fold_spans
            .iter()
            .any(|s| s.kind == SyntaxTokenKind::InlineCodeBackticks));
        assert!(analysis
            .block_decorations
            .iter()
            .any(|b| matches!(b.kind, MarkdownBlockDecorationKind::InlineCode)));
    }

    #[test]
    fn test_gfm_table_splitting_with_code_pipes_and_escaped_pipes() {
        let row = "| `a | b` | Escaped \\| pipe | $|x|$ | Plain <br/> cell |";
        let cells = split_gfm_table_cells(row);
        assert_eq!(
            cells,
            vec!["`a | b`", "Escaped | pipe", "$|x|$", "Plain   cell"]
        );
    }

    #[test]
    fn test_commonmark_tilde_and_backtick_fences() {
        let md = "~~~python\ndef foo():\n    # Not a heading\n    pass\n~~~\n";
        let analysis = analyze_markdown_document(md, 999, false, false);
        assert!(analysis.headings.is_empty());
        assert!(analysis.block_decorations.iter().any(|b| matches!(
            &b.kind,
            MarkdownBlockDecorationKind::CodeFenceStart { language } if language == "python"
        )));
    }

    #[test]
    fn test_adversarial_markdown_and_math_linear_time() {
        use std::time::Instant;

        let n = 2000usize;
        let adversarial_md = [
            // Unmatched backtick sequences of varying lengths
            "`a ".repeat(n),
            "``a ".repeat(n),
            "```a ".repeat(n),
            // Unmatched emphasis & strikethrough & highlight openers
            "*a ".repeat(n),
            "_a ".repeat(n),
            "**a ".repeat(n),
            "__a ".repeat(n),
            "***a ".repeat(n),
            "~~a ".repeat(n),
            "==a ".repeat(n),
            // Unmatched inline math
            "$a ".repeat(n),
            // Unmatched brackets & unclosed link parens
            "[a ".repeat(n),
            "[a](http://example.com/".repeat(n / 2),
            format!("{}[inner](https://example.com)", "[outer ".repeat(n)),
            // Unmatched angle brackets
            "<http://example.com/".repeat(n / 2),
        ]
        .join("\n\n");

        let start = Instant::now();
        let analysis = analyze_markdown_document(&adversarial_md, 99999, false, false);
        let elapsed = start.elapsed();
        assert!(
            elapsed.as_millis() < 250,
            "Adversarial markdown analysis took {:?}, expected <250ms",
            elapsed
        );
        assert!(!analysis.syntax_fold_spans.is_empty());

        // Deeply nested & malformed LaTeX math inputs
        let deep_braces = format!("{}{}{}", "{".repeat(500), "x+1", "}".repeat(500));
        let deep_supers = "x^".repeat(500) + "2";
        let stray_closing_braces = "}}}}}}x+y}}}}}}";
        let left_with_rightarrow = r"\left( a \rightarrow b } c \right)";

        let t_math = Instant::now();
        let m1 = crate::math::layout_latex(&deep_braces, 16.0, false);
        let m2 = crate::math::layout_latex(&deep_supers, 16.0, false);
        let m3 = crate::math::layout_latex(stray_closing_braces, 16.0, false);
        let m4 = crate::math::layout_latex(left_with_rightarrow, 16.0, false);
        let s4 = crate::math::plain_text_summary(left_with_rightarrow);
        let math_elapsed = t_math.elapsed();
        assert!(
            math_elapsed.as_millis() < 100,
            "Adversarial math parsing took {:?}, expected <100ms",
            math_elapsed
        );
        assert!(m1.width > 0.0);
        assert!(m2.width > 0.0);
        assert!(m3.width > 0.0);
        assert!(m4.width > 0.0);
        assert!(s4.contains("→"));
    }
}

