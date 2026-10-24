use crate::extension_types::{
    byte_offset_to_row, pack_rgba, BlockDecoration, CanvasElement, CanvasGlyphRun, CanvasQuad,
    CanvasTextReplacement, InlineFoldDecoration, Range,
};
use crate::inlay_folding::ZedBlockDecoration;
use crate::math_canvas::{GpuiMathCanvasDescriptor, GpuiMathPrimitive};

/// Converts a `GpuiMathCanvasDescriptor` into a Zed `v0.8.0` `CanvasElement`.
pub fn math_descriptor_to_canvas(
    desc: &GpuiMathCanvasDescriptor,
    fg: u32,
    card_style: Option<(u32, u32)>,
) -> CanvasElement {
    let pad = if card_style.is_some() { 10.0 } else { 2.0 };
    let width = (desc.width + pad * 2.0).max(24.0);
    let height = (desc.total_height() + pad * 2.0).max(20.0);
    let mut quads = Vec::new();
    let mut glyph_runs = Vec::new();
    if let Some((bg, border)) = card_style {
        quads.push(CanvasQuad {
            x: 0.0,
            y: 0.0,
            width,
            height,
            background_color: bg,
            border_color: border,
            border_width: 1.0,
            corner_radius: 6.0,
        });
    }
    for prim in &desc.primitives {
        match prim {
            GpuiMathPrimitive::ShapedGlyphRun {
                text,
                origin_x,
                baseline_y,
                font_size,
                italic,
                bold,
                serif,
            } => {
                glyph_runs.push(CanvasGlyphRun {
                    x: origin_x + pad,
                    y: (baseline_y + pad - font_size * 0.8).max(0.0),
                    text: text.clone(),
                    color: fg,
                    font_size: *font_size,
                    font_weight: bold.then_some(700),
                    italic: *italic,
                    monospace: !serif,
                });
            }
            GpuiMathPrimitive::RuleQuad {
                x,
                y,
                width: w,
                height: h,
            } => {
                quads.push(CanvasQuad {
                    x: x + pad,
                    y: y + pad,
                    width: *w,
                    height: (*h).max(1.2),
                    background_color: fg,
                    ..Default::default()
                });
            }
            GpuiMathPrimitive::RadicalStroke {
                x,
                top_y,
                bottom_y,
                hook_width,
                radicand_width,
                line_width,
            } => {
                quads.push(CanvasQuad {
                    x: x + pad,
                    y: top_y + pad,
                    width: hook_width + radicand_width,
                    height: (*line_width).max(1.2),
                    background_color: fg,
                    ..Default::default()
                });
                let _ = bottom_y;
            }
        }
    }
    CanvasElement {
        width,
        height,
        quads,
        glyph_runs,
        click_replacement: None,
    }
}

/// Appends interactive task-list checkbox inline folds (`- [ ]` <-> `- [x]`) on inactive rows.
pub fn append_task_checkbox_folds(
    text: &str,
    cursor_byte: usize,
    accent: u32,
    muted: u32,
    out: &mut Vec<InlineFoldDecoration>,
) {
    let active_row = byte_offset_to_row(text, cursor_byte);
    let mut line_start = 0usize;
    for (row, line) in text.split('\n').enumerate() {
        let trimmed = line.trim_start_matches([' ', '\t']);
        let indent = line.len() - trimmed.len();
        for prefix in ["- [ ]", "- [x]", "- [X]", "* [ ]", "* [x]", "* [X]"] {
            if trimmed.starts_with(prefix) && row as u32 != active_row {
                let box_start = line_start + indent + 2;
                let checked = !prefix.ends_with("[ ]");
                let replacement = if checked { "[ ]" } else { "[x]" }.to_string();
                let range = Range::from(box_start..box_start + 3);
                out.push(InlineFoldDecoration {
                    range,
                    placeholder_text: if checked { "☑".into() } else { "☐".into() },
                    render_canvas: Some(CanvasElement {
                        width: 16.0,
                        height: 16.0,
                        quads: vec![CanvasQuad {
                            x: 1.0,
                            y: 1.0,
                            width: 14.0,
                            height: 14.0,
                            background_color: if checked { accent } else { 0 },
                            border_color: if checked { accent } else { muted },
                            border_width: 1.5,
                            corner_radius: 3.5,
                        }],
                        glyph_runs: checked
                            .then(|| CanvasGlyphRun {
                                x: 3.5,
                                y: 2.0,
                                text: "✓".into(),
                                color: 0xFFFFFFFF,
                                font_size: 11.0,
                                font_weight: Some(700),
                                italic: false,
                                monospace: false,
                            })
                            .into_iter()
                            .collect(),
                        click_replacement: Some(CanvasTextReplacement {
                            range,
                            replacement_text: replacement,
                        }),
                    }),
                });
            }
        }
        line_start += line.len() + 1;
    }
}

/// Converts a `ZedBlockDecoration` into a Zed `v0.8.0` `BlockDecoration` canvas.
pub fn block_decoration_to_canvas(
    dec: &ZedBlockDecoration,
    muted: u32,
    card_bg: u32,
    fg: u32,
) -> Option<BlockDecoration> {
    match dec {
        ZedBlockDecoration::HeadingRule { line_range, .. }
        | ZedBlockDecoration::HorizontalRule { line_range } => Some(BlockDecoration {
            anchor_offset: line_range.start as u32,
            above: false,
            height_rows: 1,
            content: CanvasElement {
                width: 640.0,
                height: 2.0,
                quads: vec![CanvasQuad {
                    x: 0.0,
                    y: 0.0,
                    width: 640.0,
                    height: 1.5,
                    background_color: muted,
                    ..Default::default()
                }],
                glyph_runs: Vec::new(),
                click_replacement: None,
            },
        }),
        ZedBlockDecoration::CodeFenceHeader {
            language,
            accent_rgba,
            line_range,
        } if !language.is_empty() => {
            let badge = pack_rgba(accent_rgba.0, accent_rgba.1, accent_rgba.2, accent_rgba.3);
            Some(BlockDecoration {
                anchor_offset: line_range.start as u32,
                above: true,
                height_rows: 1,
                content: CanvasElement {
                    width: 120.0,
                    height: 20.0,
                    quads: vec![CanvasQuad {
                        x: 0.0,
                        y: 2.0,
                        width: (language.len() as f32 * 8.0 + 18.0).max(44.0),
                        height: 16.0,
                        background_color: card_bg,
                        border_color: badge,
                        border_width: 1.0,
                        corner_radius: 4.0,
                    }],
                    glyph_runs: vec![CanvasGlyphRun {
                        x: 8.0,
                        y: 3.0,
                        text: language.clone(),
                        color: fg,
                        font_size: 11.5,
                        font_weight: Some(600),
                        italic: false,
                        monospace: true,
                    }],
                    click_replacement: None,
                },
            })
        }
        _ => None,
    }
}
