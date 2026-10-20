import AppKit
import Foundation

extension LaTeXMathRenderer {

    // MARK: - Symbol Tables
    static let symbolMap: [String: String] = [
        // Lowercase Greek
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ",
        "epsilon": "ϵ", "varepsilon": "ε", "zeta": "ζ", "eta": "η",
        "theta": "θ", "vartheta": "ϑ", "iota": "ι", "kappa": "κ",
        "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ",
        "pi": "π", "varpi": "ϖ", "rho": "ρ", "varrho": "ϱ",
        "sigma": "σ", "varsigma": "ς", "tau": "τ", "upsilon": "υ",
        "phi": "ϕ", "varphi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω",
        // Uppercase Greek
        "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ",
        "Xi": "Ξ", "Pi": "Π", "Sigma": "Σ", "Upsilon": "Υ",
        "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω",
        // Calculus & Physics
        "nabla": "∇", "partial": "∂", "infty": "∞", "hbar": "ℏ",
        "ell": "ℓ", "wp": "℘", "Re": "ℜ", "Im": "ℑ", "aleph": "ℵ",
        "forall": "∀", "exists": "∃", "nexists": "∄", "emptyset": "∅", "varnothing": "∅",
        "prime": "′", "dagger": "†", "ddagger": "‡", "angle": "∠", "triangle": "△",
        // Binary operators
        "cdot": "·", "times": "×", "div": "÷", "pm": "±", "mp": "∓",
        "oplus": "⊕", "ominus": "⊖", "otimes": "⊗", "odot": "⊙",
        "circ": "∘", "bullet": "•", "star": "⋆", "ast": "∗",
        "cup": "∪", "cap": "∩", "setminus": "∖", "wedge": "∧", "vee": "∨",
        // Relations
        "leq": "≤", "le": "≤", "geq": "≥", "ge": "≥", "neq": "≠", "ne": "≠",
        "approx": "≈", "equiv": "≡", "sim": "∼", "simeq": "≃", "cong": "≅",
        "propto": "∝", "ll": "≪", "gg": "≫", "subset": "⊂", "supset": "⊃",
        "subseteq": "⊆", "supseteq": "⊇", "in": "∈", "notin": "∉", "ni": "∋",
        "perp": "⊥", "parallel": "∥", "mid": "∣",
        // Arrows
        "to": "→", "rightarrow": "→", "leftarrow": "←", "leftrightarrow": "↔",
        "Rightarrow": "⇒", "Leftarrow": "⇐", "Leftrightarrow": "⇔", "iff": "⇔",
        "mapsto": "↦", "uparrow": "↑", "downarrow": "↓", "nearrow": "↗", "searrow": "↘",
        // Dots
        "dots": "…", "ldots": "…", "cdots": "⋯", "vdots": "⋮", "ddots": "⋱",
        // Brackets
        "langle": "⟨", "rangle": "⟩", "lfloor": "⌊", "rfloor": "⌋",
        "lceil": "⌈", "rceil": "⌉", "{": "{", "}": "}"
    ]

    static let bigOperators: [String: String] = [
        "int": "∫", "iint": "∬", "iiint": "∭", "oint": "∮",
        "sum": "∑", "prod": "∏", "coprod": "∐",
        "bigcup": "⋃", "bigcap": "⋂", "bigoplus": "⨁", "bigotimes": "⨂"
    ]

    static let namedFunctions: Set<String> = [
        "sin", "cos", "tan", "cot", "sec", "csc",
        "arcsin", "arccos", "arctan", "sinh", "cosh", "tanh",
        "log", "ln", "lg", "exp", "lim", "limsup", "liminf",
        "sup", "inf", "min", "max", "arg", "det", "dim", "ker", "hom", "deg", "gcd", "Pr"
    ]

