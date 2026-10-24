import AppKit
import SwiftUI
import UniformTypeIdentifiers

public struct QuickOpenModalView: View {
    @ObservedObject var viewModel: EditorWorkspaceViewModel
    @FocusState private var isSearchFocused: Bool

    public init(viewModel: EditorWorkspaceViewModel) {
        self.viewModel = viewModel
    }

    private var filteredFiles: [WorkspaceFileNode] {
        let q = viewModel.quickOpenQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty {
            return Array(viewModel.flatMarkdownFiles.prefix(25))
        }
        return viewModel.flatMarkdownFiles.filter {
            $0.name.localizedCaseInsensitiveContains(q) ||
            $0.url.path.localizedCaseInsensitiveContains(q) ||
            ($0.remoteConnectionString?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(viewModel.theme.linkColor)

                TextField("Search file by name (Cmd+P)...", text: $viewModel.quickOpenQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .foregroundColor(viewModel.theme.textColor)
                    .focused($isSearchFocused)
                    .onSubmit {
                        if let first = filteredFiles.first {
                            viewModel.openFile(at: first.url)
                            viewModel.showQuickOpen = false
                        }
                    }

                Button {
                    viewModel.showQuickOpen = false
                } label: {
                    Text("ESC")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(viewModel.theme.secondaryTextColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(viewModel.theme.borderColor, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()
                .overlay(viewModel.theme.borderColor)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if filteredFiles.isEmpty {
                        Text("No matching files in workspace")
                            .font(.system(size: 12.5))
                            .foregroundColor(viewModel.theme.secondaryTextColor)
                            .padding(16)
                    } else {
                        ForEach(filteredFiles) { node in
                            Button {
                                viewModel.openFile(at: node.url)
                                viewModel.showQuickOpen = false
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: node.isRemote ? "network" : (node.isMarkdownFile ? "doc.text.fill" : "doc"))
                                        .font(.system(size: 14))
                                        .foregroundColor(viewModel.theme.linkColor)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(node.name)
                                            .font(.system(size: 13, weight: .medium))
                                            .foregroundColor(viewModel.theme.textColor)
                                        Text(node.remoteConnectionString ?? node.url.deletingLastPathComponent().path)
                                            .font(.system(size: 10.5))
                                            .foregroundColor(viewModel.theme.secondaryTextColor)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(viewModel.currentFileURL == node.url ? viewModel.theme.linkColor.opacity(0.15) : Color.clear)
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(8)
            }
            .frame(maxHeight: 280)
        }
        .frame(width: 500)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(viewModel.theme.borderColor, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.28), radius: 20, x: 0, y: 10)
        .onAppear {
            isSearchFocused = true
        }
    }
}

public struct WordCountPopoverView: View {
    @ObservedObject var viewModel: EditorWorkspaceViewModel

    public init(viewModel: EditorWorkspaceViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("DOCUMENT STATISTICS")
                .font(.system(size: 10.5, weight: .bold))
                .foregroundColor(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                GridRow {
                    Text("Reading Time")
                        .foregroundColor(.secondary)
                    Text(viewModel.stats.readingTimeString)
                        .fontWeight(.semibold)
                        .monospacedDigit()
                }
                GridRow {
                    Text("Words")
                        .foregroundColor(.secondary)
                    Text("\(viewModel.stats.words)")
                        .fontWeight(.semibold)
                        .monospacedDigit()
                }
                GridRow {
                    Text("Lines")
                        .foregroundColor(.secondary)
                    Text("\(viewModel.stats.lines)")
                        .fontWeight(.semibold)
                        .monospacedDigit()
                }
                GridRow {
                    Text("Characters")
                        .foregroundColor(.secondary)
                    Text("\(viewModel.stats.characters)")
                        .fontWeight(.semibold)
                        .monospacedDigit()
                }
                GridRow {
                    Text("Without Spaces")
                        .foregroundColor(.secondary)
                    Text("\(viewModel.stats.charactersWithoutSpaces)")
                        .fontWeight(.semibold)
                        .monospacedDigit()
                }
                if viewModel.stats.selectedCharacters > 0 {
                    Divider()
                    GridRow {
                        Text("Selected Words")
                            .foregroundColor(.secondary)
                        Text("\(viewModel.stats.selectedWords)")
                            .fontWeight(.semibold)
                            .monospacedDigit()
                    }
                    GridRow {
                        Text("Selected Chars")
                            .foregroundColor(.secondary)
                        Text("\(viewModel.stats.selectedCharacters)")
                            .fontWeight(.semibold)
                            .monospacedDigit()
                    }
                }
            }
            .font(.system(size: 12.5))
        }
        .padding(14)
        .frame(width: 230)
    }
}

public struct InsertTableModalView: View {
    @ObservedObject var viewModel: EditorWorkspaceViewModel
    @State private var rows: Int = 3
    @State private var columns: Int = 3

    public init(viewModel: EditorWorkspaceViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Insert Table")
                .font(.system(size: 14, weight: .semibold))

            HStack(spacing: 16) {
                Stepper("Rows: \(rows)", value: $rows, in: 1...25)
                Stepper("Columns: \(columns)", value: $columns, in: 1...10)
            }
            .font(.system(size: 12.5))

            HStack {
                Spacer()
                Button("Cancel") {
                    viewModel.showInsertTableSheet = false
                }
                Button("Insert") {
                    viewModel.insertTable(rows: rows, columns: columns)
                    viewModel.showInsertTableSheet = false
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .frame(width: 340)
    }
}

public struct FindReplaceBannerView: View {
    @ObservedObject var viewModel: EditorWorkspaceViewModel

    public init(viewModel: EditorWorkspaceViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11.5))
                .foregroundColor(viewModel.theme.secondaryTextColor)

            TextField("Find in document...", text: $viewModel.findQuery)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .frame(width: 180)
                .onSubmit {
                    viewModel.findNextInDocument()
                }

            TextField("Replace with...", text: $viewModel.replaceQuery)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .frame(width: 160)

            Button("Next") {
                viewModel.findNextInDocument()
            }
            .controlSize(.small)

            Button("Replace") {
                viewModel.replaceCurrentMatch()
            }
            .controlSize(.small)

            Button("Replace All") {
                viewModel.replaceAllInDocument()
            }
            .controlSize(.small)

            Spacer()

            Button {
                viewModel.showFindReplaceBar = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(viewModel.theme.secondaryTextColor)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(viewModel.theme.sidebarBackgroundColor)
        .overlay(alignment: .bottom) {
            Divider().overlay(viewModel.theme.borderColor)
        }
    }
}
