use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::ptr;

use crate::math::{layout_latex, plain_text_summary, MathDrawPrimitive};

#[repr(C)]
#[derive(Debug)]
pub struct OTMathDrawCmd {
    pub kind: u32,
    pub font_style: u32,
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
    pub font_size: f64,
    pub thickness: f64,
    pub text: *mut c_char,
}

#[repr(C)]
#[derive(Debug)]
pub struct OTMathLayoutResult {
    pub width: f64,
    pub ascent: f64,
    pub descent: f64,
    pub commands: *mut OTMathDrawCmd,
    pub command_count: usize,
}

fn map_primitive_to_cmd(prim: MathDrawPrimitive) -> OTMathDrawCmd {
    match prim {
        MathDrawPrimitive::Text {
            x,
            y,
            text,
            font_style,
            font_size,
        } => OTMathDrawCmd {
            kind: 0,
            font_style: font_style as u32,
            x,
            y,
            width: 0.0,
            height: 0.0,
            font_size,
            thickness: 0.0,
            text: CString::new(text).unwrap_or_default().into_raw(),
        },
        MathDrawPrimitive::Rule {
            x,
            y,
            width,
            height,
        } => OTMathDrawCmd {
            kind: 1,
            font_style: 0,
            x,
            y,
            width,
            height,
            font_size: 0.0,
            thickness: height,
            text: ptr::null_mut(),
        },
        MathDrawPrimitive::Radical {
            x,
            top_y,
            bottom_y,
            hook_width,
            radicand_width,
            thickness,
        } => OTMathDrawCmd {
            kind: 2,
            font_style: 0,
            x,
            y: top_y,
            width: hook_width,
            height: bottom_y,
            font_size: radicand_width,
            thickness,
            text: ptr::null_mut(),
        },
        MathDrawPrimitive::Delimiter {
            symbol,
            x,
            top_y,
            bottom_y,
            width,
            thickness,
        } => OTMathDrawCmd {
            kind: 3,
            font_style: 0,
            x,
            y: top_y,
            width,
            height: bottom_y,
            font_size: 0.0,
            thickness,
            text: CString::new(symbol).unwrap_or_default().into_raw(),
        },
    }
}

/// Parses and lays out a LaTeX expression into 2D positioned drawing commands.
///
/// # Safety
/// `latex_utf8` must be null or a valid null-terminated UTF-8 C string.
#[no_mangle]
pub unsafe extern "C" fn ot_engine_layout_latex(
    latex_utf8: *const c_char,
    base_font_size: f64,
    is_display_style: bool,
) -> *mut OTMathLayoutResult {
    let latex = if latex_utf8.is_null() {
        ""
    } else {
        CStr::from_ptr(latex_utf8).to_str().unwrap_or("")
    };

    let plan = layout_latex(latex, base_font_size, is_display_style);
    let cmds: Vec<OTMathDrawCmd> = plan
        .primitives
        .into_iter()
        .map(map_primitive_to_cmd)
        .collect();

    let mut boxed_cmds = cmds.into_boxed_slice();
    let cmd_ptr = boxed_cmds.as_mut_ptr();
    let cmd_count = boxed_cmds.len();
    std::mem::forget(boxed_cmds);

    let result = Box::new(OTMathLayoutResult {
        width: plan.width,
        ascent: plan.ascent,
        descent: plan.descent,
        commands: cmd_ptr,
        command_count: cmd_count,
    });
    Box::into_raw(result)
}

/// Frees a math layout result returned by `ot_engine_layout_latex`.
///
/// # Safety
/// `result` must be null or a pointer returned by `ot_engine_layout_latex`.
#[no_mangle]
pub unsafe extern "C" fn ot_engine_free_math_layout(result: *mut OTMathLayoutResult) {
    if result.is_null() {
        return;
    }
    let res = Box::from_raw(result);
    if !res.commands.is_null() && res.command_count > 0 {
        let slice = std::slice::from_raw_parts_mut(res.commands, res.command_count);
        for cmd in slice.iter_mut() {
            if !cmd.text.is_null() {
                let _ = CString::from_raw(cmd.text);
            }
        }
        let _ = Box::from_raw(slice as *mut [OTMathDrawCmd]);
    }
}

/// Converts a LaTeX math expression into a readable Unicode summary string.
///
/// # Safety
/// `latex_utf8` must be null or a valid null-terminated UTF-8 C string.
#[no_mangle]
pub unsafe extern "C" fn ot_engine_plain_text_latex(latex_utf8: *const c_char) -> *mut c_char {
    let latex = if latex_utf8.is_null() {
        ""
    } else {
        CStr::from_ptr(latex_utf8).to_str().unwrap_or("")
    };
    let summary = plain_text_summary(latex);
    CString::new(summary).unwrap_or_default().into_raw()
}
