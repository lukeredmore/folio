//! Zed GPUI core primitives and macOS platform window bridge (`crates/gpui`).

use std::ffi::{c_char, c_void};

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Pixels(pub f32);

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Point {
    pub x: Pixels,
    pub y: Pixels,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Size {
    pub width: Pixels,
    pub height: Pixels,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Bounds {
    pub origin: Point,
    pub size: Size,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Rgba {
    pub r: f32,
    pub g: f32,
    pub b: f32,
    pub a: f32,
}

#[derive(Debug, Clone, PartialEq)]
pub struct PaintQuad {
    pub bounds: Bounds,
    pub background: Rgba,
    pub corner_radius: f32,
}

#[derive(Debug, Clone, PartialEq)]
pub struct ShapedGlyphRun {
    pub text: String,
    pub origin: Point,
    pub font_size: f32,
    pub italic: bool,
    pub bold: bool,
    pub color: Rgba,
}

#[derive(Default, Debug, Clone)]
pub struct WindowScene {
    pub quads: Vec<PaintQuad>,
    pub glyph_runs: Vec<ShapedGlyphRun>,
}

impl WindowScene {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn paint_quad(&mut self, quad: PaintQuad) {
        self.quads.push(quad);
    }

    pub fn paint_glyph_run(&mut self, run: ShapedGlyphRun) {
        self.glyph_runs.push(run);
    }
}

// ============================================================================
// macOS Native GPUI Window Platform Bridge (AppKit + CoreText + CoreGraphics)
// ============================================================================

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct CGpuiRgba {
    pub r: f32,
    pub g: f32,
    pub b: f32,
    pub a: f32,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct CGpuiTheme {
    pub is_dark: bool,
    pub base_font_size: f32,
    pub max_write_width: f32,
    pub editor_bg: CGpuiRgba,
    pub text_fg: CGpuiRgba,
    pub heading_fg: CGpuiRgba,
    pub secondary_fg: CGpuiRgba,
    pub link_fg: CGpuiRgba,
    pub code_bg: CGpuiRgba,
    pub inline_code_fg: CGpuiRgba,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct CGpuiFoldSpan {
    pub byte_start: usize,
    pub byte_end: usize,
    pub collapse_completely: bool,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct CGpuiBlockDecoration {
    pub kind: u32,
    pub byte_start: usize,
    pub byte_end: usize,
    pub level: u32,
    pub is_active: bool,
    pub dim_factor: f32,
    pub accent_rgba: CGpuiRgba,
    pub label_text: *const c_char,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct CGpuiMathPrimitive {
    pub kind: u32,
    pub x: f32,
    pub y: f32,
    pub width: f32,
    pub height: f32,
    pub font_size: f32,
    pub line_width: f32,
    pub italic: bool,
    pub bold: bool,
    pub serif: bool,
    pub text: *const c_char,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct CGpuiMathCanvas {
    pub byte_start: usize,
    pub byte_end: usize,
    pub is_display: bool,
    pub width: f32,
    pub ascent: f32,
    pub descent: f32,
    pub primitives: *const CGpuiMathPrimitive,
    pub primitives_len: usize,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct CGpuiRenderFrame {
    pub theme: CGpuiTheme,
    pub folds: *const CGpuiFoldSpan,
    pub folds_len: usize,
    pub blocks: *const CGpuiBlockDecoration,
    pub blocks_len: usize,
    pub math_canvases: *const CGpuiMathCanvas,
    pub math_canvases_len: usize,
}

pub type CGpuiRenderCallback =
    unsafe extern "C" fn(cb_ctx: *mut c_void, frame: *const CGpuiRenderFrame);

pub type CGpuiEvaluateFn = unsafe extern "C" fn(
    user_data: *mut c_void,
    text_utf8: *const c_char,
    sel_byte_start: usize,
    sel_byte_end: usize,
    is_dark: bool,
    render_callback: CGpuiRenderCallback,
    cb_ctx: *mut c_void,
);

pub type CGpuiNewlineFn = unsafe extern "C" fn(
    user_data: *mut c_void,
    text_utf8: *const c_char,
    cursor_byte_offset: usize,
    out_new_cursor_byte: *mut usize,
) -> *mut c_char;

pub type CGpuiSetFenceLangFn = unsafe extern "C" fn(
    user_data: *mut c_void,
    text_utf8: *const c_char,
    fence_start_byte_offset: usize,
    new_lang_utf8: *const c_char,
) -> *mut c_char;

pub type CGpuiFreeStringFn = unsafe extern "C" fn(ptr: *mut c_char);

extern "C" {
    pub fn gpui_macos_run_window(
        user_data: *mut c_void,
        initial_text_utf8: *const c_char,
        evaluate_fn: CGpuiEvaluateFn,
        newline_fn: CGpuiNewlineFn,
        set_fence_lang_fn: CGpuiSetFenceLangFn,
        free_string_fn: CGpuiFreeStringFn,
    );
}
