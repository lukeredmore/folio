import AppKit
import Foundation

extension LaTeXDocumentIndexer {

    static let setFontCmdRegex = try! NSRegularExpression(
        pattern: #"\\(setmainfont|setsansfont|setmonofont)(?:\[[^\]]*\])?\{([^}]+)\}"#
    )
    static let setStretchCmdRegex = try! NSRegularExpression(
        pattern: #"\\(setstretch|linespread)\{([^}]+)\}"#
    )
    static let setLengthCmdRegex = try! NSRegularExpression(
        pattern: #"\\setlength\{\\?(parindent|parskip)\}\{([^}]+)\}"#
    )
    static let defineColorCmdRegex = try! NSRegularExpression(
        pattern: #"\\definecolor\{([^}]+)\}\{([^}]+)\}\{([^}]+)\}"#
    )
    static let familyDefaultCmdRegex = try! NSRegularExpression(
        pattern: #"\\renewcommand\{\\familydefault\}\{\\(sfdefault|rmdefault|ttdefault)\}"#
    )
    static let newifCmdRegex = try! NSRegularExpression(
        pattern: #"\\newif\s*\\if([A-Za-z@]+)"#
    )
    static let toggleIfCmdRegex = try! NSRegularExpression(
        pattern: #"\\([A-Za-z@]+)(true|false)\b"#
    )

    static func parseConditionalDirectives(in line: String, into style: inout LaTeXDocumentStyle) {
        let uncommented = stripUnescapedPercentComment(in: line)
        guard uncommented.contains("\\") else { return }
        let nsLine = uncommented as NSString
        let fullRange = NSRange(location: 0, length: nsLine.length)
        if uncommented.contains("\\newif") {
            newifCmdRegex.enumerateMatches(in: uncommented, range: fullRange) { m, _, _ in
                guard let m = m else { return }
                let condName = nsLine.substring(with: m.range(at: 1))
                if style.conditionals[condName] == nil {
                    style.conditionals[condName] = false
                }
            }
        }
        toggleIfCmdRegex.enumerateMatches(in: uncommented, range: fullRange) { m, _, _ in
            guard let m = m else { return }
            let condName = nsLine.substring(with: m.range(at: 1))
            let stateStr = nsLine.substring(with: m.range(at: 2))
            guard condName != "if", style.conditionals[condName] != nil else { return }
            style.conditionals[condName] = (stateStr == "true")
        }
    }

    private static func stripUnescapedPercentComment(in line: String) -> String {
        let chars = Array(line)
        var i = 0
        while i < chars.count {
            if chars[i] == "%" {
                var backslashes = 0
                var j = i - 1
                while j >= 0 && chars[j] == "\\" {
                    backslashes += 1
                    j -= 1
                }
                if backslashes % 2 == 0 {
                    return String(chars[0..<i])
                }
            }
            i += 1
        }
        return line
    }

    static func parseDocumentClassOptions(_ rawOptions: String, into style: inout LaTeXDocumentStyle) {
        for part in rawOptions.split(separator: ",") {
            let opt = part.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if opt.hasSuffix("pt"), let ptVal = Double(opt.dropLast(2)), ptVal >= 8.0, ptVal <= 24.0 {
                style.documentFontSizePt = CGFloat(ptVal)
            }
        }
    }

    static func applyPackageStyleDefaults(packageName: String, options: String?, into style: inout LaTeXDocumentStyle) {
        let pkg = packageName.lowercased()
        switch pkg {
        case "times", "mathptmx", "newtxtext", "tgtermes", "txfonts":
            if style.mainFontFamily == nil {
                style.mainFontFamily = "Times New Roman"
            }
        case "palatino", "mathpazo", "newpxtext", "tgpagella", "pxfonts":
            if style.mainFontFamily == nil {
                style.mainFontFamily = "Palatino"
            }
        case "charter", "bch":
            if style.mainFontFamily == nil {
                style.mainFontFamily = "Charter"
            }
        case "bookman", "tgbonum":
            if style.mainFontFamily == nil {
                style.mainFontFamily = "Georgia"
            }
        case "baskervillef", "kpfonts":
            if style.mainFontFamily == nil {
                style.mainFontFamily = "Baskerville"
            }
        case "helvet", "tgheros", "arev", "FiraSans":
            if style.sansFontFamily == nil {
                style.sansFontFamily = "Helvetica Neue"
            }
        case "courier", "tgcursor", "inconsolata":
            if style.monoFontFamily == nil {
                style.monoFontFamily = "Menlo"
            }
        case "parskip":
            if style.parindent == nil {
                style.parindent = .points(0.0)
            }
            if style.parskip == nil {
                style.parskip = .em(0.6)
            }
        case "setspace":
            if let opts = options?.lowercased() {
                if opts.contains("doublespacing") && style.lineStretch == nil {
                    style.lineStretch = 1.65
                } else if opts.contains("onehalfspacing") && style.lineStretch == nil {
                    style.lineStretch = 1.25
                }
            }
        default:
            break
        }
    }

