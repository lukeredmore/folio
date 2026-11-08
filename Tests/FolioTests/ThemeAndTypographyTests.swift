import AppKit
import XCTest
@testable import FolioEditor
@testable import FolioEditorTestSupport
@testable import FolioModels
@testable import FolioWorkspace
@testable import FolioWorkspaceTestSupport

final class ThemeAndTypographyTests: XCTestCase {

    func testDocumentStatsComputation() {
        let text = "Hello world from Folio.\nSecond line here."
        let stats = DocumentStats.compute(for: text, selectedRange: NSRange(location: 0, length: 11))
        XCTAssertEqual(stats.words, 7)
        XCTAssertEqual(stats.lines, 2)
        XCTAssertEqual(stats.selectedWords, 2)
        XCTAssertEqual(stats.selectedCharacters, 11)
    }

    func testBuiltInThemesHaveLightAndDarkSwatchVariantsAndKeepTextReadable() {
        XCTAssertEqual(EditorTheme.allCases.map(\.id), EditorTheme.builtInThemes.map(\.id))
        XCTAssertEqual(
            EditorTheme.builtInThemes.map(\.id),
            ["Daylight", "Parchment", "Editorial", "Classic", "Modernist"]
        )
        XCTAssertFalse(EditorTheme.builtInThemes.contains(where: { $0.id.caseInsensitiveCompare("Midnight") == .orderedSame }))
        XCTAssertEqual(Set(EditorTheme.allCases.map(\.id)).count, EditorTheme.allCases.count, "Theme IDs are unique")

        for preset in EditorTheme.allCases {
            XCTAssertTrue(preset.usesSeparateDarkPalette, "\(preset.id) must provide separate light and dark swatch variants")

            let lightVariant = preset.withAppearance(isDark: false)
            let lightBg = Self.relativeLuminance(lightVariant.editorBackground)
            let lightText = Self.relativeLuminance(lightVariant.text)
            XCTAssertFalse(lightBg < lightText, "\(preset.id) light variant: background must be lighter than text")
            let lightContrast = (max(lightBg, lightText) + 0.05) / (min(lightBg, lightText) + 0.05)
            XCTAssertGreaterThanOrEqual(lightContrast, 4.5, "\(preset.id) light variant: body text needs WCAG AA contrast")

            let darkVariant = preset.withAppearance(isDark: true)
            let darkBg = Self.relativeLuminance(darkVariant.editorBackground)
            let darkText = Self.relativeLuminance(darkVariant.text)
            XCTAssertTrue(darkBg < darkText, "\(preset.id) dark variant: background must be darker than text")
            let darkContrast = (max(darkBg, darkText) + 0.05) / (min(darkBg, darkText) + 0.05)
            XCTAssertGreaterThanOrEqual(darkContrast, 4.5, "\(preset.id) dark variant: body text needs WCAG AA contrast")
        }
    }

