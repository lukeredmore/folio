use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::ptr;

use crate::editor_session::FolioZedModSession;
use crate::math_canvas::{build_gpui_math_canvas, GpuiMathPrimitive};
use folio_engine::markdown::NewlineAction;
use folio_engine::mermaid::{normalize_svg_markup, render_mermaid_to_svg};

#[repr(C)]
#[derive(Debug)]
pub struct FolioZedSvgResult {
    pub svg: *mut c_char,
    pub width: f32,
    pub height: f32,
}

#[repr(C)]
#[derive(Debug)]
pub struct FolioZedMathPrim {
    pub kind: u32,
    pub x: f32,
    pub y: f32,
    pub width: f32,
    pub height: f32,
    pub extra_f32_1: f32,
    pub extra_f32_2: f32,
    pub italic: bool,
    pub bold: bool,
    pub serif: bool,
    pub text: *mut c_char,
}

#[repr(C)]
#[derive(Debug)]
pub struct FolioZedMathCanvas {
    pub width: f32,
    pub ascent: f32,
    pub descent: f32,
    pub primitives: *mut FolioZedMathPrim,
    pub primitive_count: usize,
    pub plain_text_fallback: *mut c_char,
}

#[repr(C)]
#[derive(Debug)]
pub struct FolioZedNewlineResult {
    pub kind: u32,
    pub prefix: *mut c_char,
}

unsafe fn cstr_or_empty<'a>(ptr: *const c_char) -> &'a str {
    if ptr.is_null() {
        ""
    } else {
        CStr::from_ptr(ptr).to_str().unwrap_or("")
    }
}

fn into_c_str(value: String) -> *mut c_char {
    CString::new(value).unwrap_or_default().into_raw()
}

fn map_math_prim(prim: GpuiMathPrimitive) -> FolioZedMathPrim {
    match prim {
        GpuiMathPrimitive::ShapedGlyphRun {
            text, origin_x, baseline_y, font_size, italic, bold, serif,
        } => FolioZedMathPrim {
            kind: 0, x: origin_x, y: baseline_y, width: 0.0, height: font_size,
            extra_f32_1: 0.0, extra_f32_2: 0.0, italic, bold, serif, text: into_c_str(text),
        },
        GpuiMathPrimitive::RuleQuad { x, y, width, height } => FolioZedMathPrim {
            kind: 1, x, y, width, height, extra_f32_1: 0.0, extra_f32_2: 0.0,
            italic: false, bold: false, serif: false, text: ptr::null_mut(),
        },
        GpuiMathPrimitive::RadicalStroke {
            x, top_y, bottom_y, hook_width, radicand_width, line_width,
        } => FolioZedMathPrim {
            kind: 2, x, y: top_y, width: hook_width, height: bottom_y,
            extra_f32_1: radicand_width, extra_f32_2: line_width,
            italic: false, bold: false, serif: false, text: ptr::null_mut(),
        },
    }
}

/// # Safety
/// `raw_svg_utf8` must be null or a valid null-terminated UTF-8 C string.
#[no_mangle]
pub unsafe extern "C" fn folio_zed_mod_normalize_svg(
    raw_svg_utf8: *const c_char,
) -> *mut FolioZedSvgResult {
    normalize_svg_markup(cstr_or_empty(raw_svg_utf8)).map_or(ptr::null_mut(), |(svg, width, height)| {
        Box::into_raw(Box::new(FolioZedSvgResult {
            svg: into_c_str(svg),
            width,
            height,
        }))
    })
}

/// # Safety
/// `source_utf8` must be null or a valid null-terminated UTF-8 C string.
#[no_mangle]
pub unsafe extern "C" fn folio_zed_mod_render_mermaid_svg(
    source_utf8: *const c_char,
    is_dark: bool,
) -> *mut FolioZedSvgResult {
    let rendered = render_mermaid_to_svg(cstr_or_empty(source_utf8), is_dark);
    if rendered.svg.is_empty() {
        return ptr::null_mut();
    }
    Box::into_raw(Box::new(FolioZedSvgResult {
        svg: into_c_str(rendered.svg),
        width: rendered.width,
        height: rendered.height,
    }))
}

