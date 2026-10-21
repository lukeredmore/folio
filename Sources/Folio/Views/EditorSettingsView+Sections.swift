import AppKit
import SwiftUI

extension EditorSettingsView {

    // MARK: - Tab 1: Fonts & Heading Style

    @ViewBuilder
    var fontsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            settingsCard(title: "FONT FAMILIES & SIZE") {
                fontPickerRow(
                    title: "Body Font",
                    selection: $viewModel.theme.bodyFontFamily,
                    options: EditorTheme.bodyFontChoices
                )

                Divider().opacity(0.5)

                fontPickerRow(
                    title: "Heading Font",
                    selection: $viewModel.theme.headingFontFamily,
                    options: EditorTheme.headingFontChoices
                )

                Divider().opacity(0.5)

                fontPickerRow(
                    title: "Code Font",
                    selection: $viewModel.theme.codeFontFamily,
                    options: EditorTheme.codeFontChoices
                )

                Divider().opacity(0.5)

                settingSliderRow(
                    title: "Base Font Size",
                    valueText: String(format: "%.1f pt", viewModel.theme.baseFontSize),
                    value: $viewModel.theme.baseFontSize,
                    range: 12.0...24.0,
                    step: 0.5
                )
            }

            settingsCard(title: "HEADINGS & EMPHASIS") {
                HStack {
                    Text("Heading Weight")
                        .font(.system(size: 12))
                    Spacer()
                    Picker("Heading Weight", selection: $viewModel.theme.headingWeightStyle) {
                        ForEach(HeadingWeightStyle.allCases) { style in
                            Text(style.displayName).tag(style)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 245)
                }

                Divider().opacity(0.5)

                HStack(spacing: 20) {
                    Toggle("Italic H3 Subheadings", isOn: $viewModel.theme.italicH3)
                        .font(.system(size: 12))
                    Toggle("Italic Blockquotes", isOn: $viewModel.theme.italicBlockquotes)
                        .font(.system(size: 12))
                    Spacer(minLength: 0)
                }
            }

            // Live miniature preview of the active theme's fonts & colors
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Headings & Prose Preview")
                        .font(Font(viewModel.theme.headingFont(level: 3, scale: 0.92)))
                        .foregroundColor(viewModel.theme.headingColor)
                    Spacer()
                    Text(viewModel.theme.name)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(viewModel.theme.secondaryTextColor)
                }

                Text("The quick brown fox jumps over the lazy dog.")
                    .font(Font(viewModel.theme.bodyFont(size: min(17, max(12, viewModel.theme.baseFontSize * 0.88)))))
                    .foregroundColor(viewModel.theme.textColor)

