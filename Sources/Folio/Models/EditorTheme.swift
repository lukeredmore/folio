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

    // MARK: - Built-in Default Themes (Presets)
    private static func makeBuiltInPreset(
        id: String,
        engineID: UInt32,
        bodyFontFamily: String,
        headingWeightStyle: HeadingWeightStyle,
        italicH3: Bool = false,
        italicBlockquotes: Bool = false
    ) -> EditorTheme {
        let m = ot_engine_theme_metrics(engineID)
        var typo = EditorTypographySettings.default
        typo.maxColumnWidth = CGFloat(m.max_write_width)
        return EditorTheme(
            id: id,
            name: id,
            isBuiltIn: true,
            basePresetID: id,
            isDark: m.is_dark,
            editorBackground: ThemeColorRGBA(rgba: m.editor_bg),
            sidebarBackground: ThemeColorRGBA(rgba: m.sidebar_bg),
            text: ThemeColorRGBA(rgba: m.text_fg),
            heading: ThemeColorRGBA(rgba: m.heading_fg),
            secondaryText: ThemeColorRGBA(rgba: m.secondary_text_fg),
            link: ThemeColorRGBA(rgba: m.link_fg),
            codeBackground: ThemeColorRGBA(rgba: m.code_bg),
            inlineCode: ThemeColorRGBA(rgba: m.inline_code_fg),
            markdownToken: ThemeColorRGBA(rgba: m.markdown_token_fg),
            blockquoteText: ThemeColorRGBA(rgba: m.blockquote_fg),
            bodyFontFamily: bodyFontFamily,
            headingFontFamily: "",
            codeFontFamily: "",
            baseFontSize: CGFloat(m.base_font_size),
            headingWeightStyle: headingWeightStyle,
            italicH3: italicH3,
            italicBlockquotes: italicBlockquotes,
            typography: typo
        )
    }

    public static let daylight = makeBuiltInPreset(
        id: "Daylight",
        engineID: 0,
        bodyFontFamily: "",
        headingWeightStyle: .semibold
    )

    public static let midnight = makeBuiltInPreset(
        id: "Midnight",
        engineID: 1,
        bodyFontFamily: "",
        headingWeightStyle: .semibold
    )

    public static let parchment = makeBuiltInPreset(
        id: "Parchment",
        engineID: 2,
        bodyFontFamily: "PT Serif",
        headingWeightStyle: .bold,
        italicBlockquotes: true
    )

    public static let editorial = makeBuiltInPreset(
        id: "Editorial",
        engineID: 3,
        bodyFontFamily: "Charter",
        headingWeightStyle: .bold,
        italicBlockquotes: true
    )

    public static let classic = makeBuiltInPreset(
        id: "Classic",
        engineID: 4,
        bodyFontFamily: "Palatino",
        headingWeightStyle: .classic,
        italicH3: true
    )

    public static let modernist = makeBuiltInPreset(
        id: "Modernist",
        engineID: 5,
        bodyFontFamily: "Avenir Next",
        headingWeightStyle: .classic
    )

    public static let builtInThemes: [EditorTheme] = [
        .daylight,
        .midnight,
        .parchment,
        .editorial,
        .classic,
        .modernist
    ]

    public static var allCases: [EditorTheme] {
        builtInThemes
    }

    public static func builtInPreset(id: String) -> EditorTheme? {
        builtInThemes.first {
            $0.id.caseInsensitiveCompare(id) == .orderedSame ||
            $0.name.caseInsensitiveCompare(id) == .orderedSame
        }
    }

    /// If this theme is one of the preset-named themes (`Daylight`, `Midnight`, `Parchment`, `Editorial`, `Classic`, `Modernist`),
    /// returns its factory default preset definition.
    public var defaultPreset: EditorTheme? {
        Self.builtInPreset(id: id) ?? Self.builtInPreset(id: name)
    }

    /// True if this theme is one of the built-in preset-named themes.
    public var isPresetTheme: Bool {
        defaultPreset != nil
    }

    /// True if this theme is a preset-named theme whose settings differ from its factory default preset.
    public var isModifiedFromDefaultPreset: Bool {
        guard let preset = defaultPreset else { return false }
        return self != preset
    }

    // MARK: - Curated Font Choices
    public static let bodyFontChoices: [(label: String, value: String)] = [
        ("System Sans (SF Pro)", ""),
        ("System Serif (New York)", "System Serif"),
        ("System Monospace (SF Mono)", "System Mono"),
        ("Charter", "Charter"),
        ("PT Serif", "PT Serif"),
        ("Palatino", "Palatino"),
        ("Avenir Next", "Avenir Next"),
        ("Georgia", "Georgia"),
        ("Baskerville", "Baskerville"),
        ("Helvetica Neue", "Helvetica Neue"),
        ("Times New Roman", "Times New Roman"),
        ("Gill Sans", "Gill Sans"),
        ("Optima", "Optima"),
        ("Menlo", "Menlo")
    ]

    public static let headingFontChoices: [(label: String, value: String)] = [
        ("Same as Body", ""),
        ("System Sans (SF Pro)", "System Sans"),
        ("System Serif (New York)", "System Serif"),
        ("System Monospace (SF Mono)", "System Mono"),
        ("Charter", "Charter"),
        ("PT Serif", "PT Serif"),
        ("Palatino", "Palatino"),
        ("Avenir Next", "Avenir Next"),
        ("Georgia", "Georgia"),
        ("Baskerville", "Baskerville"),
        ("Helvetica Neue", "Helvetica Neue"),
        ("Times New Roman", "Times New Roman"),
        ("Gill Sans", "Gill Sans"),
        ("Optima", "Optima")
    ]

    public static let codeFontChoices: [(label: String, value: String)] = [
        ("System Monospace (SF Mono)", ""),
        ("Menlo", "Menlo"),
        ("SF Mono", "SF Mono"),
        ("Monaco", "Monaco"),
        ("Courier New", "Courier New"),
        ("Andale Mono", "Andale Mono"),
        ("JetBrains Mono", "JetBrains Mono"),
        ("Fira Code", "Fira Code")
    ]

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
    private static func resolveFont(
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

    // MARK: - Theme Mutation & Cloning Helpers
    /// Resets only the character/line/spacing settings back to `EditorTypographySettings.default`
    /// while preserving all theme colors and font selections.
    public mutating func resetTypographyToDefaults() {
        typography = .default
    }

    /// Creates a user-saved custom theme from the current theme settings.
    public func savedAsCustomTheme(name: String, id customID: String? = nil) -> EditorTheme {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = trimmedName.isEmpty ? "Custom Theme" : trimmedName
        let resolvedID = customID ?? "custom-\(UUID().uuidString)"
        var copy = self
        copy.id = resolvedID
        copy.name = resolvedName
        copy.isBuiltIn = false
        if copy.basePresetID == nil {
            copy.basePresetID = isBuiltIn ? self.id : "Daylight"
        }
        return copy
    }
}
