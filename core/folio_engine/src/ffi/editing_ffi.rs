use std::ffi::{CStr, CString};
use std::ops::Range;
use std::os::raw::c_char;
use std::ptr;

use crate::markdown::{
    apply_newline_at_cursor, compute_newline_continuation, edit_newline, edit_set_heading_level,
    edit_symmetric_delimiter, edit_toggle_heading_level, edit_toggle_task_checkbox,
    set_heading_level_at_cursor, toggle_symmetric_delimiter, toggle_task_checkbox_at_cursor,
    NewlineAction, SpanEdit,
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

#[repr(C)]
#[derive(Debug)]
pub struct OTSpanEditResult {
    pub replacement: *mut c_char,
    pub replace_loc: usize,
    pub replace_len: usize,
    pub select_loc: usize,
    pub select_len: usize,
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

fn into_utf8_span_result(edit: SpanEdit) -> OTSpanEditResult {
    OTSpanEditResult {
        replacement: CString::new(edit.replacement)
            .unwrap_or_default()
            .into_raw(),
        replace_loc: edit.replace_range.start,
        replace_len: edit.replace_range.len(),
        select_loc: edit.new_selection.start,
        select_len: edit.new_selection.len(),
    }
}

fn utf16_to_byte_offset(text: &str, target_u16: usize, snap_right: bool) -> usize {
    let mut u16_acc = 0usize;
    for (byte_idx, ch) in text.char_indices() {
        let ch_u16 = ch.len_utf16();
        if target_u16 == u16_acc {
            return byte_idx;
        }
        if target_u16 < u16_acc + ch_u16 {
            return if snap_right {
                byte_idx + ch.len_utf8()
            } else {
                byte_idx
            };
        }
        u16_acc += ch_u16;
    }
    text.len()
}

fn utf16_range_to_bytes(text: &str, loc: usize, len: usize) -> Range<usize> {
    let start = utf16_to_byte_offset(text, loc, false);
    if len == 0 {
        start..start
    } else {
        let end = utf16_to_byte_offset(text, loc.saturating_add(len), true).max(start);
        start..end
    }
}

fn into_utf16_span_result(text: &str, edit: SpanEdit) -> OTSpanEditResult {
    let r_start = edit.replace_range.start.min(text.len());
    let r_end = edit.replace_range.end.min(text.len()).max(r_start);
    let prefix = &text[..r_start];
    let replaced = &text[r_start..r_end];
    let suffix = &text[r_end..];
    let repl = &edit.replacement;

    let prefix_u16: usize = prefix.chars().map(char::len_utf16).sum();
    let replaced_u16: usize = replaced.chars().map(char::len_utf16).sum();
    let repl_u16: usize = repl.chars().map(char::len_utf16).sum();

    let post_byte_to_u16 = |post_byte: usize| -> usize {
        if post_byte <= r_start {
            prefix[..post_byte].chars().map(char::len_utf16).sum()
        } else if post_byte <= r_start + repl.len() {
            prefix_u16
                + repl[..(post_byte - r_start)]
                    .chars()
                    .map(char::len_utf16)
                    .sum::<usize>()
        } else {
            let suffix_byte = (post_byte - r_start - repl.len()).min(suffix.len());
            prefix_u16
                + repl_u16
                + suffix[..suffix_byte]
                    .chars()
                    .map(char::len_utf16)
                    .sum::<usize>()
        }
    };

    let sel_start_u16 = post_byte_to_u16(edit.new_selection.start);
    let sel_end_u16 = post_byte_to_u16(edit.new_selection.end).max(sel_start_u16);

    OTSpanEditResult {
        replacement: CString::new(edit.replacement)
            .unwrap_or_default()
            .into_raw(),
        replace_loc: prefix_u16,
        replace_len: replaced_u16,
        select_loc: sel_start_u16,
        select_len: sel_end_u16 - sel_start_u16,
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

/// Computes a selection-aware UTF-8 `OTSpanEditResult` for smart newline continuation.
///
/// # Safety
/// `markdown_utf8` must be null or a valid null-terminated UTF-8 C string.
#[no_mangle]
pub unsafe extern "C" fn ot_engine_edit_newline_utf8(
    markdown_utf8: *const c_char,
    sel_byte_loc: usize,
    sel_byte_len: usize,
) -> OTSpanEditResult {
    let md = cstr_or_empty(markdown_utf8);
    let sel = sel_byte_loc..sel_byte_loc.saturating_add(sel_byte_len);
    into_utf8_span_result(edit_newline(md, sel))
}

/// Computes a selection-aware UTF-8 `OTSpanEditResult` for symmetric delimiter toggling.
///
/// # Safety
/// `markdown_utf8` and `delimiter_utf8` must be null or valid null-terminated UTF-8 C strings.
#[no_mangle]
pub unsafe extern "C" fn ot_engine_edit_symmetric_delimiter_utf8(
    markdown_utf8: *const c_char,
    sel_byte_loc: usize,
    sel_byte_len: usize,
    delimiter_utf8: *const c_char,
) -> OTSpanEditResult {
    let md = cstr_or_empty(markdown_utf8);
    let delim = cstr_or_empty(delimiter_utf8);
    let sel = sel_byte_loc..sel_byte_loc.saturating_add(sel_byte_len);
    into_utf8_span_result(edit_symmetric_delimiter(md, sel, delim))
}

/// Computes a selection-aware UTF-8 `OTSpanEditResult` for ATX heading level setting or toggling.
///
/// # Safety
/// `markdown_utf8` must be null or a valid null-terminated UTF-8 C string.
#[no_mangle]
pub unsafe extern "C" fn ot_engine_edit_heading_level_utf8(
    markdown_utf8: *const c_char,
    sel_byte_loc: usize,
    sel_byte_len: usize,
    level: u8,
    toggle_same_level: bool,
) -> OTSpanEditResult {
    let md = cstr_or_empty(markdown_utf8);
    let sel = sel_byte_loc..sel_byte_loc.saturating_add(sel_byte_len);
    let edit = if toggle_same_level {
        edit_toggle_heading_level(md, sel, level)
    } else {
        edit_set_heading_level(md, sel, level)
    };
    into_utf8_span_result(edit)
}

/// Computes a selection-aware UTF-8 `OTSpanEditResult` for GFM task checkbox toggling.
///
/// # Safety
/// `markdown_utf8` must be null or a valid null-terminated UTF-8 C string.
#[no_mangle]
pub unsafe extern "C" fn ot_engine_edit_task_checkbox_utf8(
    markdown_utf8: *const c_char,
    sel_byte_loc: usize,
    sel_byte_len: usize,
) -> OTSpanEditResult {
    let md = cstr_or_empty(markdown_utf8);
    let sel = sel_byte_loc..sel_byte_loc.saturating_add(sel_byte_len);
    into_utf8_span_result(edit_toggle_task_checkbox(md, sel))
}

/// Computes a selection-aware UTF-16 `OTSpanEditResult` for smart newline continuation.
///
/// # Safety
/// `markdown_utf8` must be null or a valid null-terminated UTF-8 C string.
#[no_mangle]
pub unsafe extern "C" fn ot_engine_edit_newline_utf16(
    markdown_utf8: *const c_char,
    sel_utf16_loc: usize,
    sel_utf16_len: usize,
) -> OTSpanEditResult {
    let md = cstr_or_empty(markdown_utf8);
    let sel = utf16_range_to_bytes(md, sel_utf16_loc, sel_utf16_len);
    into_utf16_span_result(md, edit_newline(md, sel))
}

/// Computes a selection-aware UTF-16 `OTSpanEditResult` for symmetric delimiter toggling.
///
/// # Safety
/// `markdown_utf8` and `delimiter_utf8` must be null or valid null-terminated UTF-8 C strings.
#[no_mangle]
pub unsafe extern "C" fn ot_engine_edit_symmetric_delimiter_utf16(
    markdown_utf8: *const c_char,
    sel_utf16_loc: usize,
    sel_utf16_len: usize,
    delimiter_utf8: *const c_char,
) -> OTSpanEditResult {
    let md = cstr_or_empty(markdown_utf8);
    let delim = cstr_or_empty(delimiter_utf8);
    let sel = utf16_range_to_bytes(md, sel_utf16_loc, sel_utf16_len);
    into_utf16_span_result(md, edit_symmetric_delimiter(md, sel, delim))
}

/// Computes a selection-aware UTF-16 `OTSpanEditResult` for ATX heading level setting or toggling.
///
/// # Safety
/// `markdown_utf8` must be null or a valid null-terminated UTF-8 C string.
#[no_mangle]
pub unsafe extern "C" fn ot_engine_edit_heading_level_utf16(
    markdown_utf8: *const c_char,
    sel_utf16_loc: usize,
    sel_utf16_len: usize,
    level: u8,
    toggle_same_level: bool,
) -> OTSpanEditResult {
    let md = cstr_or_empty(markdown_utf8);
    let sel = utf16_range_to_bytes(md, sel_utf16_loc, sel_utf16_len);
    let edit = if toggle_same_level {
        edit_toggle_heading_level(md, sel, level)
    } else {
        edit_set_heading_level(md, sel, level)
    };
    into_utf16_span_result(md, edit)
}

/// Computes a selection-aware UTF-16 `OTSpanEditResult` for GFM task checkbox toggling.
///
/// # Safety
/// `markdown_utf8` must be null or a valid null-terminated UTF-8 C string.
#[no_mangle]
pub unsafe extern "C" fn ot_engine_edit_task_checkbox_utf16(
    markdown_utf8: *const c_char,
    sel_utf16_loc: usize,
    sel_utf16_len: usize,
) -> OTSpanEditResult {
    let md = cstr_or_empty(markdown_utf8);
    let sel = utf16_range_to_bytes(md, sel_utf16_loc, sel_utf16_len);
    into_utf16_span_result(md, edit_toggle_task_checkbox(md, sel))
}

/// Frees the replacement string in an `OTSpanEditResult`.
///
/// # Safety
/// `result.replacement` must be null or a C string returned by a span-editing FFI function.
#[no_mangle]
pub unsafe extern "C" fn ot_engine_free_span_edit(result: OTSpanEditResult) {
    if !result.replacement.is_null() {
        let _ = CString::from_raw(result.replacement);
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
