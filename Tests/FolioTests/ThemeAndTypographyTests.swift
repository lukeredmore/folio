import AppKit
import CoreText
import SwiftUI
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

    @MainActor
    func testInitialEditorRepresentableMountSyncsRestoredThemeWithoutRoundTrip() throws {
        let testDefaults = isolatedDefaults()

        let setupVM = makeIsolatedViewModel(defaults: testDefaults)
        setupVM.appearanceMode = .dark
        setupVM.theme.headingFontFamily = "System Serif"
        setupVM.saveCurrentTheme()
        setupVM.typewriterMode = true
        setupVM.sourceCodeMode = false

        let restoredVM = makeIsolatedViewModel(defaults: testDefaults)
        restoredVM.markdownText = "# Guide\n\nRun `bazel test //...` now:\n\n```bash\nMAIN_REPO_ROOT=1\n```\n"

        let hostingView = NSHostingView(rootView: HybridMarkdownEditorRepresentable(viewModel: restoredVM))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.colorSpace = .sRGB
        window.contentView = hostingView
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }

        hostingView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        hostingView.layoutSubtreeIfNeeded()

        let textView = try XCTUnwrap(restoredVM.activeTextView)
        let scrollView = try XCTUnwrap(textView.enclosingScrollView)

        XCTAssertEqual(textView.currentTheme, restoredVM.theme)
        XCTAssertTrue(textView.currentTheme.isDark)
        XCTAssertEqual(
            ThemeColorRGBA(nsColor: textView.backgroundColor).hexString,
            restoredVM.theme.editorBackground.hexString
        )
        XCTAssertEqual(
            ThemeColorRGBA(nsColor: scrollView.backgroundColor).hexString,
            restoredVM.theme.editorBackground.hexString
        )
        XCTAssertEqual(
            ThemeColorRGBA(nsColor: textView.insertionPointColor).hexString,
            restoredVM.theme.link.hexString
        )
        XCTAssertEqual(textView.currentTheme.codeBackground, EditorTheme.daylight.darkPalette.codeBackground)
        XCTAssertTrue(textView.isTypewriterMode)
        XCTAssertFalse(textView.isSourceCodeMode)

        func samplePaddingColor(in view: HybridMarkdownTextView) throws -> ThemeColorRGBA {
            let width = max(1, Int(view.bounds.width))
            let height = max(1, Int(view.bounds.height))
            let rep = try XCTUnwrap(
                NSBitmapImageRep(
                    bitmapDataPlanes: nil,
                    pixelsWide: width,
                    pixelsHigh: height,
                    bitsPerSample: 8,
                    samplesPerPixel: 4,
                    hasAlpha: true,
                    isPlanar: false,
                    colorSpaceName: .deviceRGB,
                    bytesPerRow: 0,
                    bitsPerPixel: 0
                )?.retagging(with: .sRGB)
            )
            view.cacheDisplay(in: view.bounds, to: rep)
            var pixel = [Int](repeating: 0, count: 4)
            rep.getPixel(&pixel, atX: min(width - 1, 10), y: min(height - 1, 10))
            return ThemeColorRGBA(
                r: Double(pixel[0]) / 255.0,
                g: Double(pixel[1]) / 255.0,
                b: Double(pixel[2]) / 255.0,
                a: Double(pixel[3]) / 255.0
            )
        }

        let initialColor = try samplePaddingColor(in: textView)
        let expectedBg = restoredVM.theme.editorBackground
        XCTAssertEqual(initialColor.r, expectedBg.r, accuracy: 0.02)
        XCTAssertEqual(initialColor.g, expectedBg.g, accuracy: 0.02)
        XCTAssertEqual(initialColor.b, expectedBg.b, accuracy: 0.02)

        restoredVM.selectTheme(.parchment)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        hostingView.layoutSubtreeIfNeeded()
        let parchmentColor = try samplePaddingColor(in: textView)
        XCTAssertNotEqual(parchmentColor.hexString, initialColor.hexString)

        restoredVM.selectTheme(id: "Daylight")
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        hostingView.layoutSubtreeIfNeeded()

        let roundTripColor = try samplePaddingColor(in: textView)
        XCTAssertEqual(initialColor.hexString, roundTripColor.hexString)
    }

    func testBrokenGDEFSanitizationFixesBacktickOverlapAndPreservesCombiningMarks() throws {
        let regularURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("GdfM2-Regular-\(UUID().uuidString).ttf")
        let boldURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("GdfM2-Bold-\(UUID().uuidString).ttf")
        let format1URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("GdfM1-Regular-\(UUID().uuidString).ttf")

        let format2Data = try Self.buildBrokenGDEFMenloSFNT(sourcePostScriptName: "Menlo-Regular", familyName: "GdfM2", gdefFormat: 2)
        let format2BoldData = try Self.buildBrokenGDEFMenloSFNT(sourcePostScriptName: "Menlo-Bold", familyName: "GdfM2", gdefFormat: 2)
        let format1Data = try Self.buildBrokenGDEFMenloSFNT(sourcePostScriptName: "Menlo-Regular", familyName: "GdfM1", gdefFormat: 1)

        try format2Data.write(to: regularURL)
        try format2BoldData.write(to: boldURL)
        try format1Data.write(to: format1URL)

        defer {
            CTFontManagerUnregisterFontsForURL(regularURL as CFURL, .process, nil)
            CTFontManagerUnregisterFontsForURL(boldURL as CFURL, .process, nil)
            CTFontManagerUnregisterFontsForURL(format1URL as CFURL, .process, nil)
            try? FileManager.default.removeItem(at: regularURL)
            try? FileManager.default.removeItem(at: boldURL)
            try? FileManager.default.removeItem(at: format1URL)
        }

        for url in [regularURL, boldURL, format1URL] {
            var regError: Unmanaged<CFError>?
            XCTAssertTrue(
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, &regError),
                "Failed to register test font \(url.lastPathComponent): \(String(describing: regError?.takeRetainedValue()))"
            )
        }

        // 1. Confirm unsanitized CTLine collapses ```bash to x == 0 for the first 4 glyphs.
        let rawDesc = try XCTUnwrap(CTFontManagerCreateFontDescriptorFromData(format2Data as CFData))
        let rawCTFont = CTFontCreateWithFontDescriptor(rawDesc, 14.0, nil)
        let rawLine = CTLineCreateWithAttributedString(NSAttributedString(string: "```bash", attributes: [.font: rawCTFont]))
        let rawRuns = try XCTUnwrap(CTLineGetGlyphRuns(rawLine) as? [CTRun])
        var rawPositions = [CGPoint](repeating: .zero, count: CTRunGetGlyphCount(rawRuns[0]))
        CTRunGetPositions(rawRuns[0], CFRange(location: 0, length: 0), &rawPositions)
        XCTAssertEqual(rawPositions[0].x, 0.0, accuracy: 0.01)
        XCTAssertEqual(rawPositions[3].x, 0.0, accuracy: 0.01)

        // 2. Test both Format 1 and Format 2 sanitized code fonts in MarkdownLiveStyler + NSLayoutManager.
        for family in ["GdfM1", "GdfM2"] {
            var theme = EditorTheme.daylight
            theme.codeFontFamily = family
            theme.baseFontSize = 16.0

            let sample = "```bash\nMAIN_REPO_ROOT\n```\n\nDo **not** modify `${MAIN_REPO_ROOT}` (`main`).\n"
            let nsSample = sample as NSString
            let inlineLineRange = nsSample.range(of: "Do **not** modify `${MAIN_REPO_ROOT}` (`main`).")
            let storage = NSTextStorage(string: sample)
            let layoutManager = NSLayoutManager()
            let textContainer = NSTextContainer(size: NSSize(width: 720, height: 2000))
            layoutManager.addTextContainer(textContainer)
            storage.addLayoutManager(layoutManager)

            let analysis = MarkdownLiveStyler.applyStyles(
                to: storage,
                theme: theme,
                sourceCodeMode: false,
                focusMode: false,
                selectedRange: NSRange(location: inlineLineRange.location + 20, length: 0)
            )
            layoutManager.ensureLayout(for: textContainer)

            // Verify fenced code block opening (```bash) and closing (```) advances.
            let openRange = nsSample.range(of: "```bash")
            let openGlyphs = layoutManager.glyphRange(forCharacterRange: openRange, actualCharacterRange: nil)
            XCTAssertEqual(openGlyphs.length, 7)
            for i in 0..<(openGlyphs.length - 1) {
                let x0 = layoutManager.location(forGlyphAt: openGlyphs.location + i).x
                let x1 = layoutManager.location(forGlyphAt: openGlyphs.location + i + 1).x
                XCTAssertGreaterThan(x1 - x0, 5.0, "\(family) opening fence glyph \(i) collapsed")
            }

            let closeRange = nsSample.range(of: "\n```\n")
            let closeTicksRange = NSRange(location: closeRange.location + 1, length: 3)
            let closeGlyphs = layoutManager.glyphRange(forCharacterRange: closeTicksRange, actualCharacterRange: nil)
            XCTAssertEqual(closeGlyphs.length, 3)
            for i in 0..<(closeGlyphs.length - 1) {
                let x0 = layoutManager.location(forGlyphAt: closeGlyphs.location + i).x
                let x1 = layoutManager.location(forGlyphAt: closeGlyphs.location + i + 1).x
                XCTAssertGreaterThan(x1 - x0, 5.0, "\(family) closing fence glyph \(i) collapsed")
            }

            // Verify active inline-code line (`${MAIN_REPO_ROOT}` (`main`)) has monotonic spacing and non-overlapping pill bounds.
            let tailRange = nsSample.range(of: "}` (`main`)")
            let tailGlyphs = layoutManager.glyphRange(forCharacterRange: tailRange, actualCharacterRange: nil)
            XCTAssertEqual(tailGlyphs.length, tailRange.length)
            for i in 0..<(tailGlyphs.length - 1) {
                let x0 = layoutManager.location(forGlyphAt: tailGlyphs.location + i).x
                let x1 = layoutManager.location(forGlyphAt: tailGlyphs.location + i + 1).x
                XCTAssertGreaterThan(x1 - x0, 3.0, "\(family) inline-code glyph \(i) collapsed")
            }

            let parenSpanRange = nsSample.range(of: "(`main`)")
            let openParenGlyph = layoutManager.glyphIndexForCharacter(at: parenSpanRange.location)
            let openParenX = layoutManager.location(forGlyphAt: openParenGlyph).x
            let closeParenGlyph = layoutManager.glyphIndexForCharacter(at: NSMaxRange(parenSpanRange) - 1)
            let closeParenX = layoutManager.location(forGlyphAt: closeParenGlyph).x

            let mainRange = nsSample.range(of: "`main`")
            let innerMainRange = NSRange(location: mainRange.location + 1, length: 4)
            XCTAssertTrue(
                analysis.decorations.contains(where: {
                    if case let .inlineCode(decRange, _, _) = $0.kind {
                        return decRange == innerMainRange
                    }
                    return false
                }))
            let mainGlyphs = layoutManager.glyphRange(forCharacterRange: innerMainRange, actualCharacterRange: nil)
            let mainRect = layoutManager.boundingRect(forGlyphRange: mainGlyphs, in: textContainer)
            let pillMinX = mainRect.minX - 3.0
            let pillMaxX = mainRect.maxX + 3.0
            XCTAssertGreaterThan(pillMinX, openParenX + 2.0, "\(family) pill overlaps '('")
            XCTAssertLessThan(pillMaxX, closeParenX - 2.0, "\(family) pill swallows ')'")

            // Verify true combining mark U+0300 stays zero-width.
            let codeFont = theme.codeFont(size: 14.0)
            let monoWidth = ("m" as NSString).size(withAttributes: [.font: codeFont]).width
            let combiningStorage = NSTextStorage(string: "x\u{0300}a", attributes: [.font: codeFont])
            let combiningLM = NSLayoutManager()
            let combiningTC = NSTextContainer(size: NSSize(width: 400, height: 200))
            combiningLM.addTextContainer(combiningTC)
            combiningStorage.addLayoutManager(combiningLM)
            combiningLM.ensureLayout(for: combiningTC)
            let xPos = combiningLM.location(forGlyphAt: 0).x
            let aPos = combiningLM.location(forGlyphAt: 2).x
            XCTAssertEqual(aPos - xPos, monoWidth, accuracy: 0.5, "\(family) expected U+0300 to stay zero-advance")
        }

        // 3. Bold trait conversion via FontGDEFSanitizer preserves both bold trait and backtick advance.
        var boldTheme = EditorTheme.daylight
        boldTheme.codeFontFamily = "GdfM2"
        let regularSanitized = boldTheme.codeFont(size: 14.0)
        let boldSanitized = FontGDEFSanitizer.convert(regularSanitized, toHaveTrait: .boldFontMask)
        XCTAssertTrue(boldSanitized.fontDescriptor.symbolicTraits.contains(.bold))

        let boldStorage = NSTextStorage(string: "```bash", attributes: [.font: boldSanitized])
        let boldLM = NSLayoutManager()
        let boldTC = NSTextContainer(size: NSSize(width: 400, height: 200))
        boldLM.addTextContainer(boldTC)
        boldStorage.addLayoutManager(boldLM)
        boldLM.ensureLayout(for: boldTC)
        for i in 0..<6 {
            let x0 = boldLM.location(forGlyphAt: i).x
            let x1 = boldLM.location(forGlyphAt: i + 1).x
            XCTAssertGreaterThan(x1 - x0, 5.0, "bold converted backtick glyph \(i) collapsed")
        }
    }

    private static func buildBrokenGDEFMenloSFNT(
        sourcePostScriptName: String,
        familyName: String,
        gdefFormat: UInt16
    ) throws -> Data {
        precondition(familyName.utf8.count == 5)
        let sourceFont = try XCTUnwrap(NSFont(name: sourcePostScriptName, size: 14.0))
        let ctFont = sourceFont as CTFont

        var uni: [UniChar] = [0x0060, 0x0300]
        var gids: [CGGlyph] = [0, 0]
        CTFontGetGlyphsForCharacters(ctFont, &uni, &gids, 2)
        let backtickGid = gids[0]
        let combiningGid = gids[1]
        XCTAssertNotEqual(backtickGid, 0)
        XCTAssertNotEqual(combiningGid, 0)

        let keepTags: [String] = ["OS/2", "cmap", "glyf", "head", "hhea", "hmtx", "loca", "maxp", "name", "post"]
        var tables: [(tag: UInt32, bytes: [UInt8])] = []
        for tagStr in keepTags {
            let utf8 = Array(tagStr.utf8)
            let tag = (UInt32(utf8[0]) << 24) | (UInt32(utf8[1]) << 16) | (UInt32(utf8[2]) << 8) | UInt32(utf8[3])
            let tableData = try XCTUnwrap(CTFontCopyTable(ctFont, CTFontTableTag(tag), []) as Data?)
            var bytes = [UInt8](tableData)
            if tagStr == "name" {
                replaceBytes(&bytes, needle: Array("Menlo".utf8), replacement: Array(familyName.utf8))
                let menloUTF16: [UInt8] = [0, 0x4D, 0, 0x65, 0, 0x6E, 0, 0x6C, 0, 0x6F]
                var replUTF16: [UInt8] = Array(repeating: 0, count: 10)
                for (i, b) in familyName.utf8.enumerated() {
                    replUTF16[i * 2 + 1] = b
                }
                replaceBytes(&bytes, needle: menloUTF16, replacement: replUTF16)
            } else if tagStr == "head" {
                for j in 8..<12 { bytes[j] = 0 }
            }
            tables.append((tag, bytes))
        }

        func append16(_ out: inout [UInt8], _ value: UInt16) {
            out.append(UInt8(value >> 8))
            out.append(UInt8(value & 0xFF))
        }
        func append32(_ out: inout [UInt8], _ value: UInt32) {
            append16(&out, UInt16(value >> 16))
            append16(&out, UInt16(value & 0xFFFF))
        }

        var gdef: [UInt8] = [0, 1, 0, 0, 0, 12, 0, 0, 0, 0, 0, 0]
        if gdefFormat == 1 {
            let minGid = min(backtickGid, combiningGid)
            let maxGid = max(backtickGid, combiningGid)
            append16(&gdef, 1)
            append16(&gdef, minGid)
            append16(&gdef, maxGid - minGid + 1)
            for gid in minGid...maxGid {
                append16(&gdef, (gid == backtickGid || gid == combiningGid) ? 3 : 1)
            }
        } else {
            let firstGid = min(backtickGid, combiningGid)
            let secondGid = max(backtickGid, combiningGid)
            append16(&gdef, 2)
            append16(&gdef, 2)
            for gid in [firstGid, secondGid] {
                append16(&gdef, gid)
                append16(&gdef, gid)
                append16(&gdef, 3)
            }
        }
        tables.append((UInt32(kCTFontTableGDEF), gdef))

        let gpos: [UInt8] = [
            0, 1, 0, 0, 0, 10, 0, 28, 0, 30,
            0, 1, 0x44, 0x46, 0x4C, 0x54, 0, 8,
            0, 4, 0, 0,
            0, 0, 0xFF, 0xFF, 0, 0,
            0, 0,
            0, 0
        ]
        tables.append((UInt32(kCTFontTableGPOS), gpos))

        tables.sort { $0.tag < $1.tag }
        let numTables = UInt16(tables.count)
        var searchRange: UInt16 = 16
        var entrySelector: UInt16 = 0
        while searchRange * 2 <= numTables * 16 {
            searchRange *= 2
            entrySelector += 1
        }
        let rangeShift = numTables * 16 - searchRange

        func checksum(_ bytes: [UInt8]) -> UInt32 {
            var sum: UInt32 = 0
            var idx = 0
            while idx < bytes.count {
                let b0 = UInt32(bytes[idx]) << 24
                let b1 = (idx + 1 < bytes.count ? UInt32(bytes[idx + 1]) : 0) << 16
                let b2 = (idx + 2 < bytes.count ? UInt32(bytes[idx + 2]) : 0) << 8
                let b3 = (idx + 3 < bytes.count ? UInt32(bytes[idx + 3]) : 0)
                sum = sum &+ (b0 | b1 | b2 | b3)
                idx += 4
            }
            return sum
        }

        var sfnt: [UInt8] = []
        append32(&sfnt, 0x0001_0000)
        append16(&sfnt, numTables)
        append16(&sfnt, searchRange)
        append16(&sfnt, entrySelector)
        append16(&sfnt, rangeShift)

        var offset = 12 + Int(numTables) * 16
        var headOffset = 0
        for table in tables {
            if table.tag == UInt32(kCTFontTableHead) {
                headOffset = offset
            }
            append32(&sfnt, table.tag)
            append32(&sfnt, checksum(table.bytes))
            append32(&sfnt, UInt32(offset))
            append32(&sfnt, UInt32(table.bytes.count))
            offset += (table.bytes.count + 3) & ~3
        }
        for table in tables {
            sfnt.append(contentsOf: table.bytes)
            let pad = (4 - (table.bytes.count % 4)) % 4
            if pad > 0 {
                sfnt.append(contentsOf: repeatElement(UInt8(0), count: pad))
            }
        }
        let adjustment = 0xB1B0_AFBA &- checksum(sfnt)
        sfnt[headOffset + 8] = UInt8((adjustment >> 24) & 0xFF)
        sfnt[headOffset + 9] = UInt8((adjustment >> 16) & 0xFF)
        sfnt[headOffset + 10] = UInt8((adjustment >> 8) & 0xFF)
        sfnt[headOffset + 11] = UInt8(adjustment & 0xFF)
        return Data(sfnt)
    }

    private static func replaceBytes(_ haystack: inout [UInt8], needle: [UInt8], replacement: [UInt8]) {
        precondition(needle.count == replacement.count)
        var i = 0
        while i + needle.count <= haystack.count {
            if Array(haystack[i..<(i + needle.count)]) == needle {
                haystack.replaceSubrange(i..<(i + needle.count), with: replacement)
                i += needle.count
            } else {
                i += 1
            }
        }
    }
}
