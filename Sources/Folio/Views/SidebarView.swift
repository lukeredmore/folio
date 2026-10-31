import AppKit
import SwiftUI

public struct SidebarView: View {
    @ObservedObject var viewModel: EditorWorkspaceViewModel
    @ObservedObject var remoteManager: RemoteWorkspaceManager
    @State var selectedSearchMatchID: UUID?
    @State var sidebarWidth: CGFloat = 0
    @State var isWindowFullScreen: Bool = false

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
                    let heading = viewModel.headings.first(where: { $0.id == id })
                else {
                    return
                }
                viewModel.scrollToHeading(heading)
            }
        )
    }

    /// One selection for the filter results list, which mixes file rows and match rows.
    var filterResultSelectionBinding: Binding<SidebarFilterResult?> {
        Binding<SidebarFilterResult?>(
            get: {
                if let id = selectedSearchMatchID, viewModel.workspaceSearchMatches.contains(where: { $0.id == id }) {
                    return .match(id)
                }
                return viewModel.currentFileURL.map { .file($0) }
            },
            set: { newValue in
                switch newValue {
                case .file(let url):
                    selectedSearchMatchID = nil
                    if url != viewModel.currentFileURL {
                        viewModel.openFile(at: url)
                    }
                case .match(let id):
                    selectedSearchMatchID = id
                    if let match = viewModel.workspaceSearchMatches.first(where: { $0.id == id }) {
                        viewModel.jumpToSearchMatch(match)
                    }
                case nil:
                    break
                }
            }
        )
    }

    var trimmedSearchQuery: String {
        viewModel.workspaceSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var sidebarSearchTextBinding: Binding<String> {
        switch viewModel.activeSidebarTab {
        case .files:
            return $viewModel.workspaceSearchQuery
        case .outline:
            return $viewModel.outlineFilterText
        }
    }

    private var sidebarSearchPrompt: String {
        switch viewModel.activeSidebarTab {
        case .files:
            return "Filter files"
        case .outline:
            return "Filter headings"
        }
    }

    public var body: some View {
        sidebarMainContent
            .searchable(
                text: sidebarSearchTextBinding,
                placement: .sidebar,
                prompt: sidebarSearchPrompt
            )
            .onChange(of: viewModel.workspaceSearchQuery) { _, _ in
                viewModel.performWorkspaceSearch()
            }
            .onGeometryChange(for: CGFloat.self) {
                $0.size.width
            } action: {
                sidebarWidth = $0
            }
            .readsWindowFullScreen($isWindowFullScreen)
            .toolbar {
                // A collapsed sidebar moves its items next to the toggle, so show none then.
                if viewModel.showSidebar {
                    // The add button sits at the leading edge; the spacer pushes the rest to the toggle.
                    if showsAddButton {
                        ToolbarItem {
                            addMenu
                        }
                        ToolbarSpacer(.flexible)
                    }
                    ToolbarItem {
                        workspaceOptionsMenu(includesAddActions: !showsAddButton)
                    }
                    ToolbarItem {
                        Picker("Sidebar Mode", selection: $viewModel.activeSidebarTab) {
                            ForEach(SidebarTab.allCases) { tab in
                                Label(tab.rawValue, systemImage: tab.systemImage).tag(tab)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelStyle(.iconOnly)
                        .help("Switch between Files and Outline")
                    }
                }
            }
    }

    /// Full screen hides the traffic lights, which frees room for the add button.
    var showsAddButton: Bool {
        isWindowFullScreen || sidebarWidth >= Self.addButtonMinimumSidebarWidth
    }

    @ViewBuilder
    private var sidebarMainContent: some View {
        switch viewModel.activeSidebarTab {
        case .files:
            filesTabContent
        case .outline:
            outlineTabContent
        }
    }

    // MARK: - Files Tab Content
    var filteredFlatFiles: [WorkspaceFileNode] {
        let query = trimmedSearchQuery
        guard !query.isEmpty else { return viewModel.flatMarkdownFiles }
        return viewModel.flatMarkdownFiles.filter {
            $0.name.localizedCaseInsensitiveContains(query) || $0.url.path.localizedCaseInsensitiveContains(query)
                || ($0.remoteConnectionString?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    func articleRow(_ node: WorkspaceFileNode) -> some View {
        SidebarArticleRow(
            node: node,
            isSelected: viewModel.currentFileURL == node.url,
            accentColor: viewModel.theme.linkColor,
            mountConnectionState: node.remoteMountID.flatMap { remoteManager.connectionStates[$0] },
            liveSyncStatus: remoteManager.syncStatus(forLocalURL: node.url),
            actions: rowActions(for: node)
        )
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
                    Button("Add Folder…") {
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
        } else if !trimmedSearchQuery.isEmpty {
            filterResultsContent
        } else if viewModel.fileDisplayStyle == .list {
            let files = viewModel.flatMarkdownFiles
            List(selection: selectedFileURLBinding) {
                Section("Articles (\(files.count))") {
                    ForEach(files) { node in
                        articleRow(node).tag(Optional(node.url))
                    }
                }
            }
            .listStyle(.sidebar)
        } else {
            List(selection: selectedFileURLBinding) {
                ForEach(viewModel.rootFileNodes) { root in
                    if let children = root.children {
                        DisclosureGroup(isExpanded: rootExpansionBinding(for: root)) {
                            OutlineGroup(children, children: \.children) { node in
                                fileRow(for: node)
                            }
                        } label: {
                            fileRow(for: root)
                        }
                    } else {
                        fileRow(for: root)
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }

    // MARK: - Rows

    private func rootExpansionBinding(for root: WorkspaceFileNode) -> Binding<Bool> {
        Binding(
            get: { viewModel.isDirectoryExpanded(root.url) },
            set: { viewModel.setDirectoryExpanded($0, for: root.url) }
        )
    }

    private func fileRow(for node: WorkspaceFileNode) -> some View {
        SidebarFileRow(
            node: node,
            accentColor: viewModel.theme.linkColor,
            mountConnectionState: node.remoteMountID.flatMap { remoteManager.connectionStates[$0] },
            liveSyncStatus: remoteManager.syncStatus(forLocalURL: node.url),
            actions: rowActions(for: node)
        )
    }

    private func rowActions(for node: WorkspaceFileNode) -> SidebarNodeActions {
        SidebarNodeActions(
            sshDisplayPath: remoteManager.remoteSSHDisplayPath(forLocalURL: node.url) ?? node.remoteConnectionString,
            newFile: { viewModel.createNewFileInWorkspace(in: $0) },
            newLaTeXFile: { viewModel.createNewLaTeXFileInWorkspace(in: $0) },
            syncMount: { mountID in
                Task { await remoteManager.syncMount(id: mountID, isBackground: false) }
            },
            disconnectMount: { viewModel.disconnectRemoteMount(id: $0) },
            removeLocalFolder: { viewModel.removeLocalFolder($0) },
            deleteItem: { viewModel.requestDeleteWorkspaceItem(at: $0) },
            openInNewTab: { viewModel.openInNewTab($0) }
        )
    }
}
