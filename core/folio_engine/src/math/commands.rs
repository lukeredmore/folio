use super::ast::{MathFontStyle, MathNode};
use super::parser::{parse_braced_group, parse_sequence};
use super::symbols::{
    is_lowercase_greek, is_named_function, is_right_delimiter_command, lookup_big_operator,
    lookup_symbol, map_blackboard, map_calligraphic,
};

pub(crate) fn parse_escape_command(
    chars: &[char],
    index: &mut usize,
    depth: usize,
) -> Option<MathNode> {
    *index += 1;
    if *index >= chars.len() {
        return None;
    }

    let first = chars[*index];
    if !first.is_ascii_alphabetic() {
        *index += 1;
        return Some(match first {
            ',' => MathNode::Space(3.0),
            ';' | ':' => MathNode::Space(4.5),
            '!' => MathNode::Space(-1.5),
            ' ' => MathNode::Space(4.0),
            '{' | '}' | '%' | '$' | '&' | '#' => {
                MathNode::Text(first.to_string(), MathFontStyle::RomanUpright)
            }
            _ => MathNode::Text(first.to_string(), MathFontStyle::OperatorSymbol),
        });
    }

    let mut cmd = String::new();
    while *index < chars.len() && chars[*index].is_ascii_alphabetic() {
        cmd.push(chars[*index]);
        *index += 1;
    }

    Some(match cmd.as_str() {
        "frac" | "dfrac" | "tfrac" => {
            let num = parse_braced_group(chars, index, depth + 1);
            let den = parse_braced_group(chars, index, depth + 1);
            MathNode::Fraction {
                numerator: Box::new(num),
                denominator: Box::new(den),
            }
        }
        "sqrt" => {
            if *index < chars.len() && chars[*index] == '[' {
                while *index < chars.len() && chars[*index] != ']' {
                    *index += 1;
                }
                if *index < chars.len() {
                    *index += 1;
                }
            }
            MathNode::Sqrt {
                radicand: Box::new(parse_braced_group(chars, index, depth + 1)),
            }
        }
        "left" => {
            let left_delim = read_delimiter_token(chars, index);
            let body = parse_sequence(chars, index, true, false, depth + 1);
            let mut right_delim = ")".to_string();
            if *index < chars.len()
                && chars[*index] == '\\'
                && is_right_delimiter_command(chars, *index)
            {
                *index += 6;
                right_delim = read_delimiter_token(chars, index);
            }
            MathNode::Delimited {
                left: left_delim,
                body: Box::new(body),
                right: right_delim,
            }
        }
        "text" | "textrm" | "mathrm" | "operatorname" => {
            MathNode::Text(extract_raw_braced_string(chars, index), MathFontStyle::RomanUpright)
        }
        "mathbf" | "textbf" | "boldsymbol" | "bm" => {
            let raw = extract_raw_braced_string(chars, index);
            MathNode::Text(resolve_simple_symbols(&raw), MathFontStyle::BoldUpright)
        }
        "mathcal" | "mathscr" => {
            let mapped = extract_raw_braced_string(chars, index)
                .chars()
                .map(map_calligraphic)
                .collect();
            MathNode::Text(mapped, MathFontStyle::Calligraphic)
        }
        "mathbb" => {
            let mapped = extract_raw_braced_string(chars, index)
                .chars()
                .map(map_blackboard)
                .collect();
            MathNode::Text(mapped, MathFontStyle::BlackboardBold)
        }
        "mathtt" | "texttt" => {
            MathNode::Text(extract_raw_braced_string(chars, index), MathFontStyle::Monospace)
        }
        "mathit" | "textit" => {
            MathNode::Text(extract_raw_braced_string(chars, index), MathFontStyle::ItalicVariable)
        }
        "hat" | "widehat" | "bar" | "overline" | "vec" | "overrightarrow" | "tilde"
        | "widetilde" | "dot" | "ddot" => parse_accent_command(&cmd, chars, index, depth),
        "quad" => MathNode::Space(12.0),
        "qquad" => MathNode::Space(22.0),
        _ => resolve_command_symbol(cmd),
    })
}