                HStack(spacing: 8) {
                    Text("> Quoted note")
                        .font(Font(viewModel.theme.bodyFont(size: 12, italic: viewModel.theme.italicBlockquotes)))
                        .foregroundColor(viewModel.theme.blockquoteTextColor)

                    Text("let theme = \"\(viewModel.theme.name)\"")
                        .font(Font(viewModel.theme.codeFont(size: 11.5)))
                        .foregroundColor(viewModel.theme.inlineCodeColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(viewModel.theme.codeBackgroundColor)
                        )
                }
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(viewModel.theme.editorBackgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
            )
        }
    }

    // MARK: - Tab 2: Theme Colors & Appearance

    @ViewBuilder
    var colorsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            settingsCard(title: "WINDOW APPEARANCE") {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Dark Appearance")
                            .font(.system(size: 12, weight: .medium))
                        Text("Controls window chrome, scrollbars, and dark syntax contrast")
                            .font(.system(size: 10.5))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: $viewModel.theme.isDark)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
            }

            settingsCard(title: "PALETTE SWATCHES") {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 10),
                        GridItem(.flexible(), spacing: 10)
                    ],
                    alignment: .leading,
                    spacing: 8
                ) {
                    themeColorRow("Editor Surface", color: $viewModel.theme.editorBackground)
                    themeColorRow("Sidebar Surface", color: $viewModel.theme.sidebarBackground)
                    themeColorRow("Body Text", color: $viewModel.theme.text)
                    themeColorRow("Heading Text", color: $viewModel.theme.heading)
                    themeColorRow("Secondary Text", color: $viewModel.theme.secondaryText)
                    themeColorRow("Links & Accent", color: $viewModel.theme.link)
                    themeColorRow("Code Block Fill", color: $viewModel.theme.codeBackground)
                    themeColorRow("Inline Code", color: $viewModel.theme.inlineCode)
                    themeColorRow("Syntax Tokens", color: $viewModel.theme.markdownToken)
                    themeColorRow("Blockquotes", color: $viewModel.theme.blockquoteText)
                }
            }
        }
    }

    // MARK: - Tab 3: Character, Line & Spacing

    @ViewBuilder
    var characterAndSpacingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            settingsCard(
                title: "BODY & PARAGRAPH SPACING",
                trailingHeader: {
                    Button("Reset Spacing Defaults") {
                        viewModel.resetTypographyToDefaults()
                    }
                    .controlSize(.mini)
                    .disabled(viewModel.typography == .default)
                    .help("Reset character, line, paragraph, and column spacing to standard defaults while keeping your theme's fonts and colors")
                }
            ) {
                settingSliderRow(
                    title: "Font Size Scale",
                    valueText: "\(Int(round(viewModel.typography.fontSizeScale * 100)))%",
                    value: $viewModel.typography.fontSizeScale,
                    range: 0.80...1.50,
                    step: 0.05
                )

                settingSliderRow(
                    title: "Line Height",
                    valueText: String(format: "%.2f×", viewModel.typography.lineHeightMultiple),
                    value: $viewModel.typography.lineHeightMultiple,
                    range: 1.00...1.80,
                    step: 0.02
                )

                settingSliderRow(
                    title: "Line Spacing",
                    valueText: String(format: "%.1f pt", viewModel.typography.lineSpacing),
                    value: $viewModel.typography.lineSpacing,
                    range: 0.0...16.0,
                    step: 0.5
                )

                settingSliderRow(
                    title: "Paragraph Spacing",
                    valueText: String(format: "%.1f pt", viewModel.typography.paragraphSpacing),
                    value: $viewModel.typography.paragraphSpacing,
                    range: 2.0...28.0,
                    step: 1.0
                )

                settingSliderRow(
                    title: "Character Spacing",
                    valueText: String(format: "%+.2f pt", viewModel.typography.characterSpacing),
                    value: $viewModel.typography.characterSpacing,
                    range: -0.50...2.50,
                    step: 0.05
                )
            }

            settingsCard(title: "HEADINGS & COLUMN LAYOUT") {
                settingSliderRow(
                    title: "Title Letter Spacing",
                    valueText: String(format: "%+.2f pt", viewModel.typography.headingCharacterSpacing),
                    value: $viewModel.typography.headingCharacterSpacing,
                    range: -0.50...3.00,
                    step: 0.05
                )

                settingSliderRow(
                    title: "Title Vertical Spacing",
                    valueText: String(format: "%.2f×", viewModel.typography.headingSpacingScale),
                    value: $viewModel.typography.headingSpacingScale,
                    range: 0.60...2.00,
                    step: 0.05
                )

                settingSliderRow(
                    title: "Underline Offset",
                    valueText: String(format: "%.1f pt", viewModel.typography.headingUnderlineOffset),
                    value: $viewModel.typography.headingUnderlineOffset,
                    range: 2.0...16.0,
                    step: 0.5
                )

                Divider().opacity(0.5)

                Toggle("Show H1 / H2 Heading Underlines", isOn: $viewModel.typography.showHeadingUnderlines)
                    .font(.system(size: 12))
            }
        }
    }
}
