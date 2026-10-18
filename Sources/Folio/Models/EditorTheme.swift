import AppKit
import FolioEngineFFI
import SwiftUI

public enum EditorTheme: String, CaseIterable, Identifiable {
    case daylight = "Daylight"
    case midnight = "Midnight"
    case parchment = "Parchment"
    case editorial = "Editorial"
    case classic = "Classic"
    case modernist = "Modernist"

    public var id: String { rawValue }

    public var engineThemeID: UInt32 {
        switch self {
        case .daylight: return 0
        case .midnight: return 1
        case .parchment: return 2
        case .editorial: return 3
        case .classic: return 4
        case .modernist: return 5
        }
    }

    private var coreMetrics: OTThemeMetrics {
        ot_engine_theme_metrics(engineThemeID)
    }

    private static func nsColor(from rgba: OTRgbaColor) -> NSColor {
        NSColor(srgbRed: rgba.r, green: rgba.g, blue: rgba.b, alpha: rgba.a)
    }

    public var isDark: Bool {
        coreMetrics.is_dark
    }

    public var nsAppearance: NSAppearance? {
        NSAppearance(named: isDark ? .darkAqua : .aqua)
    }

    public var colorScheme: ColorScheme {
        isDark ? .dark : .light
    }

    // Main editor background
    public var editorBackgroundNSColor: NSColor {
        Self.nsColor(from: coreMetrics.editor_bg)
    }

    public var editorBackgroundColor: Color {
        Color(nsColor: editorBackgroundNSColor)
    }

    // Sidebar background
    public var sidebarBackgroundNSColor: NSColor {
        Self.nsColor(from: coreMetrics.sidebar_bg)
    }

    public var sidebarBackgroundColor: Color {
        Color(nsColor: sidebarBackgroundNSColor)
    }

    // Primary text color
    public var textNSColor: NSColor {
        Self.nsColor(from: coreMetrics.text_fg)
    }

    public var textColor: Color {
        Color(nsColor: textNSColor)
    }

    // Heading color
    public var headingNSColor: NSColor {
        Self.nsColor(from: coreMetrics.heading_fg)
    }

    // Secondary / control text color
    public var secondaryTextNSColor: NSColor {
        Self.nsColor(from: coreMetrics.secondary_text_fg)
    }

    public var secondaryTextColor: Color {
        Color(nsColor: secondaryTextNSColor)
    }

    // Link & accent color
    public var linkNSColor: NSColor {
        Self.nsColor(from: coreMetrics.link_fg)
    }

    public var linkColor: Color {
        Color(nsColor: linkNSColor)
    }

    // Code block & inline code background
    public var codeBackgroundNSColor: NSColor {
        Self.nsColor(from: coreMetrics.code_bg)
    }

    // Inline code foreground
    public var inlineCodeNSColor: NSColor {
        Self.nsColor(from: coreMetrics.inline_code_fg)
    }

    // Syntax token marker color (when revealed on active line)
    public var markdownTokenNSColor: NSColor {
        Self.nsColor(from: coreMetrics.markdown_token_fg)
    }

    // Blockquote accent & text color
    public var blockquoteTextNSColor: NSColor {
        Self.nsColor(from: coreMetrics.blockquote_fg)
    }

    public var borderColor: Color {
        isDark ? Color.white.opacity(0.09) : Color.black.opacity(0.08)
    }

    // Base font size per theme
    public var baseFontSize: CGFloat {
        CGFloat(coreMetrics.base_font_size)
    }

    // Max content width
    public var maxWriteWidth: CGFloat {
        CGFloat(coreMetrics.max_write_width)
    }

    public func bodyFont(size: CGFloat, bold: Bool = false, italic: Bool = false, semibold: Bool = false) -> NSFont {
        let familyCandidates: [String]
        switch self {
        case .daylight, .midnight:
            familyCandidates = [] // system sans-serif
        case .parchment:
            familyCandidates = ["PT Serif", "Georgia", "Times New Roman"]
        case .editorial:
            familyCandidates = ["Charter", "Georgia", "Palatino"]
        case .classic:
            familyCandidates = ["Palatino", "Baskerville", "Times New Roman"]
        case .modernist:
            familyCandidates = ["Avenir Next", "Century Gothic", "Helvetica Neue"]
        }

        if familyCandidates.isEmpty {
            let weight: NSFont.Weight = semibold ? .semibold : (bold ? .bold : .regular)
            let sysFont = NSFont.systemFont(ofSize: size, weight: weight)
            if italic {
                let desc = sysFont.fontDescriptor.withSymbolicTraits(
                    sysFont.fontDescriptor.symbolicTraits.union(.italic)
                )
                return NSFont(descriptor: desc, size: size) ?? NSFontManager.shared.convert(sysFont, toHaveTrait: .italicFontMask)
            }
            return sysFont
        }

        var baseFont: NSFont?
        for family in familyCandidates {
            if let f = NSFont(name: family, size: size) {
                baseFont = f
                break
            }
        }
        guard let resolvedFont = baseFont else {
            return NSFont.systemFont(ofSize: size, weight: semibold ? .semibold : (bold ? .bold : .regular))
        }

        var traits: NSFontTraitMask = []
        if bold || semibold { traits.insert(.boldFontMask) }
        if italic { traits.insert(.italicFontMask) }

        if !traits.isEmpty {
            return NSFontManager.shared.convert(resolvedFont, toHaveTrait: traits)
        }
        return resolvedFont
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
        let useSemibold = (self == .daylight || self == .midnight)
        let isBold = !useSemibold && ((self != .classic && self != .modernist) || level >= 4)
        let isItalic = (self == .classic && level == 3)
        return bodyFont(size: size, bold: isBold, italic: isItalic, semibold: useSemibold)
    }

    public func codeFont(size: CGFloat? = nil) -> NSFont {
        let targetSize = size ?? round(baseFontSize * 0.88)
        return NSFont.monospacedSystemFont(ofSize: targetSize, weight: .regular)
    }
}
