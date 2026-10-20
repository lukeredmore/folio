pub(crate) fn lookup_symbol(cmd: &str) -> Option<&'static str> {
    lookup_greek_or_calculus(cmd).or_else(|| lookup_operator_or_relation(cmd))
}

fn lookup_greek_or_calculus(cmd: &str) -> Option<&'static str> {
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
        _ => None,
    }
}

fn lookup_operator_or_relation(cmd: &str) -> Option<&'static str> {
    match cmd {
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
        // Dots & Brackets
        "dots" | "ldots" => Some("…"),
        "cdots" => Some("⋯"),
        "vdots" => Some("⋮"),
        "ddots" => Some("⋱"),
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

pub(crate) fn lookup_big_operator(cmd: &str) -> Option<&'static str> {
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

pub(crate) fn is_named_function(cmd: &str) -> bool {
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

pub(crate) fn is_lowercase_greek(cmd: &str) -> bool {
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

pub(crate) fn map_calligraphic(ch: char) -> char {
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

pub(crate) fn map_blackboard(ch: char) -> char {
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

pub(crate) fn is_right_delimiter_command(chars: &[char], index: usize) -> bool {
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
