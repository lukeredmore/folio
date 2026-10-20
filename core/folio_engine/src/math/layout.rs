use super::ast::{
    estimate_glyph_run_metrics, MathDrawPrimitive, MathFontStyle, MathLayoutPlan, MathNode,
};

pub(crate) fn layout_node_internal(
    node: &MathNode,
    font_size: f64,
    is_display: bool,
) -> MathLayoutPlan {
    let axis_height = font_size * 0.30;

    match node {
        MathNode::Space(pts) => {
            let scaled = (pts * (font_size / 16.0)).max(0.0);
            MathLayoutPlan {
                width: scaled,
                ascent: 0.0,
                descent: 0.0,
                primitives: Vec::new(),
            }
        }
        MathNode::Text(str_val, style) => layout_text_node(str_val, *style, font_size, axis_height),
        MathNode::Row(children) => layout_row_node(children, font_size, is_display),
        MathNode::Fraction {
            numerator,
            denominator,
        } => layout_fraction_node(numerator, denominator, font_size, is_display, axis_height),
        MathNode::Sqrt { radicand } => layout_sqrt_node(radicand, font_size, is_display),
        MathNode::Scripts { base, sub, sup } => {
            layout_scripts_node(base, sub.as_deref(), sup.as_deref(), font_size, is_display)
        }
        MathNode::Delimited { left, body, right } => {
            layout_delimited_node(left, body, right, font_size, is_display, axis_height)
        }
        MathNode::Accent { base, mark } => layout_accent_node(base, mark, font_size, is_display),
    }
}

fn layout_text_node(
    str_val: &str,
    style: MathFontStyle,
    font_size: f64,
    axis_height: f64,
) -> MathLayoutPlan {
    if str_val.is_empty() {
        return MathLayoutPlan {
            width: 0.0,
            ascent: 0.0,
            descent: 0.0,
            primitives: Vec::new(),
        };
    }
    let (raw_w, asc, desc) = estimate_glyph_run_metrics(str_val, style, font_size);
    if style == MathFontStyle::BigOperator {
        let total_h = asc + desc;
        let half_h = total_h * 0.5;
        let box_asc = axis_height + half_h * 0.85;
        let box_desc = (total_h - box_asc).max(4.0);
        return MathLayoutPlan {
            width: raw_w + 2.0,
            ascent: box_asc,
            descent: box_desc,
            primitives: vec![MathDrawPrimitive::Text {
                x: 0.0,
                y: -box_asc,
                text: str_val.to_string(),
                font_style: style,
                font_size,
            }],
        };
    }

    let extra_italic_pad = if matches!(
        style,
        MathFontStyle::ItalicVariable | MathFontStyle::Calligraphic
    ) {
        1.2
    } else {
        0.0
    };

    MathLayoutPlan {
        width: raw_w + extra_italic_pad,
        ascent: asc,
        descent: desc,
        primitives: vec![MathDrawPrimitive::Text {
            x: 0.0,
            y: -asc,
            text: str_val.to_string(),
            font_style: style,
            font_size,
        }],
    }
}

fn layout_row_node(children: &[MathNode], font_size: f64, is_display: bool) -> MathLayoutPlan {
    let mut total_width = 0.0;
    let mut max_asc = font_size * 0.75;
    let mut max_desc = font_size * 0.25;
    let mut primitives = Vec::new();

    if !children.is_empty() {
        max_asc = 0.0_f64;
        max_desc = 0.0_f64;
    }

    for child in children {
        let box_plan = layout_node_internal(child, font_size, is_display);
        max_asc = max_asc.max(box_plan.ascent);
        max_desc = max_desc.max(box_plan.descent);
        primitives.extend(box_plan.shifted(total_width, 0.0));
        total_width += box_plan.width;
    }

    MathLayoutPlan {
        width: total_width,
        ascent: max_asc,
        descent: max_desc,
        primitives,
    }
}

fn layout_fraction_node(
    numerator: &MathNode,
    denominator: &MathNode,
    font_size: f64,
    is_display: bool,
    axis_height: f64,
) -> MathLayoutPlan {
    let child_font_size = (font_size * if is_display { 0.82 } else { 0.74 }).max(10.0);
    let num_box = layout_node_internal(numerator, child_font_size, false);
    let den_box = layout_node_internal(denominator, child_font_size, false);

    let h_pad = if is_display { 5.0 } else { 3.5 };
    let bar_width = num_box.width.max(den_box.width) + h_pad * 2.0;
    let gap = if is_display { 2.5 } else { 1.5 };
    let bar_thickness = (font_size * 0.06).max(1.0);

    let total_ascent = axis_height + gap + num_box.total_height();
    let total_descent = ((den_box.total_height() + gap) - axis_height).max(2.0);

    let inner_x = 1.5;
    let axis_y = -axis_height;

    let mut primitives = Vec::new();
    primitives.push(MathDrawPrimitive::Rule {
        x: inner_x,
        y: axis_y - bar_thickness * 0.5,
        width: bar_width,
        height: bar_thickness,
    });

    let num_x = inner_x + (bar_width - num_box.width) * 0.5;
    let num_baseline_y = axis_y - gap - num_box.descent;
    primitives.extend(num_box.shifted(num_x, num_baseline_y));

    let den_x = inner_x + (bar_width - den_box.width) * 0.5;
    let den_baseline_y = axis_y + gap + den_box.ascent;
    primitives.extend(den_box.shifted(den_x, den_baseline_y));

    MathLayoutPlan {
        width: bar_width + 3.0,
        ascent: total_ascent,
        descent: total_descent,
        primitives,
    }
}