fn parse_accent_command(cmd: &str, chars: &[char], index: &mut usize, depth: usize) -> MathNode {
    let mark = match cmd {
        "hat" | "widehat" => "\u{0302}",
        "bar" | "overline" => "\u{0304}",
        "vec" | "overrightarrow" => "\u{20D7}",
        "tilde" | "widetilde" => "\u{0303}",
        "dot" => "\u{0307}",
        _ => "\u{0308}",
    };
    MathNode::Accent {
        base: Box::new(parse_braced_group(chars, index, depth + 1)),
        mark: mark.to_string(),
    }
}

fn resolve_command_symbol(cmd: String) -> MathNode {
    if let Some(big_op) = lookup_big_operator(&cmd) {
        MathNode::Text(big_op.to_string(), MathFontStyle::BigOperator)
    } else if is_named_function(&cmd) {
        MathNode::Text(cmd, MathFontStyle::RomanUpright)
    } else if let Some(sym) = lookup_symbol(&cmd) {
        let style = if is_lowercase_greek(&cmd) {
            MathFontStyle::ItalicVariable
        } else {
            MathFontStyle::OperatorSymbol
        };
        MathNode::Text(sym.to_string(), style)
    } else {
        MathNode::Text(cmd, MathFontStyle::RomanUpright)
    }
}

fn extract_raw_braced_string(chars: &[char], index: &mut usize) -> String {
    while *index < chars.len() && chars[*index].is_whitespace() {
        *index += 1;
    }
    if *index >= chars.len() {
        return String::new();
    }
    if chars[*index] == '{' {
        *index += 1;
        let mut depth = 1usize;
        let mut out = String::new();
        while *index < chars.len() && depth > 0 {
            let c = chars[*index];
            *index += 1;
            if c == '{' {
                depth += 1;
                if depth > 1 {
                    out.push(c);
                }
            } else if c == '}' {
                depth -= 1;
                if depth > 0 {
                    out.push(c);
                }
            } else {
                out.push(c);
            }
        }
        out
    } else {
        let c = chars[*index];
        *index += 1;
        c.to_string()
    }
}

fn resolve_simple_symbols(raw: &str) -> String {
    let chars: Vec<char> = raw.chars().collect();
    let mut out = String::new();
    let mut i = 0;
    while i < chars.len() {
        if chars[i] == '\\' && i + 1 < chars.len() && chars[i + 1].is_ascii_alphabetic() {
            i += 1;
            let mut cmd = String::new();
            while i < chars.len() && chars[i].is_ascii_alphabetic() {
                cmd.push(chars[i]);
                i += 1;
            }
            if let Some(sym) = lookup_symbol(&cmd) {
                out.push_str(sym);
            } else {
                out.push_str(&cmd);
            }
        } else {
            out.push(chars[i]);
            i += 1;
        }
    }
    out
}

fn read_delimiter_token(chars: &[char], index: &mut usize) -> String {
    while *index < chars.len() && chars[*index].is_whitespace() {
        *index += 1;
    }
    if *index >= chars.len() {
        return String::new();
    }
    if chars[*index] == '\\' {
        *index += 1;
        if *index >= chars.len() {
            return String::new();
        }
        if !chars[*index].is_ascii_alphabetic() {
            let c = chars[*index];
            *index += 1;
            return c.to_string();
        }
        let mut cmd = String::new();
        while *index < chars.len() && chars[*index].is_ascii_alphabetic() {
            cmd.push(chars[*index]);
            *index += 1;
        }
        lookup_symbol(&cmd).unwrap_or(&cmd).to_string()
    } else {
        let c = chars[*index];
        *index += 1;
        if c == '.' {
            String::new()
        } else {
            c.to_string()
        }
    }
}
