use folio_engine::math::{layout_latex, plain_text_summary, MathDrawPrimitive, MathFontStyle};

/// A GPU-ready paint command for Zed's GPUI `WindowContext::paint_quad` and `TextSystem::shape_line`.
#[derive(Debug, Clone, PartialEq)]
pub enum GpuiMathPrimitive {
    ShapedGlyphRun {
        text: String,
        origin_x: f32,
        baseline_y: f32,
        font_size: f32,
        italic: bool,
        bold: bool,
        serif: bool,
    },
    RuleQuad {
        x: f32,
        y: f32,
        width: f32,
        height: f32,
    },
    RadicalStroke {
        x: f32,
        top_y: f32,
        bottom_y: f32,
        hook_width: f32,
        radicand_width: f32,
        line_width: f32,
    },
}

/// Complete GPUI canvas descriptor for an inline `$...$` or display `$$...$$` math block.
#[derive(Debug, Clone, PartialEq)]
pub struct GpuiMathCanvasDescriptor {
    pub latex: String,
    pub width: f32,
    pub ascent: f32,
    pub descent: f32,
    pub is_display_style: bool,
    pub plain_text_accessibility: String,
    pub primitives: Vec<GpuiMathPrimitive>,
}

impl GpuiMathCanvasDescriptor {
    pub fn total_height(&self) -> f32 {
        self.ascent + self.descent
    }
}

/// Builds a GPUI canvas layout descriptor for a LaTeX math expression using the shared Folio core engine.
pub fn build_gpui_math_canvas(
    latex: &str,
    base_font_size: f32,
    is_display_style: bool,
) -> GpuiMathCanvasDescriptor {
    let plan = layout_latex(latex, base_font_size as f64, is_display_style);
    let primitives = plan
        .primitives
        .into_iter()
        .map(|prim| match prim {
            MathDrawPrimitive::Text {
                x,
                y,
                text,
                font_style,
                font_size,
            } => GpuiMathPrimitive::ShapedGlyphRun {
                text,
                origin_x: x as f32,
                baseline_y: y as f32,
                font_size: font_size as f32,
                italic: matches!(font_style, MathFontStyle::ItalicVariable),
                bold: matches!(font_style, MathFontStyle::BoldUpright),
                serif: !matches!(font_style, MathFontStyle::Monospace),
            },
            MathDrawPrimitive::Rule {
                x,
                y,
                width,
                height,
            } => GpuiMathPrimitive::RuleQuad {
                x: x as f32,
                y: y as f32,
                width: width as f32,
                height: height as f32,
            },
            MathDrawPrimitive::Radical {
                x,
                top_y,
                bottom_y,
                hook_width,
                radicand_width,
                thickness,
            } => GpuiMathPrimitive::RadicalStroke {
                x: x as f32,
                top_y: top_y as f32,
                bottom_y: bottom_y as f32,
                hook_width: hook_width as f32,
                radicand_width: radicand_width as f32,
                line_width: thickness as f32,
            },
            MathDrawPrimitive::Delimiter {
                symbol,
                x,
                top_y,
                bottom_y,
                ..
            } => GpuiMathPrimitive::ShapedGlyphRun {
                text: symbol,
                origin_x: x as f32,
                baseline_y: top_y as f32,
                font_size: (bottom_y - top_y).abs().max(base_font_size as f64) as f32,
                italic: false,
                bold: false,
                serif: true,
            },
        })
        .collect();

    GpuiMathCanvasDescriptor {
        latex: latex.to_string(),
        width: plan.width as f32,
        ascent: plan.ascent as f32,
        descent: plan.descent as f32,
        is_display_style,
        plain_text_accessibility: plain_text_summary(latex),
        primitives,
    }
}