fn layout_sqrt_node(radicand: &MathNode, font_size: f64, is_display: bool) -> MathLayoutPlan {
    let rad_box = layout_node_internal(radicand, font_size * 0.95, is_display);
    let hook_width = font_size * 0.55;
    let top_gap = 2.5;
    let bar_thickness = (font_size * 0.058).max(1.0);
    let asc = rad_box.ascent + top_gap + bar_thickness + 1.0;
    let desc = rad_box.descent + 1.0;
    let total_width = hook_width + rad_box.width + 3.0;

    let top_y = -rad_box.ascent - top_gap;
    let bottom_y = rad_box.descent;

    let mut primitives = vec![MathDrawPrimitive::Radical {
        x: 0.0,
        top_y,
        bottom_y,
        hook_width,
        radicand_width: rad_box.width,
        thickness: bar_thickness,
    }];
    primitives.extend(rad_box.shifted(hook_width + 1.0, 0.0));

    MathLayoutPlan {
        width: total_width,
        ascent: asc,
        descent: desc,
        primitives,
    }
}

fn layout_scripts_node(
    base: &MathNode,
    sub: Option<&MathNode>,
    sup: Option<&MathNode>,
    font_size: f64,
    is_display: bool,
) -> MathLayoutPlan {
    let base_box = layout_node_internal(base, font_size, is_display);
    let script_font_size = (font_size * 0.68).max(9.0);
    let sub_box = sub.map(|n| layout_node_internal(n, script_font_size, false));
    let sup_box = sup.map(|n| layout_node_internal(n, script_font_size, false));

    let is_big_op = matches!(base, MathNode::Text(_, MathFontStyle::BigOperator));

    let sup_shift_up = if is_big_op {
        (font_size * 0.55).max(base_box.ascent - sup_box.as_ref().map_or(0.0, |b| b.descent) * 0.4)
    } else {
        (font_size * 0.36).max(base_box.ascent * 0.55)
    };

    let sub_shift_down = if is_big_op {
        (font_size * 0.48).max(base_box.descent + sub_box.as_ref().map_or(0.0, |b| b.ascent) * 0.55)
    } else {
        (font_size * 0.22).max(base_box.descent * 0.65 + font_size * 0.16)
    };

    let script_width = sub_box
        .as_ref()
        .map_or(0.0, |b| b.width)
        .max(sup_box.as_ref().map_or(0.0, |b| b.width));
    let new_asc = base_box
        .ascent
        .max(sup_box.as_ref().map_or(0.0, |b| sup_shift_up + b.ascent));
    let new_desc = base_box
        .descent
        .max(sub_box.as_ref().map_or(0.0, |b| sub_shift_down + b.descent));

    let mut primitives = base_box.primitives;
    let script_x = base_box.width + if is_big_op { 0.5 } else { 0.0 };

    if let Some(sup_b) = sup_box {
        primitives.extend(sup_b.shifted(script_x, -sup_shift_up));
    }
    if let Some(sub_b) = sub_box {
        let sub_offset = if is_big_op { -1.5 } else { 0.0 };
        primitives.extend(sub_b.shifted(script_x + sub_offset, sub_shift_down));
    }

    MathLayoutPlan {
        width: base_box.width + script_width + 1.5,
        ascent: new_asc,
        descent: new_desc,
        primitives,
    }
}

fn layout_delimited_node(
    left: &str,
    body: &MathNode,
    right: &str,
    font_size: f64,
    is_display: bool,
    axis_height: f64,
) -> MathLayoutPlan {
    let body_box = layout_node_internal(body, font_size, is_display);
    let half_span = (body_box.ascent - axis_height).max(body_box.descent + axis_height) + 2.0;
    let delim_asc = axis_height + half_span;
    let delim_desc = (half_span - axis_height).max(2.0);
    let delim_w = if left.is_empty() {
        0.0
    } else {
        (font_size * 0.38).max(6.0)
    };
    let right_delim_w = if right.is_empty() {
        0.0
    } else {
        (font_size * 0.38).max(6.0)
    };

    let top_y = -delim_asc + 1.5;
    let bot_y = delim_desc - 1.5;

    let mut primitives = Vec::new();
    if !left.is_empty() {
        primitives.push(MathDrawPrimitive::Delimiter {
            symbol: left.to_string(),
            x: 1.0,
            top_y,
            bottom_y: bot_y,
            width: delim_w - 1.5,
            thickness: 1.35,
        });
    }
    primitives.extend(body_box.shifted(delim_w + 1.0, 0.0));
    if !right.is_empty() {
        primitives.push(MathDrawPrimitive::Delimiter {
            symbol: right.to_string(),
            x: delim_w + body_box.width + 1.5,
            top_y,
            bottom_y: bot_y,
            width: right_delim_w - 1.5,
            thickness: 1.35,
        });
    }

    MathLayoutPlan {
        width: delim_w + body_box.width + right_delim_w + 2.0,
        ascent: delim_asc,
        descent: delim_desc,
        primitives,
    }
}

fn layout_accent_node(
    base: &MathNode,
    mark: &str,
    font_size: f64,
    is_display: bool,
) -> MathLayoutPlan {
    let base_box = layout_node_internal(base, font_size, is_display);
    let mut primitives = base_box.primitives;
    primitives.push(MathDrawPrimitive::Text {
        x: base_box.width * 0.35,
        y: -base_box.ascent - font_size * 0.55,
        text: mark.to_string(),
        font_style: MathFontStyle::OperatorSymbol,
        font_size,
    });

    MathLayoutPlan {
        width: base_box.width,
        ascent: base_box.ascent + font_size * 0.22,
        descent: base_box.descent,
        primitives,
    }
}
