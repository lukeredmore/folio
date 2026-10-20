use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::ptr;

use crate::markdown::{
    apply_newline_at_cursor, compute_newline_continuation, set_heading_level_at_cursor,
    toggle_symmetric_delimiter, toggle_task_checkbox_at_cursor, NewlineAction,
};

#[repr(C)]
#[derive(Debug)]
pub struct OTNewlineAction {
    pub kind: u32,
    pub prefix: *mut c_char,
}

#[repr(C)]
#[derive(Debug)]
pub struct OTParagraphReflow {
    pub found: bool,
    pub start_line: u32,
    pub end_line: u32,
    pub replacement: *mut c_char,
}

#[repr(C)]
#[derive(Debug)]
pub struct OTCursorEditResult {
    pub text: *mut c_char,
    pub cursor_byte: usize,
}

unsafe fn cstr_or_empty<'a>(ptr: *const c_char) -> &'a str {
    if ptr.is_null() {
        ""
    } else {
        CStr::from_ptr(ptr).to_str().unwrap_or("")
    }
}

fn into_cursor_edit_result((text, cursor_byte): (String, usize)) -> OTCursorEditResult {
    OTCursorEditResult {
        text: CString::new(text).unwrap_or_default().into_raw(),
        cursor_byte,
    }
}

/// Computes the smart-newline list/blockquote continuation action for a line prefix.
///
/// # Safety
/// `line_up_to_cursor_utf8` must be null or a valid null-terminated UTF-8 C string.
#[no_mangle]
pub unsafe extern "C" fn ot_engine_newline_continuation(
    line_up_to_cursor_utf8: *const c_char,
) -> OTNewlineAction {
    let line = cstr_or_empty(line_up_to_cursor_utf8);
    match compute_newline_continuation(line) {
        NewlineAction::Default => OTNewlineAction {
            kind: 0,
            prefix: ptr::null_mut(),
        },
        NewlineAction::ClearEmptyListLine => OTNewlineAction {
            kind: 1,
            prefix: ptr::null_mut(),
        },
        NewlineAction::InsertPrefix(prefix) => OTNewlineAction {
            kind: 2,
            prefix: CString::new(prefix).unwrap_or_default().into_raw(),
        },
    }
}

/// Frees the prefix string in an `OTNewlineAction`.
///
/// # Safety
/// `action.prefix` must be null or a C string returned by `ot_engine_newline_continuation`.
#[no_mangle]
pub unsafe extern "C" fn ot_engine_free_newline_action(action: OTNewlineAction) {
    if !action.prefix.is_null() {
        let _ = CString::from_raw(action.prefix);
    }
}

/// Applies a smart newline at `cursor_byte` and returns the updated buffer and cursor byte.
///
/// # Safety
/// `markdown_utf8` must be null or a valid null-terminated UTF-8 C string.
#[no_mangle]
pub unsafe extern "C" fn ot_engine_apply_newline_at_cursor(
    markdown_utf8: *const c_char,
    cursor_byte: usize,
) -> OTCursorEditResult {
    let md = cstr_or_empty(markdown_utf8);
    into_cursor_edit_result(apply_newline_at_cursor(md, cursor_byte))
}

/// Toggles a symmetric Markdown delimiter (e.g. `**`, `*`, `` ` ``) at `cursor_byte`.
///
/// # Safety
/// `markdown_utf8` and `delimiter_utf8` must be null or valid null-terminated UTF-8 C strings.
#[no_mangle]
pub unsafe extern "C" fn ot_engine_toggle_symmetric_delimiter(
    markdown_utf8: *const c_char,
    cursor_byte: usize,
    delimiter_utf8: *const c_char,
) -> OTCursorEditResult {
    let md = cstr_or_empty(markdown_utf8);
    let delim = cstr_or_empty(delimiter_utf8);
    into_cursor_edit_result(toggle_symmetric_delimiter(md, cursor_byte, delim))
}

/// Sets the ATX heading level (`0..=6`) on the line containing `cursor_byte`.
///
/// # Safety
/// `markdown_utf8` must be null or a valid null-terminated UTF-8 C string.
#[no_mangle]
pub unsafe extern "C" fn ot_engine_set_heading_level_at_cursor(
    markdown_utf8: *const c_char,
    cursor_byte: usize,
    level: u8,
) -> OTCursorEditResult {
    let md = cstr_or_empty(markdown_utf8);
    into_cursor_edit_result(set_heading_level_at_cursor(md, cursor_byte, level))
}

/// Toggles a GFM task checkbox (`[ ]` <-> `[x]`) on the line containing `cursor_byte`.
///
/// # Safety
/// `markdown_utf8` must be null or a valid null-terminated UTF-8 C string.
#[no_mangle]
pub unsafe extern "C" fn ot_engine_toggle_task_checkbox_at_cursor(
    markdown_utf8: *const c_char,
    cursor_byte: usize,
) -> OTCursorEditResult {
    let md = cstr_or_empty(markdown_utf8);
    into_cursor_edit_result(toggle_task_checkbox_at_cursor(md, cursor_byte))
}

/// Frees the text string in an `OTCursorEditResult`.
///
/// # Safety
/// `result.text` must be null or a C string returned by a cursor-editing FFI function.
#[no_mangle]
pub unsafe extern "C" fn ot_engine_free_cursor_edit(result: OTCursorEditResult) {
    if !result.text.is_null() {
        let _ = CString::from_raw(result.text);
    }
}

/// Rewraps the paragraph containing the 1-based `line` to `width` columns.
///
/// # Safety
/// `markdown_utf8` must be null or a valid null-terminated UTF-8 C string.
#[no_mangle]
pub unsafe extern "C" fn ot_engine_reflow_paragraph_at_line(
    markdown_utf8: *const c_char,
    line: u32,
    width: u32,
) -> OTParagraphReflow {
    let markdown = cstr_or_empty(markdown_utf8);
    match crate::reflow::reflow_paragraph_at_line(markdown, line, width as usize) {
        Some(r) => OTParagraphReflow {
            found: true,
            start_line: r.start_line,
            end_line: r.end_line,
            replacement: CString::new(r.replacement).unwrap_or_default().into_raw(),
        },
        None => OTParagraphReflow {
            found: false,
            start_line: 0,
            end_line: 0,
            replacement: ptr::null_mut(),
        },
    }
}

/// Frees the replacement string in an `OTParagraphReflow`.
///
/// # Safety
/// `result.replacement` must be null or a C string returned by `ot_engine_reflow_paragraph_at_line`.
#[no_mangle]
pub unsafe extern "C" fn ot_engine_free_paragraph_reflow(result: OTParagraphReflow) {
    if !result.replacement.is_null() {
        let _ = CString::from_raw(result.replacement);
    }
}

/// Rewraps every paragraph in the document to `width` columns.
///
/// # Safety
/// `markdown_utf8` must be null or a valid null-terminated UTF-8 C string.
#[no_mangle]
pub unsafe extern "C" fn ot_engine_reflow_markdown(
    markdown_utf8: *const c_char,
    width: u32,
) -> *mut c_char {
    let markdown = cstr_or_empty(markdown_utf8);
    let out = crate::reflow::reflow_markdown(markdown, width as usize);
    CString::new(out).unwrap_or_default().into_raw()
}
