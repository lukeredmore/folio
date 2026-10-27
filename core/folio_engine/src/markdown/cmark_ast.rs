use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_int};

use super::cmark_sys::{
    cmark_find_syntax_extension, cmark_gfm_extensions_get_table_alignments,
    cmark_gfm_extensions_get_table_columns, cmark_gfm_extensions_get_tasklist_item_checked,
    cmark_iter_free, cmark_iter_get_node, cmark_iter_new, cmark_iter_next, cmark_node_first_child,
    cmark_node_free, cmark_node_get_end_column, cmark_node_get_end_line, cmark_node_get_fence_info,
    cmark_node_get_fenced, cmark_node_get_heading_level, cmark_node_get_list_start,
    cmark_node_get_list_type, cmark_node_get_literal, cmark_node_get_start_column,
    cmark_node_get_start_line, cmark_node_get_type_string, cmark_node_get_url, cmark_node_next,
    cmark_node_parent, cmark_parser_attach_syntax_extension, cmark_parser_feed,
    cmark_parser_finish, cmark_parser_free, cmark_parser_new, ensure_cmark_gfm_initialized,
    CmarkNode, CMARK_EVENT_DONE, CMARK_EVENT_ENTER, CMARK_LOCK, CMARK_OPT_DEFAULT,
    CMARK_OPT_FOOTNOTES, CMARK_OPT_UNSAFE, CMARK_ORDERED_LIST, DEFAULT_GFM_EXTENSIONS,
};
use super::types::{
    CmarkAstAnalysis, CmarkBlockKind, CmarkBlockSpan, CmarkInlineKind, CmarkInlineSpan,
};

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
    let _guard = CMARK_LOCK
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);

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
            let pos = (
                cmark_node_get_start_line(node).max(0) as u32,
                cmark_node_get_start_column(node).max(0) as u32,
                cmark_node_get_end_line(node).max(0) as u32,
                cmark_node_get_end_column(node).max(0) as u32,
            );

            if !visit_cmark_block_node(node, type_str, pos, &raw_lines, &mut blocks) {
                visit_cmark_inline_node(node, type_str, pos, &mut inlines);
            }
        }

        cmark_iter_free(iter);
        cmark_node_free(doc);
        cmark_parser_free(parser);
    }

    CmarkAstAnalysis { blocks, inlines }
}

unsafe fn visit_cmark_block_node(
    node: *mut CmarkNode,
    type_str: &str,
    pos: (u32, u32, u32, u32),
    raw_lines: &[&str],
    blocks: &mut Vec<CmarkBlockSpan>,
) -> bool {
    let span = match type_str {
        "heading" => extract_heading_span(node, pos, raw_lines),
        "code_block" => extract_code_block_span(node, pos),
        "thematic_break" => simple_block_span(CmarkBlockKind::ThematicBreak, pos, 0),
        "block_quote" => simple_block_span(CmarkBlockKind::BlockQuote, pos, blockquote_depth(node)),
        "item" | "tasklist" => extract_list_item_span(node, type_str, pos),
        "table" => extract_table_span(node, pos),
        "html_block" => simple_block_span(CmarkBlockKind::HtmlBlock, pos, 0),
        "paragraph" => simple_block_span(CmarkBlockKind::Paragraph, pos, 0),
        _ => return false,
    };
    blocks.push(span);
    true
}

fn simple_block_span(
    kind: CmarkBlockKind,
    pos: (u32, u32, u32, u32),
    level: u32,
) -> CmarkBlockSpan {
    CmarkBlockSpan {
        kind,
        start_line: pos.0,
        start_column: pos.1,
        end_line: pos.2,
        end_column: pos.3,
        level,
        flags: 0,
        info: String::new(),
    }
}

unsafe fn extract_heading_span(
    node: *mut CmarkNode,
    pos: (u32, u32, u32, u32),
    raw_lines: &[&str],
) -> CmarkBlockSpan {
    let (start_line, start_column, end_line, end_column) = pos;
    let level = cmark_node_get_heading_level(node).max(1) as u32;
    let is_setext = end_line > start_line
        || (start_line > 0
            && raw_lines
                .get((start_line - 1) as usize)
                .is_some_and(|l| !l.trim_start().starts_with('#')));
    let mut title = String::new();
    collect_node_plain_text(node, &mut title);
    CmarkBlockSpan {
        kind: CmarkBlockKind::Heading,
        start_line,
        start_column,
        end_line,
        end_column,
        level,
        flags: if is_setext { 2 } else { 0 },
        info: title,
    }
}

