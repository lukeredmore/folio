pub mod editing_ffi;
pub mod markdown_ffi;
pub mod math_ffi;

pub use editing_ffi::*;
pub use markdown_ffi::*;
pub use math_ffi::*;

use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::ptr;

use crate::stats::DocumentStats;
use crate::theme::{language_accent_color, RgbaColor, ThemeId, ThemeMetrics};

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct OTDocumentStats {
    pub words: usize,
    pub lines: usize,
    pub characters: usize,
    pub characters_without_spaces: usize,
    pub selected_words: usize,
    pub selected_characters: usize,
    pub reading_time_seconds: usize,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct OTRgbaColor {
    pub r: f64,
    pub g: f64,
    pub b: f64,
    pub a: f64,
}

impl From<RgbaColor> for OTRgbaColor {
    fn from(c: RgbaColor) -> Self {
        Self {
            r: c.r,
            g: c.g,
            b: c.b,
            a: c.a,
        }
    }
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct OTThemeMetrics {
    pub is_dark: bool,
    pub base_font_size: f64,
    pub max_write_width: f64,
    pub editor_bg: OTRgbaColor,
    pub sidebar_bg: OTRgbaColor,
    pub text_fg: OTRgbaColor,
    pub heading_fg: OTRgbaColor,
    pub secondary_text_fg: OTRgbaColor,
    pub link_fg: OTRgbaColor,
    pub code_bg: OTRgbaColor,
    pub inline_code_fg: OTRgbaColor,
    pub markdown_token_fg: OTRgbaColor,
    pub blockquote_fg: OTRgbaColor,
}

#[repr(C)]
#[derive(Debug)]
pub struct OTMermaidRenderResult {
    pub svg: *mut c_char,
    pub width: f64,
    pub height: f64,
}

/// Computes document word/line/character statistics and reading time for C/Swift callers.
///
/// # Safety
/// `text_utf8` must be either null or a valid null-terminated UTF-8 C string.
#[no_mangle]
pub unsafe extern "C" fn ot_engine_compute_stats(
    text_utf8: *const c_char,
    has_selection: bool,
    sel_utf16_loc: usize,
    sel_utf16_len: usize,
) -> OTDocumentStats {
    if text_utf8.is_null() {
        return OTDocumentStats {
            words: 0,
            lines: 1,
            characters: 0,
            characters_without_spaces: 0,
            selected_words: 0,
            selected_characters: 0,
            reading_time_seconds: 0,
        };
    }

    let text = CStr::from_ptr(text_utf8).to_string_lossy();
    let sel = if has_selection {
        Some((sel_utf16_loc, sel_utf16_len))
    } else {
        None
    };
    let stats = DocumentStats::compute(&text, sel);

    OTDocumentStats {
        words: stats.words,
        lines: stats.lines,
        characters: stats.characters,
        characters_without_spaces: stats.characters_without_spaces,
        selected_words: stats.selected_words,
        selected_characters: stats.selected_characters,
        reading_time_seconds: stats.reading_time_seconds,
    }
}

/// Frees a C string previously allocated by `folio_engine`.
///
/// # Safety
/// `str_ptr` must be null or a pointer returned by a `folio_engine` FFI string constructor.
#[no_mangle]
pub unsafe extern "C" fn ot_engine_free_string(str_ptr: *mut c_char) {
    if !str_ptr.is_null() {
        let _ = CString::from_raw(str_ptr);
    }
}

#[no_mangle]
pub extern "C" fn ot_engine_theme_metrics(theme_id: u32) -> OTThemeMetrics {
    let m = ThemeMetrics::for_theme(ThemeId::from_u32(theme_id));
    OTThemeMetrics {
        is_dark: m.is_dark,
        base_font_size: m.base_font_size,
        max_write_width: m.max_write_width,
        editor_bg: m.editor_bg.into(),
        sidebar_bg: m.sidebar_bg.into(),
        text_fg: m.text_fg.into(),
        heading_fg: m.heading_fg.into(),
        secondary_text_fg: m.secondary_text_fg.into(),
        link_fg: m.link_fg.into(),
        code_bg: m.code_bg.into(),
        inline_code_fg: m.inline_code_fg.into(),
        markdown_token_fg: m.markdown_token_fg.into(),
        blockquote_fg: m.blockquote_fg.into(),
    }
}

/// Returns the accent color for a code fence language identifier.
///
/// # Safety
/// `language_utf8` must be null or a valid null-terminated UTF-8 C string.
#[no_mangle]
pub unsafe extern "C" fn ot_engine_language_accent_color(
    language_utf8: *const c_char,
    is_dark: bool,
) -> OTRgbaColor {
    let lang = if language_utf8.is_null() {
        ""
    } else {
        CStr::from_ptr(language_utf8).to_str().unwrap_or("")
    };
    language_accent_color(lang, is_dark).into()
}

/// Renders a Mermaid diagram source string into a standalone SVG with intrinsic dimensions.
///
/// # Safety
/// `mermaid_utf8` must be null or a valid null-terminated UTF-8 C string.
#[no_mangle]
pub unsafe extern "C" fn ot_engine_render_mermaid_svg(
    mermaid_utf8: *const c_char,
    is_dark: bool,
) -> *mut OTMermaidRenderResult {
    let source = if mermaid_utf8.is_null() {
        ""
    } else {
        CStr::from_ptr(mermaid_utf8).to_str().unwrap_or("")
    };
    let rendered = crate::mermaid::render_mermaid_to_svg(source, is_dark);
    let svg_ptr = CString::new(rendered.svg).unwrap_or_default().into_raw();
    Box::into_raw(Box::new(OTMermaidRenderResult {
        svg: svg_ptr,
        width: rendered.width as f64,
        height: rendered.height as f64,
    }))
}

/// Validates and normalizes an inline or fenced `<svg>...</svg>` string and extracts its dimensions.
///
/// # Safety
/// `svg_utf8` must be null or a valid null-terminated UTF-8 C string.
#[no_mangle]
pub unsafe extern "C" fn ot_engine_normalize_svg(
    svg_utf8: *const c_char,
) -> *mut OTMermaidRenderResult {
    let source = if svg_utf8.is_null() {
        ""
    } else {
        CStr::from_ptr(svg_utf8).to_str().unwrap_or("")
    };
    if let Some((norm_svg, w, h)) = crate::mermaid::normalize_svg_markup(source) {
        let svg_ptr = CString::new(norm_svg).unwrap_or_default().into_raw();
        Box::into_raw(Box::new(OTMermaidRenderResult {
            svg: svg_ptr,
            width: w as f64,
            height: h as f64,
        }))
    } else {
        ptr::null_mut()
    }
}

/// Frees an `OTMermaidRenderResult` previously allocated by `folio_engine`.
///
/// # Safety
/// `result` must be null or a pointer returned by `ot_engine_render_mermaid_svg` / `ot_engine_normalize_svg`.
#[no_mangle]
pub unsafe extern "C" fn ot_engine_free_mermaid_result(result: *mut OTMermaidRenderResult) {
    if result.is_null() {
        return;
    }
    let res = Box::from_raw(result);
    if !res.svg.is_null() {
        let _ = CString::from_raw(res.svg);
    }
}
