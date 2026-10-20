use super::ast::{MathFontStyle, MathNode};
use super::commands::parse_escape_command;
use super::symbols::is_right_delimiter_command;
use super::MAX_PARSE_DEPTH;

pub(crate) fn parse_sequence(
    chars: &[char],
    index: &mut usize,
    stop_on_right_command: bool,
    stop_on_close_brace: bool,
    depth: usize,
) -> MathNode {
    if depth > MAX_PARSE_DEPTH {
        if *index < chars.len() {
            *index += 1;
        }
        return MathNode::Text(String::new(), MathFontStyle::RomanUpright);
    }

    let mut nodes = Vec::new();

    while *index < chars.len() {
        let ch = chars[*index];

        if ch == '}' {
            if stop_on_close_brace {
                break;
            }
            *index += 1;
            nodes.push(MathNode::Text("}".to_string(), MathFontStyle::RomanUpright));
            continue;
        }

        if ch.is_whitespace() {
            *index += 1;
            continue;
        }

        if stop_on_right_command && ch == '\\' && is_right_delimiter_command(chars, *index) {
            break;
        }

        let Some(atom) = parse_atom(chars, index, depth + 1) else {
            continue;
        };

        let (sub_node, sup_node) = parse_attached_scripts(chars, index, depth + 1);
        if sub_node.is_some() || sup_node.is_some() {
            nodes.push(MathNode::Scripts {
                base: Box::new(atom),
                sub: sub_node,
                sup: sup_node,
            });
        } else {
            nodes.push(atom);
        }
    }

    if nodes.len() == 1 {
        nodes.remove(0)
    } else {
        MathNode::Row(nodes)
    }
}

fn parse_attached_scripts(
    chars: &[char],
    index: &mut usize,
    depth: usize,
) -> (Option<Box<MathNode>>, Option<Box<MathNode>>) {
    let mut sub_node: Option<Box<MathNode>> = None;
    let mut sup_node: Option<Box<MathNode>> = None;

    while *index < chars.len() {
        while *index < chars.len() && chars[*index].is_whitespace() {
            *index += 1;
        }
        if *index >= chars.len() {
            break;
        }
        if chars[*index] == '_' {
            *index += 1;
            sub_node = Some(Box::new(parse_script_argument(chars, index, depth)));
        } else if chars[*index] == '^' {
            *index += 1;
            sup_node = Some(Box::new(parse_script_argument(chars, index, depth)));
        } else if chars[*index] == '\'' {
            *index += 1;
            let prime_node = MathNode::Text("′".to_string(), MathFontStyle::OperatorSymbol);
            if let Some(existing_sup) = sup_node.take() {
                sup_node = Some(Box::new(MathNode::Row(vec![*existing_sup, prime_node])));
            } else {
                sup_node = Some(Box::new(prime_node));
            }
        } else {
            break;
        }
    }
    (sub_node, sup_node)
}

fn parse_script_argument(chars: &[char], index: &mut usize, depth: usize) -> MathNode {
    if depth > MAX_PARSE_DEPTH {
        if *index < chars.len() {
            *index += 1;
        }
        return MathNode::Text(String::new(), MathFontStyle::ItalicVariable);
    }
    while *index < chars.len() && chars[*index].is_whitespace() {
        *index += 1;
    }
    if *index >= chars.len() {
        return MathNode::Text(String::new(), MathFontStyle::ItalicVariable);
    }
    if chars[*index] == '{' {
        return parse_braced_group(chars, index, depth + 1);
    }
    parse_atom(chars, index, depth + 1)
        .unwrap_or(MathNode::Text(String::new(), MathFontStyle::ItalicVariable))
}

pub(crate) fn parse_braced_group(chars: &[char], index: &mut usize, depth: usize) -> MathNode {
    if depth > MAX_PARSE_DEPTH {
        if *index < chars.len() {
            *index += 1;
        }
        return MathNode::Text(String::new(), MathFontStyle::ItalicVariable);
    }
    while *index < chars.len() && chars[*index].is_whitespace() {
        *index += 1;
    }
    if *index >= chars.len() {
        return MathNode::Text(String::new(), MathFontStyle::ItalicVariable);
    }
    if chars[*index] == '{' {
        *index += 1;
        let inside = parse_sequence(chars, index, false, true, depth + 1);
        if *index < chars.len() && chars[*index] == '}' {
            *index += 1;
        }
        inside
    } else {
        parse_atom(chars, index, depth + 1)
            .unwrap_or(MathNode::Text(String::new(), MathFontStyle::ItalicVariable))
    }
}

fn parse_atom(chars: &[char], index: &mut usize, depth: usize) -> Option<MathNode> {
    if depth > MAX_PARSE_DEPTH {
        if *index < chars.len() {
            *index += 1;
        }
        return None;
    }
    while *index < chars.len() && chars[*index].is_whitespace() {
        *index += 1;
    }
    if *index >= chars.len() {
        return None;
    }

    let ch = chars[*index];
    if ch == '{' {
        return Some(parse_braced_group(chars, index, depth + 1));
    }

    if ch == '\\' {
        return parse_escape_command(chars, index, depth);
    }

    if ch.is_ascii_digit() {
        let mut num_str = String::new();
        while *index < chars.len() && (chars[*index].is_ascii_digit() || chars[*index] == '.') {
            num_str.push(chars[*index]);
            *index += 1;
        }
        return Some(MathNode::Text(num_str, MathFontStyle::RomanUpright));
    }

    if "+-=<>".contains(ch) {
        *index += 1;
        let op_symbol = if ch == '-' {
            "−".to_string()
        } else {
            ch.to_string()
        };
        return Some(MathNode::Row(vec![
            MathNode::Space(2.5),
            MathNode::Text(op_symbol, MathFontStyle::OperatorSymbol),
            MathNode::Space(2.5),
        ]));
    }

    if "*/(),:;[]|!".contains(ch) {
        *index += 1;
        if ch == '*' {
            return Some(MathNode::Text("∗".to_string(), MathFontStyle::OperatorSymbol));
        }
        return Some(MathNode::Text(ch.to_string(), MathFontStyle::RomanUpright));
    }

    *index += 1;
    Some(MathNode::Text(ch.to_string(), MathFontStyle::ItalicVariable))
}
