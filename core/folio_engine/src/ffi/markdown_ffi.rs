use std::ffi::{CStr, CString};
use std::os::raw::c_char;

use crate::markdown::{parse_cmark_gfm_ast, render_gfm_to_html, render_markdown_to_html};

#[repr(C)]
#[derive(Debug)]
pub struct OTMarkdownBlockSpan {
    pub kind: u32,
    pub start_line: u32,
    pub start_column: u32,
    pub end_line: u32,
    pub end_column: u32,
    pub level: u32,
    pub flags: u32,
    pub info: *mut c_char,
}

#[repr(C)]
#[derive(Debug)]
pub struct OTMarkdownInlineSpan {
    pub kind: u32,
    pub start_line: u32,
    pub start_column: u32,
    pub end_line: u32,
    pub end_column: u32,
    pub url: *mut c_char,
    pub literal: *mut c_char,
}

#[repr(C)]
#[derive(Debug)]
pub struct OTMarkdownAstResult {
    pub blocks: *mut OTMarkdownBlockSpan,
    pub block_count: usize,
    pub inlines: *mut OTMarkdownInlineSpan,
    pub inline_count: usize,
}

/// Renders Markdown to HTML using the `cmark-gfm` parser.
///
/// # Safety
/// `markdown_utf8` and `extensions_space_separated_utf8` must be null or valid null-terminated C strings.
#[no_mangle]
pub unsafe extern "C" fn ot_engine_render_markdown_html(
    markdown_utf8: *const c_char,
    extensions_space_separated_utf8: *const c_char,
) -> *mut c_char {
    let markdown = if markdown_utf8.is_null() {
        ""
    } else {
        CStr::from_ptr(markdown_utf8).to_str().unwrap_or("")
    };

    let html = if extensions_space_separated_utf8.is_null() {
        render_gfm_to_html(markdown)
    } else {
        let ext_str = CStr::from_ptr(extensions_space_separated_utf8)
            .to_str()
            .unwrap_or("");
        let exts: Vec<&str> = ext_str.split_whitespace().collect();
        render_markdown_to_html(markdown, &exts)
    };

    CString::new(html).unwrap_or_default().into_raw()
}

/// Parses Markdown using `cmark-gfm` and returns block and inline AST spans.
///
/// # Safety
/// `markdown_utf8` must be null or a valid null-terminated UTF-8 C string.
#[no_mangle]
pub unsafe extern "C" fn ot_engine_parse_markdown_ast(
    markdown_utf8: *const c_char,
) -> *mut OTMarkdownAstResult {
    let markdown = if markdown_utf8.is_null() {
        ""
    } else {
        CStr::from_ptr(markdown_utf8).to_str().unwrap_or("")
    };

    let analysis = parse_cmark_gfm_ast(markdown);

    let mut blocks: Vec<OTMarkdownBlockSpan> = Vec::with_capacity(analysis.blocks.len());
    for b in analysis.blocks {
        blocks.push(OTMarkdownBlockSpan {
            kind: b.kind as u32,
            start_line: b.start_line,
            start_column: b.start_column,
            end_line: b.end_line,
            end_column: b.end_column,
            level: b.level,
            flags: b.flags,
            info: CString::new(b.info).unwrap_or_default().into_raw(),
        });
    }

    let mut inlines: Vec<OTMarkdownInlineSpan> = Vec::with_capacity(analysis.inlines.len());
    for i in analysis.inlines {
        inlines.push(OTMarkdownInlineSpan {
            kind: i.kind as u32,
            start_line: i.start_line,
            start_column: i.start_column,
            end_line: i.end_line,
            end_column: i.end_column,
            url: CString::new(i.url).unwrap_or_default().into_raw(),
            literal: CString::new(i.literal).unwrap_or_default().into_raw(),
        });
    }

    let mut boxed_blocks = blocks.into_boxed_slice();
    let block_ptr = boxed_blocks.as_mut_ptr();
    let block_count = boxed_blocks.len();
    std::mem::forget(boxed_blocks);

    let mut boxed_inlines = inlines.into_boxed_slice();
    let inline_ptr = boxed_inlines.as_mut_ptr();
    let inline_count = boxed_inlines.len();
    std::mem::forget(boxed_inlines);

    let result = Box::new(OTMarkdownAstResult {
        blocks: block_ptr,
        block_count,
        inlines: inline_ptr,
        inline_count,
    });
    Box::into_raw(result)
}

/// Frees an `OTMarkdownAstResult` returned by `ot_engine_parse_markdown_ast`.
///
/// # Safety
/// `result` must be null or a pointer returned by `ot_engine_parse_markdown_ast`.
#[no_mangle]
pub unsafe extern "C" fn ot_engine_free_markdown_ast(result: *mut OTMarkdownAstResult) {
    if result.is_null() {
        return;
    }
    let res = Box::from_raw(result);
    if !res.blocks.is_null() && res.block_count > 0 {
        let slice = std::slice::from_raw_parts_mut(res.blocks, res.block_count);
        for b in slice.iter_mut() {
            if !b.info.is_null() {
                let _ = CString::from_raw(b.info);
            }
        }
        let _ = Box::from_raw(slice as *mut [OTMarkdownBlockSpan]);
    }
    if !res.inlines.is_null() && res.inline_count > 0 {
        let slice = std::slice::from_raw_parts_mut(res.inlines, res.inline_count);
        for i in slice.iter_mut() {
            if !i.url.is_null() {
                let _ = CString::from_raw(i.url);
            }
            if !i.literal.is_null() {
                let _ = CString::from_raw(i.literal);
            }
        }
        let _ = Box::from_raw(slice as *mut [OTMarkdownInlineSpan]);
    }
}
