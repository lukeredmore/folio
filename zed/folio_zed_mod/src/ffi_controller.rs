use std::ffi::c_char;
use std::ptr;

use crate::ffi::{folio_zed_mod_free_string, into_c_str};
use crate::keystroke_controller::{
    evaluate_markdown_keystroke, KeystrokeDecision, KeystrokeInput,
};
use crate::markdown_formatting::cycle_code_block_language;
use crate::text_navigation::{
    extract_html_attr, percent_decode_str, surrounding_code_span_delimiters,
};

#[repr(C)]
pub struct FolioKeystrokeDecisionC {
    pub kind: u32,
    pub range_start: usize,
    pub range_end: usize,
    pub has_post_selection: bool,
    pub post_sel_start: usize,
    pub post_sel_end: usize,
    pub replacement: *mut c_char,
}

#[repr(C)]
pub struct FolioCodeSpanDelimitersC {
    pub valid: bool,
    pub open_start: usize,
    pub open_end: usize,
    pub close_start: usize,
    pub close_end: usize,
}

#[repr(C)]
pub struct FolioSourceEditC {
    pub valid: bool,
    pub range_start: usize,
    pub range_end: usize,
    pub replacement: *mut c_char,
}

unsafe fn slice_to_str<'a>(ptr: *const u8, len: usize) -> Option<&'a str> {
    if ptr.is_null() {
        return None;
    }
    let bytes = unsafe { std::slice::from_raw_parts(ptr, len) };
    std::str::from_utf8(bytes).ok()
}

impl FolioKeystrokeDecisionC {
    const fn empty(kind: u32, range_start: usize, range_end: usize) -> Self {
        Self {
            kind,
            range_start,
            range_end,
            has_post_selection: false,
            post_sel_start: 0,
            post_sel_end: 0,
            replacement: ptr::null_mut(),
        }
    }
}

/// # Safety
/// `src_ptr` and `key_ptr` must be valid UTF-8 byte slices of lengths `src_len` and `key_len`.
#[no_mangle]
pub unsafe extern "C" fn folio_zed_mod_evaluate_keystroke(
    src_ptr: *const u8,
    src_len: usize,
    sel_start: usize,
    sel_end: usize,
    head: usize,
    tail: usize,
    key_ptr: *const u8,
    key_len: usize,
    platform: bool,
    control: bool,
    alt: bool,
    shift: bool,
    function: bool,
) -> FolioKeystrokeDecisionC {
    let (Some(source), Some(key)) = (
        unsafe { slice_to_str(src_ptr, src_len) },
        unsafe { slice_to_str(key_ptr, key_len) },
    ) else {
        return FolioKeystrokeDecisionC::empty(0, 0, 0);
    };
    let input = KeystrokeInput {
        key,
        platform,
        control,
        alt,
        shift,
        function,
    };
    match evaluate_markdown_keystroke(source, sel_start..sel_end, head, tail, &input) {
        KeystrokeDecision::Unhandled => FolioKeystrokeDecisionC::empty(0, 0, 0),
        KeystrokeDecision::HandledNoOp => FolioKeystrokeDecisionC::empty(1, 0, 0),
        KeystrokeDecision::TogglePrettyMode => FolioKeystrokeDecisionC::empty(2, 0, 0),
        KeystrokeDecision::ClipboardCut(r) => FolioKeystrokeDecisionC::empty(3, r.start, r.end),
        KeystrokeDecision::ClipboardPaste(r) => FolioKeystrokeDecisionC::empty(4, r.start, r.end),
        KeystrokeDecision::SelectRange(r) => FolioKeystrokeDecisionC::empty(5, r.start, r.end),
        KeystrokeDecision::SourceEdit {
            edit_range,
            replacement,
            post_selection,
        } => {
            let (has_post_selection, post_sel_start, post_sel_end) =
                post_selection.map_or((false, 0, 0), |r| (true, r.start, r.end));
            FolioKeystrokeDecisionC {
                kind: 6,
                range_start: edit_range.start,
                range_end: edit_range.end,
                has_post_selection,
                post_sel_start,
                post_sel_end,
                replacement: into_c_str(replacement),
            }
        }
    }
}

