use std::ffi::{CStr, CString};
use std::os::raw::c_char;

use crate::latex::{
    analyze_macro_template, classify_latex_line, normalize_display_math, parse_bibtex_entries,
    scan_latex_directives, scan_latex_inlines,
};

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

fn c_str_in<'a>(p: *const c_char) -> &'a str {
    if p.is_null() {
        ""
    } else {
        unsafe { CStr::from_ptr(p) }.to_str().unwrap_or("")
    }
}

fn to_c_str(s: String) -> *mut c_char {
    CString::new(s).unwrap_or_default().into_raw()
}

unsafe fn free_c_ptrs<const N: usize>(ptrs: [*mut c_char; N]) {
    for p in ptrs {
        if !p.is_null() {
            let _ = CString::from_raw(p);
        }
    }
}

/// Scans a single LaTeX line/range for inline constructs and returns UTF-16 ranges.
/// # Safety
/// `line_utf8` must be null or a valid null-terminated UTF-8 C string.
#[no_mangle]
pub unsafe extern "C" fn ot_engine_scan_latex_inlines(
    line_utf8: *const c_char,
) -> *mut OTLatexInlineScanResult {
    let mut spans: Vec<OTLatexInlineSpan> = scan_latex_inlines(c_str_in(line_utf8))
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
    let (spans_ptr, span_count) = (spans.as_mut_ptr(), spans.len());
    std::mem::forget(spans);
    Box::into_raw(Box::new(OTLatexInlineScanResult {
        spans: spans_ptr,
        span_count,
    }))
}

/// Frees an `OTLatexInlineScanResult`.
/// # Safety
/// `res` must be null or returned by `ot_engine_scan_latex_inlines`.
#[no_mangle]
pub unsafe extern "C" fn ot_engine_free_latex_inlines(res: *mut OTLatexInlineScanResult) {
    if !res.is_null() {
        let b = Box::from_raw(res);
        if !b.spans.is_null() && b.span_count > 0 {
            for s in Vec::from_raw_parts(b.spans, b.span_count, b.span_count) {
                free_c_ptrs([s.cmd, s.arg]);
            }
        }
    }
}

/// Scans a LaTeX line for document/preamble/style/conditional directives.
/// # Safety
/// `line_utf8` must be null or a valid null-terminated UTF-8 C string.
#[no_mangle]
pub unsafe extern "C" fn ot_engine_scan_latex_directives(
    line_utf8: *const c_char,
    is_preamble: bool,
) -> *mut OTLatexDirectivesResult {
    let mut items: Vec<OTLatexDirectiveItem> =
        scan_latex_directives(c_str_in(line_utf8), is_preamble)
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
    let (items_ptr, count) = (items.as_mut_ptr(), items.len());
    std::mem::forget(items);
    Box::into_raw(Box::new(OTLatexDirectivesResult {
        items: items_ptr,
        count,
    }))
}

/// Frees an `OTLatexDirectivesResult`.
/// # Safety
/// `res` must be null or returned by `ot_engine_scan_latex_directives`.
#[no_mangle]
pub unsafe extern "C" fn ot_engine_free_latex_directives(res: *mut OTLatexDirectivesResult) {
    if !res.is_null() {
        let b = Box::from_raw(res);
        if !b.items.is_null() && b.count > 0 {
            for d in Vec::from_raw_parts(b.items, b.count, b.count) {
                free_c_ptrs([d.cmd, d.opt_arg, d.arg1, d.arg2, d.arg3]);
            }
        }
    }
}

/// Classifies a single LaTeX line for block/environment/sectioning/item/display-math structure.
/// # Safety
/// `line_utf8` must be null or a valid null-terminated UTF-8 C string.
#[no_mangle]
pub unsafe extern "C" fn ot_engine_classify_latex_line(
    line_utf8: *const c_char,
) -> OTLatexLineClassification {
    let c = classify_latex_line(c_str_in(line_utf8));
    OTLatexLineClassification {
        kind: c.kind as u32,
        has_opt_arg: c.has_opt_arg,
        open_loc: c.open_loc,
        open_len: c.open_len,
        opt_loc: c.opt_loc,
        opt_len: c.opt_len,
        space_loc: c.space_loc,
        space_len: c.space_len,
        body_loc: c.body_loc,
        body_len: c.body_len,
        close_loc: c.close_loc,
        close_len: c.close_len,
        cmd: to_c_str(c.cmd),
        opt_arg: to_c_str(c.opt_arg),
        arg1: to_c_str(c.arg1),
    }
}

