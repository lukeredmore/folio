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

    fn shifted(&self, dx: f64, dy: f64) -> Vec<MathDrawPrimitive> {
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

const MAX_PARSE_DEPTH: usize = 64;

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
        } => format!("({})/({})", flatten_to_text(numerator), flatten_to_text(denominator)),
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

fn lookup_symbol(cmd: &str) -> Option<&'static str> {
    match cmd {
        // Lowercase Greek
        "alpha" => Some("α"),
        "beta" => Some("β"),
        "gamma" => Some("γ"),
        "delta" => Some("δ"),
        "epsilon" => Some("ϵ"),
        "varepsilon" => Some("ε"),
        "zeta" => Some("ζ"),
        "eta" => Some("η"),
        "theta" => Some("θ"),
        "vartheta" => Some("ϑ"),
        "iota" => Some("ι"),
        "kappa" => Some("κ"),
        "lambda" => Some("λ"),
        "mu" => Some("μ"),
        "nu" => Some("ν"),
        "xi" => Some("ξ"),
        "pi" => Some("π"),
        "varpi" => Some("ϖ"),
        "rho" => Some("ρ"),
        "varrho" => Some("ϱ"),
        "sigma" => Some("σ"),
        "varsigma" => Some("ς"),
        "tau" => Some("τ"),
        "upsilon" => Some("υ"),
        "phi" => Some("ϕ"),
        "varphi" => Some("φ"),
        "chi" => Some("χ"),
        "psi" => Some("ψ"),
        "omega" => Some("ω"),
        // Uppercase Greek
        "Gamma" => Some("Γ"),
        "Delta" => Some("Δ"),
        "Theta" => Some("Θ"),
        "Lambda" => Some("Λ"),
        "Xi" => Some("Ξ"),
        "Pi" => Some("Π"),
        "Sigma" => Some("Σ"),
        "Upsilon" => Some("Υ"),
        "Phi" => Some("Φ"),
        "Psi" => Some("Ψ"),
        "Omega" => Some("Ω"),
        // Calculus & Physics
        "nabla" => Some("∇"),
        "partial" => Some("∂"),
        "infty" => Some("∞"),
        "hbar" => Some("ℏ"),
        "ell" => Some("ℓ"),
        "wp" => Some("℘"),
        "Re" => Some("ℜ"),
        "Im" => Some("ℑ"),
        "aleph" => Some("ℵ"),
        "forall" => Some("∀"),
        "exists" => Some("∃"),
        "nexists" => Some("∄"),
        "emptyset" | "varnothing" => Some("∅"),
        "prime" => Some("′"),
        "dagger" => Some("†"),
        "ddagger" => Some("‡"),
        "angle" => Some("∠"),
        "triangle" => Some("△"),
        // Binary operators
        "cdot" => Some("·"),
        "times" => Some("×"),
        "div" => Some("÷"),
        "pm" => Some("±"),
        "mp" => Some("∓"),
        "oplus" => Some("⊕"),
        "ominus" => Some("⊖"),
        "otimes" => Some("⊗"),
        "odot" => Some("⊙"),
        "circ" => Some("∘"),
        "bullet" => Some("•"),
        "star" => Some("⋆"),
        "ast" => Some("∗"),
        "cup" => Some("∪"),
        "cap" => Some("∩"),
        "setminus" => Some("∖"),
        "wedge" => Some("∧"),
        "vee" => Some("∨"),
        // Relations
        "leq" | "le" => Some("≤"),
        "geq" | "ge" => Some("≥"),
        "neq" | "ne" => Some("≠"),
        "approx" => Some("≈"),
        "equiv" => Some("≡"),
        "sim" => Some("∼"),
        "simeq" => Some("≃"),
        "cong" => Some("≅"),
        "propto" => Some("∝"),
        "ll" => Some("≪"),
        "gg" => Some("≫"),
        "subset" => Some("⊂"),
        "supset" => Some("⊃"),
        "subseteq" => Some("⊆"),
        "supseteq" => Some("⊇"),
        "in" => Some("∈"),
        "notin" => Some("∉"),
        "ni" => Some("∋"),
        "perp" => Some("⊥"),
        "parallel" => Some("∥"),
        "mid" => Some("∣"),
        // Arrows
        "to" | "rightarrow" => Some("→"),
        "leftarrow" => Some("←"),
        "leftrightarrow" => Some("↔"),
        "Rightarrow" => Some("⇒"),
        "Leftarrow" => Some("⇐"),
        "Leftrightarrow" | "iff" => Some("⇔"),
        "mapsto" => Some("↦"),
        "uparrow" => Some("↑"),
        "downarrow" => Some("↓"),
        "nearrow" => Some("↗"),
        "searrow" => Some("↘"),
        // Dots
        "dots" | "ldots" => Some("…"),
        "cdots" => Some("⋯"),
        "vdots" => Some("⋮"),
        "ddots" => Some("⋱"),
        // Brackets
        "langle" => Some("⟨"),
        "rangle" => Some("⟩"),
        "lfloor" => Some("⌊"),
        "rfloor" => Some("⌋"),
        "lceil" => Some("⌈"),
        "rceil" => Some("⌉"),
        "{" => Some("{"),
        "}" => Some("}"),
        _ => None,
    }
}

