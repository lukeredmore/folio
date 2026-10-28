import AppKit
import FolioEngineFFI
import Foundation

extension LaTeXDocumentIndexer {

    static func applyScannedDirectives(
        in line: String,
        lineLocation: Int,
        inPreamble: Bool,
        baseDirectoryURL: URL?,
        secCounters: inout [Int],
        currentContext: inout (kind: String, number: String, title: String, loc: Int),
        bibFiles: inout [String],
        into idx: inout LaTeXDocumentIndex
    ) {
        line.withCString { cStr in
            guard let resPtr = ot_engine_scan_latex_directives(cStr, inPreamble) else { return }
            defer { ot_engine_free_latex_directives(resPtr) }
            let count = Int(resPtr.pointee.count)
            guard count > 0, let items = resPtr.pointee.items else { return }

            for i in 0..<count {
                let d = items[i]
                let cmd = d.cmd.map { String(cString: $0) } ?? ""
                let optArg = d.opt_arg.map { String(cString: $0) } ?? ""
                let arg1 = d.arg1.map { String(cString: $0) } ?? ""
                let arg2 = d.arg2.map { String(cString: $0) } ?? ""
                let arg3 = d.arg3.map { String(cString: $0) } ?? ""

                switch d.kind {
                case 1: // DocumentClass
                    if !optArg.isEmpty {
                        idx.documentClassOptions = optArg
                        parseDocumentClassOptions(optArg, into: &idx.documentStyle)
                    }
                    idx.documentClass = arg1
                case 2: // UsePackage
                    let pkgOpts = optArg.isEmpty ? nil : optArg
                    for pkg in arg1.split(separator: ",") {
                        let pkgName = pkg.trimmingCharacters(in: .whitespaces)
                        idx.packageNames.append(pkgName)
                        applyPackageStyleDefaults(packageName: pkgName, options: pkgOpts, into: &idx.documentStyle)
                    }
                case 3: // Section
                    let level = sectionLevel(for: cmd)
                    var numStr = ""
                    if !d.starred && level <= 4 {
                        let cIdx = max(0, level - 1)
                        secCounters[cIdx] += 1
                        for j in (cIdx + 1)..<secCounters.count { secCounters[j] = 0 }
                        numStr = secCounters[0...cIdx].map(String.init).joined(separator: ".")
                        currentContext = ("Section", numStr, arg1, lineLocation)
                    }
                    idx.lineSectionNumbers[lineLocation] = (level, numStr, arg1, d.starred)
                case 4: // Label
                    if !arg1.isEmpty {
                        idx.labels[arg1] = LaTeXLabelTarget(
                            key: arg1,
                            kind: currentContext.kind,
                            number: currentContext.number,
                            title: currentContext.title,
                            characterLocation: currentContext.loc
                        )
                    }
                case 5: // BibResource
                    for part in arg1.split(separator: ",") {
                        bibFiles.append(part.trimmingCharacters(in: .whitespaces))
                    }
                case 6: // InputFile
                    if let baseDir = baseDirectoryURL,
                        let inputURL = resolveTeXFileURL(path: arg1, baseDirectoryURL: baseDir)
                    {
                        let imported = loadInputMacros(from: inputURL)
                        idx.extraMacros.merge(imported) { _, new in new }
                    }
                case 7: // Frontmatter
                    if cmd == "title" {
                        idx.title = arg1
                    } else if cmd == "author" {
                        idx.author = arg1
                    } else if cmd == "date" {
                        idx.date = arg1 == "\\today" ? formattedToday() : arg1
                    }
                default:
                    applyStyleOrConditionalDirective(
                        kind: d.kind,
                        cmd: cmd,
                        arg1: arg1,
                        arg2: arg2,
                        arg3: arg3,
                        into: &idx.documentStyle
                    )
                }
            }
        }
    }

    private static func applyStyleOrConditionalDirective(
        kind: UInt32,
        cmd: String,
        arg1: String,
        arg2: String,
        arg3: String,
        into style: inout LaTeXDocumentStyle
    ) {
        switch kind {
        case 8: // SetFont
            guard !arg1.isEmpty else { return }
            switch cmd {
            case "setmainfont": style.mainFontFamily = arg1
            case "setsansfont": style.sansFontFamily = arg1
            case "setmonofont": style.monoFontFamily = arg1
            default: break
            }
        case 9: // FamilyDefault
            style.defaultFamilyIsSans = (arg1 == "sfdefault")
            if arg1 == "sfdefault" && style.sansFontFamily == nil {
                style.sansFontFamily = "Helvetica Neue"
            }
        case 10: // SetStretch
            if let val = Double(arg1), val >= 0.7, val <= 3.5 {
                style.lineStretch = CGFloat(val)
            }
        case 11: // SetLength
            if let parsed = LaTeXLength.parse(arg2) {
                if arg1 == "parindent" { style.parindent = parsed } else if arg1 == "parskip" { style.parskip = parsed }
            }
        case 12: // DefineColor
            if let color = parseDefinedColor(model: arg2, spec: arg3) {
                style.customColors[arg1] = color
            }
        case 13: // NewIf
            if style.conditionals[arg1] == nil {
                style.conditionals[arg1] = false
            }
        case 14: // ToggleIf
            if arg1 != "if", style.conditionals[arg1] != nil {
                style.conditionals[arg1] = (arg2 == "true")
            }
        default:
            break
        }
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
            if style.mainFontFamily == nil { style.mainFontFamily = "Times New Roman" }
        case "palatino", "mathpazo", "newpxtext", "tgpagella", "pxfonts":
            if style.mainFontFamily == nil { style.mainFontFamily = "Palatino" }
        case "charter", "bch":
            if style.mainFontFamily == nil { style.mainFontFamily = "Charter" }
        case "bookman", "tgbonum":
            if style.mainFontFamily == nil { style.mainFontFamily = "Georgia" }
        case "baskervillef", "kpfonts":
            if style.mainFontFamily == nil { style.mainFontFamily = "Baskerville" }
        case "helvet", "tgheros", "arev", "firasans":
            if style.sansFontFamily == nil { style.sansFontFamily = "Helvetica Neue" }
        case "courier", "tgcursor", "inconsolata":
            if style.monoFontFamily == nil { style.monoFontFamily = "Menlo" }
        case "parskip":
            if style.parindent == nil { style.parindent = .points(0.0) }
            if style.parskip == nil { style.parskip = .em(0.6) }
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
