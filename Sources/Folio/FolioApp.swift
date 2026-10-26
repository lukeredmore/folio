import AppKit
import SwiftUI

public struct MainWindowView: View {
    @ObservedObject var viewModel: EditorWorkspaceViewModel
    @ObservedObject var updateManager: AppUpdateManager = .shared
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var isHoveringBottomEdge: Bool = false
    @State private var didCopyAllComments: Bool = false

    public init(viewModel: EditorWorkspaceViewModel) {
        self.viewModel = viewModel
        self._columnVisibility = State(initialValue: viewModel.showSidebar ? .all : .detailOnly)
    }

    private var isBottomBarVisibleWhenSidebarClosed: Bool {
        isHoveringBottomEdge || viewModel.showSettingsModal || viewModel.showWordCountPopover
    }

    private var commentsInspectorBinding: Binding<Bool> {
        Binding(
            get: { viewModel.isCommentsSidebarVisible },
            set: { shouldShow in
                guard !viewModel.selectionComments.isEmpty else { return }
                if viewModel.showCommentsSidebar != shouldShow {
                    viewModel.showCommentsSidebar = shouldShow
                }
            }
        )
    }

    public var body: some View {
        ZStack {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                SidebarView(viewModel: viewModel)
                    .navigationSplitViewColumnWidth(min: 255, ideal: 265, max: 380)
            } detail: {
                GeometryReader { proxy in
                    VStack(spacing: 0) {
                        ZStack(alignment: .topLeading) {
                            HybridMarkdownEditorRepresentable(viewModel: viewModel)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .ignoresSafeArea(.container, edges: .top)

                            if let anchor = viewModel.selectionTooltipAnchor {
                                SelectionTooltipOverlayRepresentable(viewModel: viewModel, anchor: anchor)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .ignoresSafeArea(.container, edges: .top)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                        if viewModel.showSidebar {
                            StatusBarView(viewModel: viewModel)
                        }
                    }
                    .overlay(alignment: .top) {
                        VStack(spacing: 0) {
                            RemoteConnectionBannerView(viewModel: viewModel)
                            DocumentConflictBannerView(viewModel: viewModel)
                            ExternalUpdateBannerView(viewModel: viewModel)
                            if viewModel.showFindReplaceBar {
                                FindReplaceBannerView(viewModel: viewModel)
                            }
                        }
                    }
                    .overlay(alignment: .bottom) {
                        if !viewModel.showSidebar && isBottomBarVisibleWhenSidebarClosed {
                            StatusBarView(viewModel: viewModel)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                    .onContinuousHover(coordinateSpace: .local) { phase in
                        guard !viewModel.showSidebar else {
                            if isHoveringBottomEdge {
                                isHoveringBottomEdge = false
                            }
                            return
                        }
                        switch phase {
                        case .active(let location):
                            let nearBottom = (proxy.size.height - location.y) <= 34.0
                            if isHoveringBottomEdge != nearBottom {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    isHoveringBottomEdge = nearBottom
                                }
                            }
                        case .ended:
                            if isHoveringBottomEdge {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    isHoveringBottomEdge = false
                                }
                            }
                        }
                    }
                }
                .ignoresSafeArea(.container, edges: .top)
                .background(viewModel.theme.editorBackgroundColor.ignoresSafeArea(.container, edges: [.top, .bottom, .leading]))
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        if !viewModel.selectionComments.isEmpty {
                            if viewModel.isCommentsSidebarVisible {
                                Button {
                                    viewModel.showCommentsSidebar = false
                                } label: {
                                    Label("Hide Comments", systemImage: "sidebar.right")
                                }
                                .help("Hide comments sidebar")

                                Button {
                                    if viewModel.copyAllSelectionComments() != nil {
                                        didCopyAllComments = true
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
                                            didCopyAllComments = false
                                        }
                                    }
                                } label: {
                                    Label(
                                        didCopyAllComments ? "Copied" : "Copy All Comments",
                                        systemImage: didCopyAllComments ? "checkmark" : "doc.on.doc"
                                    )
                                }
                                .help("Copy all comments (Cmd+Ctrl+C)")

                                Button {
                                    viewModel.clearAllSelectionComments()
                                } label: {
                                    Label("Delete All Comments", systemImage: "trash")
                                }
                                .help("Clear all comments and remove companion file")
                            } else {
                                Button {
                                    viewModel.showCommentsSidebar = true
                                } label: {
                                    Label("Show Comments", systemImage: "text.bubble")
                                }
                                .help("Show comments sidebar")
                            }
                        }
                    }
                }
                .inspector(isPresented: commentsInspectorBinding) {
                    SelectionCommentsSidebarView(viewModel: viewModel)
                        .inspectorColumnWidth(min: 240, ideal: 280, max: 380)
                }
            }

