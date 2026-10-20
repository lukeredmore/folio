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
pub enum MathNode {
    Row(Vec<MathNode>),
    Text(String, MathFontStyle),
    Space(f64),
    Fraction {
        numerator: Box<MathNode>,
        denominator: Box<MathNode>,
    },
    Sqrt {
        radicand: Box<MathNode>,
    },
    Scripts {
        base: Box<MathNode>,
        sub: Option<Box<MathNode>>,
        sup: Option<Box<MathNode>>,
    },
    Delimited {
        left: String,
        body: Box<MathNode>,
        right: String,
    },
    Accent {
        base: Box<MathNode>,
        mark: String,
    },
}

#[derive(Debug, Clone, PartialEq)]
pub enum MathDrawPrimitive {
    /// Draw a text/glyph run at `(x, y)` where `x` is relative to box left and `y` is top-left relative to baseline (`baseline_y + y`).
    Text {
        x: f64,
        y: f64,
        text: String,
        font_style: MathFontStyle,
        font_size: f64,
    },
    /// Fill a horizontal rule (e.g. fraction bar) at `(x, baseline_y + y)` with `(width, height)`.
    Rule {
        x: f64,
        y: f64,
        width: f64,
        height: f64,
    },
    /// Stroke a square-root radical with vinculum bar inside `(x, baseline_y + top_y)` to `baseline_y + bottom_y`.
    Radical {
        x: f64,
        top_y: f64,
        bottom_y: f64,
        hook_width: f64,
        radicand_width: f64,
        thickness: f64,
    },
    /// Stroke a tall delimiter `(`, `)`, `[`, `]`, `|`, etc.
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

    pub(crate) fn shifted(&self, dx: f64, dy: f64) -> Vec<MathDrawPrimitive> {
        self.primitives
            .iter()
            .map(|p| match p {
                MathDrawPrimitive::Text {
                    x,
                    y,
                    text,
                    font_style,
                    font_size,
                } => MathDrawPrimitive::Text {
                    x: x + dx,
                    y: y + dy,
                    text: text.clone(),
                    font_style: *font_style,
                    font_size: *font_size,
                },
                MathDrawPrimitive::Rule {
                    x,
                    y,
                    width,
                    height,
                } => MathDrawPrimitive::Rule {
                    x: x + dx,
                    y: y + dy,
                    width: *width,
                    height: *height,
                },
                MathDrawPrimitive::Radical {
                    x,
                    top_y,
                    bottom_y,
                    hook_width,
                    radicand_width,
                    thickness,
                } => MathDrawPrimitive::Radical {
                    x: x + dx,
                    top_y: top_y + dy,
                    bottom_y: bottom_y + dy,
                    hook_width: *hook_width,
                    radicand_width: *radicand_width,
                    thickness: *thickness,
                },
                MathDrawPrimitive::Delimiter {
                    symbol,
                    x,
                    top_y,
                    bottom_y,
                    width,
                    thickness,
                } => MathDrawPrimitive::Delimiter {
                    symbol: symbol.clone(),
                    x: x + dx,
                    top_y: top_y + dy,
                    bottom_y: bottom_y + dy,
                    width: *width,
                    thickness: *thickness,
                },
            })
            .collect()
    }
}

pub(crate) fn estimate_glyph_run_metrics(
    text: &str,
    style: MathFontStyle,
    font_size: f64,
) -> (f64, f64, f64) {
    let effective_font_size = if style == MathFontStyle::BigOperator {
        font_size * 1.45
    } else if style == MathFontStyle::Monospace {
        font_size * 0.90
    } else {
        font_size
    };

    let mut width = 0.0;
    for ch in text.chars() {
        let factor = if ch.is_ascii_uppercase() {
            0.68
        } else if ch.is_ascii_lowercase() || ch.is_ascii_digit() {
            0.54
        } else if "∫∬∭∮∑∏∐⋃⋂⨁⨂".contains(ch) {
            0.78
        } else if "∇∂∞ℏ∀∃≤≥≠≈≡±∓×÷⋅·→←↔⇒⇐⇔".contains(ch) {
            0.72
        } else if "()[]{}|.,:;!".contains(ch) {
            0.34
        } else {
            0.62
        };
        width += effective_font_size * factor;
    }

    let ascent = effective_font_size * 0.82;
    let descent = effective_font_size * 0.24;
    (width, ascent, descent)
}