fn lookup_big_operator(cmd: &str) -> Option<&'static str> {
    match cmd {
        "int" => Some("∫"),
        "iint" => Some("∬"),
        "iiint" => Some("∭"),
        "oint" => Some("∮"),
        "sum" => Some("∑"),
        "prod" => Some("∏"),
        "coprod" => Some("∐"),
        "bigcup" => Some("⋃"),
        "bigcap" => Some("⋂"),
        "bigoplus" => Some("⨁"),
        "bigotimes" => Some("⨂"),
        _ => None,
    }
}

fn is_named_function(cmd: &str) -> bool {
    matches!(
        cmd,
        "sin"
            | "cos"
            | "tan"
            | "cot"
            | "sec"
            | "csc"
            | "arcsin"
            | "arccos"
            | "arctan"
            | "sinh"
            | "cosh"
            | "tanh"
            | "log"
            | "ln"
            | "lg"
            | "exp"
            | "lim"
            | "limsup"
            | "liminf"
            | "sup"
            | "inf"
            | "min"
            | "max"
            | "arg"
            | "det"
            | "dim"
            | "ker"
            | "hom"
            | "deg"
            | "gcd"
            | "Pr"
    )
}

fn is_lowercase_greek(cmd: &str) -> bool {
    matches!(
        cmd,
        "alpha"
            | "beta"
            | "gamma"
            | "delta"
            | "epsilon"
            | "varepsilon"
            | "zeta"
            | "eta"
            | "theta"
            | "vartheta"
            | "iota"
            | "kappa"
            | "lambda"
            | "mu"
            | "nu"
            | "xi"
            | "pi"
            | "varpi"
            | "rho"
            | "varrho"
            | "sigma"
            | "varsigma"
            | "tau"
            | "upsilon"
            | "phi"
            | "varphi"
            | "chi"
            | "psi"
            | "omega"
    )
}

fn map_calligraphic(ch: char) -> char {
    match ch {
        'A' => '𝒜',
        'B' => 'ℬ',
        'C' => '𝒞',
        'D' => '𝒟',
        'E' => 'ℰ',
        'F' => 'ℱ',
        'G' => '𝒢',
        'H' => 'ℋ',
        'I' => 'ℐ',
        'J' => '𝒥',
        'K' => '𝒦',
        'L' => 'ℒ',
        'M' => 'ℳ',
        'N' => '𝒩',
        'O' => '𝒪',
        'P' => '𝒫',
        'Q' => '𝒬',
        'R' => 'ℛ',
        'S' => '𝒮',
        'T' => '𝒯',
        'U' => '𝒰',
        'V' => '𝒱',
        'W' => '𝒲',
        'X' => '𝒳',
        'Y' => '𝒴',
        'Z' => '𝒵',
        _ => ch,
    }
}

fn map_blackboard(ch: char) -> char {
    match ch {
        'A' => '𝔸',
        'B' => '𝔹',
        'C' => 'ℂ',
        'D' => '𝔻',
        'E' => '𝔼',
        'F' => '𝔽',
        'G' => '𝔾',
        'H' => 'ℍ',
        'I' => '𝕀',
        'J' => '𝕁',
        'K' => '𝕂',
        'L' => '𝕃',
        'M' => '𝕄',
        'N' => 'ℕ',
        'O' => '𝕆',
        'P' => 'ℙ',
        'Q' => 'ℚ',
        'R' => 'ℝ',
        'S' => '𝕊',
        'T' => '𝕋',
        'U' => '𝕌',
        'V' => '𝕍',
        'W' => '𝕎',
        'X' => '𝕏',
        'Y' => '𝕐',
        'Z' => 'ℤ',
        _ => ch,
    }
}

fn is_right_delimiter_command(chars: &[char], index: usize) -> bool {
    const PREFIX: [char; 6] = ['\\', 'r', 'i', 'g', 'h', 't'];
    if index + PREFIX.len() > chars.len() {
        return false;
    }
    if chars[index..index + PREFIX.len()] != PREFIX {
        return false;
    }
    if index + PREFIX.len() < chars.len() && chars[index + PREFIX.len()].is_ascii_alphabetic() {
        return false;
    }
    true
}