            // Floating Quick Open overlay (Shift+Shift)
            if viewModel.showQuickOpen {
                Color.black.opacity(0.18)
                    .ignoresSafeArea()
                    .onTapGesture {
                        viewModel.closeQuickOpen()
                    }

                VStack {
                    QuickOpenModalView(viewModel: viewModel)
                        .padding(.top, 64)
                    Spacer()
                }
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .preferredColorScheme(viewModel.theme.colorScheme)
        .onChange(of: columnVisibility) { _, newVisibility in
            let shouldShow = (newVisibility != .detailOnly)
            if viewModel.showSidebar != shouldShow {
                viewModel.showSidebar = shouldShow
            }
        }
        .onChange(of: viewModel.showSidebar) { _, shouldShow in
            if shouldShow {
                if columnVisibility == .detailOnly {
                    columnVisibility = .all
                }
            } else if columnVisibility != .detailOnly {
                columnVisibility = .detailOnly
            }
        }
        .background(
            WindowStatePersistenceAccessor(userDefaults: viewModel.userDefaults)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        )
        .background(
            DoubleShiftEventMonitorAccessor(viewModel: viewModel)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        )
        .sheet(isPresented: $viewModel.showInsertTableSheet) {
            InsertTableModalView(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.showAddRemoteModal) {
            AddRemoteMountModalView(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.showConflictResolverModal) {
            ConflictResolverModalView(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.showExternalUpdateDiffModal) {
            ExternalUpdateDiffModalView(viewModel: viewModel)
        }
        .sheet(item: $viewModel.expandedDiagram) { diagram in
            DiagramZoomSheet(diagram: diagram)
        }
        .sheet(isPresented: $updateManager.showUpdateSheet) {
            AppUpdateModalView(updateManager: updateManager)
        }
    }
}

@MainActor
public final class FolioAppDelegate: NSObject, NSApplicationDelegate {
    public weak var viewModel: EditorWorkspaceViewModel?
    private var pendingOpenPaths: [String] = []

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    public func application(_ application: NSApplication, open urls: [URL]) {
        let paths = urls.filter(\.isFileURL).map(\.path)
        handleOpenPaths(paths)
    }

    public func application(_ sender: NSApplication, openFiles filenames: [String]) {
        handleOpenPaths(filenames)
        sender.reply(toOpenOrPrint: .success)
    }

    public func drainPendingOpenPaths() -> [String] {
        let queued = pendingOpenPaths
        pendingOpenPaths.removeAll()
        return queued
    }

    private func handleOpenPaths(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        if let vm = viewModel {
            vm.openPathsFromCLI(paths)
            NSApplication.shared.activate(ignoringOtherApps: true)
        } else {
            pendingOpenPaths.append(contentsOf: paths)
        }
    }
}

#if !FOLIO_NO_MAIN
@main
#endif
public struct FolioApp: App {
    @NSApplicationDelegateAdaptor(FolioAppDelegate.self) var appDelegate
    @StateObject var viewModel = EditorWorkspaceViewModel()
    @ObservedObject var updateManager = AppUpdateManager.shared

    public init() {
        FolioCLIManager.handleImmediateCLIFlagsIfNeeded()
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.applicationIconImage = FolioBrandIcon.makeCurrentAppIconImage(pixelSize: 512)
    }

    public var body: some Scene {
        WindowGroup("Folio") {
            MainWindowView(viewModel: viewModel)
                .frame(minWidth: 720, minHeight: 480)
                .onAppear {
                    appDelegate.viewModel = viewModel
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    FolioCLIManager.shared.setupCLIOnFirstLaunchIfNeeded(userDefaults: viewModel.userDefaults)
                    let cliArgs = FolioCLIManager.extractCommandLinePaths(from: ProcessInfo.processInfo.arguments)
                    let queuedPaths = FolioCLIManager.drainPendingOpenRequests()
                    let delegatePaths = appDelegate.drainPendingOpenPaths()
                    let initialPaths = FolioCLIManager.deduplicateCommandLinePaths(cliArgs + queuedPaths + delegatePaths)
                    viewModel.openPathsFromCLI(initialPaths)
                    FolioCLIManager.shared.startListeningForCLIOpenSignal { paths in
                        viewModel.openPathsFromCLI(FolioCLIManager.deduplicateCommandLinePaths(paths))
                        NSApplication.shared.activate(ignoringOtherApps: true)
                    }
                    updateManager.checkForUpdatesOnLaunchIfNeeded()
                    viewModel.remoteWorkspaceManager.startBackgroundSyncLoop()
                }
        }
        .defaultSize(width: 1120, height: 760)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            FolioAppCommands(viewModel: viewModel, updateManager: updateManager)
        }
    }
}
