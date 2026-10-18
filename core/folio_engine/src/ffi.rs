use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::ptr;

use crate::markdown::{
    compute_newline_continuation, parse_cmark_gfm_ast, render_gfm_to_html, render_markdown_to_html,
    NewlineAction,
};
use crate::math::{layout_latex, plain_text_summary, MathDrawPrimitive};
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

#[repr(C)]
#[derive(Debug)]
pub struct OTNewlineAction {
    pub kind: u32,
    pub prefix: *mut c_char,
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
    let mut cmds: Vec<OTMathDrawCmd> = Vec::with_capacity(plan.primitives.len());

    for prim in plan.primitives {
        match prim {
            MathDrawPrimitive::Text {
                x,
                y,
                text,
                font_style,
                font_size,
            } => {
                let c_str = CString::new(text).unwrap_or_default().into_raw();
                cmds.push(OTMathDrawCmd {
                    kind: 0,
                    font_style: font_style as u32,
                    x,
                    y,
                    width: 0.0,
                    height: 0.0,
                    font_size,
                    thickness: 0.0,
                    text: c_str,
                });
            }
            MathDrawPrimitive::Rule {
                x,
                y,
                width,
                height,
            } => {
                cmds.push(OTMathDrawCmd {
                    kind: 1,
                    font_style: 0,
                    x,
                    y,
                    width,
                    height,
                    font_size: 0.0,
                    thickness: height,
                    text: ptr::null_mut(),
                });
            }
            MathDrawPrimitive::Radical {
                x,
                top_y,
                bottom_y,
                hook_width,
                radicand_width,
                thickness,
            } => {
                cmds.push(OTMathDrawCmd {
                    kind: 2,
                    font_style: 0,
                    x,
                    y: top_y,
                    width: hook_width,
                    height: bottom_y,
                    font_size: radicand_width,
                    thickness,
                    text: ptr::null_mut(),
                });
            }
            MathDrawPrimitive::Delimiter {
                symbol,
                x,
                top_y,
                bottom_y,
                width,
                thickness,
            } => {
                let c_str = CString::new(symbol).unwrap_or_default().into_raw();
                cmds.push(OTMathDrawCmd {
                    kind: 3,
                    font_style: 0,
                    x,
                    y: top_y,
                    width,
                    height: bottom_y,
                    font_size: 0.0,
                    thickness,
                    text: c_str,
                });
            }
        }
    }

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

#[no_mangle]
pub unsafe extern "C" fn ot_engine_free_string(str_ptr: *mut c_char) {
    if !str_ptr.is_null() {
        let _ = CString::from_raw(str_ptr);
    }
}

#[no_mangle]
pub unsafe extern "C" fn ot_engine_newline_continuation(
    line_up_to_cursor_utf8: *const c_char,
) -> OTNewlineAction {
    let line = if line_up_to_cursor_utf8.is_null() {
        ""
    } else {
        CStr::from_ptr(line_up_to_cursor_utf8).to_str().unwrap_or("")
    };
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

#[no_mangle]
pub unsafe extern "C" fn ot_engine_free_newline_action(action: OTNewlineAction) {
    if !action.prefix.is_null() {
        let _ = CString::from_raw(action.prefix);
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

#[repr(C)]
#[derive(Debug)]
pub struct OTMarkdownBlockSpan {
    pub kind: u32,
    pub start_line: u32,
    pub start_column: u32,
    pub end_line: u32,
    pub end_column: u32,
    pub level: u32,
    pub flags: u32,
    pub info: *mut c_char,
}

#[repr(C)]
#[derive(Debug)]
pub struct OTMarkdownInlineSpan {
    pub kind: u32,
    pub start_line: u32,
    pub start_column: u32,
    pub end_line: u32,
    pub end_column: u32,
    pub url: *mut c_char,
    pub literal: *mut c_char,
}

#[repr(C)]
#[derive(Debug)]
pub struct OTMarkdownAstResult {
    pub blocks: *mut OTMarkdownBlockSpan,
    pub block_count: usize,
    pub inlines: *mut OTMarkdownInlineSpan,
    pub inline_count: usize,
}

#[no_mangle]
pub unsafe extern "C" fn ot_engine_render_markdown_html(
    markdown_utf8: *const c_char,
    extensions_space_separated_utf8: *const c_char,
) -> *mut c_char {
    let markdown = if markdown_utf8.is_null() {
        ""
    } else {
        CStr::from_ptr(markdown_utf8).to_str().unwrap_or("")
    };

    let html = if extensions_space_separated_utf8.is_null() {
        render_gfm_to_html(markdown)
    } else {
        let ext_str = CStr::from_ptr(extensions_space_separated_utf8)
            .to_str()
            .unwrap_or("");
        let exts: Vec<&str> = ext_str.split_whitespace().collect();
        render_markdown_to_html(markdown, &exts)
    };

    CString::new(html).unwrap_or_default().into_raw()
}

#[no_mangle]
pub unsafe extern "C" fn ot_engine_parse_markdown_ast(
    markdown_utf8: *const c_char,
) -> *mut OTMarkdownAstResult {
    let markdown = if markdown_utf8.is_null() {
        ""
    } else {
        CStr::from_ptr(markdown_utf8).to_str().unwrap_or("")
    };

    let analysis = parse_cmark_gfm_ast(markdown);

    let mut blocks: Vec<OTMarkdownBlockSpan> = Vec::with_capacity(analysis.blocks.len());
    for b in analysis.blocks {
        blocks.push(OTMarkdownBlockSpan {
            kind: b.kind as u32,
            start_line: b.start_line,
            start_column: b.start_column,
            end_line: b.end_line,
            end_column: b.end_column,
            level: b.level,
            flags: b.flags,
            info: CString::new(b.info).unwrap_or_default().into_raw(),
        });
    }

    let mut inlines: Vec<OTMarkdownInlineSpan> = Vec::with_capacity(analysis.inlines.len());
    for i in analysis.inlines {
        inlines.push(OTMarkdownInlineSpan {
            kind: i.kind as u32,
            start_line: i.start_line,
            start_column: i.start_column,
            end_line: i.end_line,
            end_column: i.end_column,
            url: CString::new(i.url).unwrap_or_default().into_raw(),
            literal: CString::new(i.literal).unwrap_or_default().into_raw(),
        });
    }

    let mut boxed_blocks = blocks.into_boxed_slice();
    let block_ptr = boxed_blocks.as_mut_ptr();
    let block_count = boxed_blocks.len();
    std::mem::forget(boxed_blocks);

    let mut boxed_inlines = inlines.into_boxed_slice();
    let inline_ptr = boxed_inlines.as_mut_ptr();
    let inline_count = boxed_inlines.len();
    std::mem::forget(boxed_inlines);

    let result = Box::new(OTMarkdownAstResult {
        blocks: block_ptr,
        block_count,
        inlines: inline_ptr,
        inline_count,
    });
    Box::into_raw(result)
}

#[no_mangle]
pub unsafe extern "C" fn ot_engine_free_markdown_ast(result: *mut OTMarkdownAstResult) {
    if result.is_null() {
        return;
    }
    let res = Box::from_raw(result);
    if !res.blocks.is_null() && res.block_count > 0 {
        let slice = std::slice::from_raw_parts_mut(res.blocks, res.block_count);
        for b in slice.iter_mut() {
            if !b.info.is_null() {
                let _ = CString::from_raw(b.info);
            }
        }
        let _ = Box::from_raw(slice as *mut [OTMarkdownBlockSpan]);
    }
    if !res.inlines.is_null() && res.inline_count > 0 {
        let slice = std::slice::from_raw_parts_mut(res.inlines, res.inline_count);
        for i in slice.iter_mut() {
            if !i.url.is_null() {
                let _ = CString::from_raw(i.url);
            }
            if !i.literal.is_null() {
                let _ = CString::from_raw(i.literal);
            }
        }
        let _ = Box::from_raw(slice as *mut [OTMarkdownInlineSpan]);
    }
}

