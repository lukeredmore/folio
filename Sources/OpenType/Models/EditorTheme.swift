import AppKit
import SwiftUI

public enum EditorTheme: String, CaseIterable, Identifiable {
    case daylight = "Daylight"
    case midnight = "Midnight"
    case parchment = "Parchment"
    case editorial = "Editorial"
    case classic = "Classic"
    case modernist = "Modernist"

    public var id: String { rawValue }

    public var isDark: Bool {
        self == .midnight
    }

    public var nsAppearance: NSAppearance? {
        NSAppearance(named: isDark ? .darkAqua : .aqua)
    }

    public var colorScheme: ColorScheme {
        isDark ? .dark : .light
    }

    // Main editor background
    public var editorBackgroundNSColor: NSColor {
        switch self {
        case .daylight: return NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1.0) // #ffffff
        case .midnight: return NSColor(srgbRed: 0.212, green: 0.231, blue: 0.251, alpha: 1.0) // #363B40
        case .parchment: return NSColor(srgbRed: 0.953, green: 0.949, blue: 0.933, alpha: 1.0) // #f3f2ee
        case .editorial: return NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1.0) // #ffffff
        case .classic: return NSColor(srgbRed: 0.996, green: 0.996, blue: 0.996, alpha: 1.0) // #fefefe
        case .modernist: return NSColor(srgbRed: 0.988, green: 0.988, blue: 0.988, alpha: 1.0) // #fcfcfc
        }
    }

    public var editorBackgroundColor: Color {
        Color(nsColor: editorBackgroundNSColor)
    }

    // Sidebar background
    public var sidebarBackgroundNSColor: NSColor {
        switch self {
        case .daylight: return NSColor(srgbRed: 0.980, green: 0.980, blue: 0.980, alpha: 1.0) // #fafafa
        case .midnight: return NSColor(srgbRed: 0.180, green: 0.188, blue: 0.200, alpha: 1.0) // #2E3033
        case .parchment: return NSColor(srgbRed: 0.922, green: 0.918, blue: 0.898, alpha: 1.0) // #ebeae5
        case .editorial: return NSColor(srgbRed: 0.976, green: 0.976, blue: 0.976, alpha: 1.0) // #f9f9f9
        case .classic: return NSColor(srgbRed: 0.969, green: 0.969, blue: 0.969, alpha: 1.0) // #f7f7f7
        case .modernist: return NSColor(srgbRed: 0.953, green: 0.953, blue: 0.953, alpha: 1.0) // #f3f3f3
        }
    }

    public var sidebarBackgroundColor: Color {
        Color(nsColor: sidebarBackgroundNSColor)
    }

    // Primary text color
    public var textNSColor: NSColor {
        switch self {
        case .daylight: return NSColor(srgbRed: 0.20, green: 0.20, blue: 0.20, alpha: 1.0) // #333333
        case .midnight: return NSColor(srgbRed: 0.722, green: 0.749, blue: 0.776, alpha: 1.0) // #B8BFC6
        case .parchment: return NSColor(srgbRed: 0.122, green: 0.035, blue: 0.035, alpha: 1.0) // #1f0909
        case .editorial: return NSColor(srgbRed: 0.20, green: 0.20, blue: 0.20, alpha: 1.0) // #333333
        case .classic: return NSColor(srgbRed: 0.20, green: 0.20, blue: 0.20, alpha: 1.0) // #333333
        case .modernist: return NSColor(srgbRed: 0.067, green: 0.067, blue: 0.067, alpha: 1.0) // #111111
        }
    }

    public var textColor: Color {
        Color(nsColor: textNSColor)
    }

    // Heading color
    public var headingNSColor: NSColor {
        switch self {
        case .midnight: return NSColor(srgbRed: 0.871, green: 0.871, blue: 0.871, alpha: 1.0) // #DEDEDE
        case .parchment: return NSColor(srgbRed: 0.122, green: 0.035, blue: 0.035, alpha: 1.0)
        default: return NSColor(srgbRed: 0.067, green: 0.067, blue: 0.067, alpha: 1.0)
        }
    }

    // Secondary / control text color
    public var secondaryTextNSColor: NSColor {
        switch self {
        case .midnight: return NSColor(srgbRed: 0.54, green: 0.57, blue: 0.60, alpha: 1.0)
        case .parchment: return NSColor(srgbRed: 0.267, green: 0.267, blue: 0.267, alpha: 1.0) // #444
        default: return NSColor(srgbRed: 0.467, green: 0.467, blue: 0.467, alpha: 1.0) // #777
        }
    }

    public var secondaryTextColor: Color {
        Color(nsColor: secondaryTextNSColor)
    }

    // Link & accent color
    public var linkNSColor: NSColor {
        switch self {
        case .daylight: return NSColor(srgbRed: 0.255, green: 0.514, blue: 0.769, alpha: 1.0) // #4183C4
        case .midnight: return NSColor(srgbRed: 0.878, green: 0.698, blue: 0.494, alpha: 1.0) // #e0b27e
        case .parchment: return NSColor(srgbRed: 0.024, green: 0.333, blue: 0.533, alpha: 1.0) // #065588
        case .editorial: return NSColor(srgbRed: 0.0, green: 0.463, blue: 0.875, alpha: 1.0) // #0076df
        case .classic: return NSColor(srgbRed: 0.165, green: 0.416, blue: 0.659, alpha: 1.0)
        case .modernist: return NSColor(srgbRed: 0.15, green: 0.35, blue: 0.60, alpha: 1.0)
        }
    }

    public var linkColor: Color {
        Color(nsColor: linkNSColor)
    }

    // Code block & inline code background
    public var codeBackgroundNSColor: NSColor {
        switch self {
        case .daylight: return NSColor(srgbRed: 0.973, green: 0.973, blue: 0.973, alpha: 1.0) // #f8f8f8
        case .midnight: return NSColor(srgbRed: 0.157, green: 0.173, blue: 0.192, alpha: 1.0) // #282c31
        case .parchment: return NSColor(srgbRed: 0.902, green: 0.898, blue: 0.878, alpha: 1.0) // #e6e5e0
        case .editorial: return NSColor(srgbRed: 0.965, green: 0.965, blue: 0.965, alpha: 1.0)
        case .classic: return NSColor(srgbRed: 0.975, green: 0.975, blue: 0.975, alpha: 1.0)
        case .modernist: return NSColor(srgbRed: 0.955, green: 0.955, blue: 0.955, alpha: 1.0)
        }
    }

    // Inline code foreground
    public var inlineCodeNSColor: NSColor {
        switch self {
        case .daylight: return NSColor(srgbRed: 0.83, green: 0.18, blue: 0.30, alpha: 1.0)
        case .midnight: return NSColor(srgbRed: 0.596, green: 0.765, blue: 0.475, alpha: 1.0)
        case .parchment: return NSColor(srgbRed: 0.45, green: 0.15, blue: 0.15, alpha: 1.0)
        default: return NSColor(srgbRed: 0.75, green: 0.22, blue: 0.28, alpha: 1.0)
        }
    }

    // Syntax token marker color (when revealed on active line)
    public var markdownTokenNSColor: NSColor {
        switch self {
        case .midnight: return NSColor(srgbRed: 0.47, green: 0.53, blue: 0.60, alpha: 1.0)
        default: return NSColor(srgbRed: 0.58, green: 0.62, blue: 0.67, alpha: 1.0)
        }
    }

    // Blockquote accent & text color
    public var blockquoteTextNSColor: NSColor {
        switch self {
        case .daylight: return NSColor(srgbRed: 0.467, green: 0.467, blue: 0.467, alpha: 1.0) // #777777
        case .midnight: return NSColor(srgbRed: 0.60, green: 0.63, blue: 0.66, alpha: 1.0)
        default: return secondaryTextNSColor
        }
    }

    public var borderColor: Color {
        isDark ? Color.white.opacity(0.09) : Color.black.opacity(0.08)
    }

    // Base font size per theme
    public var baseFontSize: CGFloat {
        switch self {
        case .daylight: return 16.0
        case .midnight: return 16.0
        case .parchment: return 16.0
        case .editorial: return 17.5
        case .classic: return 18.0
        case .modernist: return 16.0
        }
    }

    // Max content width
    public var maxWriteWidth: CGFloat {
        switch self {
        case .daylight: return 860
        case .midnight: return 860
        case .parchment: return 760
        case .editorial: return 840
        case .classic: return 920
        case .modernist: return 880
        }
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
