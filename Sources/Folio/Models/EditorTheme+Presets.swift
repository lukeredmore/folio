import AppKit
import FolioEngineFFI
import SwiftUI

extension EditorTheme {
    // MARK: - Built-in Default Themes (Presets)
    static func makeBuiltInPreset(
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
