import AppKit
import SwiftUI

extension EditorTheme {
    // MARK: - Appearance & Color Accessors
    public var nsAppearance: NSAppearance? {
        NSAppearance(named: isDark ? .darkAqua : .aqua)
    }

    public var colorScheme: ColorScheme {
        isDark ? .dark : .light
    }

    public var editorBackgroundNSColor: NSColor {
        get { editorBackground.nsColor }
        set { editorBackground = ThemeColorRGBA(nsColor: newValue) }
    }

    public var editorBackgroundColor: Color {
        get { editorBackground.color }
        set { editorBackground = ThemeColorRGBA(color: newValue) }
    }

    public var sidebarBackgroundNSColor: NSColor {
        get { sidebarBackground.nsColor }
        set { sidebarBackground = ThemeColorRGBA(nsColor: newValue) }
    }

    public var sidebarBackgroundColor: Color {
        get { sidebarBackground.color }
        set { sidebarBackground = ThemeColorRGBA(color: newValue) }
    }

    public var textNSColor: NSColor {
        get { text.nsColor }
        set { text = ThemeColorRGBA(nsColor: newValue) }
    }

    public var textColor: Color {
        get { text.color }
        set { text = ThemeColorRGBA(color: newValue) }
    }

    public var headingNSColor: NSColor {
        get { heading.nsColor }
        set { heading = ThemeColorRGBA(nsColor: newValue) }
    }

    public var headingColor: Color {
        get { heading.color }
        set { heading = ThemeColorRGBA(color: newValue) }
    }

    public var secondaryTextNSColor: NSColor {
        get { secondaryText.nsColor }
        set { secondaryText = ThemeColorRGBA(nsColor: newValue) }
    }

    public var secondaryTextColor: Color {
        get { secondaryText.color }
        set { secondaryText = ThemeColorRGBA(color: newValue) }
    }

    public var linkNSColor: NSColor {
        get { link.nsColor }
        set { link = ThemeColorRGBA(nsColor: newValue) }
    }

    public var linkColor: Color {
        get { link.color }
        set { link = ThemeColorRGBA(color: newValue) }
    }

    public var codeBackgroundNSColor: NSColor {
        get { codeBackground.nsColor }
        set { codeBackground = ThemeColorRGBA(nsColor: newValue) }
    }

    public var codeBackgroundColor: Color {
        get { codeBackground.color }
        set { codeBackground = ThemeColorRGBA(color: newValue) }
    }

    public var inlineCodeNSColor: NSColor {
        get { inlineCode.nsColor }
        set { inlineCode = ThemeColorRGBA(nsColor: newValue) }
    }

    public var inlineCodeColor: Color {
        get { inlineCode.color }
        set { inlineCode = ThemeColorRGBA(color: newValue) }
    }

    public var markdownTokenNSColor: NSColor {
        get { markdownToken.nsColor }
        set { markdownToken = ThemeColorRGBA(nsColor: newValue) }
    }

    public var markdownTokenColor: Color {
        get { markdownToken.color }
        set { markdownToken = ThemeColorRGBA(color: newValue) }
    }

    public var blockquoteTextNSColor: NSColor {
        get { blockquoteText.nsColor }
        set { blockquoteText = ThemeColorRGBA(nsColor: newValue) }
    }

    public var blockquoteTextColor: Color {
        get { blockquoteText.color }
        set { blockquoteText = ThemeColorRGBA(color: newValue) }
    }

    public var borderColor: Color {
        isDark ? Color.white.opacity(0.09) : Color.black.opacity(0.08)
    }

    public var maxWriteWidth: CGFloat {
        get { typography.maxColumnWidth }
        set { typography.maxColumnWidth = newValue }
    }

