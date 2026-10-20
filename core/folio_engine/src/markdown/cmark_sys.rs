use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_int, c_void};
use std::sync::{Mutex, Once};

use super::types::UpstreamSpecExample;

#[repr(C)]
pub(crate) struct CmarkMem {
    pub calloc: unsafe extern "C" fn(usize, usize) -> *mut c_void,
    pub realloc: unsafe extern "C" fn(*mut c_void, usize) -> *mut c_void,
    pub free: unsafe extern "C" fn(*mut c_void),
}

pub(crate) enum CmarkParser {}
pub(crate) enum CmarkNode {}
pub(crate) enum CmarkIter {}
pub(crate) enum CmarkSyntaxExtension {}
pub(crate) enum CmarkLlist {}

pub(crate) const CMARK_OPT_DEFAULT: c_int = 0;
pub(crate) const CMARK_OPT_FOOTNOTES: c_int = 1 << 13;
pub(crate) const CMARK_OPT_UNSAFE: c_int = 1 << 17;

pub(crate) const CMARK_EVENT_DONE: c_int = 1;
pub(crate) const CMARK_EVENT_ENTER: c_int = 2;

pub(crate) const CMARK_ORDERED_LIST: c_int = 2;

extern "C" {
    pub(crate) fn cmark_gfm_core_extensions_ensure_registered();
    pub(crate) fn cmark_get_default_mem_allocator() -> *mut CmarkMem;
    pub(crate) fn cmark_parser_new(options: c_int) -> *mut CmarkParser;
    pub(crate) fn cmark_parser_free(parser: *mut CmarkParser);
    pub(crate) fn cmark_find_syntax_extension(name: *const c_char) -> *mut CmarkSyntaxExtension;
    pub(crate) fn cmark_parser_attach_syntax_extension(
        parser: *mut CmarkParser,
        extension: *mut CmarkSyntaxExtension,
    ) -> c_int;
    pub(crate) fn cmark_parser_feed(parser: *mut CmarkParser, buffer: *const c_char, len: usize);
    pub(crate) fn cmark_parser_finish(parser: *mut CmarkParser) -> *mut CmarkNode;
    pub(crate) fn cmark_parser_get_syntax_extensions(parser: *mut CmarkParser) -> *mut CmarkLlist;
    pub(crate) fn cmark_render_html(
        root: *mut CmarkNode,
        options: c_int,
        extensions: *mut CmarkLlist,
    ) -> *mut c_char;
    pub(crate) fn cmark_node_free(node: *mut CmarkNode);
    pub(crate) fn cmark_iter_new(root: *mut CmarkNode) -> *mut CmarkIter;
    pub(crate) fn cmark_iter_free(iter: *mut CmarkIter);
    pub(crate) fn cmark_iter_next(iter: *mut CmarkIter) -> c_int;
    pub(crate) fn cmark_iter_get_node(iter: *mut CmarkIter) -> *mut CmarkNode;
    pub(crate) fn cmark_node_get_type_string(node: *mut CmarkNode) -> *const c_char;
    pub(crate) fn cmark_node_get_literal(node: *mut CmarkNode) -> *const c_char;
    pub(crate) fn cmark_node_get_heading_level(node: *mut CmarkNode) -> c_int;
    pub(crate) fn cmark_node_get_list_type(node: *mut CmarkNode) -> c_int;
    pub(crate) fn cmark_node_get_list_start(node: *mut CmarkNode) -> c_int;
    pub(crate) fn cmark_node_get_fence_info(node: *mut CmarkNode) -> *const c_char;
    pub(crate) fn cmark_node_get_fenced(
        node: *mut CmarkNode,
        length: *mut c_int,
        offset: *mut c_int,
        character: *mut c_char,
    ) -> c_int;
    pub(crate) fn cmark_node_get_url(node: *mut CmarkNode) -> *const c_char;
    pub(crate) fn cmark_node_get_start_line(node: *mut CmarkNode) -> c_int;
    pub(crate) fn cmark_node_get_start_column(node: *mut CmarkNode) -> c_int;
    pub(crate) fn cmark_node_get_end_line(node: *mut CmarkNode) -> c_int;
    pub(crate) fn cmark_node_get_end_column(node: *mut CmarkNode) -> c_int;
    pub(crate) fn cmark_node_first_child(node: *mut CmarkNode) -> *mut CmarkNode;
    pub(crate) fn cmark_node_next(node: *mut CmarkNode) -> *mut CmarkNode;
    pub(crate) fn cmark_node_parent(node: *mut CmarkNode) -> *mut CmarkNode;
    pub(crate) fn cmark_gfm_extensions_get_table_columns(node: *mut CmarkNode) -> u16;
    pub(crate) fn cmark_gfm_extensions_get_table_alignments(node: *mut CmarkNode) -> *const u8;
    pub(crate) fn cmark_gfm_extensions_get_tasklist_item_checked(node: *mut CmarkNode) -> bool;
}

static CMARK_INIT: Once = Once::new();
/// Upstream `cmark-gfm` mutates a non-thread-safe global `SPECIAL_CHARS` table inside
/// `cmark_manage_extensions_special_characters` during `cmark_parser_finish`.
/// Guarding `cmark` parse invocations with `CMARK_LOCK` makes multi-threaded calls 100% deterministic.
pub(crate) static CMARK_LOCK: Mutex<()> = Mutex::new(());

pub(crate) fn ensure_cmark_gfm_initialized() {
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
    let _guard = CMARK_LOCK
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
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

pub fn parse_upstream_spec_txt(spec_text: &str) -> Vec<UpstreamSpecExample> {
    let mut line_number = 0usize;
    let mut start_line = 0usize;
    let mut example_number = 0usize;
    let mut markdown_lines: Vec<String> = Vec::new();
    let mut html_lines: Vec<String> = Vec::new();
    let mut state = 0u8;
    let mut extensions: Vec<String> = Vec::new();
    let mut headertext = String::new();
    let mut tests = Vec::new();

    let fence_prefix = "````````````````````````````````";

    for raw_line in spec_text.split_inclusive('\n') {
        line_number += 1;
        let stripped = raw_line.trim();
        if let Some(after) = stripped.strip_prefix(&format!("{fence_prefix} example")) {
            state = 1;
            extensions = after.split_whitespace().map(str::to_string).collect();
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