unsafe fn extract_code_block_span(
    node: *mut CmarkNode,
    pos: (u32, u32, u32, u32),
) -> CmarkBlockSpan {
    let (mut fence_len, mut fence_offset, mut fence_char): (c_int, c_int, c_char) = (0, 0, 0);
    let is_fenced =
        cmark_node_get_fenced(node, &mut fence_len, &mut fence_offset, &mut fence_char) != 0;
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
    CmarkBlockSpan {
        kind: CmarkBlockKind::CodeBlock,
        start_line: pos.0,
        start_column: pos.1,
        end_line: pos.2,
        end_column: pos.3,
        level: fence_len.max(0) as u32,
        flags: u32::from(is_fenced),
        info,
    }
}

unsafe fn blockquote_depth(node: *mut CmarkNode) -> u32 {
    let mut depth = 1u32;
    let mut p = cmark_node_parent(node);
    while !p.is_null() {
        let p_type = cmark_node_get_type_string(p);
        if !p_type.is_null() && CStr::from_ptr(p_type).to_str() == Ok("block_quote") {
            depth += 1;
        }
        p = cmark_node_parent(p);
    }
    depth
}

unsafe fn extract_list_item_span(
    node: *mut CmarkNode,
    type_str: &str,
    pos: (u32, u32, u32, u32),
) -> CmarkBlockSpan {
    let is_task = type_str == "tasklist";
    let task_checked = is_task && cmark_gfm_extensions_get_tasklist_item_checked(node);
    let parent = cmark_node_parent(node);
    let is_ordered = !parent.is_null() && cmark_node_get_list_type(parent) == CMARK_ORDERED_LIST;
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
    let flags =
        (u32::from(is_ordered) * 4) | (u32::from(is_task) * 8) | (u32::from(task_checked) * 16);
    CmarkBlockSpan {
        kind: CmarkBlockKind::ListItem,
        start_line: pos.0,
        start_column: pos.1,
        end_line: pos.2,
        end_column: pos.3,
        level: item_num,
        flags,
        info: String::new(),
    }
}

unsafe fn extract_table_span(node: *mut CmarkNode, pos: (u32, u32, u32, u32)) -> CmarkBlockSpan {
    let cols = cmark_gfm_extensions_get_table_columns(node) as usize;
    let align_ptr = cmark_gfm_extensions_get_table_alignments(node);
    let mut align_str = String::with_capacity(cols);
    if !align_ptr.is_null() && cols > 0 {
        for &b in std::slice::from_raw_parts(align_ptr, cols) {
            align_str.push(match b {
                b'l' => 'l',
                b'c' => 'c',
                b'r' => 'r',
                _ => 'n',
            });
        }
    }
    CmarkBlockSpan {
        kind: CmarkBlockKind::Table,
        start_line: pos.0,
        start_column: pos.1,
        end_line: pos.2,
        end_column: pos.3,
        level: cols as u32,
        flags: 0,
        info: align_str,
    }
}

unsafe fn cstr_to_string(ptr: *const c_char) -> String {
    if ptr.is_null() {
        String::new()
    } else {
        CStr::from_ptr(ptr).to_string_lossy().into_owned()
    }
}

unsafe fn visit_cmark_inline_node(
    node: *mut CmarkNode,
    type_str: &str,
    pos: (u32, u32, u32, u32),
    inlines: &mut Vec<CmarkInlineSpan>,
) {
    let (kind, url, literal) = match type_str {
        "emph" => (CmarkInlineKind::Emphasis, String::new(), String::new()),
        "strong" => (CmarkInlineKind::Strong, String::new(), String::new()),
        "strikethrough" => (CmarkInlineKind::Strikethrough, String::new(), String::new()),
        "code" => (
            CmarkInlineKind::Code,
            String::new(),
            cstr_to_string(cmark_node_get_literal(node)),
        ),
        "html_inline" => (
            CmarkInlineKind::HtmlInline,
            String::new(),
            cstr_to_string(cmark_node_get_literal(node)),
        ),
        "link" | "image" => {
            let mut label = String::new();
            collect_node_plain_text(node, &mut label);
            let kind = if type_str == "image" {
                CmarkInlineKind::Image
            } else {
                CmarkInlineKind::Link
            };
            (kind, cstr_to_string(cmark_node_get_url(node)), label)
        }
        _ => return,
    };
    inlines.push(CmarkInlineSpan {
        kind,
        start_line: pos.0,
        start_column: pos.1,
        end_line: pos.2,
        end_column: pos.3,
        url,
        literal,
    });
}