    // MARK: - Font Resolution
    static func resolveFont(
        familySpec: String,
        size: CGFloat,
        bold: Bool,
        italic: Bool,
        semibold: Bool
    ) -> NSFont {
        let trimmed = familySpec.trimmingCharacters(in: .whitespacesAndNewlines)
        let weight: NSFont.Weight = semibold ? .semibold : (bold ? .bold : .regular)

        if trimmed.isEmpty || trimmed == "System Sans" {
            let sysFont = NSFont.systemFont(ofSize: size, weight: weight)
            if italic {
                let desc = sysFont.fontDescriptor.withSymbolicTraits(
                    sysFont.fontDescriptor.symbolicTraits.union(.italic)
                )
                return NSFont(descriptor: desc, size: size)
                    ?? NSFontManager.shared.convert(sysFont, toHaveTrait: .italicFontMask)
            }
            return sysFont
        }

        if trimmed == "System Serif" {
            let sysFont = NSFont.systemFont(ofSize: size, weight: weight)
            if let serifDesc = sysFont.fontDescriptor.withDesign(.serif) {
                let finalDesc = italic
                    ? serifDesc.withSymbolicTraits(serifDesc.symbolicTraits.union(.italic))
                    : serifDesc
                if let font = NSFont(descriptor: finalDesc, size: size) {
                    return font
                }
            }
        }

        if trimmed == "System Mono" {
            let mono = NSFont.monospacedSystemFont(ofSize: size, weight: weight)
            if italic {
                return NSFontManager.shared.convert(mono, toHaveTrait: .italicFontMask)
            }
            return mono
        }

        let familyCandidates: [String]
        switch trimmed {
        case "PT Serif":
            familyCandidates = ["PT Serif", "Georgia", "Times New Roman"]
        case "Charter":
            familyCandidates = ["Charter", "Georgia", "Palatino"]
        case "Palatino":
            familyCandidates = ["Palatino", "Baskerville", "Times New Roman"]
        case "Avenir Next":
            familyCandidates = ["Avenir Next", "Century Gothic", "Helvetica Neue"]
        default:
            familyCandidates = [trimmed]
        }

        var baseFont: NSFont?
        for family in familyCandidates {
            if let f = NSFont(name: family, size: size) {
                baseFont = f
                break
            }
        }
        guard let resolvedFont = baseFont else {
            let fallback = NSFont.systemFont(ofSize: size, weight: weight)
            if italic {
                return NSFontManager.shared.convert(fallback, toHaveTrait: .italicFontMask)
            }
            return fallback
        }

        var traits: NSFontTraitMask = []
        if bold || semibold { traits.insert(.boldFontMask) }
        if italic { traits.insert(.italicFontMask) }

        if !traits.isEmpty {
            return NSFontManager.shared.convert(resolvedFont, toHaveTrait: traits)
        }
        return resolvedFont
    }

    public func bodyFont(size: CGFloat, bold: Bool = false, italic: Bool = false, semibold: Bool = false) -> NSFont {
        Self.resolveFont(
            familySpec: bodyFontFamily,
            size: size,
            bold: bold,
            italic: italic,
            semibold: semibold
        )
    }

    public func headingFont(level: Int, scale: CGFloat = 1.0) -> NSFont {
        let multipliers: [Int: CGFloat] = [
            1: 1.95,
            2: 1.52,
            3: 1.26,
            4: 1.10,
            5: 1.00,
            6: 0.92
        ]
        let mult = multipliers[level] ?? 1.0
        let size = round(baseFontSize * scale * mult)

        let useSemibold: Bool
        let isBold: Bool
        switch headingWeightStyle {
        case .semibold:
            useSemibold = true
            isBold = false
        case .bold:
            useSemibold = false
            isBold = true
        case .classic:
            useSemibold = false
            isBold = (level >= 4)
        case .regular:
            useSemibold = false
            isBold = false
        }
        let isItalic = italicH3 && (level == 3)
        let targetFamily = headingFontFamily.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? bodyFontFamily
            : headingFontFamily

        return Self.resolveFont(
            familySpec: targetFamily,
            size: size,
            bold: isBold,
            italic: isItalic,
            semibold: useSemibold
        )
    }

    public func codeFont(size: CGFloat? = nil) -> NSFont {
        let targetSize = size ?? round(baseFontSize * 0.88)
        let trimmed = codeFontFamily.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "System Mono" {
            return NSFont.monospacedSystemFont(ofSize: targetSize, weight: .regular)
        }
        if let customFont = NSFont(name: trimmed, size: targetSize) {
            return customFont
        }
        return NSFont.monospacedSystemFont(ofSize: targetSize, weight: .regular)
    }
}
