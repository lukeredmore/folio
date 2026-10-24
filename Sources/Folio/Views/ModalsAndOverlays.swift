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
        viewModel.quickOpenFilteredFiles
    }

    private var directPathCandidate: QuickOpenPathCandidate? {
        guard let candidate = viewModel.resolveQuickOpenPathCandidate(for: viewModel.quickOpenQuery) else {
            return nil
        }
        if candidate.exists && !candidate.isDirectory && candidate.lineNumber == nil {
            let candidateResolved = candidate.url.resolvingSymlinksInPath()
            if filteredFiles.contains(where: { $0.url.resolvingSymlinksInPath() == candidateResolved }) {
                return nil
            }
        }
        return candidate
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(viewModel.theme.linkColor)

                TextField("Search file by name or paste path (Shift+Shift)...", text: $viewModel.quickOpenQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .foregroundColor(viewModel.theme.textColor)
                    .focused($isSearchFocused)
                    .onSubmit {
                        viewModel.submitQuickOpen()
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
                    if let candidate = directPathCandidate {
                        directPathCandidateRow(candidate)
                    }

                    if filteredFiles.isEmpty && directPathCandidate == nil {
                        Text("No matching files in workspace — paste any file or folder path to open")
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
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(viewModel.theme.sidebarBackgroundColor)
                .shadow(color: Color.black.opacity(0.28), radius: 20, x: 0, y: 10)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(viewModel.theme.borderColor, lineWidth: 1)
        )
        .onAppear {
            isSearchFocused = true
        }
    }

    @ViewBuilder
    private func directPathCandidateRow(_ candidate: QuickOpenPathCandidate) -> some View {
        let iconName = !candidate.exists
            ? "doc.badge.plus"
            : (candidate.isDirectory ? "folder.fill" : "doc.text.fill")
        let titleText: String = {
            let name = candidate.url.lastPathComponent
            if !candidate.exists {
                return "Create & Open \"\(name)\""
            }
            if candidate.isDirectory {
                return "Open Folder \"\(name)\""
            }
            if let line = candidate.lineNumber {
                return "\(name):\(line)"
            }
            return name
        }()

        Button {
            viewModel.openQuickOpenCandidate(candidate)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: iconName)
                    .font(.system(size: 14))
                    .foregroundColor(viewModel.theme.linkColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(titleText)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(viewModel.theme.textColor)
                    Text(candidate.url.path)
                        .font(.system(size: 10.5))
                        .foregroundColor(viewModel.theme.secondaryTextColor)
                        .lineLimit(1)
                }
                Spacer()
                Text("Return ↵")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(viewModel.theme.secondaryTextColor)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(viewModel.theme.linkColor.opacity(0.12))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