    static func parsePreambleStyleDirectives(in line: String, trimmed: String, into style: inout LaTeXDocumentStyle) {
        let nsLine = line as NSString
        let fullRange = NSRange(location: 0, length: nsLine.length)

        if line.contains("\\setmainfont") || line.contains("\\setsansfont") || line.contains("\\setmonofont") {
            setFontCmdRegex.enumerateMatches(in: line, range: fullRange) { m, _, _ in
                guard let m = m else { return }
                let cmd = nsLine.substring(with: m.range(at: 1))
                let fontName = nsLine.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !fontName.isEmpty else { return }
                switch cmd {
                case "setmainfont": style.mainFontFamily = fontName
                case "setsansfont": style.sansFontFamily = fontName
                case "setmonofont": style.monoFontFamily = fontName
                default: break
                }
            }
        }

        if line.contains("\\familydefault"),
           let fm = familyDefaultCmdRegex.firstMatch(in: line, range: fullRange) {
            let target = nsLine.substring(with: fm.range(at: 1))
            style.defaultFamilyIsSans = (target == "sfdefault")
            if target == "sfdefault" && style.sansFontFamily == nil {
                style.sansFontFamily = "Helvetica Neue"
            }
        }

        if line.contains("\\setstretch") || line.contains("\\linespread") {
            setStretchCmdRegex.enumerateMatches(in: line, range: fullRange) { m, _, _ in
                guard let m = m else { return }
                let rawVal = nsLine.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
                if let val = Double(rawVal), val >= 0.7, val <= 3.5 {
                    style.lineStretch = CGFloat(val)
                }
            }
        } else if trimmed == "\\onehalfspacing" {
            style.lineStretch = 1.25
        } else if trimmed == "\\doublespacing" {
            style.lineStretch = 1.65
        } else if trimmed == "\\singlespacing" {
            style.lineStretch = 1.0
        }

        if line.contains("\\setlength") {
            setLengthCmdRegex.enumerateMatches(in: line, range: fullRange) { m, _, _ in
                guard let m = m else { return }
                let param = nsLine.substring(with: m.range(at: 1))
                let rawLen = nsLine.substring(with: m.range(at: 2))
                guard let parsed = LaTeXLength.parse(rawLen) else { return }
                if param == "parindent" {
                    style.parindent = parsed
                } else if param == "parskip" {
                    style.parskip = parsed
                }
            }
        }

        if line.contains("\\definecolor") {
            defineColorCmdRegex.enumerateMatches(in: line, range: fullRange) { m, _, _ in
                guard let m = m else { return }
                let name = nsLine.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                let model = nsLine.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
                let spec = nsLine.substring(with: m.range(at: 3)).trimmingCharacters(in: .whitespacesAndNewlines)
                if let color = parseDefinedColor(model: model, spec: spec) {
                    style.customColors[name] = color
                }
            }
        }
    }

    private static func parseDefinedColor(model: String, spec: String) -> ThemeColorRGBA? {
        switch model {
        case "RGB":
            let parts = spec.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard parts.count >= 3 else { return nil }
            return ThemeColorRGBA(
                r: min(1.0, max(0.0, parts[0] / 255.0)),
                g: min(1.0, max(0.0, parts[1] / 255.0)),
                b: min(1.0, max(0.0, parts[2] / 255.0)),
                a: 1.0
            )
        case "rgb":
            let parts = spec.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard parts.count >= 3 else { return nil }
            return ThemeColorRGBA(
                r: min(1.0, max(0.0, parts[0])),
                g: min(1.0, max(0.0, parts[1])),
                b: min(1.0, max(0.0, parts[2])),
                a: 1.0
            )
        case "HTML", "html":
            let hex = spec.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
            guard hex.count == 6, let val = UInt32(hex, radix: 16) else { return nil }
            return ThemeColorRGBA(
                r: Double((val >> 16) & 0xFF) / 255.0,
                g: Double((val >> 8) & 0xFF) / 255.0,
                b: Double(val & 0xFF) / 255.0,
                a: 1.0
            )
        case "gray":
            guard let g = Double(spec.trimmingCharacters(in: .whitespaces)) else { return nil }
            let clamped = min(1.0, max(0.0, g))
            return ThemeColorRGBA(r: clamped, g: clamped, b: clamped, a: 1.0)
        default:
            return nil
        }
    }
}
