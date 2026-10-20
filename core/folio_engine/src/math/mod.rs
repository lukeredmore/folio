pub mod ast;
pub(crate) mod commands;
pub mod layout;
pub mod parser;
pub mod symbols;

pub use ast::{MathDrawPrimitive, MathFontStyle, MathLayoutPlan, MathNode};

use layout::layout_node_internal;
use parser::parse_sequence;

pub(crate) const MAX_PARSE_DEPTH: usize = 64;

pub fn parse_latex(latex: &str) -> MathNode {
    let chars: Vec<char> = latex.trim().chars().collect();
    let mut index = 0;
    parse_sequence(&chars, &mut index, false, false, 0)
}

pub fn plain_text_summary(latex: &str) -> String {
    let node = parse_latex(latex);
    flatten_to_text(&node)
}

pub fn layout_latex(latex: &str, base_font_size: f64, is_display_style: bool) -> MathLayoutPlan {
    let node = parse_latex(latex);
    layout_math_node(&node, base_font_size, is_display_style)
}

pub fn layout_math_node(
    node: &MathNode,
    base_font_size: f64,
    is_display_style: bool,
) -> MathLayoutPlan {
    let effective_size = if is_display_style {
        base_font_size * 1.18
    } else {
        base_font_size * 1.02
    };
    layout_node_internal(node, effective_size, is_display_style)
}

fn flatten_to_text(node: &MathNode) -> String {
    match node {
        MathNode::Row(children) => children.iter().map(flatten_to_text).collect(),
        MathNode::Text(s, _) => s.clone(),
        MathNode::Space(_) => " ".to_string(),
        MathNode::Fraction {
            numerator,
            denominator,
        } => format!(
            "({})/({})",
            flatten_to_text(numerator),
            flatten_to_text(denominator)
        ),
        MathNode::Sqrt { radicand } => format!("√({})", flatten_to_text(radicand)),
        MathNode::Scripts { base, sub, sup } => {
            let mut res = flatten_to_text(base);
            if let Some(sub) = sub {
                res.push('_');
                res.push_str(&flatten_to_text(sub));
            }
            if let Some(sup) = sup {
                res.push('^');
                res.push_str(&flatten_to_text(sup));
            }
            res
        }
        MathNode::Delimited { left, body, right } => {
            format!("{}{}{}", left, flatten_to_text(body), right)
        }
        MathNode::Accent { base, mark } => format!("{}{}", flatten_to_text(base), mark),
    }
}
