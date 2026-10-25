import AppKit
import Foundation

public enum LaTeXLength: Equatable {
    case points(CGFloat)
    case em(CGFloat)

    public func resolvedPoints(baseSize: CGFloat) -> CGFloat {
        switch self {
        case .points(let pt):
            return max(0.0, pt)
        case .em(let factor):
            return max(0.0, factor * baseSize)
        }
    }

    public static func parse(_ raw: String) -> LaTeXLength? {
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let plusRange = cleaned.range(of: "plus", options: .caseInsensitive) {
            cleaned = String(cleaned[..<plusRange.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        if let minusRange = cleaned.range(of: "minus", options: .caseInsensitive) {
            cleaned = String(cleaned[..<minusRange.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        guard !cleaned.isEmpty else { return nil }
        if cleaned == "0" || cleaned == "0.0" {
            return .points(0.0)
        }
        let units: [(suffix: String, isEm: Bool, multiplier: CGFloat)] = [
            ("truept", false, 1.0),
            ("pt", false, 1.0),
            ("bp", false, 1.0),
            ("in", false, 72.0),
            ("cm", false, 28.3465),
            ("mm", false, 2.83465),
            ("pc", false, 12.0),
            ("dd", false, 1.07),
            ("em", true, 1.0),
            ("ex", true, 0.5),
            ("\\baselineskip", true, 1.2)
        ]
        let lower = cleaned.lowercased()
        for u in units where lower.hasSuffix(u.suffix) {
            let numStr = String(cleaned.dropLast(u.suffix.count)).trimmingCharacters(in: .whitespaces)
            let val: CGFloat
            if numStr.isEmpty || numStr == "+" {
                val = 1.0
            } else if numStr == "-" {
                val = -1.0
            } else if let d = Double(numStr) {
                val = CGFloat(d)
            } else {
                continue
            }
            return u.isEm ? .em(val * u.multiplier) : .points(val * u.multiplier)
        }
        if let d = Double(cleaned) {
            return .points(CGFloat(d))
        }
        return nil
    }
}

public struct LaTeXDocumentStyle: Equatable {
    public var mainFontFamily: String?
    public var sansFontFamily: String?
    public var monoFontFamily: String?
    public var defaultFamilyIsSans: Bool = false
    public var documentFontSizePt: CGFloat?
    public var lineStretch: CGFloat?
    public var parindent: LaTeXLength?
    public var parskip: LaTeXLength?
    public var customColors: [String: ThemeColorRGBA] = [:]

    public init() {}

    public var effectiveMainFontFamily: String? {
        if let mainFontFamily, !mainFontFamily.isEmpty {
            return mainFontFamily
        }
        if defaultFamilyIsSans, let sansFontFamily, !sansFontFamily.isEmpty {
            return sansFontFamily
        }
        return nil
    }
}

extension LaTeXDocumentIndex {

    public func effectiveBaseFontSize(theme: EditorTheme, typography: EditorTypographySettings) -> CGFloat {
        let base = theme.baseFontSize * typography.fontSizeScale
        guard let docPt = documentStyle.documentFontSizePt, docPt > 0 else {
            return base
        }
        // When printing (or when fontSizeScale already normalized base to docPt), honor the exact
        // LaTeX document point size; on screen, scale proportionally relative to 11pt LaTeX articles.
        if abs(base - docPt) < 0.05 || abs(theme.baseFontSize - 12.0) < 0.01 {
            return base
        }
        let ratio = min(1.30, max(0.85, docPt / 11.0))
        return round(base * ratio * 10.0) / 10.0
    }

    public func bodyFont(
        size: CGFloat,
        bold: Bool = false,
        italic: Bool = false,
        semibold: Bool = false,
        fallbackTheme: EditorTheme
    ) -> NSFont {
        if let family = documentStyle.effectiveMainFontFamily {
            return EditorTheme.resolveFont(
                familySpec: family,
                size: size,
                bold: bold,
                italic: italic,
                semibold: semibold
            )
        }
        return fallbackTheme.bodyFont(size: size, bold: bold, italic: italic, semibold: semibold)
    }

    public func headingFont(
        level: Int,
        scale: CGFloat,
        baseSize: CGFloat,
        fallbackTheme: EditorTheme
    ) -> NSFont {
        guard let family = documentStyle.effectiveMainFontFamily else {
            if documentStyle.documentFontSizePt != nil {
                let mults: [Int: CGFloat] = [1: 1.75, 2: 1.42, 3: 1.20, 4: 1.08, 5: 1.0, 6: 0.92]
                let sz = round(baseSize * (mults[level] ?? 1.0))
                return fallbackTheme.bodyFont(size: sz, bold: true)
            }
            return fallbackTheme.headingFont(level: level, scale: scale)
        }
        let multipliers: [Int: CGFloat] = [
            1: 1.72,
            2: 1.40,
            3: 1.18,
            4: 1.06,
            5: 1.00,
            6: 0.92
        ]
        let mult = multipliers[level] ?? 1.0
        let size = round(baseSize * mult)
        let targetFamily = (documentClass.hasPrefix("scr") && documentStyle.sansFontFamily != nil)
            ? (documentStyle.sansFontFamily ?? family)
            : family
        return EditorTheme.resolveFont(
            familySpec: targetFamily,
            size: size,
            bold: true,
            italic: false,
            semibold: false
        )
    }

    public func codeFont(size: CGFloat, fallbackTheme: EditorTheme) -> NSFont {
        if let mono = documentStyle.monoFontFamily, !mono.isEmpty,
           let custom = NSFont(name: mono, size: size) {
            return custom
        }
        return fallbackTheme.codeFont(size: size)
    }

    public func effectiveLineHeightMultiple(fallback: EditorTypographySettings) -> CGFloat {
        if let stretch = documentStyle.lineStretch, stretch > 0 {
            return stretch
        }
        return fallback.lineHeightMultiple
    }

    public func effectiveLineSpacing(fallback: EditorTypographySettings) -> CGFloat {
        if documentStyle.lineStretch != nil {
            return 0.0
        }
        return max(0.0, fallback.lineSpacing)
    }

    public func effectiveParagraphSpacing(baseSize: CGFloat, fallback: EditorTypographySettings) -> CGFloat {
        if let skip = documentStyle.parskip {
            return skip.resolvedPoints(baseSize: baseSize)
        }
        return max(4.0, fallback.paragraphSpacing * 0.65)
    }

    public func effectiveFirstLineIndent(baseSize: CGFloat) -> CGFloat {
        if let indent = documentStyle.parindent {
            return indent.resolvedPoints(baseSize: baseSize)
        }
        return 0.0
    }

    public func resolveColor(named rawName: String, fallbackTheme: EditorTheme) -> NSColor {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return fallbackTheme.linkNSColor }
        if let custom = documentStyle.customColors[name] {
            return custom.nsColor
        }
        let baseName = name.split(separator: "!").first.map(String.init) ?? name
        if let customBase = documentStyle.customColors[baseName] {
            return customBase.nsColor
        }
        switch baseName.lowercased() {
        case "red", "brickred", "crimson", "maroon":
            return NSColor(srgbRed: 0.78, green: 0.14, blue: 0.16, alpha: 1.0)
        case "blue", "navyblue", "royalblue", " midnightblue":
            return NSColor(srgbRed: 0.0, green: 0.35, blue: 0.72, alpha: 1.0)
        case "green", "forestgreen", "olive", "darkgreen":
            return NSColor(srgbRed: 0.12, green: 0.52, blue: 0.22, alpha: 1.0)
        case "teal", "cyan":
            return NSColor(srgbRed: 0.0, green: 0.50, blue: 0.55, alpha: 1.0)
        case "orange", "burntorange":
            return NSColor(srgbRed: 0.85, green: 0.42, blue: 0.06, alpha: 1.0)
        case "purple", "violet", "magenta", "plum":
            return NSColor(srgbRed: 0.52, green: 0.18, blue: 0.68, alpha: 1.0)
        case "brown", "sepia":
            return NSColor(srgbRed: 0.48, green: 0.28, blue: 0.14, alpha: 1.0)
        case "darkgray", "darkgrey":
            return NSColor(srgbRed: 0.30, green: 0.30, blue: 0.32, alpha: 1.0)
        case "gray", "grey":
            return NSColor(srgbRed: 0.50, green: 0.50, blue: 0.52, alpha: 1.0)
        case "black":
            return fallbackTheme.textNSColor
        default:
            return fallbackTheme.linkNSColor
        }
    }

    func isBlankBlockRedundant(range: NSRange, in nsString: NSString, fullLength: Int) -> Bool {
        let bodyStart = preambleRange.map { NSMaxRange($0) } ?? 0
        if range.location <= bodyStart || NSMaxRange(range) >= fullLength {
            return true
        }
        // Check following line
        let nextLR = nsString.lineRange(for: NSRange(location: NSMaxRange(range), length: 0))
        let nextCR = MarkdownLiveStyler.strippedLineContentRange(nsString: nsString, lineRange: nextLR)
        let nextTrimmed = nsString.substring(with: nextCR).trimmingCharacters(in: .whitespaces)
        if Self.isVerticalGlueOrSectionLine(nextTrimmed) || nextTrimmed.hasPrefix("%") {
            return true
        }
        // Check preceding line(s), skipping back over comment/blank blocks to see if at start of body
        var prevPos = range.location
        var checkedImmediatePrev = false
        while prevPos > bodyStart {
            let prevLR = nsString.lineRange(for: NSRange(location: prevPos - 1, length: 0))
            let prevCR = MarkdownLiveStyler.strippedLineContentRange(nsString: nsString, lineRange: prevLR)
            let prevTrimmed = nsString.substring(with: prevCR).trimmingCharacters(in: .whitespaces)
            if !checkedImmediatePrev {
                checkedImmediatePrev = true
                if Self.isVerticalGlueOrSectionLine(prevTrimmed) {
                    return true
                }
            }
            if prevTrimmed.isEmpty || prevTrimmed.hasPrefix("%") || prevTrimmed == "\\begin{document}" {
                prevPos = prevLR.location
                continue
            }
            return false
        }
        return true
    }

    private static func isVerticalGlueOrSectionLine(_ trimmed: String) -> Bool {
        if trimmed.hasPrefix("\\vspace") || trimmed == "\\vfill"
            || trimmed == "\\newpage" || trimmed == "\\clearpage"
            || trimmed == "\\begin{document}" || trimmed == "\\end{document}"
            || trimmed == "\\begin{center}" || trimmed == "\\end{center}"
            || trimmed == "\\begin{itemize}" || trimmed == "\\end{itemize}"
            || trimmed == "\\begin{enumerate}" || trimmed == "\\end{enumerate}" {
            return true
        }
        if trimmed.hasPrefix("\\section") || trimmed.hasPrefix("\\subsection")
            || trimmed.hasPrefix("\\subsubsection") || trimmed.hasPrefix("\\chapter")
            || trimmed.hasPrefix("\\part") || trimmed.hasPrefix("\\sectiontitle") {
            return true
        }
        return false
    }
}

extension LaTeXLiveStyler {
    static func styleLaTeXBlankLineBlock(
        in storage: NSTextStorage,
        nsString: NSString,
        fullLength: Int,
        lineRange: NSRange,
        isActiveLine: Bool,
        activeLineRange: NSRange,
        selectedRange: NSRange,
        docIndex: LaTeXDocumentIndex,
        typography: EditorTypographySettings,
        effectiveBaseSize: CGFloat,
        effectiveContainerWidth: CGFloat,
        prettyMode: Bool
    ) -> (nextIndex: Int, lineDelta: Int) {
        var blankRanges: [NSRange] = [lineRange]
        var anyActive = isActiveLine
        var scanIndex = NSMaxRange(lineRange)
        while scanIndex < fullLength {
            let nextLR = nsString.lineRange(for: NSRange(location: scanIndex, length: 0))
            let nextCR = MarkdownLiveStyler.strippedLineContentRange(nsString: nsString, lineRange: nextLR)
            let nextTrimmed = nsString.substring(with: nextCR).trimmingCharacters(in: .whitespaces)
            guard nextTrimmed.isEmpty else { break }
            if MarkdownLiveStyler.isLineActive(lineRange: nextLR, activeLineRange: activeLineRange, selectedRange: selectedRange) {
                anyActive = true
            }
            blankRanges.append(nextLR)
            scanIndex = NSMaxRange(nextLR)
        }
        let fullBlockRange = NSRange(location: lineRange.location, length: scanIndex - lineRange.location)
        if fullBlockRange.length > lineRange.length {
            LaTeXBlockStyleCache.resetAttributes(
                in: storage,
                range: NSRange(location: NSMaxRange(lineRange), length: fullBlockRange.length - lineRange.length)
            )
        }
        let isBlockActive = anyActive || NSIntersectionRange(fullBlockRange, selectedRange).length > 0
        let redundant = docIndex.isBlankBlockRedundant(range: fullBlockRange, in: nsString, fullLength: fullLength)
        let parskip = max(2.0, docIndex.effectiveParagraphSpacing(baseSize: effectiveBaseSize, fallback: typography))
        let lineH: CGFloat = (!isBlockActive && prettyMode)
            ? (redundant ? 0.5 : parskip)
            : max(parskip, round(effectiveBaseSize * 1.05))
        let pStyle = NSMutableParagraphStyle()
        pStyle.minimumLineHeight = lineH
        pStyle.maximumLineHeight = lineH
        pStyle.lineSpacing = 0
        pStyle.paragraphSpacing = 0
        pStyle.paragraphSpacingBefore = 0
        pStyle.tailIndent = effectiveContainerWidth
        storage.addAttributes([
            .font: NSFont.systemFont(ofSize: max(0.1, min(effectiveBaseSize, lineH * 0.7))),
            .paragraphStyle: pStyle
        ], range: fullBlockRange)
        if !isBlockActive && prettyMode && blankRanges.count > 1 {
            LaTeXBlockStyleCache.collapseInternalNewlines(in: storage, nsString: nsString, range: fullBlockRange)
        }
        LaTeXBlockStyleCache.pendingGlyphInvalidationRanges.append(fullBlockRange)
        return (scanIndex, blankRanges.count)
    }
}
