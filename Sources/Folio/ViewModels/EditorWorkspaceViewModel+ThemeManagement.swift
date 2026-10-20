import AppKit
import Foundation
import SwiftUI

extension EditorWorkspaceViewModel {

    // MARK: - Theme & Typography Management

    public static func mergeAvailableThemes(customThemes: [EditorTheme]) -> [EditorTheme] {
        let presets = EditorTheme.builtInThemes.map { preset -> EditorTheme in
            if let savedOverride = customThemes.first(where: {
                $0.id.caseInsensitiveCompare(preset.id) == .orderedSame ||
                $0.name.caseInsensitiveCompare(preset.name) == .orderedSame
            }) {
                return savedOverride
            }
            return preset
        }
        let nonPresetCustom = customThemes.filter { custom in
            !EditorTheme.builtInThemes.contains(where: {
                $0.id.caseInsensitiveCompare(custom.id) == .orderedSame ||
                $0.name.caseInsensitiveCompare(custom.name) == .orderedSame
            })
        }
        return presets + nonPresetCustom
    }

    public var availableThemes: [EditorTheme] {
        Self.mergeAvailableThemes(customThemes: customThemes)
    }

    func persistActiveThemeState() {
        userDefaults.set(theme.rawValue, forKey: Self.themeDefaultsKey)
        if let encodedTheme = try? JSONEncoder().encode(theme) {
            userDefaults.set(encodedTheme, forKey: Self.activeThemeDataDefaultsKey)
        }
        if let encodedTypo = try? JSONEncoder().encode(typography) {
            userDefaults.set(encodedTypo, forKey: Self.typographyDefaultsKey)
        }
    }

    /// Returns the unmodified preset or saved custom theme matching the active theme's ID or name.
    public var savedReferenceForCurrentTheme: EditorTheme? {
        availableThemes.first {
            $0.id == theme.id || $0.name.caseInsensitiveCompare(theme.name) == .orderedSame
        }
    }

    /// True when the active theme has unsaved font, color, or spacing modifications relative to its saved definition.
    public var isCurrentThemeModified: Bool {
        guard let reference = savedReferenceForCurrentTheme else { return true }
        return reference != theme
    }

    /// If the active theme is one of the built-in preset-named themes (`Daylight`, `Midnight`, `Parchment`, `Editorial`, `Classic`, `Modernist`),
    /// returns its factory default definition.
    public var defaultPresetForCurrentTheme: EditorTheme? {
        theme.defaultPreset
    }

    /// True when the active theme is a preset-named theme and differs from its factory default (either via unsaved edits or saved modifications).
    public var canResetCurrentPresetToDefault: Bool {
        guard let factoryDefault = defaultPresetForCurrentTheme else { return false }
        return theme != factoryDefault
    }

    /// Switches to a built-in or custom saved theme by value.
    public func selectTheme(_ selected: EditorTheme) {
        theme = selected
    }

    /// Switches to a built-in or custom saved theme by its ID or name.
    public func selectTheme(id: String) {
        if let found = availableThemes.first(where: {
            $0.id == id || $0.name.caseInsensitiveCompare(id) == .orderedSame
        }) {
            theme = found
        }
    }

    /// Saves all current fonts, colors, and character/line/spacing settings in-place to the currently active theme
    /// (works for both preset-named themes and user-created custom themes).
    @discardableResult
    public func saveCurrentTheme() -> EditorTheme {
        saveCurrentTheme(as: theme.name)
    }

    /// Saves all current fonts, colors, and character/line/spacing settings under `name`.
    /// If `name` matches a built-in preset name, saves the modified preset in-place while retaining its preset identity.
    /// If a custom theme with the same name already exists, it is updated in-place; otherwise a new custom theme is created.
    @discardableResult
    public func saveCurrentTheme(as name: String) -> EditorTheme {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = trimmed.isEmpty ? "Custom Theme" : trimmed

        if let preset = EditorTheme.builtInPreset(id: resolvedName) {
            var savedPreset = theme
            savedPreset.id = preset.id
            savedPreset.name = preset.name
            savedPreset.isBuiltIn = true
            savedPreset.basePresetID = preset.id

            if savedPreset == preset {
                customThemes.removeAll {
                    $0.id.caseInsensitiveCompare(preset.id) == .orderedSame ||
                    $0.name.caseInsensitiveCompare(preset.name) == .orderedSame
                }
            } else if let existingIdx = customThemes.firstIndex(where: {
                $0.id.caseInsensitiveCompare(preset.id) == .orderedSame ||
                $0.name.caseInsensitiveCompare(preset.name) == .orderedSame
            }) {
                customThemes[existingIdx] = savedPreset
            } else {
                customThemes.append(savedPreset)
            }
            theme = savedPreset
            return savedPreset
        }

        if let existingIdx = customThemes.firstIndex(where: {
            $0.name.caseInsensitiveCompare(resolvedName) == .orderedSame ||
            (!theme.isBuiltIn && $0.id == theme.id && $0.name.caseInsensitiveCompare(resolvedName) == .orderedSame)
        }) {
            let existingID = customThemes[existingIdx].id
            let updated = theme.savedAsCustomTheme(name: resolvedName, id: existingID)
            customThemes[existingIdx] = updated
            theme = updated
            return updated
        } else {
            let created = theme.savedAsCustomTheme(name: resolvedName)
            customThemes.append(created)
            theme = created
            return created
        }
    }

    /// Saves the currently selected theme in-place with any modified fonts, colors, or spacing settings.
    public func updateCurrentCustomTheme() {
        saveCurrentTheme()
    }

    /// Deletes a user-saved custom theme by ID and falls back to its base preset (or Daylight) if it was active.
    public func deleteCustomTheme(id: String) {
        let wasActive = (theme.id == id)
        let fallbackPresetID = customThemes.first(where: { $0.id == id })?.basePresetID ?? theme.basePresetID
        customThemes.removeAll { $0.id == id }
        if wasActive {
            let targetID = fallbackPresetID ?? "Daylight"
            theme = availableThemes.first(where: { $0.id.caseInsensitiveCompare(targetID) == .orderedSame })
                ?? EditorTheme.builtInPreset(id: targetID)
                ?? .daylight
        }
    }

    /// Reverts unsaved changes on the current theme back to its last saved definition (or built-in preset).
    public func resetCurrentTheme() {
        if let reference = savedReferenceForCurrentTheme {
            theme = reference
        } else if let baseID = theme.basePresetID, let preset = EditorTheme.builtInPreset(id: baseID) {
            theme = preset
        } else {
            theme = .daylight
        }
    }

    /// Resets a preset-named theme back to its factory default definition, clearing any saved modifications for that preset.
    public func resetCurrentThemeToDefault() {
        guard let factoryDefault = defaultPresetForCurrentTheme else {
            resetCurrentTheme()
            return
        }
        customThemes.removeAll {
            $0.id.caseInsensitiveCompare(factoryDefault.id) == .orderedSame ||
            $0.name.caseInsensitiveCompare(factoryDefault.name) == .orderedSame
        }
        theme = factoryDefault
    }
}
