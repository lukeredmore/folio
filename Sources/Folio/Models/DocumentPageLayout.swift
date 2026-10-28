import AppKit
import Foundation

/// Parses in-document page layout directives from LaTeX (`\documentclass`, `geometry`) and
/// Markdown (YAML frontmatter `--- ... ---` and `<!-- page: ... -->` / `<!-- geometry: ... -->` comments).
public struct DocumentPageLayout: Equatable, Sendable {
    public var paperSize: PrintPaperSize?
    public var paperWidth: CGFloat?
    public var paperHeight: CGFloat?
    public var orientation: PrintOrientation?
    public var topMargin: CGFloat?
    public var bottomMargin: CGFloat?
    public var leftMargin: CGFloat?
    public var rightMargin: CGFloat?
    public var textWidth: CGFloat?
    public var textHeight: CGFloat?
    public var baseFontSizePoints: CGFloat?
    public var textAlignment: EditorTextAlignment?
    public var metadataRange: NSRange?

    public init() {}

    public var isEmpty: Bool {
        paperSize == nil && paperWidth == nil && paperHeight == nil && orientation == nil && topMargin == nil && bottomMargin == nil && leftMargin == nil
            && rightMargin == nil && textWidth == nil && textHeight == nil && baseFontSizePoints == nil && textAlignment == nil
    }

    public func resolve(
        defaultPaper: PrintPaperSize,
        defaultOrientation: PrintOrientation,
        defaultMargins: PrintPageMargins
    ) -> ResolvedPrintPageLayout {
        let resolvedPaper = paperSize ?? defaultPaper
        let resolvedOrientation = orientation ?? defaultOrientation
        let customDimensions: NSSize? = {
            if let pw = paperWidth, let ph = paperHeight, pw > 144, ph > 144 {
                return NSSize(width: pw, height: ph)
            }
            return nil
        }()
        let rawPaper = customDimensions ?? resolvedPaper.size
        let effPaper: NSSize = {
            switch resolvedOrientation {
            case .portrait: return rawPaper.width <= rawPaper.height ? rawPaper : NSSize(width: rawPaper.height, height: rawPaper.width)
            case .landscape: return rawPaper.width >= rawPaper.height ? rawPaper : NSSize(width: rawPaper.height, height: rawPaper.width)
            }
        }()

        var margins = defaultMargins
        if let tw = textWidth, tw > 100, tw < effPaper.width - 36 {
            let side = floor((effPaper.width - tw) * 0.5)
            margins.left = side
            margins.right = side
        }
        if let th = textHeight, th > 100, th < effPaper.height - 36 {
            let vert = floor((effPaper.height - th) * 0.5)
            margins.top = vert
            margins.bottom = vert
        }
        if let topMargin { margins.top = max(18, min(216, topMargin)) }
        if let bottomMargin { margins.bottom = max(18, min(216, bottomMargin)) }
        if let leftMargin { margins.left = max(18, min(216, leftMargin)) }
        if let rightMargin { margins.right = max(18, min(216, rightMargin)) }

        let hasOverrides = !isEmpty
        var parts: [String] = []
        if let customDimensions {
            parts.append(String(format: "%.1f×%.1f in", customDimensions.width / 72, customDimensions.height / 72))
        } else if let paperSize {
            parts.append(paperSize.shortTitle)
        }
        if let orientation { parts.append(orientation.title) }
        if topMargin != nil || bottomMargin != nil || leftMargin != nil || rightMargin != nil || textWidth != nil || textHeight != nil {
            parts.append(margins.summaryText)
        }
        if let fs = baseFontSizePoints {
            parts.append("\(Int(round(fs)))pt")
        }

        return ResolvedPrintPageLayout(
            paperSize: resolvedPaper,
            customPaperDimensions: customDimensions,
            orientation: resolvedOrientation,
            margins: margins,
            baseFontSizePoints: baseFontSizePoints,
            textAlignmentOverride: textAlignment?.nsAlignment,
            hasDocumentOverrides: hasOverrides,
            overrideSummary: parts.isEmpty ? nil : parts.joined(separator: " · ")
        )
    }

    // MARK: - Extraction Entry Point

    public static func extract(from text: String, fileURL: URL? = nil) -> DocumentPageLayout {
        let kind = LaTeXLiveStyler.documentKind(for: text, fileURL: fileURL)
        if kind == .latex {
            return extractFromLaTeX(text)
        }
        return extractFromMarkdown(text)
    }

    // MARK: - LaTeX Preamble Parser (\documentclass, \usepackage[...]{geometry}, \geometry{...})