fn parse_sequence(
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
            } else {
                *index += 1;
                nodes.push(MathNode::Text("}".to_string(), MathFontStyle::RomanUpright));
                continue;
            }
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
                sub_node = Some(Box::new(parse_script_argument(chars, index, depth + 1)));
            } else if chars[*index] == '^' {
                *index += 1;
                sup_node = Some(Box::new(parse_script_argument(chars, index, depth + 1)));
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

fn parse_braced_group(chars: &[char], index: &mut usize, depth: usize) -> MathNode {
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

        return Some(match cmd.as_str() {
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
                let rad = parse_braced_group(chars, index, depth + 1);
                MathNode::Sqrt {
                    radicand: Box::new(rad),
                }
            }
            "left" => {
                let left_delim = read_delimiter_token(chars, index);
                let body = parse_sequence(chars, index, true, false, depth + 1);
                let mut right_delim = ")".to_string();
                if *index < chars.len() && chars[*index] == '\\' && is_right_delimiter_command(chars, *index) {
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
                let raw = extract_raw_braced_string(chars, index);
                MathNode::Text(raw, MathFontStyle::RomanUpright)
            }
            "mathbf" | "textbf" | "boldsymbol" | "bm" => {
                let raw = extract_raw_braced_string(chars, index);
                let resolved = resolve_simple_symbols(&raw);
                MathNode::Text(resolved, MathFontStyle::BoldUpright)
            }
            "mathcal" | "mathscr" => {
                let raw = extract_raw_braced_string(chars, index);
                let mapped: String = raw.chars().map(map_calligraphic).collect();
                MathNode::Text(mapped, MathFontStyle::Calligraphic)
            }
            "mathbb" => {
                let raw = extract_raw_braced_string(chars, index);
                let mapped: String = raw.chars().map(map_blackboard).collect();
                MathNode::Text(mapped, MathFontStyle::BlackboardBold)
            }
            "mathtt" | "texttt" => {
                let raw = extract_raw_braced_string(chars, index);
                MathNode::Text(raw, MathFontStyle::Monospace)
            }
            "mathit" | "textit" => {
                let raw = extract_raw_braced_string(chars, index);
                MathNode::Text(raw, MathFontStyle::ItalicVariable)
            }
            "hat" | "widehat" => MathNode::Accent {
                base: Box::new(parse_braced_group(chars, index, depth + 1)),
                mark: "\u{0302}".to_string(),
            },
            "bar" | "overline" => MathNode::Accent {
                base: Box::new(parse_braced_group(chars, index, depth + 1)),
                mark: "\u{0304}".to_string(),
            },
            "vec" | "overrightarrow" => MathNode::Accent {
                base: Box::new(parse_braced_group(chars, index, depth + 1)),
                mark: "\u{20D7}".to_string(),
            },
            "tilde" | "widetilde" => MathNode::Accent {
                base: Box::new(parse_braced_group(chars, index, depth + 1)),
                mark: "\u{0303}".to_string(),
            },
            "dot" => MathNode::Accent {
                base: Box::new(parse_braced_group(chars, index, depth + 1)),
                mark: "\u{0307}".to_string(),
            },
            "ddot" => MathNode::Accent {
                base: Box::new(parse_braced_group(chars, index, depth + 1)),
                mark: "\u{0308}".to_string(),
            },
            "quad" => MathNode::Space(12.0),
            "qquad" => MathNode::Space(22.0),
            _ => {
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
        });
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

fn estimate_glyph_run_metrics(text: &str, style: MathFontStyle, font_size: f64) -> (f64, f64, f64) {
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

fn layout_node_internal(node: &MathNode, font_size: f64, is_display: bool) -> MathLayoutPlan {
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

        MathNode::Text(str_val, style) => {
            if str_val.is_empty() {
                return MathLayoutPlan {
                    width: 0.0,
                    ascent: 0.0,
                    descent: 0.0,
                    primitives: Vec::new(),
                };
            }
            let (raw_w, asc, desc) = estimate_glyph_run_metrics(str_val, *style, font_size);
            if *style == MathFontStyle::BigOperator {
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
                        text: str_val.clone(),
                        font_style: *style,
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
                    text: str_val.clone(),
                    font_style: *style,
                    font_size,
                }],
            }
        }

        MathNode::Row(children) => {
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

        MathNode::Fraction {
            numerator,
            denominator,
        } => {
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

        MathNode::Sqrt { radicand } => {
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

        MathNode::Scripts { base, sub, sup } => {
            let base_box = layout_node_internal(base, font_size, is_display);
            let script_font_size = (font_size * 0.68).max(9.0);
            let sub_box = sub
                .as_ref()
                .map(|n| layout_node_internal(n, script_font_size, false));
            let sup_box = sup
                .as_ref()
                .map(|n| layout_node_internal(n, script_font_size, false));

            let is_big_op = matches!(base.as_ref(), MathNode::Text(_, MathFontStyle::BigOperator));

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

            let mut primitives = base_box.primitives.clone();
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

        MathNode::Delimited { left, body, right } => {
            let body_box = layout_node_internal(body, font_size, is_display);
            let half_span = (body_box.ascent - axis_height)
                .max(body_box.descent + axis_height)
                + 2.0;
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
                    symbol: left.clone(),
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
                    symbol: right.clone(),
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

        MathNode::Accent { base, mark } => {
            let base_box = layout_node_internal(base, font_size, is_display);
            let mut primitives = base_box.primitives.clone();
            primitives.push(MathDrawPrimitive::Text {
                x: base_box.width * 0.35,
                y: -base_box.ascent - font_size * 0.55,
                text: mark.clone(),
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
    }
}
