import AppKit
import SwiftUI

public struct EditorSettingsView: View {
    public enum SettingsTab: String, CaseIterable, Identifiable, Sendable {
        case fonts = "Fonts"
        case colors = "Colors"
        case spacing = "Spacing"
        case editor = "Editor"

        public var id: String { rawValue }

        public var icon: String {
            switch self {
            case .fonts: return "textformat"
            case .colors: return "paintpalette"
            case .spacing: return "arrow.up.and.down.text.horizontal"
            case .editor: return "gearshape"
            }
        }
    }

    @ObservedObject var viewModel: EditorWorkspaceViewModel
    @State var selectedTab: SettingsTab
    @State var isSavingNewTheme: Bool = false
    @State var newThemeName: String = ""

    public init(viewModel: EditorWorkspaceViewModel, initialTab: SettingsTab = .fonts) {
        self.viewModel = viewModel
        self._selectedTab = State(initialValue: initialTab)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerSection
            themeGallerySection
            tabPickerSection

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    switch selectedTab {
                    case .fonts:
                        fontsSection
                    case .colors:
                        colorsSection
                    case .spacing:
                        characterAndSpacingSection
                    case .editor:
                        editorAndUpdatesSection
                    }
                }
                .padding(.top, 2)
                .padding(.bottom, 4)
            }
        }
        .padding(16)
        .frame(width: 460, height: 635)
    }

    // MARK: - Header & Theme Bar

    @ViewBuilder
    var headerSection: some View {
        HStack(spacing: 6) {
            Image(systemName: "paintbrush.pointed.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.accentColor)

            Text("Theme Settings")
                .font(.system(size: 13.5, weight: .semibold))

            if viewModel.isCurrentThemeModified {
                Text("Edited")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.orange.opacity(0.15)))
            }

            Spacer(minLength: 4)

            if viewModel.defaultPresetForCurrentTheme != nil {
                Button("Reset to Default") {
                    viewModel.resetCurrentThemeToDefault()
                }
                .controlSize(.small)
                .disabled(!viewModel.canResetCurrentPresetToDefault)
                .help("Reset '\(viewModel.theme.name)' back to its factory default preset")
            } else if viewModel.isCurrentThemeModified {
                Button("Revert") {
                    viewModel.resetCurrentTheme()
                }
                .controlSize(.small)
                .help("Revert unsaved changes back to '\(viewModel.theme.name)'")
            }

            if viewModel.isCurrentThemeModified {
                Button("Save") {
                    viewModel.saveCurrentTheme()
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .help("Save changes to '\(viewModel.theme.name)'")
            } else {
                Button("Save") {
                    viewModel.saveCurrentTheme()
                }
                .controlSize(.small)
                .disabled(true)
                .help("Save changes to '\(viewModel.theme.name)'")
            }

            Button("Save As…") {
                newThemeName = viewModel.isCurrentThemeModified
                    ? "\(viewModel.theme.name) Custom"
                    : "\(viewModel.theme.name) Copy"
                isSavingNewTheme.toggle()
            }
            .controlSize(.small)
            .help("Save current settings as a new named theme")

            if !viewModel.theme.isPresetTheme {
                Button(role: .destructive) {
                    viewModel.deleteCustomTheme(id: viewModel.theme.id)
                } label: {
                    Image(systemName: "trash")
                }
                .controlSize(.small)
                .help("Delete custom theme '\(viewModel.theme.name)'")
            }
        }
    }

    @ViewBuilder
    var themeGallerySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isSavingNewTheme {
                HStack(spacing: 6) {
                    TextField("New theme name…", text: $newThemeName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .onSubmit {
                            commitNewTheme()
                        }
                    Button("Save Theme") {
                        commitNewTheme()
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)

                    Button("Cancel") {
                        isSavingNewTheme = false
                    }
                    .controlSize(.small)
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.primary.opacity(0.04))
                )
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(viewModel.availableThemes) { candidate in
                        themeSwatchCard(for: candidate)
                    }
                }
                .padding(.vertical, 2)
                .padding(.horizontal, 1)
            }
        }
    }

    func themeSwatchCard(for candidate: EditorTheme) -> some View {
        let isSelected = viewModel.theme.id == candidate.id
        let displayTheme = isSelected ? viewModel.theme : candidate

        return Button {
            viewModel.selectTheme(candidate)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("Aa")
                        .font(.system(size: 15, weight: .bold, design: swatchFontDesign(for: displayTheme)))
                        .foregroundColor(displayTheme.headingColor)

                    Spacer(minLength: 4)

                    Circle()
                        .fill(displayTheme.linkColor)
                        .frame(width: 7, height: 7)
                }

                VStack(alignment: .leading, spacing: 2) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(displayTheme.textColor.opacity(0.65))
                        .frame(width: 44, height: 2.5)
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(displayTheme.secondaryTextColor.opacity(0.5))
                        .frame(width: 30, height: 2.5)
                }

                HStack(spacing: 3) {
                    Text(candidate.name)
                        .font(.system(size: 10.5, weight: isSelected ? .semibold : .medium))
                        .foregroundColor(displayTheme.textColor)
                        .lineLimit(1)

                    if !candidate.isPresetTheme {
                        Image(systemName: "sparkles")
                            .font(.system(size: 8))
                            .foregroundColor(displayTheme.linkColor)
                    } else if displayTheme.isModifiedFromDefaultPreset {
                        Circle()
                            .fill(displayTheme.linkColor.opacity(0.85))
                            .frame(width: 4.5, height: 4.5)
                    }
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .frame(width: 86, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(displayTheme.editorBackgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        isSelected ? Color.accentColor : Color.primary.opacity(0.14),
                        lineWidth: isSelected ? 2.0 : 1.0
                    )
            )
            .shadow(color: Color.black.opacity(isSelected ? 0.10 : 0.03), radius: 2, x: 0, y: 1)
        }
        .buttonStyle(.plain)
    }

    func swatchFontDesign(for theme: EditorTheme) -> Font.Design {
        let family = theme.bodyFontFamily.lowercased()
        if family.contains("mono") || family.contains("menlo") {
            return .monospaced
        } else if family.contains("serif") || family.contains("charter") || family.contains("palatino") || family.contains("georgia") || family.contains("baskerville") || family.contains("times") {
            return .serif
        }
        return .default
    }

    @ViewBuilder
    var tabPickerSection: some View {
        Picker("Category", selection: $selectedTab) {
            ForEach(SettingsTab.allCases) { tab in
                Text(tab.rawValue).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }
}
