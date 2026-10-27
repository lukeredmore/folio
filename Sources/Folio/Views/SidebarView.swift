import AppKit
import SwiftUI

public struct SidebarView: View {
    @ObservedObject var viewModel: EditorWorkspaceViewModel
    @ObservedObject var remoteManager: RemoteWorkspaceManager
    @State var isLocalSectionExpanded: Bool = true
    @State var isRemoteSectionExpanded: Bool = true
    @State var selectedSearchMatchID: UUID?

    public init(viewModel: EditorWorkspaceViewModel) {
        self.viewModel = viewModel
        self.remoteManager = viewModel.remoteWorkspaceManager
    }

    var selectedFileURLBinding: Binding<URL?> {
        Binding<URL?>(
            get: { viewModel.currentFileURL },
            set: { newURL in
                if let url = newURL, url != viewModel.currentFileURL {
                    viewModel.openFile(at: url)
                }
            }
        )
    }

    var selectedHeadingIDBinding: Binding<String?> {
        Binding<String?>(
            get: { viewModel.activeHeadingID },
            set: { newID in
                guard let id = newID,
                      id != viewModel.activeHeadingID,
                      let heading = viewModel.headings.first(where: { $0.id == id }) else {
                    return
                }
                viewModel.scrollToHeading(heading)
            }
        )
    }

    var selectedSearchMatchBinding: Binding<UUID?> {
        Binding<UUID?>(
            get: { selectedSearchMatchID },
            set: { newID in
                selectedSearchMatchID = newID
                if let id = newID,
                   let match = viewModel.workspaceSearchMatches.first(where: { $0.id == id }) {
                    viewModel.jumpToSearchMatch(match)
                }
            }
        )
    }

    private var sidebarSearchTextBinding: Binding<String> {
        switch viewModel.activeSidebarTab {
        case .files:
            return $viewModel.fileFilterText
        case .outline:
            return $viewModel.outlineFilterText
        case .search:
            return $viewModel.workspaceSearchQuery
        }
    }

    private var sidebarSearchPrompt: String {
        switch viewModel.activeSidebarTab {
        case .files:
            return "Filter files"
        case .outline:
            return "Filter headings"
        case .search:
            return "Search workspace"
        }
    }

    public var body: some View {
        sidebarMainContent
            .searchable(
                text: sidebarSearchTextBinding,
                placement: .sidebar,
                prompt: sidebarSearchPrompt
            )
            .onSubmit(of: .search) {
                if viewModel.activeSidebarTab == .search {
                    viewModel.performWorkspaceSearch()
                }
            }
            .onChange(of: viewModel.workspaceSearchQuery) { _, _ in
                if viewModel.activeSidebarTab == .search {
                    viewModel.performWorkspaceSearch()
                }
            }
            .background(
                SidebarModeSegmentedControl(
                    activeTab: $viewModel.activeSidebarTab,
                    isVisible: viewModel.showSidebar
                )
                .frame(width: 0, height: 0)
            )
            .safeAreaBar(edge: .bottom) {
                sidebarFooterBar
            }
    }

    @ViewBuilder
    private var sidebarMainContent: some View {
        switch viewModel.activeSidebarTab {
        case .files:
            filesTabContent
        case .outline:
            outlineTabContent
        case .search:
            searchTabContent
        }
    }