    static let calligraphicMap: [Character: String] = [
        "A": "𝒜", "B": "ℬ", "C": "𝒞", "D": "𝒟", "E": "ℰ", "F": "ℱ", "G": "𝒢",
        "H": "ℋ", "I": "ℐ", "J": "𝒥", "K": "𝒦", "L": "ℒ", "M": "ℳ", "N": "𝒩",
        "O": "𝒪", "P": "𝒫", "Q": "𝒬", "R": "ℛ", "S": "𝒮", "T": "𝒯", "U": "𝒰",
        "V": "𝒱", "W": "𝒲", "X": "𝒳", "Y": "𝒴", "Z": "𝒵"
    ]

    static let blackboardMap: [Character: String] = [
        "A": "𝔸", "B": "𝔹", "C": "ℂ", "D": "𝔻", "E": "𝔼", "F": "𝔽", "G": "𝔾",
        "H": "ℍ", "I": "𝕀", "J": "𝕁", "K": "𝕂", "L": "𝕃", "M": "𝕄", "N": "ℕ",
        "O": "𝕆", "P": "ℙ", "Q": "ℚ", "R": "ℝ", "S": "𝕊", "T": "𝕋", "U": "𝕌",
        "V": "𝕍", "W": "𝕎", "X": "𝕏", "Y": "𝕐", "Z": "ℤ"
    ]

    static let maxParseDepth = 64

    static func isRightDelimiterCommand(_ chars: [Character], at index: Int) -> Bool {
        let prefix: [Character] = ["\\", "r", "i", "g", "h", "t"]
        guard index + prefix.count <= chars.count else { return false }
        for i in 0..<prefix.count {
            if chars[index + i] != prefix[i] { return false }
        }
        if index + prefix.count < chars.count && chars[index + prefix.count].isLetter {
            return false
        }
        return true
    }

    static func stopOnCloseBraceForLeft() -> Bool {
        false
    }

    static func extractRawBracedString(_ chars: [Character], index: inout Int) -> String {
        while index < chars.count && chars[index].isWhitespace {
            index += 1
        }
        guard index < chars.count else { return "" }
        if chars[index] == "{" {
            index += 1
            var depth = 1
            var out = ""
            while index < chars.count && depth > 0 {
                let c = chars[index]
                index += 1
                if c == "{" {
                    depth += 1
                    if depth > 1 { out.append(c) }
                } else if c == "}" {
                    depth -= 1
                    if depth > 0 { out.append(c) }
                } else {
                    out.append(c)
                }
            }
            return out
        } else {
            let c = chars[index]
            index += 1
            return String(c)
        }
    }

    static func readDelimiterToken(_ chars: [Character], index: inout Int) -> String {
        while index < chars.count && chars[index].isWhitespace {
            index += 1
        }
        guard index < chars.count else { return "" }
        if chars[index] == "\\" {
            index += 1
            guard index < chars.count else { return "" }
            if !chars[index].isLetter {
                let c = chars[index]
                index += 1
                return String(c)
            }
            var cmd = ""
            while index < chars.count && chars[index].isLetter {
                cmd.append(chars[index])
                index += 1
            }
            return symbolMap[cmd] ?? cmd
        } else {
            let c = chars[index]
            index += 1
            return c == "." ? "" : String(c)
        }
    }

    static func resolveSimpleSymbols(in raw: String) -> String {
        guard raw.contains("\\") else { return raw }
        let chars = Array(raw)
        var out = ""
        out.reserveCapacity(chars.count)
        var i = 0
        while i < chars.count {
            if chars[i] == "\\", i + 1 < chars.count, chars[i + 1].isLetter {
                i += 1
                var cmd = ""
                while i < chars.count && chars[i].isLetter {
                    cmd.append(chars[i])
                    i += 1
                }
                if let sym = symbolMap[cmd] {
                    out.append(sym)
                } else {
                    out.append(cmd)
                }
            } else {
                out.append(chars[i])
                i += 1
            }
        }
        return out
    }
}
