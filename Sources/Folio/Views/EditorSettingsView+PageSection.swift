import SwiftUI

extension EditorSettingsView {

    /// Canvas layout (alignment and column width) and print / PDF page setup settings.
    var pageAndPrintSection: some View {
        let resolved = viewModel.resolvedPrintPageLayout()

        return VStack(alignment: .leading, spacing: 10) {
            settingsCard(title: "CANVAS") {
                HStack {
                    Text("Text Alignment")
                        .font(.system(size: 12))
                    Spacer()
                    Picker("Text Alignment", selection: $viewModel.textAlignment) {
                        ForEach(EditorTextAlignment.allCases) { alignment in
                            Text(alignment.title).tag(alignment)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 170)
                }
                .help("Applies to paragraphs, list items, and quotes. Headings, code, and tables stay left-aligned.")

                Divider().opacity(0.5)

                settingSliderRow(
                    title: "Column Width",
                    valueText: "\(Int(viewModel.typography.maxColumnWidth)) pt",
                    value: $viewModel.typography.maxColumnWidth,
                    range: 480.0...1600.0,
                    step: 20.0
                )
                Text(
                    "The column is always centered. Tables wider than the column are centered at full width, and scroll sideways on their own when wider than the window."
                )
                .font(.system(size: 10.5))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            settingsCard(title: "PRINT & PDF PAGE SETUP") {
                HStack {
                    Text("Paper Size")
                        .font(.system(size: 12))
                    Spacer()
                    Picker("Paper Size", selection: $viewModel.printPaperSize) {
                        ForEach(PrintPaperSize.allCases) { paper in
                            Text(paper.title).tag(paper)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 210)
                }

                HStack {
                    Text("Orientation")
                        .font(.system(size: 12))
                    Spacer()
                    Picker("Orientation", selection: $viewModel.printOrientation) {
                        ForEach(PrintOrientation.allCases) { orientation in
                            Text(orientation.title).tag(orientation)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 210)
                }

                Divider().opacity(0.5)

                HStack {
                    Text("Margin Preset")
                        .font(.system(size: 12))
                    Spacer()
                    Picker(
                        "Margin Preset",
                        selection: Binding(
                            get: { viewModel.printMargins.preset },
                            set: { preset in
                                if let margins = preset.margins {
                                    viewModel.printMargins = margins
                                }
                            }
                        )
                    ) {
                        ForEach(PrintMarginPreset.allCases) { preset in
                            Text(preset.title).tag(preset)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 210)
                }

                marginInchesSliderRow(
                    title: "Top Margin",
                    points: $viewModel.printMargins.top
                )
                marginInchesSliderRow(
                    title: "Bottom Margin",
                    points: $viewModel.printMargins.bottom
                )
                marginInchesSliderRow(
                    title: "Left Margin",
                    points: $viewModel.printMargins.left
                )
                marginInchesSliderRow(
                    title: "Right Margin",
                    points: $viewModel.printMargins.right
                )

                if resolved.hasDocumentOverrides, let summary = resolved.overrideSummary {
                    Divider().opacity(0.5)
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "doc.badge.gearshape")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.accentColor)
                            .padding(.top, 1)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Document Page Directives Active")
                                .font(.system(size: 11, weight: .semibold))
                            Text("Effective print layout: \(summary)")
                                .font(.system(size: 10.5))
                                .foregroundColor(.secondary)
                        }
                    }
                } else {
                    Text(
                        "You can also configure paper size and margins in document source via \\usepackage[margin=1in,a4paper]{geometry} (LaTeX) or YAML frontmatter / <!-- page: margin=1in --> (Markdown)."
                    )
                    .font(.system(size: 10.5))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Spacer()
                    Button("Print / Save as PDF…") { viewModel.printDocument() }
                        .controlSize(.small)
                }
            }
        }
    }

    private func marginInchesSliderRow(title: String, points: Binding<CGFloat>) -> some View {
        let inchesBinding = Binding<CGFloat>(
            get: { points.wrappedValue / 72.0 },
            set: { points.wrappedValue = $0 * 72.0 }
        )
        return settingSliderRow(
            title: title,
            valueText: String(format: "%.2f in (%.0f pt)", points.wrappedValue / 72.0, points.wrappedValue),
            value: inchesBinding,
            range: 0.25...2.50,
            step: 0.05
        )
    }
}