    /// WCAG 2 relative luminance of an sRGB color.
    private static func relativeLuminance(_ color: ThemeColorRGBA) -> Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.r) + 0.7152 * linear(color.g) + 0.0722 * linear(color.b)
    }

    func testTypographySettingsCustomization() {
        let sample = "# Main Title\n\nBody paragraph text.\n\n---\n"
        let storage = NSTextStorage(string: sample)
        let customTypo = EditorTypographySettings(
            fontSizeScale: 1.15,
            lineHeightMultiple: 1.40,
            lineSpacing: 9.0,
            paragraphSpacing: 16.0,
            characterSpacing: 0.45,
            headingCharacterSpacing: 0.85,
            headingSpacingScale: 1.25,
            headingUnderlineOffset: 10.0,
            showHeadingUnderlines: true,
            maxColumnWidth: 920.0
        )

        let analysis = MarkdownLiveStyler.applyStyles(
            to: storage,
            theme: .daylight,
            typography: customTypo,
            sourceCodeMode: false,
            focusMode: false,
            selectedRange: NSRange(location: 20, length: 0)
        )

        let titleLoc = (sample as NSString).range(of: "Main Title").location
        let titleKern = storage.attribute(.kern, at: titleLoc, effectiveRange: nil) as? CGFloat
        XCTAssertEqual(titleKern ?? 0.0, 0.85, accuracy: 0.01)

        let bodyLoc = (sample as NSString).range(of: "Body paragraph").location
        let bodyKern = storage.attribute(.kern, at: bodyLoc, effectiveRange: nil) as? CGFloat
        XCTAssertEqual(bodyKern ?? 0.0, 0.45, accuracy: 0.01)

        let bodyPara = storage.attribute(.paragraphStyle, at: bodyLoc, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(bodyPara?.lineSpacing ?? 0.0, 9.0, accuracy: 0.01)
        XCTAssertEqual(bodyPara?.lineHeightMultiple ?? 0.0, 1.40, accuracy: 0.01)

        let hrLoc = (sample as NSString).range(of: "---").location
        let hrPara = storage.attribute(.paragraphStyle, at: hrLoc, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(hrPara?.minimumLineHeight ?? 0.0, 28.0, accuracy: 0.01)

        XCTAssertTrue(analysis.decorations.contains(where: { $0.kind == .headingUnderline(level: 1) }))
    }

    @MainActor
    func testExtensibleThemeSystemAndTypographyDefaults() throws {
        let testDefaults = isolatedDefaults()

        // 1. Default presets are available as built-in themes (Midnight removed)
        XCTAssertEqual(
            EditorTheme.builtInThemes.map(\.name),
            [
                "Daylight", "Parchment", "Editorial", "Classic", "Modernist"
            ])

        let vm1 = makeIsolatedViewModel(defaults: testDefaults)
        XCTAssertEqual(vm1.theme, .daylight)
        XCTAssertEqual(vm1.appearanceMode, .system)
        XCTAssertEqual(vm1.typography, .default)
        XCTAssertFalse(vm1.isCurrentThemeModified)

        // 2. Customize fonts, colors, and character/line/spacing settings on the active theme
        vm1.selectTheme(.editorial)
        XCTAssertEqual(vm1.theme.name, "Editorial")
        XCTAssertFalse(vm1.isCurrentThemeModified)

        // Switching app appearance mode between Light, Dark, and System switches active swatches without marking theme as modified
        vm1.appearanceMode = .dark
        XCTAssertTrue(vm1.theme.isDark)
        XCTAssertEqual(vm1.theme.editorBackground, EditorTheme.editorial.darkPalette.editorBackground)
        XCTAssertFalse(vm1.isCurrentThemeModified)

        vm1.appearanceMode = .light
        XCTAssertFalse(vm1.theme.isDark)
        XCTAssertEqual(vm1.theme.editorBackground, EditorTheme.editorial.lightPalette.editorBackground)
        XCTAssertFalse(vm1.isCurrentThemeModified)

        vm1.appearanceMode = .dark
        vm1.theme.bodyFontFamily = "Avenir Next"
        vm1.theme.headingFontFamily = "Baskerville"
        vm1.theme.codeFontFamily = "Menlo"
        vm1.theme.baseFontSize = 18.5
        vm1.theme.headingWeightStyle = .bold
        vm1.theme.italicH3 = false
        vm1.theme.italicBlockquotes = true
        vm1.theme.editorBackground = ThemeColorRGBA(r: 0.08, g: 0.09, b: 0.12)
        vm1.theme.text = ThemeColorRGBA(r: 0.92, g: 0.93, b: 0.95)
        vm1.theme.link = ThemeColorRGBA(r: 0.40, g: 0.75, b: 0.98)

        vm1.typography.fontSizeScale = 1.15
        vm1.typography.lineHeightMultiple = 1.48
        vm1.typography.lineSpacing = 4.5
        vm1.typography.paragraphSpacing = 16.0
        vm1.typography.characterSpacing = 0.25
        vm1.typography.headingCharacterSpacing = 0.60
        vm1.typography.headingSpacingScale = 1.25
        vm1.typography.headingUnderlineOffset = 8.0
        vm1.typography.showHeadingUnderlines = false
        vm1.typography.maxColumnWidth = 920.0

        // Typography and theme.typography stay synchronized
        XCTAssertEqual(vm1.theme.typography, vm1.typography)
        XCTAssertTrue(vm1.isCurrentThemeModified)

        // 3. Save customized fonts, colors, and spacing as a brand-new named theme
        let savedTheme = vm1.saveCurrentTheme(as: "Noir Journal")
        XCTAssertFalse(savedTheme.isBuiltIn)
        XCTAssertEqual(savedTheme.name, "Noir Journal")
        XCTAssertEqual(vm1.theme, savedTheme)
        XCTAssertEqual(vm1.customThemes.map(\.name), ["Noir Journal"])
        XCTAssertFalse(vm1.isCurrentThemeModified)

        // 4. Verify persistence of custom themes, appearance mode, and active theme across launches
        let vm2 = makeIsolatedViewModel(defaults: testDefaults)
        XCTAssertEqual(vm2.customThemes.count, 1)
        XCTAssertEqual(vm2.appearanceMode, .dark)
        XCTAssertEqual(vm2.theme, savedTheme)
        XCTAssertEqual(vm2.theme.bodyFontFamily, "Avenir Next")
        XCTAssertEqual(vm2.theme.headingFontFamily, "Baskerville")
        XCTAssertEqual(vm2.theme.codeFontFamily, "Menlo")
        XCTAssertEqual(vm2.theme.baseFontSize, 18.5, accuracy: 0.001)
        XCTAssertEqual(vm2.theme.editorBackground, ThemeColorRGBA(r: 0.08, g: 0.09, b: 0.12))
        XCTAssertEqual(vm2.typography.lineSpacing, 4.5, accuracy: 0.001)
        XCTAssertEqual(vm2.typography.characterSpacing, 0.25, accuracy: 0.001)
        XCTAssertEqual(vm2.typography.maxColumnWidth, 920.0, accuracy: 0.001)
        XCTAssertFalse(vm2.typography.showHeadingUnderlines)

        // 5. Resetting character/line/spacing defaults keeps custom theme fonts and colors intact
        vm2.resetTypographyToDefaults()
        XCTAssertEqual(vm2.typography, .default)
        XCTAssertEqual(vm2.theme.typography, .default)
        XCTAssertEqual(vm2.theme.bodyFontFamily, "Avenir Next")
        XCTAssertEqual(vm2.theme.headingFontFamily, "Baskerville")
        XCTAssertEqual(vm2.theme.editorBackground, ThemeColorRGBA(r: 0.08, g: 0.09, b: 0.12))
        XCTAssertTrue(vm2.isCurrentThemeModified)

        // 6. Revert unsaved edits back to saved custom theme, then update and delete
        vm2.resetCurrentTheme()
        XCTAssertFalse(vm2.isCurrentThemeModified)
        XCTAssertEqual(vm2.typography.lineSpacing, 4.5, accuracy: 0.001)

        vm2.theme.baseFontSize = 20.0
        XCTAssertTrue(vm2.isCurrentThemeModified)
        vm2.updateCurrentCustomTheme()
        XCTAssertFalse(vm2.isCurrentThemeModified)
        XCTAssertEqual(vm2.customThemes.first?.baseFontSize, 20.0)

        // 7. MarkdownLiveStyler applies the custom theme's embedded typography and colors
        let textStorage = NSTextStorage(string: "# Heading\n\n> Quoted line\n\nBody paragraph")
        MarkdownLiveStyler.applyStyles(
            to: textStorage,
            theme: vm2.theme,
            sourceCodeMode: false,
            focusMode: false,
            selectedRange: NSRange(location: 0, length: 0)
        )
        let bodyAttrs = textStorage.attributes(at: textStorage.string.count - 4, effectiveRange: nil)
        let bodyFont = bodyAttrs[.font] as? NSFont
        XCTAssertNotNil(bodyFont)
        XCTAssertEqual(bodyFont?.pointSize ?? 0, 20.0 * 1.15, accuracy: 0.5)

        // 8. Delete custom theme falls back cleanly to its base preset (.editorial) while keeping dark appearance
        vm2.deleteCustomTheme(id: savedTheme.id)
        XCTAssertTrue(vm2.customThemes.isEmpty)
        XCTAssertEqual(vm2.theme, EditorTheme.editorial.withAppearance(isDark: true))

        // 9. Preset-named themes can be modified and saved in-place, then reset to factory default
        XCTAssertFalse(vm2.canResetCurrentPresetToDefault)
        vm2.theme.baseFontSize = 19.0
        vm2.typography.lineSpacing = 6.0
        XCTAssertTrue(vm2.isCurrentThemeModified)
        XCTAssertTrue(vm2.canResetCurrentPresetToDefault)

        let savedPreset = vm2.saveCurrentTheme()
        XCTAssertTrue(savedPreset.isPresetTheme)
        XCTAssertEqual(savedPreset.id, "Editorial")
        XCTAssertEqual(savedPreset.name, "Editorial")
        XCTAssertFalse(vm2.isCurrentThemeModified, "Saving a preset-named theme in-place clears the unsaved state")
        XCTAssertTrue(vm2.canResetCurrentPresetToDefault, "Saved preset still differs from factory default and can be reset")

        // Switching to another preset and back preserves the saved preset modifications
        vm2.selectTheme(id: "Daylight")
        XCTAssertEqual(vm2.theme, EditorTheme.daylight.withAppearance(isDark: true))
        vm2.selectTheme(id: "Editorial")
        XCTAssertEqual(vm2.theme.baseFontSize, 19.0, accuracy: 0.001)
        XCTAssertEqual(vm2.typography.lineSpacing, 6.0, accuracy: 0.001)

        // Resetting the preset to default restores the factory Editorial preset
        vm2.resetCurrentThemeToDefault()
        XCTAssertEqual(vm2.theme, EditorTheme.editorial.withAppearance(isDark: true))
        XCTAssertFalse(vm2.canResetCurrentPresetToDefault)
        XCTAssertFalse(vm2.isCurrentThemeModified)
    }

    @MainActor
    func testAppearanceModesAndSeparateLightDarkSwatchesToggle() {
        let vm = makeIsolatedViewModel()
        vm.selectTheme(.parchment)

        // System mode tracks systemIsDark
        vm.appearanceMode = .system
        vm.systemIsDark = false
        XCTAssertFalse(vm.effectiveIsDark)
        XCTAssertFalse(vm.theme.isDark)
        XCTAssertEqual(vm.theme.editorBackground, EditorTheme.parchment.lightPalette.editorBackground)

        vm.systemIsDark = true
        XCTAssertTrue(vm.effectiveIsDark)
        XCTAssertTrue(vm.theme.isDark)
        XCTAssertEqual(vm.theme.editorBackground, EditorTheme.parchment.darkPalette.editorBackground)

        // Explicit Light mode overrides systemIsDark = true
        vm.appearanceMode = .light
        XCTAssertFalse(vm.effectiveIsDark)
        XCTAssertFalse(vm.theme.isDark)
        XCTAssertEqual(vm.theme.editorBackground, EditorTheme.parchment.lightPalette.editorBackground)

        // Explicit Dark mode overrides systemIsDark = false
        vm.systemIsDark = false
        vm.appearanceMode = .dark
        XCTAssertTrue(vm.effectiveIsDark)
        XCTAssertTrue(vm.theme.isDark)
        XCTAssertEqual(vm.theme.editorBackground, EditorTheme.parchment.darkPalette.editorBackground)

        // When a theme disables separate dark swatches, it uses its single palette in both Light and Dark mode
        vm.theme.usesSeparateDarkPalette = false
        XCTAssertEqual(vm.theme.editorBackground, EditorTheme.parchment.lightPalette.editorBackground)
        vm.appearanceMode = .light
        XCTAssertEqual(vm.theme.editorBackground, EditorTheme.parchment.lightPalette.editorBackground)
    }

    @MainActor
    func testSystemFontSelectionResolution() throws {
        let allFamilies = EditorTheme.allSystemFontFamilies
        XCTAssertFalse(allFamilies.isEmpty)
        let extraBodyFamilies = EditorTheme.additionalSystemFontFamilies(excluding: EditorTheme.bodyFontChoices)
        XCTAssertFalse(extraBodyFamilies.isEmpty, "System must have additional font families beyond the curated subset")

        let vm = makeIsolatedViewModel()
        let pickedFont = try XCTUnwrap(extraBodyFamilies.first)
        vm.theme.bodyFontFamily = pickedFont
        vm.theme.headingFontFamily = pickedFont
        vm.theme.codeFontFamily = pickedFont

        XCTAssertNotNil(vm.theme.bodyFont(size: 16))
        XCTAssertNotNil(vm.theme.headingFont(level: 1))
        XCTAssertNotNil(vm.theme.codeFont(size: 14))
    }
}
