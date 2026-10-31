import AppKit
import SwiftUI

enum SidebarFilterResult: Hashable {
    case file(URL)
    case match(UUID)
}

extension SidebarView {

    private var searchOptionsRow: some View {
        HStack(spacing: 4) {
            Toggle(isOn: $viewModel.showWorkspaceReplace) {
                Image(systemName: "arrow.left.arrow.right")
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .font(.system(size: 10.5, weight: .medium))
            .help("Toggle Replace in Files (Cmd+Shift+R)")

            Toggle("Aa", isOn: $viewModel.searchCaseSensitive)
                .toggleStyle(.button)
                .controlSize(.small)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .help("Case Sensitive")
                .onChange(of: viewModel.searchCaseSensitive) { _, _ in
                    viewModel.performWorkspaceSearch()
                }

            Toggle("ab", isOn: $viewModel.searchWholeWord)
                .toggleStyle(.button)
                .controlSize(.small)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .help("Whole Word")
                .onChange(of: viewModel.searchWholeWord) { _, _ in
                    viewModel.performWorkspaceSearch()
                }

            Toggle(".*", isOn: $viewModel.searchUseRegex)
                .toggleStyle(.button)
                .controlSize(.small)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .help("Regular Expression")
                .onChange(of: viewModel.searchUseRegex) { _, _ in
                    viewModel.performWorkspaceSearch()
                }

            Spacer()

            if !viewModel.workspaceSearchQuery.isEmpty {
                Text("\(viewModel.workspaceSearchMatches.count) \(viewModel.workspaceSearchMatches.count == 1 ? "match" : "matches")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private var workspaceReplaceRow: some View {
        HStack(spacing: 6) {
            TextField("Replace in files (Cmd+Shift+R)…", text: $viewModel.workspaceReplaceQuery)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .font(.system(size: 11.5))
                .onSubmit {
                    viewModel.replaceAllInWorkspace()
                }

            Button("All") {
                viewModel.replaceAllInWorkspace()
            }
            .controlSize(.small)
            .disabled(viewModel.workspaceSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help("Replace all occurrences across workspace files")
        }
    }

    // MARK: - Outline Tab Content
    private var filteredHeadings: [OutlineHeading] {
        let query = viewModel.outlineFilterText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return viewModel.headings }
        return viewModel.headings.filter {
            $0.title.localizedCaseInsensitiveContains(query)
        }
    }

    @ViewBuilder
    var outlineTabContent: some View {
        let headings = filteredHeadings
        if headings.isEmpty {
            if !viewModel.outlineFilterText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ContentUnavailableView.search(text: viewModel.outlineFilterText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    "Outline is Empty",
                    systemImage: "list.bullet.indent",
                    description: Text("Add Markdown (# H1) or LaTeX (\\section) headings to navigate sections.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            List(selection: selectedHeadingIDBinding) {
                Section("Document Outline") {
                    ForEach(headings) { heading in
                        HStack(spacing: 6) {
                            Text("H\(heading.level)")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .frame(width: 18, alignment: .leading)

                            Text(heading.title)
                                .fontWeight(heading.level == 1 ? .semibold : .regular)
                                .lineLimit(1)
                        }
                        .padding(.leading, CGFloat(max(0, heading.level - 1)) * 10.0)
                        .tag(Optional(heading.id))
                        .help("Jump to line \(heading.lineNumber)")
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }

    // MARK: - Search Tab Content
    private struct FileSearchGroup: Identifiable {
        let fileURL: URL
        let fileName: String
        let matches: [WorkspaceSearchMatch]
        var id: URL { fileURL }
    }

    private var groupedSearchMatches: [FileSearchGroup] {
        var groups: [FileSearchGroup] = []
        var indexByURL: [URL: Int] = [:]
        for match in viewModel.workspaceSearchMatches {
            if let idx = indexByURL[match.fileURL] {
                let existing = groups[idx]
                groups[idx] = FileSearchGroup(
                    fileURL: existing.fileURL,
                    fileName: existing.fileName,
                    matches: existing.matches + [match]
                )
            } else {
                indexByURL[match.fileURL] = groups.count
                groups.append(
                    FileSearchGroup(
                        fileURL: match.fileURL,
                        fileName: match.fileName,
                        matches: [match]
                    )
                )
            }
        }
        return groups
    }
    /// File-name matches first (cheap), then full-text matches across the workspace.
    @ViewBuilder
    var filterResultsContent: some View {
        let files = filteredFlatFiles
        List(selection: filterResultSelectionBinding) {
            if !files.isEmpty {
                Section("Files (\(files.count))") {
                    ForEach(files) { node in
                        articleRow(node).tag(Optional(SidebarFilterResult.file(node.url)))
                    }
                }
            }

            if viewModel.workspaceSearchMatches.isEmpty {
                Section("In Files") {
                    Label("No text matches for \"\(viewModel.workspaceSearchQuery)\"", systemImage: "magnifyingglass")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                }
            } else {
                ForEach(groupedSearchMatches) { group in
                    Section {
                        ForEach(group.matches) { match in
                            searchMatchRow(match).tag(Optional(SidebarFilterResult.match(match.id)))
                        }
                    } header: {
                        HStack(spacing: 4) {
                            Text(group.fileName)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 4)
                            Text("\(group.matches.count)")
                                .monospacedDigit()
                        }
                        .padding(.trailing, 8)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaBar(edge: .top) {
            VStack(spacing: 6) {
                searchOptionsRow
                if viewModel.showWorkspaceReplace {
                    workspaceReplaceRow
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
    }

    /// The line number fills the same column as the file icon in `SidebarArticleRow`.
    private func searchMatchRow(_ match: WorkspaceSearchMatch) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(match.lineNumber)")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .frame(minWidth: SidebarArticleRow.iconColumnWidth, alignment: .trailing)

            Text(match.lineSnippet)
                .font(.callout.monospaced())
                .lineLimit(2)

            if viewModel.showWorkspaceReplace {
                Spacer(minLength: 4)
                Button {
                    viewModel.replaceWorkspaceMatch(match)
                } label: {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.caption2.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .help("Replace this match")
            }
        }
    }

    // MARK: - Toolbar Menus

    /// Sidebar width at which the add menu gets its own toolbar button outside full screen.
    static let addButtonMinimumSidebarWidth: CGFloat = 330

    @ViewBuilder
    var addActions: some View {
        Button {
            viewModel.createNewFileInWorkspace()
        } label: {
            Label("New Markdown File (.md)", systemImage: "doc.badge.plus")
        }
        Button {
            viewModel.createNewLaTeXFileInWorkspace()
        } label: {
            Label("New LaTeX File (.tex)", systemImage: "function")
        }
        Divider()
        Button {
            viewModel.openFolderPanel()
        } label: {
            Label("Add Local Folder…", systemImage: "folder.badge.plus")
        }
        Button {
            viewModel.showAddRemoteModal = true
        } label: {
            Label("Connect Remote (SSH)…", systemImage: "network")
        }
    }

    var addMenu: some View {
        Menu {
            addActions
        } label: {
            Label("Add", systemImage: "plus")
        }
        .menuIndicator(.hidden)
        .help("New File, Add Folder, or Connect Remote")
    }

    /// Holds the add actions too unless `addMenu` shows them.
    func workspaceOptionsMenu(includesAddActions: Bool) -> some View {
        Menu {
            if includesAddActions {
                addActions
                Divider()
            }
            if !remoteManager.mounts.isEmpty {
                Button {
                    Task {
                        await remoteManager.syncAllMounts(isBackground: false)
                    }
                } label: {
                    Label("Sync All Remotes Now", systemImage: "arrow.triangle.2.circlepath")
                }
                Divider()
            }
            Picker("View Mode", selection: $viewModel.fileDisplayStyle) {
                Label("File Tree View", systemImage: "list.bullet.indent").tag(FileDisplayStyle.tree)
                Label("Article List View", systemImage: "list.bullet").tag(FileDisplayStyle.list)
            }
            Picker("Sort By", selection: $viewModel.fileSortOrder) {
                ForEach(FileSortOrder.allCases) { order in
                    Text(order.rawValue).tag(order)
                }
            }
            .onChange(of: viewModel.fileSortOrder) { _, _ in
                viewModel.sortFileNodes()
            }
        } label: {
            Label("Workspace Options", systemImage: "ellipsis")
        }
        .menuIndicator(.hidden)
        .help("Workspace & Sort Options")
    }
}