/// Frees an `OTLatexLineClassification`.
/// # Safety
/// `res` must have been returned by `ot_engine_classify_latex_line`.
#[no_mangle]
pub unsafe extern "C" fn ot_engine_free_latex_line_classification(res: OTLatexLineClassification) {
    free_c_ptrs([res.cmd, res.opt_arg, res.arg1]);
}

/// Analyzes a `\newcommand` / `\def` macro body template.
/// # Safety
/// `active_utf8` and `placeholder_utf8` must be null or valid null-terminated UTF-8 C strings.
#[no_mangle]
pub unsafe extern "C" fn ot_engine_analyze_macro_template(
    active_utf8: *const c_char,
    placeholder_utf8: *const c_char,
) -> OTMacroTemplateAnalysis {
    let a = analyze_macro_template(c_str_in(active_utf8), c_str_in(placeholder_utf8));
    OTMacroTemplateAnalysis {
        shows_body: a.shows_body,
        heading_level: a.heading_level,
        color_name: to_c_str(a.color_name),
        prefix_label: to_c_str(a.prefix_label),
        vspace_args: to_c_str(a.vspace_args),
    }
}

/// Frees an `OTMacroTemplateAnalysis`.
/// # Safety
/// `res` must have been returned by `ot_engine_analyze_macro_template`.
#[no_mangle]
pub unsafe extern "C" fn ot_engine_free_macro_template_analysis(res: OTMacroTemplateAnalysis) {
    free_c_ptrs([res.color_name, res.prefix_label, res.vspace_args]);
}

/// Normalizes a display math inner payload (`\tag{...}`, `\label{...}`).
/// # Safety
/// `raw_utf8` and `env_utf8` must be null or valid null-terminated UTF-8 C strings.
#[no_mangle]
pub unsafe extern "C" fn ot_engine_normalize_display_math(
    raw_utf8: *const c_char,
    env_utf8: *const c_char,
) -> OTNormalizedDisplayMath {
    let n = normalize_display_math(c_str_in(raw_utf8), c_str_in(env_utf8));
    OTNormalizedDisplayMath {
        cleaned_latex: to_c_str(n.cleaned_latex),
        explicit_tag: to_c_str(n.explicit_tag),
    }
}

/// Frees an `OTNormalizedDisplayMath`.
/// # Safety
/// `res` must have been returned by `ot_engine_normalize_display_math`.
#[no_mangle]
pub unsafe extern "C" fn ot_engine_free_normalized_display_math(res: OTNormalizedDisplayMath) {
    free_c_ptrs([res.cleaned_latex, res.explicit_tag]);
}

/// Parses a BibTeX `.bib` file string into structured entries and UTF-16 offsets.
/// # Safety
/// `bib_utf8` must be null or a valid null-terminated UTF-8 C string.
#[no_mangle]
pub unsafe extern "C" fn ot_engine_parse_bibtex(bib_utf8: *const c_char) -> *mut OTBibParseResult {
    let mut entries: Vec<OTBibEntry> = parse_bibtex_entries(c_str_in(bib_utf8))
        .into_iter()
        .map(|e| OTBibEntry {
            key: to_c_str(e.key),
            entry_type: to_c_str(e.entry_type),
            author: to_c_str(e.author),
            year: to_c_str(e.year),
            title: to_c_str(e.title),
            utf16_loc: e.utf16_loc,
        })
        .collect();
    entries.shrink_to_fit();
    let (entries_ptr, count) = (entries.as_mut_ptr(), entries.len());
    std::mem::forget(entries);
    Box::into_raw(Box::new(OTBibParseResult {
        entries: entries_ptr,
        count,
    }))
}

/// Frees an `OTBibParseResult`.
/// # Safety
/// `res` must be null or returned by `ot_engine_parse_bibtex`.
#[no_mangle]
pub unsafe extern "C" fn ot_engine_free_bibtex(res: *mut OTBibParseResult) {
    if !res.is_null() {
        let b = Box::from_raw(res);
        if !b.entries.is_null() && b.count > 0 {
            for e in Vec::from_raw_parts(b.entries, b.count, b.count) {
                free_c_ptrs([e.key, e.entry_type, e.author, e.year, e.title]);
            }
        }
    }
}
