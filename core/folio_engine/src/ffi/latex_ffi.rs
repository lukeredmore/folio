use std::ffi::{CStr, CString};
use std::os::raw::c_char;

use crate::latex::{scan_latex_directives, scan_latex_inlines};

#[repr(C)]
#[derive(Debug)]
pub struct OTLatexInlineSpan {
    pub kind: u32,
    pub full_loc: usize,
    pub full_len: usize,
    pub open_loc: usize,
    pub open_len: usize,
    pub inner_loc: usize,
    pub inner_len: usize,
    pub close_loc: usize,
    pub close_len: usize,
    pub cmd: *mut c_char,
    pub arg: *mut c_char,
}

#[repr(C)]
#[derive(Debug)]
pub struct OTLatexInlineScanResult {
    pub spans: *mut OTLatexInlineSpan,
    pub span_count: usize,
}

#[repr(C)]
#[derive(Debug)]
pub struct OTLatexDirectiveItem {
    pub kind: u32,
    pub starred: bool,
    pub cmd: *mut c_char,
    pub opt_arg: *mut c_char,
    pub arg1: *mut c_char,
    pub arg2: *mut c_char,
    pub arg3: *mut c_char,
}

#[repr(C)]
#[derive(Debug)]
pub struct OTLatexDirectivesResult {
    pub items: *mut OTLatexDirectiveItem,
    pub count: usize,
}

#[repr(C)]
#[derive(Debug)]
pub struct OTLatexLineClassification {
    pub kind: u32,
    pub has_opt_arg: bool,
    pub open_loc: usize,
    pub open_len: usize,
    pub opt_loc: usize,
    pub opt_len: usize,
    pub space_loc: usize,
    pub space_len: usize,
    pub body_loc: usize,
    pub body_len: usize,
    pub close_loc: usize,
    pub close_len: usize,
    pub cmd: *mut c_char,
    pub opt_arg: *mut c_char,
    pub arg1: *mut c_char,
}

#[repr(C)]
#[derive(Debug)]
pub struct OTMacroTemplateAnalysis {
    pub shows_body: bool,
    pub heading_level: u32,
    pub color_name: *mut c_char,
    pub prefix_label: *mut c_char,
    pub vspace_args: *mut c_char,
}

#[repr(C)]
#[derive(Debug)]
pub struct OTNormalizedDisplayMath {
    pub cleaned_latex: *mut c_char,
    pub explicit_tag: *mut c_char,
}

#[repr(C)]
#[derive(Debug)]
pub struct OTBibEntry {
    pub key: *mut c_char,
    pub entry_type: *mut c_char,
    pub author: *mut c_char,
    pub year: *mut c_char,
    pub title: *mut c_char,
    pub utf16_loc: usize,
}

#[repr(C)]
#[derive(Debug)]
pub struct OTBibParseResult {
    pub entries: *mut OTBibEntry,
    pub count: usize,
}

fn to_c_str(s: String) -> *mut c_char {
    CString::new(s).unwrap_or_default().into_raw()
}

/// Scans a single LaTeX line/range for inline constructs and returns UTF-16 ranges.
///
/// # Safety
/// `line_utf8` must be null or a valid null-terminated UTF-8 C string.
#[no_mangle]
pub unsafe extern "C" fn ot_engine_scan_latex_inlines(
    line_utf8: *const c_char,
) -> *mut OTLatexInlineScanResult {
    let text = if line_utf8.is_null() {
        ""
    } else {
        CStr::from_ptr(line_utf8).to_str().unwrap_or("")
    };
    let mut spans: Vec<OTLatexInlineSpan> = scan_latex_inlines(text)
        .into_iter()
        .map(|s| OTLatexInlineSpan {
            kind: s.kind as u32,
            full_loc: s.full_loc,
            full_len: s.full_len,
            open_loc: s.open_loc,
            open_len: s.open_len,
            inner_loc: s.inner_loc,
            inner_len: s.inner_len,
            close_loc: s.close_loc,
            close_len: s.close_len,
            cmd: to_c_str(s.cmd),
            arg: to_c_str(s.arg),
        })
        .collect();
    spans.shrink_to_fit();
    let count = spans.len();
    let ptr = spans.as_mut_ptr();
    std::mem::forget(spans);
    Box::into_raw(Box::new(OTLatexInlineScanResult {
        spans: ptr,
        span_count: count,
    }))
}

/// Frees an `OTLatexInlineScanResult`.
///
/// # Safety
/// `res` must be null or returned by `ot_engine_scan_latex_inlines`.
#[no_mangle]
pub unsafe extern "C" fn ot_engine_free_latex_inlines(res: *mut OTLatexInlineScanResult) {
    if res.is_null() {
        return;
    }
    let boxed = Box::from_raw(res);
    if !boxed.spans.is_null() && boxed.span_count > 0 {
        let vec = Vec::from_raw_parts(boxed.spans, boxed.span_count, boxed.span_count);
        for s in vec {
            if !s.cmd.is_null() {
                let _ = CString::from_raw(s.cmd);
            }
            if !s.arg.is_null() {
                let _ = CString::from_raw(s.arg);
            }
        }
    }
}

/// Scans a LaTeX line for document/preamble/style/conditional directives.
///
/// # Safety
/// `line_utf8` must be null or a valid null-terminated UTF-8 C string.
#[no_mangle]
pub unsafe extern "C" fn ot_engine_scan_latex_directives(
    line_utf8: *const c_char,
    is_preamble: bool,
) -> *mut OTLatexDirectivesResult {
    let text = if line_utf8.is_null() {
        ""
    } else {
        CStr::from_ptr(line_utf8).to_str().unwrap_or("")
    };
    let mut items: Vec<OTLatexDirectiveItem> = scan_latex_directives(text, is_preamble)
        .into_iter()
        .map(|d| OTLatexDirectiveItem {
            kind: d.kind as u32,
            starred: d.starred,
            cmd: to_c_str(d.cmd),
            opt_arg: to_c_str(d.opt_arg),
            arg1: to_c_str(d.arg1),
            arg2: to_c_str(d.arg2),
            arg3: to_c_str(d.arg3),
        })
        .collect();
    items.shrink_to_fit();
    let count = items.len();
    let ptr = items.as_mut_ptr();
    std::mem::forget(items);
    Box::into_raw(Box::new(OTLatexDirectivesResult { items: ptr, count }))
}

/// Frees an `OTLatexDirectivesResult`.
///
/// # Safety
/// `res` must be null or returned by `ot_engine_scan_latex_directives`.
#[no_mangle]
pub unsafe extern "C" fn ot_engine_free_latex_directives(res: *mut OTLatexDirectivesResult) {
    if res.is_null() {
        return;
    }
    let boxed = Box::from_raw(res);
    if !boxed.items.is_null() && boxed.count > 0 {
        let vec = Vec::from_raw_parts(boxed.items, boxed.count, boxed.count);
        for d in vec {
            for ptr in [d.cmd, d.opt_arg, d.arg1, d.arg2, d.arg3] {
                if !ptr.is_null() {
                    let _ = CString::from_raw(ptr);
                }
            }
        }
    }
}
