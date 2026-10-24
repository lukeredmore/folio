import AppKit
import SwiftUI

struct WorkspaceSearchTabView: View {
    @ObservedObject var viewModel: EditorWorkspaceViewModel
    @FocusState private var isSearchFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.12)) {
                            viewModel.showWorkspaceReplace.toggle()
                        }
                    } label: {
                        Image(systemName: viewModel.showWorkspaceReplace ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(viewModel.theme.secondaryTextColor)
                            .frame(width: 12, height: 12)
                    }
                    .buttonStyle(.plain)
                    .help("Toggle Replace in Files (Cmd+Shift+R)")

                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundColor(viewModel.theme.secondaryTextColor)

                    TextField("Find in files (Cmd+Shift+F)...", text: $viewModel.workspaceSearchQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundColor(viewModel.theme.textColor)
                        .focused($isSearchFieldFocused)
                        .onSubmit {
                            viewModel.performWorkspaceSearch()
                        }
                        .onChange(of: viewModel.workspaceSearchQuery) { _, _ in
                            viewModel.performWorkspaceSearch()
                        }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(viewModel.theme.editorBackgroundColor)
                )

                if viewModel.showWorkspaceReplace {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.left.arrow.right")
                            .font(.system(size: 10.5))
                            .foregroundColor(viewModel.theme.secondaryTextColor)
                            .padding(.leading, 14)

                        TextField("Replace in files (Cmd+Shift+R)...", text: $viewModel.workspaceReplaceQuery)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                            .foregroundColor(viewModel.theme.textColor)
                            .onSubmit {
                                viewModel.replaceAllInWorkspace()
                            }

                        Button("All") {
                            viewModel.replaceAllInWorkspace()
                        }
                        .controlSize(.mini)
                        .disabled(viewModel.workspaceSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .help("Replace all occurrences across workspace files")
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(viewModel.theme.editorBackgroundColor)
                    )
                }

                // Search option toggles (Case Sensitive, Whole Word, Regex)
                HStack(spacing: 6) {
                    searchTogglePill(label: "Aa", help: "Case Sensitive", isOn: $viewModel.searchCaseSensitive)
                    searchTogglePill(label: "ab", help: "Whole Word", isOn: $viewModel.searchWholeWord)
                    searchTogglePill(label: ".*", help: "Regular Expression", isOn: $viewModel.searchUseRegex)
                    Spacer()
                    Text("\(viewModel.workspaceSearchMatches.count) hits")
                        .font(.system(size: 10.5))
                        .foregroundColor(viewModel.theme.secondaryTextColor)
                }
            }
            .padding(8)

            Divider()
                .overlay(viewModel.theme.borderColor)

            if viewModel.workspaceSearchMatches.isEmpty {
                VStack(spacing: 6) {
                    Text(viewModel.workspaceSearchQuery.isEmpty ? "Type to search across files" : "No matches found")
                        .font(.system(size: 12))
                        .foregroundColor(viewModel.theme.secondaryTextColor)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(viewModel.workspaceSearchMatches) { match in
                            HStack(spacing: 4) {
                                Button {
                                    viewModel.jumpToSearchMatch(match)
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack {
                                            Image(systemName: "doc.text")
                                                .font(.system(size: 10))
                                                .foregroundColor(viewModel.theme.linkColor)
                                            Text(match.fileName)
                                                .font(.system(size: 11.5, weight: .semibold))
                                                .foregroundColor(viewModel.theme.textColor)
                                                .lineLimit(1)
                                            Spacer()
                                            Text(":\(match.lineNumber)")
                                                .font(.system(size: 10, design: .monospaced))
                                                .foregroundColor(viewModel.theme.secondaryTextColor)
                                        }
                                        Text(match.lineSnippet)
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundColor(viewModel.theme.secondaryTextColor)
                                            .lineLimit(2)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)

                                if viewModel.showWorkspaceReplace {
                                    Button {
                                        viewModel.replaceWorkspaceMatch(match)
                                    } label: {
                                        Image(systemName: "arrow.turn.down.right")
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundColor(viewModel.theme.linkColor)
                                            .padding(4)
                                    }
                                    .buttonStyle(.plain)
                                    .help("Replace this match")
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(viewModel.theme.editorBackgroundColor.opacity(0.5))
                            )
                        }
                    }
                    .padding(6)
                }
            }
        }
        .onAppear {
            isSearchFieldFocused = true
        }
        .onChange(of: viewModel.workspaceSearchFocusRequestID) { _, _ in
            isSearchFieldFocused = true
        }
    }

    private func searchTogglePill(label: String, help: String, isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
            viewModel.performWorkspaceSearch()
        } label: {
            Text(label)
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .foregroundColor(isOn.wrappedValue ? .white : viewModel.theme.secondaryTextColor)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isOn.wrappedValue ? viewModel.theme.linkColor : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

extension SidebarView {
    // MARK: - Search Tab
    var searchTabContent: some View {
        WorkspaceSearchTabView(viewModel: viewModel)
    }

    // MARK: - Sidebar Footer
    var sidebarFooter: some View {
        HStack(spacing: 10) {
            Button {
                viewModel.createNewFileInWorkspace()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12))
                    .foregroundColor(viewModel.theme.secondaryTextColor)
            }
            .buttonStyle(.plain)
            .help("New File in Workspace")

            Button {
                viewModel.showAddRemoteModal = true
            } label: {
                Image(systemName: "network")
                    .font(.system(size: 11.5))
                    .foregroundColor(
                        !remoteManager.unhealthyMounts.isEmpty
                            ? Color.orange
                            : (!remoteManager.mounts.isEmpty ? viewModel.theme.linkColor : viewModel.theme.secondaryTextColor)
                    )
            }
            .buttonStyle(.plain)
            .help("Connect Remote Folder or File via SSH (Cmd+Option+Shift+R)")

            Menu {
                if let folder = viewModel.workspaceFolderURL {
                    Text("Local: \(folder.lastPathComponent)")
                }
                if !remoteManager.mounts.isEmpty {
                    Text("Remotes: \(remoteManager.mounts.count) connected")
                }
                Divider()
                Button("Open Local Folder...") {
                    viewModel.openFolderPanel()
                }
                Button("Connect Remote Folder or File (SSH)...") {
                    viewModel.showAddRemoteModal = true
                }
                if !remoteManager.mounts.isEmpty {
                    Button("Sync All Remotes Now") {
                        Task {
                            await remoteManager.syncAllMounts(isBackground: false)
                        }
                    }
                }
                Divider()
                Picker("View Mode", selection: $viewModel.fileDisplayStyle) {
                    Text("File Tree View").tag(FileDisplayStyle.tree)
                    Text("File List View").tag(FileDisplayStyle.list)
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
                HStack(spacing: 4) {
                    Image(systemName: "folder")
                        .font(.system(size: 11))
                    Text(workspaceFooterLabel)
                        .font(.system(size: 11.5))
                        .lineLimit(1)
                }
                .foregroundColor(viewModel.theme.secondaryTextColor)
            }
            .menuStyle(.borderlessButton)

            Spacer()

            Button {
                viewModel.fileDisplayStyle = (viewModel.fileDisplayStyle == .tree) ? .list : .tree
            } label: {
                Image(systemName: viewModel.fileDisplayStyle == .tree ? "list.bullet.indent" : "list.bullet")
                    .font(.system(size: 11.5))
                    .foregroundColor(viewModel.theme.secondaryTextColor)
            }
            .buttonStyle(.plain)
            .help("Switch between File Tree and File List view")
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(viewModel.theme.sidebarBackgroundColor)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(viewModel.theme.borderColor)
                .frame(height: 1)
        }
    }

    var workspaceFooterLabel: String {
        if let folder = viewModel.workspaceFolderURL {
            if remoteManager.mounts.isEmpty {
                return folder.lastPathComponent
            }
            return "\(folder.lastPathComponent) + \(remoteManager.mounts.count) remote"
        }
        if let firstMount = remoteManager.mounts.first {
            return remoteManager.mounts.count == 1
                ? firstMount.label
                : "\(remoteManager.mounts.count) Remotes"
        }
        return "Workspace"
    }
}
