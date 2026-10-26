use std::sync::OnceLock;

use latex_rust::{
    layout, lookup, parse, tokenize, BoxContent, Dim, MathBox, MathFont, MathStyle, SymbolKind,
    Token,
};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u32)]
pub enum MathFontStyle {
    ItalicVariable = 0,
    RomanUpright = 1,
    BoldUpright = 2,
    Calligraphic = 3,
    BlackboardBold = 4,
    Monospace = 5,
    OperatorSymbol = 6,
    BigOperator = 7,
}

#[derive(Debug, Clone, PartialEq)]
pub enum MathDrawPrimitive {
    Text {
        x: f64,
        y: f64,
        text: String,
        font_style: MathFontStyle,
        font_size: f64,
    },
    Rule {
        x: f64,
        y: f64,
        width: f64,
        height: f64,
    },
    Radical {
        x: f64,
        top_y: f64,
        bottom_y: f64,
        hook_width: f64,
        radicand_width: f64,
        thickness: f64,
    },
    Delimiter {
        symbol: String,
        x: f64,
        top_y: f64,
        bottom_y: f64,
        width: f64,
        thickness: f64,
    },
}

#[derive(Debug, Clone, PartialEq)]
pub struct MathLayoutPlan {
    pub width: f64,
    pub ascent: f64,
    pub descent: f64,
    pub primitives: Vec<MathDrawPrimitive>,
}

impl MathLayoutPlan {
    pub fn total_height(&self) -> f64 {
        self.ascent + self.descent
    }
}

fn stix_font() -> &'static MathFont {
    static FONT: OnceLock<MathFont> = OnceLock::new();
    FONT.get_or_init(|| MathFont::stix_two_math().expect("embedded STIX Two Math font"))
}

fn dim_pt(dim: &Dim, em_pt: f64) -> f64 {
    f64::from(f32::from_bits(dim.to_ieee32_bits())) * em_pt
}

pub fn plain_text_summary(latex: &str) -> String {
    let Ok(tokens) = tokenize(latex) else {
        return latex.trim().to_string();
    };
    let mut out = String::with_capacity(tokens.len() * 2);
    for tok in tokens {
        match tok {
            Token::Char(c) => out.push(c),
            Token::Command(name) => {
                if let Some(entry) = lookup(&name) {
                    if matches!(entry.kind, SymbolKind::Symbol | SymbolKind::Operator) {
                        out.push_str(entry.glyph);
                        continue;
                    }
                }
                match name.as_str() {
                    "sqrt" => out.push('√'),
                    "frac" | "dfrac" | "tfrac" => out.push('/'),
                    "left" | "right" | "mathbf" | "mathrm" | "mathit" | "mathcal" | "mathbb"
                    | "text" => {}
                    _ => out.push_str(&name),
                }
            }
            Token::Superscript => out.push('^'),
            Token::Subscript => out.push('_'),
            Token::Space => out.push(' '),
            Token::BeginGroup | Token::EndGroup | Token::AlignmentTab | Token::MathShift
            | Token::DisplayShift => {}
        }
    }
    out
}

pub fn layout_latex(latex: &str, base_font_size: f64, is_display_style: bool) -> MathLayoutPlan {
    let effective_size = if is_display_style {
        base_font_size * 1.18
    } else {
        base_font_size * 1.02
    };
    let style = if is_display_style {
        MathStyle::Display
    } else {
        MathStyle::Text
    };
    if let Ok(ast) = parse(latex) {
        if let Ok(tree) = layout(&ast, stix_font(), style) {
            let mut primitives = Vec::new();
            emit_box(&tree, effective_size, 0.0, 0.0, &mut primitives);
            if !primitives.is_empty() {
                return MathLayoutPlan {
                    width: dim_pt(&tree.width, effective_size).max(effective_size * 0.4),
                    ascent: (dim_pt(&tree.height, effective_size) + 2.0).max(effective_size * 0.72),
                    descent: (dim_pt(&tree.depth, effective_size) + 2.0).max(effective_size * 0.22),
                    primitives,
                };
            }
        }
    }
    let text = plain_text_summary(latex);
    let width = (text.chars().count() as f64 * effective_size * 0.55).max(effective_size * 0.5);
    let ascent = effective_size * 0.82;
    let descent = effective_size * 0.24;
    MathLayoutPlan {
        width,
        ascent,
        descent,
        primitives: vec![MathDrawPrimitive::Text {
            x: 0.0,
            y: -ascent,
            text,
            font_style: MathFontStyle::RomanUpright,
            font_size: effective_size,
        }],
    }
}

fn emit_box(
    bx: &MathBox,
    em_pt: f64,
    origin_x: f64,
    baseline_y: f64,
    out: &mut Vec<MathDrawPrimitive>,
) {
    let base = baseline_y - dim_pt(&bx.shift, em_pt);
    match &bx.content {
        BoxContent::Empty | BoxContent::Kern(_) | BoxContent::Line { .. } => {}
        BoxContent::Glyph { ch, scale, .. } => {
            let scale_f = f64::from(f32::from_bits(scale.to_ieee32_bits())).max(0.5);
            let font_size = em_pt * scale_f;
            let font_style = if ch.is_ascii_alphabetic() {
                MathFontStyle::ItalicVariable
            } else if "∫∬∭∮∑∏∐⋃⋂⨁⨂".contains(*ch) {
                MathFontStyle::BigOperator
            } else {
                MathFontStyle::RomanUpright
            };
            out.push(MathDrawPrimitive::Text {
                x: origin_x,
                y: base - dim_pt(&bx.height, em_pt).max(font_size * 0.78),
                text: ch.to_string(),
                font_style,
                font_size,
            });
        }
        BoxContent::Rule => {
            let width = dim_pt(&bx.width, em_pt);
            let height = (dim_pt(&bx.height, em_pt) + dim_pt(&bx.depth, em_pt)).max(1.0);
            if width > 0.0 {
                out.push(MathDrawPrimitive::Rule {
                    x: origin_x,
                    y: base - dim_pt(&bx.height, em_pt),
                    width,
                    height,
                });
            }
        }
        BoxContent::HList(kids) => {
            let mut x = origin_x;
            for k in kids {
                emit_box(k, em_pt, x, base, out);
                x += dim_pt(&k.width, em_pt);
            }
        }
        BoxContent::VList(kids) => {
            if let Some((first, rest)) = kids.split_first() {
                emit_box(first, em_pt, origin_x, base, out);
                let mut y_below = dim_pt(&first.depth, em_pt);
                for k in rest {
                    let child_base = base + y_below + dim_pt(&k.height, em_pt);
                    emit_box(k, em_pt, origin_x, child_base, out);
                    y_below += dim_pt(&k.height, em_pt) + dim_pt(&k.depth, em_pt);
                }
            }
        }
        BoxContent::Overlap(kids) => {
            for k in kids {
                emit_box(k, em_pt, origin_x, base, out);
            }
        }
        BoxContent::Color(_, inner)
        | BoxContent::BackColor(_, inner)
        | BoxContent::Frame { inner, .. } => emit_box(inner, em_pt, origin_x, base, out),
    }
}