/// # Safety
/// `res` must have been returned by `folio_zed_mod_evaluate_keystroke`.
#[no_mangle]
pub unsafe extern "C" fn folio_zed_mod_free_keystroke_decision(res: FolioKeystrokeDecisionC) {
    unsafe { folio_zed_mod_free_string(res.replacement) };
}

/// # Safety
/// `src_ptr` must be a valid UTF-8 byte slice of length `src_len`.
#[no_mangle]
pub unsafe extern "C" fn folio_zed_mod_surrounding_code_span_delimiters(
    src_ptr: *const u8,
    src_len: usize,
    content_start: usize,
    content_end: usize,
) -> FolioCodeSpanDelimitersC {
    let empty = FolioCodeSpanDelimitersC {
        valid: false,
        open_start: 0,
        open_end: 0,
        close_start: 0,
        close_end: 0,
    };
    let Some(source) = (unsafe { slice_to_str(src_ptr, src_len) }) else {
        return empty;
    };
    let Some((open, close)) =
        surrounding_code_span_delimiters(source, &(content_start..content_end))
    else {
        return empty;
    };
    FolioCodeSpanDelimitersC {
        valid: true,
        open_start: open.start,
        open_end: open.end,
        close_start: close.start,
        close_end: close.end,
    }
}

/// # Safety
/// `src_ptr` and `lang_ptr` must be valid UTF-8 byte slices of lengths `src_len` and `lang_len`.
#[no_mangle]
pub unsafe extern "C" fn folio_zed_mod_cycle_code_block_language(
    src_ptr: *const u8,
    src_len: usize,
    block_start: usize,
    block_end: usize,
    lang_ptr: *const u8,
    lang_len: usize,
) -> FolioSourceEditC {
    let empty = FolioSourceEditC {
        valid: false,
        range_start: 0,
        range_end: 0,
        replacement: ptr::null_mut(),
    };
    let (Some(source), Some(lang)) = (
        unsafe { slice_to_str(src_ptr, src_len) },
        unsafe { slice_to_str(lang_ptr, lang_len) },
    ) else {
        return empty;
    };
    let Some((range, updated_line)) =
        cycle_code_block_language(source, block_start..block_end, lang)
    else {
        return empty;
    };
    FolioSourceEditC {
        valid: true,
        range_start: range.start,
        range_end: range.end,
        replacement: into_c_str(updated_line),
    }
}

/// # Safety
/// `res` must have been returned by `folio_zed_mod_cycle_code_block_language`.
#[no_mangle]
pub unsafe extern "C" fn folio_zed_mod_free_source_edit(res: FolioSourceEditC) {
    unsafe { folio_zed_mod_free_string(res.replacement) };
}

/// # Safety
/// `tag_ptr` and `attr_ptr` must be valid UTF-8 byte slices of lengths `tag_len` and `attr_len`.
#[no_mangle]
pub unsafe extern "C" fn folio_zed_mod_extract_html_attr(
    tag_ptr: *const u8,
    tag_len: usize,
    attr_ptr: *const u8,
    attr_len: usize,
) -> *mut c_char {
    let (Some(tag), Some(attr)) = (
        unsafe { slice_to_str(tag_ptr, tag_len) },
        unsafe { slice_to_str(attr_ptr, attr_len) },
    ) else {
        return ptr::null_mut();
    };
    extract_html_attr(tag, attr).map_or(ptr::null_mut(), into_c_str)
}

/// # Safety
/// `input_ptr` must be a valid UTF-8 byte slice of length `input_len`.
#[no_mangle]
pub unsafe extern "C" fn folio_zed_mod_percent_decode(
    input_ptr: *const u8,
    input_len: usize,
) -> *mut c_char {
    let Some(input) = (unsafe { slice_to_str(input_ptr, input_len) }) else {
        return ptr::null_mut();
    };
    into_c_str(percent_decode_str(input))
}
