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
        let converted =
            nsColor.usingColorSpace(.sRGB)
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
            let value = UInt64(trimmed, radix: 16)
        else {
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

/// Color swatch palette for one appearance variant (light or dark) of an `EditorTheme`.
public struct ThemeColorPalette: Equatable, Hashable, Codable, Sendable {
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

    public init(metrics m: OTThemeMetrics) {
        self.editorBackground = ThemeColorRGBA(rgba: m.editor_bg)
        self.sidebarBackground = ThemeColorRGBA(rgba: m.sidebar_bg)
        self.text = ThemeColorRGBA(rgba: m.text_fg)
        self.heading = ThemeColorRGBA(rgba: m.heading_fg)
        self.secondaryText = ThemeColorRGBA(rgba: m.secondary_text_fg)
        self.link = ThemeColorRGBA(rgba: m.link_fg)
        self.codeBackground = ThemeColorRGBA(rgba: m.code_bg)
        self.inlineCode = ThemeColorRGBA(rgba: m.inline_code_fg)
        self.markdownToken = ThemeColorRGBA(rgba: m.markdown_token_fg)
        self.blockquoteText = ThemeColorRGBA(rgba: m.blockquote_fg)
    }
}

/// App-wide appearance mode selectable under the Themes menu.
public enum EditorAppearanceMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case system = "system"
    case light = "light"
    case dark = "dark"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    public var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    public func resolvedIsDark(systemIsDark: Bool) -> Bool {
        switch self {
        case .light: return false
        case .dark: return true
        case .system: return systemIsDark
        }
    }

    @MainActor
    public static var currentSystemIsDark: Bool {
        let appearance = NSApp?.effectiveAppearance ?? NSAppearance.currentDrawing()
        return appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
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

/// Extensible editor theme encapsulating light and dark color swatch variants, fonts, heading styles,
/// and character/line/spacing settings.
public struct EditorTheme: Identifiable, Equatable, Hashable, Codable, Sendable {
    public var id: String
    public var name: String
    public var isBuiltIn: Bool
    public var basePresetID: String?
    public var isDark: Bool
    /// When true, the theme switches between `lightPalette` and `darkPalette` based on the app appearance.
    /// When false, `lightPalette` is used in both light and dark mode.
    public var usesSeparateDarkPalette: Bool
    public var lightPalette: ThemeColorPalette
    public var darkPalette: ThemeColorPalette

    // MARK: - Active Palette Colors
    public var activePalette: ThemeColorPalette {
        get { (isDark && usesSeparateDarkPalette) ? darkPalette : lightPalette }
        set {
            if isDark && usesSeparateDarkPalette {
                darkPalette = newValue
            } else {
                lightPalette = newValue
            }
        }
    }

    public var editorBackground: ThemeColorRGBA {
        get { activePalette.editorBackground }
        set { activePalette.editorBackground = newValue }
    }
    public var sidebarBackground: ThemeColorRGBA {
        get { activePalette.sidebarBackground }
        set { activePalette.sidebarBackground = newValue }
    }
    public var text: ThemeColorRGBA {
        get { activePalette.text }
        set { activePalette.text = newValue }
    }
    public var heading: ThemeColorRGBA {
        get { activePalette.heading }
        set { activePalette.heading = newValue }
    }
    public var secondaryText: ThemeColorRGBA {
        get { activePalette.secondaryText }
        set { activePalette.secondaryText = newValue }
    }
    public var link: ThemeColorRGBA {
        get { activePalette.link }
        set { activePalette.link = newValue }
    }
    public var codeBackground: ThemeColorRGBA {
        get { activePalette.codeBackground }
        set { activePalette.codeBackground = newValue }
    }
    public var inlineCode: ThemeColorRGBA {
        get { activePalette.inlineCode }
        set { activePalette.inlineCode = newValue }
    }
    public var markdownToken: ThemeColorRGBA {
        get { activePalette.markdownToken }
        set { activePalette.markdownToken = newValue }
    }
    public var blockquoteText: ThemeColorRGBA {
        get { activePalette.blockquoteText }
        set { activePalette.blockquoteText = newValue }
    }

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
}

extension EditorTheme {
    public func withAppearance(isDark: Bool) -> EditorTheme {
        var copy = self
        copy.isDark = isDark
        return copy
    }

    /// Compares theme definitions independent of the active runtime `isDark` state.
    public func hasSameDefinition(as other: EditorTheme) -> Bool {
        withAppearance(isDark: false) == other.withAppearance(isDark: false)
    }

    // MARK: - RawValue & Built-in Preset Compatibility
    public var rawValue: String {
        name
    }

    public init?(rawValue: String) {
        if let match = Self.builtInThemes.first(where: {
            $0.id.caseInsensitiveCompare(rawValue) == .orderedSame || $0.name.caseInsensitiveCompare(rawValue) == .orderedSame
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
        case "parchment": return 1
        case "editorial": return 2
        case "classic": return 3
        case "modernist": return 4
        default: return 0
        }
    }
}
