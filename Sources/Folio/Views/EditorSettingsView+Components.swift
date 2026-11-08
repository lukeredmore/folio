import AppKit
import SwiftUI

extension EditorSettingsView {

    // MARK: - Tab 4: Editor & Software Updates

    @ViewBuilder
    var editorAndUpdatesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            settingsCard(title: "MARKDOWN EDITING") {
                Toggle("Pretty Mode (Render Images, Mermaid, SVGs & Inline HTML)", isOn: $viewModel.prettyModeEnabled)
                    .font(.system(size: 12))

                Divider().opacity(0.5)
                HStack {
                    Text("Wrap Markdown Source At")
                        .font(.system(size: 12))
                    Spacer()
                    Picker("Wrap Markdown Source At", selection: $viewModel.sourceLineWidth) {
                        ForEach(MarkdownSourceReflow.widthOptions, id: \.self) { width in
                            Text(width == 0 ? "Off" : "\(width) columns").tag(width)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                }
                .help("Rewraps a paragraph's source lines when you finish editing it. Line breaks inside a paragraph never show in the rendered view.")

                Divider().opacity(0.5)

                Toggle("Continuous Spellcheck", isOn: $viewModel.spellCheckEnabled)
                    .font(.system(size: 12))
            }

            remoteMediaAndAuthSection

            settingsCard(title: "SOFTWARE UPDATES & BUILD") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Folio \(AppUpdateManager.shared.currentVersion.displayString)")
                            .font(.system(size: 12, weight: .medium))
                        Text("Core Engine v\(AppUpdateManager.shared.currentVersion.engineVersion)")
                            .font(.system(size: 10.5))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("Check for Updates…") {
                        Task {
                            await AppUpdateManager.shared.checkForUpdates(userInitiated: true)
                        }
                    }
                    .controlSize(.small)
                }

                Divider().opacity(0.5)

                Toggle(
                    "Automatically check for updates on launch",
                    isOn: Binding(
                        get: { AppUpdateManager.shared.autoCheckForUpdates },
                        set: { AppUpdateManager.shared.autoCheckForUpdates = $0 }
                    )
                )
                .font(.system(size: 12))
            }
        }
    }

    // MARK: - Shared Row & Card Helpers

    func settingsCard<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        settingsCard(title: title, trailingHeader: { EmptyView() }, content: content)
    }

    func settingsCard<Trailing: View, Content: View>(
        title: String,
        @ViewBuilder trailingHeader: () -> Trailing,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary)
                Spacer()
                trailingHeader()
            }

            VStack(alignment: .leading, spacing: 8) {
                content()
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(Color.primary.opacity(0.035))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
            )
        }
    }

    func commitNewTheme() {
        let trimmed = newThemeName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        viewModel.saveCurrentTheme(as: trimmed)
        isSavingNewTheme = false
        newThemeName = ""
    }

    func fontPickerRow(
        title: String,
        selection: Binding<String>,
        options: [(label: String, value: String)]
    ) -> some View {
        let extraFamilies = EditorTheme.additionalSystemFontFamilies(excluding: options)
        return HStack {
            Text(title)
                .font(.system(size: 12))
            Spacer()
            FontFamilyPopUpButton(
                title: title,
                selection: selection,
                options: options,
                extraFamilies: extraFamilies
            )
            .frame(width: 245)
        }
    }

    func themeColorRow(_ label: String, color: Binding<ThemeColorRGBA>) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
                Text(color.wrappedValue.hexString)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            Spacer(minLength: 4)

            ColorPicker(
                "",
                selection: Binding<Color>(
                    get: { color.wrappedValue.color },
                    set: { newColor in
                        color.wrappedValue = ThemeColorRGBA(nsColor: NSColor(newColor))
                    }
                ),
                supportsOpacity: true
            )
            .labelsHidden()
            .fixedSize()
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        )
    }

    func settingSliderRow(
        title: String,
        valueText: String,
        value: Binding<CGFloat>,
        range: ClosedRange<CGFloat>,
        step: CGFloat
    ) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 12))
                .frame(width: 132, alignment: .leading)

            Slider(
                value: Binding<Double>(
                    get: { Double(value.wrappedValue) },
                    set: { raw in
                        let stepped = (CGFloat(raw) / step).rounded() * step
                        value.wrappedValue = min(range.upperBound, max(range.lowerBound, stepped))
                    }
                ),
                in: Double(range.lowerBound)...Double(range.upperBound)
            )

            Text(valueText)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 58, alignment: .trailing)
        }
    }
}

private struct FontFamilyPopUpButton: NSViewRepresentable {
    let title: String
    @Binding var selection: String
    let options: [(label: String, value: String)]
    let extraFamilies: [String]

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let popUp = NSPopUpButton(frame: .zero, pullsDown: false)
        popUp.setAccessibilityTitle(title)
        context.coordinator.configureMenu(for: popUp, options: options, extraFamilies: extraFamilies, selection: selection)
        return popUp
    }

    func updateNSView(_ nsView: NSPopUpButton, context: Context) {
        context.coordinator.selection = $selection
        context.coordinator.configureMenu(for: nsView, options: options, extraFamilies: extraFamilies, selection: selection)
    }

    @MainActor
    final class Coordinator: NSObject {
        var selection: Binding<String>

        init(selection: Binding<String>) { self.selection = selection }

        func configureMenu(
            for popUp: NSPopUpButton,
            options: [(label: String, value: String)],
            extraFamilies: [String],
            selection: String
        ) {
            let menu = NSMenu(title: popUp.accessibilityTitle() ?? "Font")
            var itemToSelect: NSMenuItem?

            func makeItem(title: String, value: String) -> NSMenuItem {
                let item = NSMenuItem(title: title, action: #selector(selectFontItem(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = value
                item.state = (value == selection) ? .on : .off
                return item
            }

            for option in options {
                let item = makeItem(title: option.label, value: option.value)
                if option.value == selection { itemToSelect = item }
                menu.addItem(item)
            }

            if itemToSelect == nil {
                let customItem = makeItem(title: selection, value: selection)
                menu.addItem(customItem)
                itemToSelect = customItem
            }

            if !extraFamilies.isEmpty {
                menu.addItem(.separator())
                let moreItem = NSMenuItem(title: "More", action: nil, keyEquivalent: "")
                let submenu = NSMenu(title: "More")
                for family in extraFamilies {
                    submenu.addItem(makeItem(title: family, value: family))
                }
                moreItem.submenu = submenu
                menu.addItem(moreItem)
            }

            popUp.menu = menu
            if let itemToSelect { popUp.select(itemToSelect) }
        }

        @objc func selectFontItem(_ sender: NSMenuItem) {
            guard let value = sender.representedObject as? String else { return }
            selection.wrappedValue = value
        }
    }
}
