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
        let lightMetrics = ot_engine_theme_metrics(engineID, false)
        let darkMetrics = ot_engine_theme_metrics(engineID, true)
        var typo = EditorTypographySettings.default
        typo.maxColumnWidth = CGFloat(lightMetrics.max_write_width)
        return EditorTheme(
            id: id,
            name: id,
            isBuiltIn: true,
            basePresetID: id,
            isDark: false,
            usesSeparateDarkPalette: true,
            lightPalette: ThemeColorPalette(metrics: lightMetrics),
            darkPalette: ThemeColorPalette(metrics: darkMetrics),
            bodyFontFamily: bodyFontFamily,
            headingFontFamily: "",
            codeFontFamily: "",
            baseFontSize: CGFloat(lightMetrics.base_font_size),
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

    public static let parchment = makeBuiltInPreset(
        id: "Parchment",
        engineID: 1,
        bodyFontFamily: "PT Serif",
        headingWeightStyle: .bold,
        italicBlockquotes: true
    )

    public static let editorial = makeBuiltInPreset(
        id: "Editorial",
        engineID: 2,
        bodyFontFamily: "Charter",
        headingWeightStyle: .bold,
        italicBlockquotes: true
    )

    public static let classic = makeBuiltInPreset(
        id: "Classic",
        engineID: 3,
        bodyFontFamily: "Palatino",
        headingWeightStyle: .classic,
        italicH3: true
    )

    public static let modernist = makeBuiltInPreset(
        id: "Modernist",
        engineID: 4,
        bodyFontFamily: "Avenir Next",
        headingWeightStyle: .classic
    )

    public static let builtInThemes: [EditorTheme] = [
        .daylight,
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
            $0.id.caseInsensitiveCompare(id) == .orderedSame || $0.name.caseInsensitiveCompare(id) == .orderedSame
        }
    }

    /// If this theme is one of the preset-named themes (`Daylight`, `Parchment`, `Editorial`, `Classic`, `Modernist`),
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
        return !hasSameDefinition(as: preset)
    }

    // MARK: - Curated & System Font Choices
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

    /// All non-hidden font families installed on the system, sorted alphabetically.
    public static var allSystemFontFamilies: [String] {
        let families = NSFontManager.shared.availableFontFamilies
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix(".") }
        return Array(Set(families)).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    /// System font families not already present in the given curated option list.
    public static func additionalSystemFontFamilies(excluding options: [(label: String, value: String)]) -> [String] {
        let curated = Set(options.map { $0.value.lowercased() })
        return allSystemFontFamilies.filter { !curated.contains($0.lowercased()) }
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