    private static let docClassRegex = try! NSRegularExpression(pattern: #"\\documentclass(?:\[([^\]]*)\])?\{([^\}]+)\}"#)
    private static let usepackageGeometryRegex = try! NSRegularExpression(pattern: #"\\usepackage\[([^\]]*)\]\{[^}]*\bgeometry\b[^}]*\}"#)
    private static let geometryCmdRegex = try! NSRegularExpression(pattern: #"\\geometry\{([^\}]*)\}"#)

    private static func extractFromLaTeX(_ text: String) -> DocumentPageLayout {
        var layout = DocumentPageLayout()
        let prefix = String(text.prefix(12000))
        let preambleText: String
        if let beginRange = prefix.range(of: "\\begin{document}") {
            preambleText = String(prefix[..<beginRange.lowerBound])
        } else {
            preambleText = prefix
        }
        let uncommented =
            preambleText
            .components(separatedBy: .newlines)
            .map { line -> String in
                if let pct = line.firstIndex(of: "%") { return String(line[..<pct]) }
                return line
            }
            .joined(separator: "\n")
        let ns = uncommented as NSString
        let fullRange = NSRange(location: 0, length: ns.length)

        if let m = docClassRegex.firstMatch(in: uncommented, range: fullRange), m.range(at: 1).location != NSNotFound {
            applyKeyValueOptions(ns.substring(with: m.range(at: 1)), to: &layout)
        }
        usepackageGeometryRegex.enumerateMatches(in: uncommented, range: fullRange) { m, _, _ in
            guard let m, m.range(at: 1).location != NSNotFound else { return }
            applyKeyValueOptions(ns.substring(with: m.range(at: 1)), to: &layout)
        }
        geometryCmdRegex.enumerateMatches(in: uncommented, range: fullRange) { m, _, _ in
            guard let m, m.range(at: 1).location != NSNotFound else { return }
            applyKeyValueOptions(ns.substring(with: m.range(at: 1)), to: &layout)
        }
        if uncommented.contains("\\raggedright") {
            layout.textAlignment = .left
        }
        return layout
    }

    // MARK: - Markdown Frontmatter & Comment Directive Parser

    private static let htmlPageDirectiveRegex = try! NSRegularExpression(
        pattern: #"<!--\s*(?:page|geometry|print)\s*:\s*(.*?)\s*-->"#,
        options: [.caseInsensitive, .dotMatchesLineSeparators]
    )

    private static func extractFromMarkdown(_ text: String) -> DocumentPageLayout {
        var layout = DocumentPageLayout()
        let prefix = String(text.prefix(6000))
        if let fm = parseMarkdownFrontmatter(in: prefix) {
            layout.metadataRange = fm.range
            for (key, value) in fm.pairs {
                applySingleOption(key: key, value: value, to: &layout)
            }
        }
        let ns = prefix as NSString
        htmlPageDirectiveRegex.enumerateMatches(in: prefix, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m, m.range(at: 1).location != NSNotFound else { return }
            applyKeyValueOptions(ns.substring(with: m.range(at: 1)), to: &layout)
        }
        return layout
    }

    public static func parseMarkdownFrontmatter(in text: String) -> (range: NSRange, pairs: [(String, String)])? {
        let ns = text as NSString
        guard ns.length >= 7 else { return nil }
        let firstLineRange = ns.lineRange(for: NSRange(location: 0, length: 0))
        let firstLine = ns.substring(with: firstLineRange).trimmingCharacters(in: .whitespacesAndNewlines)
        guard firstLine == "---" else { return nil }

        var idx = NSMaxRange(firstLineRange)
        var pairs: [(String, String)] = []
        var activeListKey: String?

        while idx < ns.length {
            let lr = ns.lineRange(for: NSRange(location: idx, length: 0))
            let rawLine = ns.substring(with: lr).trimmingCharacters(in: .newlines)
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" || trimmed == "..." {
                guard !pairs.isEmpty else { return nil }
                return (NSRange(location: 0, length: NSMaxRange(lr)), pairs)
            }
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                idx = NSMaxRange(lr)
                continue
            }
            if trimmed.hasPrefix("- "), let listKey = activeListKey {
                let itemVal = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                pairs.append((listKey, itemVal))
                idx = NSMaxRange(lr)
                continue
            }
            guard let colon = trimmed.firstIndex(of: ":") else { return nil }
            let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            let val = String(trimmed[trimmed.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if val.isEmpty {
                activeListKey = key
            } else {
                activeListKey = nil
                pairs.append((key, val))
            }
            idx = NSMaxRange(lr)
            if idx > 4000 { break }
        }
        return nil
    }

    // MARK: - Option & Dimension Parsing

    static func applyKeyValueOptions(_ rawOptions: String, to layout: inout DocumentPageLayout) {
        for token in splitTopLevelCommas(rawOptions) {
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if let eq = trimmed.firstIndex(of: "=") {
                let key = String(trimmed[..<eq]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let val = String(trimmed[trimmed.index(after: eq)...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
                applySingleOption(key: key, value: val, to: &layout)
            } else {
                applySingleOption(key: trimmed.lowercased(), value: "", to: &layout)
            }
        }
    }

    private static func applySingleOption(key: String, value: String, to layout: inout DocumentPageLayout) {
        let lowerVal = value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        switch key {
        case "a4paper", "a4": layout.paperSize = .a4
        case "letterpaper", "letter", "us-letter": layout.paperSize = .letter
        case "legalpaper", "legal", "us-legal": layout.paperSize = .legal
        case "a5paper", "a5": layout.paperSize = .a5
        case "landscape":
            layout.orientation = (lowerVal == "false" || lowerVal == "no") ? .portrait : .landscape
        case "portrait":
            layout.orientation = (lowerVal == "false" || lowerVal == "no") ? .landscape : .portrait
        case "paper", "papersize", "page-size", "pagesize":
            if let p = parsePaperName(lowerVal) { layout.paperSize = p }
        case "orientation":
            if lowerVal.contains("land") { layout.orientation = .landscape } else if lowerVal.contains("port") { layout.orientation = .portrait }
        case "10pt": layout.baseFontSizePoints = 10
        case "11pt": layout.baseFontSizePoints = 11
        case "12pt": layout.baseFontSizePoints = 12
        case "fontsize", "font-size":
            if let pt = parsePoints(lowerVal), pt >= 8, pt <= 28 { layout.baseFontSizePoints = pt }
        case "margin", "margins":
            if let pt = parsePoints(lowerVal) {
                layout.topMargin = pt; layout.bottomMargin = pt; layout.leftMargin = pt; layout.rightMargin = pt
            }
        case "hmargin":
            let parts = lowerVal.split(separator: ",").compactMap { parsePoints(String($0)) }
            if parts.count == 2 {
                layout.leftMargin = parts[0]; layout.rightMargin = parts[1]
            } else if let pt = parts.first {
                layout.leftMargin = pt; layout.rightMargin = pt
            }
        case "vmargin":
            let parts = lowerVal.split(separator: ",").compactMap { parsePoints(String($0)) }
            if parts.count == 2 {
                layout.topMargin = parts[0]; layout.bottomMargin = parts[1]
            } else if let pt = parts.first {
                layout.topMargin = pt; layout.bottomMargin = pt
            }
        case "top", "tmargin", "margin-top", "top-margin":
            if let pt = parsePoints(lowerVal) { layout.topMargin = pt }
        case "bottom", "bmargin", "margin-bottom", "bottom-margin":
            if let pt = parsePoints(lowerVal) { layout.bottomMargin = pt }
        case "left", "lmargin", "inner", "margin-left", "left-margin":
            if let pt = parsePoints(lowerVal) { layout.leftMargin = pt }
        case "right", "rmargin", "outer", "margin-right", "right-margin":
            if let pt = parsePoints(lowerVal) { layout.rightMargin = pt }
        case "textwidth", "width", "column-width":
            if let pt = parsePoints(lowerVal) { layout.textWidth = pt }
        case "textheight", "height":
            if let pt = parsePoints(lowerVal) { layout.textHeight = pt }
        case "paperwidth":
            if let pt = parsePoints(lowerVal) { layout.paperWidth = pt }
        case "paperheight":
            if let pt = parsePoints(lowerVal) { layout.paperHeight = pt }
        case "geometry", "page", "print":
            applyKeyValueOptions(value, to: &layout)
        case "align", "alignment", "text-align":
            if lowerVal.hasPrefix("justif") {
                layout.textAlignment = .justified
            } else if lowerVal == "left" || lowerVal == "raggedright" {
                layout.textAlignment = .left
            }
        default:
            break
        }
    }

    private static func parsePaperName(_ raw: String) -> PrintPaperSize? {
        let cleaned = raw.replacingOccurrences(of: "paper", with: "").trimmingCharacters(in: .whitespaces)
        switch cleaned {
        case "a4": return .a4
        case "letter", "us-letter", "usletter": return .letter
        case "legal", "us-legal", "uslegal": return .legal
        case "a5": return .a5
        default: return nil
        }
    }

    public static func parsePoints(_ raw: String) -> CGFloat? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !s.isEmpty else { return nil }
        let units: [(String, CGFloat)] = [
            ("in", 72.0), ("inch", 72.0), ("inches", 72.0), ("\"", 72.0),
            ("cm", 72.0 / 2.54), ("mm", 72.0 / 25.4),
            ("pt", 1.0), ("bp", 1.0), ("pc", 12.0), ("px", 0.75)
        ]
        for (suffix, factor) in units where s.hasSuffix(suffix) {
            let numStr = String(s.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
            if let val = Double(numStr), val >= 0 { return CGFloat(val) * factor }
        }
        if let val = Double(s), val >= 0 {
            return val <= 5.0 ? CGFloat(val) * 72.0 : CGFloat(val)
        }
        return nil
    }

    private static func splitTopLevelCommas(_ s: String) -> [String] {
        var result: [String] = []
        var current = ""
        var depth = 0
        for ch in s {
            if ch == "{" { depth += 1 } else if ch == "}" { depth = max(0, depth - 1) }
            if (ch == "," || ch == ";") && depth == 0 {
                result.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
