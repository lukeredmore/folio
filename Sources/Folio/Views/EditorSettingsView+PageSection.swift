import SwiftUI

extension EditorSettingsView {

    /// Canvas layout (alignment and column width) and print settings.
    var pageAndPrintSection: some View {
        VStack(alignment: .leading, spacing: 10) {
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
                Text("The column is always centered. Tables wider than the column are centered at full width, and scroll sideways on their own when wider than the window.")
                    .font(.system(size: 10.5))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            settingsCard(title: "PRINTING") {
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
                Text("Prints with 0.75 in margins. Dark themes print with the light theme.")
                    .font(.system(size: 10.5))
                    .foregroundColor(.secondary)
                HStack {
                    Spacer()
                    Button("Print…") { viewModel.printDocument() }
                        .controlSize(.small)
                }
            }
        }
    }
}
