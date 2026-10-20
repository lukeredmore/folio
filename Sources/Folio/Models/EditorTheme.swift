import AppKit
import FolioEngineFFI
import SwiftUI

/// Serializable RGBA color in sRGB color space used by `EditorTheme`.
public struct ThemeColorRGBA: Equatable, Hashable, Codable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double
    public var a: Double

    public init(r: Double, g: Double, b: Double, a: Double = 1.0) {
        self.r = min(1.0, max(0.0, r))
        self.g = min(1.0, max(0.0, g))
        self.b = min(1.0, max(0.0, b))
        self.a = min(1.0, max(0.0, a))
    }

    public init(rgba: OTRgbaColor) {
        self.init(r: rgba.r, g: rgba.g, b: rgba.b, a: rgba.a)
    }

    public init(nsColor: NSColor) {
        let converted = nsColor.usingColorSpace(.sRGB)
            ?? nsColor.usingColorSpace(.deviceRGB)
            ?? nsColor
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 1
        converted.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        self.init(r: Double(red), g: Double(green), b: Double(blue), a: Double(alpha))
    }

    public init(color: Color) {
        self.init(nsColor: NSColor(color))
    }

    public init?(hex: String) {
        let trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        guard trimmed.count == 6 || trimmed.count == 8,
              let value = UInt64(trimmed, radix: 16) else {
            return nil
        }
        if trimmed.count == 6 {
            let r = Double((value >> 16) & 0xFF) / 255.0
            let g = Double((value >> 8) & 0xFF) / 255.0
            let b = Double(value & 0xFF) / 255.0
            self.init(r: r, g: g, b: b, a: 1.0)
        } else {
            let r = Double((value >> 24) & 0xFF) / 255.0
            let g = Double((value >> 16) & 0xFF) / 255.0
            let b = Double((value >> 8) & 0xFF) / 255.0
            let a = Double(value & 0xFF) / 255.0
            self.init(r: r, g: g, b: b, a: a)
        }
    }

    public var nsColor: NSColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    public var color: Color {
        Color(nsColor: nsColor)
    }

    public var hexString: String {
        let ri = Int(round(r * 255.0))
        let gi = Int(round(g * 255.0))
        let bi = Int(round(b * 255.0))
        let ai = Int(round(a * 255.0))
        if ai >= 255 {
            return String(format: "#%02X%02X%02X", ri, gi, bi)
        } else {
            return String(format: "#%02X%02X%02X%02X", ri, gi, bi, ai)
        }
    }
}

/// Controls how heading font weights are applied across H1–H6.
public enum HeadingWeightStyle: String, CaseIterable, Identifiable, Codable, Sendable {
    case semibold = "semibold"
    case bold = "bold"
    case classic = "classic"
    case regular = "regular"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .semibold: return "Semibold"
        case .bold: return "Bold"
        case .classic: return "Classic (H1–H3 Regular)"
        case .regular: return "Regular"
        }
    }
}

/// Extensible editor theme encapsulating colors, fonts, heading styles, and character/line/spacing settings.
/// Built-in presets (`Daylight`, `Midnight`, `Parchment`, `Editorial`, `Classic`, `Modernist`) act as default
/// themes, and any combination of fonts, colors, and typography settings can be customized and saved as a theme.
public struct EditorTheme: Identifiable, Equatable, Hashable, Codable, Sendable {
    public var id: String
    public var name: String
    public var isBuiltIn: Bool
    public var basePresetID: String?
    public var isDark: Bool

    // MARK: - Palette Colors
    public var editorBackground: ThemeColorRGBA
    public var sidebarBackground: ThemeColorRGBA
    public var text: ThemeColorRGBA
    public var heading: ThemeColorRGBA
    public var secondaryText: ThemeColorRGBA
    public var link: ThemeColorRGBA
    public var codeBackground: ThemeColorRGBA
    public var inlineCode: ThemeColorRGBA
    public var markdownToken: ThemeColorRGBA
    public var blockquoteText: ThemeColorRGBA

    // MARK: - Font & Heading Configuration
    /// Empty string or `"System Sans"` uses the system sans-serif font.
    public var bodyFontFamily: String
    /// Empty string or `"Same as Body"` inherits `bodyFontFamily`.
    public var headingFontFamily: String
    /// Empty string or `"System Mono"` uses the system monospaced font.
    public var codeFontFamily: String
    public var baseFontSize: CGFloat
    public var headingWeightStyle: HeadingWeightStyle
    public var italicH3: Bool
    public var italicBlockquotes: Bool

    // MARK: - Character, Line & Spacing Settings
    public var typography: EditorTypographySettings

    public init(
        id: String,
        name: String,
        isBuiltIn: Bool = false,
        basePresetID: String? = nil,
        isDark: Bool,
        editorBackground: ThemeColorRGBA,
        sidebarBackground: ThemeColorRGBA,
        text: ThemeColorRGBA,
        heading: ThemeColorRGBA,
        secondaryText: ThemeColorRGBA,
        link: ThemeColorRGBA,
        codeBackground: ThemeColorRGBA,
        inlineCode: ThemeColorRGBA,
        markdownToken: ThemeColorRGBA,
        blockquoteText: ThemeColorRGBA,
        bodyFontFamily: String = "",
        headingFontFamily: String = "",
        codeFontFamily: String = "",
        baseFontSize: CGFloat = 16.0,
        headingWeightStyle: HeadingWeightStyle = .semibold,
        italicH3: Bool = false,
        italicBlockquotes: Bool = false,
        typography: EditorTypographySettings = .default
    ) {
        self.id = id
        self.name = name
        self.isBuiltIn = isBuiltIn
        self.basePresetID = basePresetID
        self.isDark = isDark
        self.editorBackground = editorBackground
        self.sidebarBackground = sidebarBackground
        self.text = text
        self.heading = heading
        self.secondaryText = secondaryText
        self.link = link
        self.codeBackground = codeBackground
        self.inlineCode = inlineCode
        self.markdownToken = markdownToken
        self.blockquoteText = blockquoteText
        self.bodyFontFamily = bodyFontFamily
        self.headingFontFamily = headingFontFamily
        self.codeFontFamily = codeFontFamily
        self.baseFontSize = baseFontSize
        self.headingWeightStyle = headingWeightStyle
        self.italicH3 = italicH3
        self.italicBlockquotes = italicBlockquotes
        self.typography = typography
    }

    // MARK: - RawValue & Built-in Preset Compatibility
    public var rawValue: String {
        name
    }

    public init?(rawValue: String) {
        if let match = Self.builtInThemes.first(where: {
            $0.id.caseInsensitiveCompare(rawValue) == .orderedSame ||
            $0.name.caseInsensitiveCompare(rawValue) == .orderedSame
        }) {
            self = match
        } else {
            return nil
        }
    }

    public var engineThemeID: UInt32 {
        let key = (basePresetID ?? id).lowercased()
        switch key {
        case "daylight": return 0
        case "midnight": return 1
        case "parchment": return 2
        case "editorial": return 3
        case "classic": return 4
        case "modernist": return 5
        default: return isDark ? 1 : 0
        }
    }
}
