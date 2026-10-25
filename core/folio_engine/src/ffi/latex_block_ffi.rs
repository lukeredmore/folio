use std::ffi::{CStr, CString};
use std::os::raw::c_char;

use super::latex_ffi::{
    OTBibEntry, OTBibParseResult, OTLatexLineClassification, OTMacroTemplateAnalysis,
    OTNormalizedDisplayMath,
};
use crate::latex::{
    analyze_macro_template, classify_latex_line, normalize_display_math, parse_bibtex_entries,
};

fn to_c_str(s: String) -> *mut c_char {
    CString::new(s).unwrap_or_default().into_raw()
}

/// Classifies a single LaTeX line for list items, figure/table commands, or custom macro block opens.
///
/// # Safety
/// `line_utf8` must be null or a valid null-terminated UTF-8 C string.
#[no_mangle]
pub unsafe extern "C" fn ot_engine_classify_latex_line(
    line_utf8: *const c_char,
) -> OTLatexLineClassification {
    let text = if line_utf8.is_null() {
        ""
    } else {
        CStr::from_ptr(line_utf8).to_str().unwrap_or("")
    };
    let c = classify_latex_line(text);
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

/// Frees the C strings inside an `OTLatexLineClassification`.
///
/// # Safety
/// `res` must have been returned by `ot_engine_classify_latex_line`.
#[no_mangle]
pub unsafe extern "C" fn ot_engine_free_latex_line_classification(res: OTLatexLineClassification) {
    for ptr in [res.cmd, res.opt_arg, res.arg1] {
        if !ptr.is_null() {
            let _ = CString::from_raw(ptr);
        }
    }
}

/// Analyzes an expanded macro replacement template.
///
/// # Safety
/// `active_utf8` and `placeholder_utf8` must be null or valid null-terminated UTF-8 C strings.
#[no_mangle]
pub unsafe extern "C" fn ot_engine_analyze_macro_template(
    active_utf8: *const c_char,
    placeholder_utf8: *const c_char,
) -> OTMacroTemplateAnalysis {
    let active = if active_utf8.is_null() {
        ""
    } else {
        CStr::from_ptr(active_utf8).to_str().unwrap_or("")
    };
    let placeholder = if placeholder_utf8.is_null() {
        ""
    } else {
        CStr::from_ptr(placeholder_utf8).to_str().unwrap_or("")
    };
    let a = analyze_macro_template(active, placeholder);
    OTMacroTemplateAnalysis {
        shows_body: a.shows_body,
        heading_level: a.heading_level,
        color_name: to_c_str(a.color_name),
        prefix_label: to_c_str(a.prefix_label),
        vspace_args: to_c_str(a.vspace_args),
    }
}

/// Frees the C strings inside an `OTMacroTemplateAnalysis`.
///
/// # Safety
/// `res` must have been returned by `ot_engine_analyze_macro_template`.
#[no_mangle]
pub unsafe extern "C" fn ot_engine_free_macro_template_analysis(res: OTMacroTemplateAnalysis) {
    for ptr in [res.color_name, res.prefix_label, res.vspace_args] {
        if !ptr.is_null() {
            let _ = CString::from_raw(ptr);
        }
    }
}

/// Normalizes a display math block body and extracts any `\tag{...}`.
///
/// # Safety
/// `raw_utf8` and `env_utf8` must be null or valid null-terminated UTF-8 C strings.
#[no_mangle]
pub unsafe extern "C" fn ot_engine_normalize_display_math(
    raw_utf8: *const c_char,
    env_utf8: *const c_char,
) -> OTNormalizedDisplayMath {
    let raw = if raw_utf8.is_null() {
        ""
    } else {
        CStr::from_ptr(raw_utf8).to_str().unwrap_or("")
    };
    let env = if env_utf8.is_null() {
        ""
    } else {
        CStr::from_ptr(env_utf8).to_str().unwrap_or("")
    };
    let n = normalize_display_math(raw, env);
    OTNormalizedDisplayMath {
        cleaned_latex: to_c_str(n.cleaned_latex),
        explicit_tag: to_c_str(n.explicit_tag),
    }
}

/// Frees the C strings inside an `OTNormalizedDisplayMath`.
///
/// # Safety
/// `res` must have been returned by `ot_engine_normalize_display_math`.
#[no_mangle]
pub unsafe extern "C" fn ot_engine_free_normalized_display_math(res: OTNormalizedDisplayMath) {
    for ptr in [res.cleaned_latex, res.explicit_tag] {
        if !ptr.is_null() {
            let _ = CString::from_raw(ptr);
        }
    }
}

/// Parses a BibTeX `.bib` file content string into entries.
///
/// # Safety
/// `content_utf8` must be null or a valid null-terminated UTF-8 C string.
#[no_mangle]
pub unsafe extern "C" fn ot_engine_parse_bibtex(
    content_utf8: *const c_char,
) -> *mut OTBibParseResult {
    let content = if content_utf8.is_null() {
        ""
    } else {
        CStr::from_ptr(content_utf8).to_str().unwrap_or("")
    };
    let mut entries: Vec<OTBibEntry> = parse_bibtex_entries(content)
        .into_iter()
        .map(|b| OTBibEntry {
            key: to_c_str(b.key),
            entry_type: to_c_str(b.entry_type),
            author: to_c_str(b.author),
            year: to_c_str(b.year),
            title: to_c_str(b.title),
            utf16_loc: b.utf16_loc,
        })
        .collect();
    entries.shrink_to_fit();
    let count = entries.len();
    let ptr = entries.as_mut_ptr();
    std::mem::forget(entries);
    Box::into_raw(Box::new(OTBibParseResult {
        entries: ptr,
        count,
    }))
}

/// Frees an `OTBibParseResult`.
///
/// # Safety
/// `res` must be null or returned by `ot_engine_parse_bibtex`.
#[no_mangle]
pub unsafe extern "C" fn ot_engine_free_bibtex(res: *mut OTBibParseResult) {
    if res.is_null() {
        return;
    }
    let boxed = Box::from_raw(res);
    if !boxed.entries.is_null() && boxed.count > 0 {
        let vec = Vec::from_raw_parts(boxed.entries, boxed.count, boxed.count);
        for b in vec {
            for ptr in [b.key, b.entry_type, b.author, b.year, b.title] {
                if !ptr.is_null() {
                    let _ = CString::from_raw(ptr);
                }
            }
        }
    }
}
