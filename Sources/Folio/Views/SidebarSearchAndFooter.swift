import AppKit
import SwiftUI

extension SidebarView {

    // MARK: - Top Navigation Bar
    var sidebarHeaderBar: some View {
        VStack(spacing: 6) {
            Picker("Sidebar Mode", selection: $viewModel.activeSidebarTab) {
                ForEach(SidebarTab.allCases) { tab in
                    Label(tab.rawValue, systemImage: tab.systemImage)
                        .tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .help("Switch between Files (Ctrl+Cmd+2/3), Outline (Ctrl+Cmd+1), and Search (Cmd+Shift+F)")

            if viewModel.activeSidebarTab == .search {
                searchOptionsRow

                if viewModel.showWorkspaceReplace {
                    workspaceReplaceRow
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

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
                    description: Text("Add Markdown headings (# H1, ## H2) to navigate sections.")
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

    @ViewBuilder
    var searchTabContent: some View {
        if viewModel.workspaceSearchMatches.isEmpty {
            if viewModel.workspaceSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ContentUnavailableView(
                    "Search Workspace",
                    systemImage: "magnifyingglass",
                    description: Text("Use the search field to find text across all Markdown files.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView.search(text: viewModel.workspaceSearchQuery)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            List(selection: selectedSearchMatchBinding) {
                ForEach(groupedSearchMatches) { group in
                    Section {
                        ForEach(group.matches) { match in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("\(match.lineNumber)")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .frame(minWidth: 24, alignment: .trailing)

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
                            .tag(Optional(match.id))
                        }
                    } header: {
                        HStack {
                            Label(group.fileName, systemImage: "doc.text")
                                .lineLimit(1)
                            Spacer()
                            Text("\(group.matches.count)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }

    // MARK: - Bottom Action Bar
    var sidebarFooterBar: some View {
        HStack(spacing: 8) {
            Button {
                viewModel.createNewFileInWorkspace()
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("New Markdown File in Workspace")

            Button {
                viewModel.showAddRemoteModal = true
            } label: {
                Image(systemName: "network")
                    .foregroundStyle(
                        !remoteManager.unhealthyMounts.isEmpty
                            ? Color.orange
                            : (!remoteManager.mounts.isEmpty ? viewModel.theme.linkColor : Color.secondary)
                    )
            }
            .buttonStyle(.borderless)
            .help("Connect Remote Folder or File via SSH (Cmd+Option+Shift+R)")

            Spacer(minLength: 4)

            Menu {
                if let folder = viewModel.workspaceFolderURL {
                    Text("Local: \(folder.lastPathComponent)")
                }
                if !remoteManager.mounts.isEmpty {
                    Text("Remotes: \(remoteManager.mounts.count) connected")
                }
                Divider()
                Button {
                    viewModel.openFolderPanel()
                } label: {
                    Label("Open Local Folder…", systemImage: "folder.badge.plus")
                }
                Button {
                    viewModel.showAddRemoteModal = true
                } label: {
                    Label("Connect Remote (SSH)…", systemImage: "network")
                }
                if !remoteManager.mounts.isEmpty {
                    Button {
                        Task {
                            await remoteManager.syncAllMounts(isBackground: false)
                        }
                    } label: {
                        Label("Sync All Remotes Now", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                Divider()
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
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Workspace & Sort Options")

            Button {
                viewModel.fileDisplayStyle = (viewModel.fileDisplayStyle == .tree) ? .list : .tree
            } label: {
                Image(systemName: viewModel.fileDisplayStyle == .tree ? "list.bullet.indent" : "list.bullet")
            }
            .buttonStyle(.borderless)
            .help("Switch between File Tree and Article List view")
        }
        .controlSize(.small)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