/// # Safety
/// `result` must be null or a pointer returned by a `folio_zed_mod_*_svg` FFI function.
#[no_mangle]
pub unsafe extern "C" fn folio_zed_mod_free_svg_result(result: *mut FolioZedSvgResult) {
    if !result.is_null() {
        let boxed = Box::from_raw(result);
        folio_zed_mod_free_string(boxed.svg);
    }
}

/// # Safety
/// `latex_utf8` must be null or a valid null-terminated UTF-8 C string.
#[no_mangle]
pub unsafe extern "C" fn folio_zed_mod_build_math_canvas(
    latex_utf8: *const c_char,
    font_size_px: f32,
    display_mode: bool,
) -> *mut FolioZedMathCanvas {
    let desc = build_gpui_math_canvas(cstr_or_empty(latex_utf8), font_size_px, display_mode);
    let mut boxed_prims = desc
        .primitives
        .into_iter()
        .map(map_math_prim)
        .collect::<Vec<_>>()
        .into_boxed_slice();
    let prim_ptr = boxed_prims.as_mut_ptr();
    let prim_count = boxed_prims.len();
    std::mem::forget(boxed_prims);

    Box::into_raw(Box::new(FolioZedMathCanvas {
        width: desc.width,
        ascent: desc.ascent,
        descent: desc.descent,
        primitives: prim_ptr,
        primitive_count: prim_count,
        plain_text_fallback: into_c_str(desc.plain_text_accessibility),
    }))
}

/// # Safety
/// `canvas` must be null or a pointer returned by `folio_zed_mod_build_math_canvas`.
#[no_mangle]
pub unsafe extern "C" fn folio_zed_mod_free_math_canvas(canvas: *mut FolioZedMathCanvas) {
    if canvas.is_null() {
        return;
    }
    let boxed = Box::from_raw(canvas);
    if !boxed.primitives.is_null() && boxed.primitive_count > 0 {
        let slice = std::slice::from_raw_parts_mut(boxed.primitives, boxed.primitive_count);
        for prim in slice.iter_mut() {
            folio_zed_mod_free_string(prim.text);
        }
        let _ = Box::from_raw(slice as *mut [FolioZedMathPrim]);
    }
    folio_zed_mod_free_string(boxed.plain_text_fallback);
}

/// # Safety
/// `line_up_to_cursor_utf8` must be null or a valid null-terminated UTF-8 C string.
#[no_mangle]
pub unsafe extern "C" fn folio_zed_mod_on_editor_newline(
    line_up_to_cursor_utf8: *const c_char,
) -> FolioZedNewlineResult {
    match FolioZedModSession::new(true).on_editor_newline(cstr_or_empty(line_up_to_cursor_utf8)) {
        NewlineAction::Default => FolioZedNewlineResult { kind: 0, prefix: ptr::null_mut() },
        NewlineAction::ClearEmptyListLine => FolioZedNewlineResult { kind: 1, prefix: ptr::null_mut() },
        NewlineAction::InsertPrefix(prefix) => FolioZedNewlineResult {
            kind: 2,
            prefix: into_c_str(prefix),
        },
    }
}

/// # Safety
/// `res.prefix` must be null or a C string returned by `folio_zed_mod_on_editor_newline`.
#[no_mangle]
pub unsafe extern "C" fn folio_zed_mod_free_newline_result(res: FolioZedNewlineResult) {
    folio_zed_mod_free_string(res.prefix);
}

/// # Safety
/// `source_utf8` and `new_language_utf8` must be null or valid null-terminated UTF-8 C strings.
#[no_mangle]
pub unsafe extern "C" fn folio_zed_mod_set_code_fence_language(
    source_utf8: *const c_char,
    fence_start_byte_offset: usize,
    new_language_utf8: *const c_char,
) -> *mut c_char {
    FolioZedModSession::set_code_fence_language(
        cstr_or_empty(source_utf8),
        fence_start_byte_offset,
        cstr_or_empty(new_language_utf8),
    )
    .map_or(ptr::null_mut(), into_c_str)
}

/// # Safety
/// `str_ptr` must be null or a pointer returned by a `folio_zed_mod` string constructor.
#[no_mangle]
pub unsafe extern "C" fn folio_zed_mod_free_string(str_ptr: *mut c_char) {
    if !str_ptr.is_null() {
        let _ = CString::from_raw(str_ptr);
    }
}