    // MARK: - Files Tab Content
    private var filteredFlatFiles: [WorkspaceFileNode] {
        let query = viewModel.fileFilterText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return viewModel.flatMarkdownFiles }
        return viewModel.flatMarkdownFiles.filter {
            $0.name.localizedCaseInsensitiveContains(query) ||
            $0.url.path.localizedCaseInsensitiveContains(query) ||
            ($0.remoteConnectionString?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    @ViewBuilder
    private var filesTabContent: some View {
        if viewModel.rootFileNodes.isEmpty {
            ContentUnavailableView {
                Label("No Open Folder", systemImage: "folder.badge.plus")
            } description: {
                Text("Open a local Markdown or LaTeX workspace, or mount a remote folder via SSH.")
            } actions: {
                VStack(spacing: 8) {
                    Button("Open Folder…") {
                        viewModel.openFolderPanel()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Button {
                        viewModel.showAddRemoteModal = true
                    } label: {
                        Label("Connect Remote (SSH)…", systemImage: "network")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !viewModel.fileFilterText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.fileDisplayStyle == .list {
            let files = filteredFlatFiles
            if files.isEmpty {
                ContentUnavailableView.search(text: viewModel.fileFilterText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: selectedFileURLBinding) {
                    Section(
                        viewModel.fileFilterText.isEmpty
                            ? "Articles (\(files.count))"
                            : "Matching Files (\(files.count))"
                    ) {
                        ForEach(files) { node in
                            SidebarArticleRow(
                                node: node,
                                isSelected: viewModel.currentFileURL == node.url,
                                accentColor: viewModel.theme.linkColor,
                                mountConnectionState: node.remoteMountID.flatMap { remoteManager.connectionStates[$0] },
                                liveSyncStatus: remoteManager.syncStatus(forLocalURL: node.url),
                                onNewFileInDirectory: { viewModel.createNewFileInWorkspace(in: $0) },
                                onNewLaTeXFileInDirectory: { viewModel.createNewLaTeXFileInWorkspace(in: $0) },
                                onSyncMount: { mountID in
                                    Task { await remoteManager.syncMount(id: mountID, isBackground: false) }
                                },
                                onDisconnectMount: { viewModel.disconnectRemoteMount(id: $0) },
                                onDeleteItem: { viewModel.requestDeleteWorkspaceItem(at: $0) },
                                sshDisplayPath: remoteManager.remoteSSHDisplayPath(forLocalURL: node.url) ?? node.remoteConnectionString
                            )
                            .tag(Optional(node.url))
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        } else {
            let localNodes = viewModel.rootFileNodes.filter { !$0.isRemoteRoot }
            let remoteNodes = viewModel.rootFileNodes.filter { $0.isRemoteRoot }

            List(selection: selectedFileURLBinding) {
                if !localNodes.isEmpty {
                    Section(isExpanded: $isLocalSectionExpanded) {
                        OutlineGroup(localNodes, children: \.children) { node in
                            SidebarFileRow(
                                node: node,
                                accentColor: viewModel.theme.linkColor,
                                mountConnectionState: node.remoteMountID.flatMap { remoteManager.connectionStates[$0] },
                                liveSyncStatus: remoteManager.syncStatus(forLocalURL: node.url),
                                onNewFileInDirectory: { viewModel.createNewFileInWorkspace(in: $0) },
                                onNewLaTeXFileInDirectory: { viewModel.createNewLaTeXFileInWorkspace(in: $0) },
                                onSyncMount: { mountID in
                                    Task { await remoteManager.syncMount(id: mountID, isBackground: false) }
                                },
                                onDisconnectMount: { viewModel.disconnectRemoteMount(id: $0) },
                                onDeleteItem: { viewModel.requestDeleteWorkspaceItem(at: $0) },
                                sshDisplayPath: remoteManager.remoteSSHDisplayPath(forLocalURL: node.url) ?? node.remoteConnectionString
                            )
                        }
                    } header: {
                        Text(viewModel.workspaceFolderURL?.lastPathComponent ?? "Workspace")
                    }
                }

                if !remoteNodes.isEmpty {
                    Section(isExpanded: $isRemoteSectionExpanded) {
                        OutlineGroup(remoteNodes, children: \.children) { node in
                            SidebarFileRow(
                                node: node,
                                accentColor: viewModel.theme.linkColor,
                                mountConnectionState: node.remoteMountID.flatMap { remoteManager.connectionStates[$0] },
                                liveSyncStatus: remoteManager.syncStatus(forLocalURL: node.url),
                                onNewFileInDirectory: { viewModel.createNewFileInWorkspace(in: $0) },
                                onNewLaTeXFileInDirectory: { viewModel.createNewLaTeXFileInWorkspace(in: $0) },
                                onSyncMount: { mountID in
                                    Task { await remoteManager.syncMount(id: mountID, isBackground: false) }
                                },
                                onDisconnectMount: { viewModel.disconnectRemoteMount(id: $0) },
                                onDeleteItem: { viewModel.requestDeleteWorkspaceItem(at: $0) },
                                sshDisplayPath: remoteManager.remoteSSHDisplayPath(forLocalURL: node.url) ?? node.remoteConnectionString
                            )
                        }
                    } header: {
                        Text("Remote (SSH)")
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }
}
