import AppKit
import SwiftUI

public struct MainWindowView: View {
    @ObservedObject var viewModel: EditorWorkspaceViewModel
    @ObservedObject var updateManager: AppUpdateManager = .shared
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var isHoveringBottomEdge: Bool = false
    @State private var isWindowTabBarVisible: Bool = false

    public init(viewModel: EditorWorkspaceViewModel) {
        self.viewModel = viewModel
        self._columnVisibility = State(initialValue: viewModel.showSidebar ? .all : .detailOnly)
    }

    private var isBottomBarVisibleWhenSidebarClosed: Bool {
        isHoveringBottomEdge || viewModel.showSettingsModal || viewModel.showWordCountPopover
            || viewModel.externalUpdateNotice != nil
    }

    /// The editor bleeds under the transparent toolbar, but not under the opaque native tab bar.
    private var editorBleedEdges: Edge.Set { isWindowTabBarVisible ? [] : .top }

    private var commentsInspectorBinding: Binding<Bool> {
        Binding(
            get: { viewModel.isCommentsSidebarVisible },
            set: { _ in }
        )
    }

    /// Only the active window shows the app-wide update sheet.
    private var updateSheetBinding: Binding<Bool> {
        Binding(
            get: { updateManager.showUpdateSheet && viewModel.presentsAppWideSheets },
            set: { updateManager.showUpdateSheet = $0 }
        )
    }

    public var body: some View {
        ZStack {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                SidebarView(viewModel: viewModel)
                    .navigationSplitViewColumnWidth(min: 255, ideal: 265, max: 380)
            } detail: {
                ZStack(alignment: .top) {
                    GeometryReader { proxy in
                        VStack(spacing: 0) {
                            ZStack(alignment: .topLeading) {
                                HybridMarkdownEditorRepresentable(viewModel: viewModel)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .ignoresSafeArea(.container, edges: editorBleedEdges)

                                if let anchor = viewModel.selectionTooltipAnchor {
                                    SelectionTooltipOverlayRepresentable(viewModel: viewModel, anchor: anchor)
                                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                                        .ignoresSafeArea(.container, edges: editorBleedEdges)
                                }
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)

                            if viewModel.showSidebar {
                                StatusBarView(viewModel: viewModel)
                            }
                        }
                        .overlay(alignment: .bottom) {
                            if !viewModel.showSidebar && isBottomBarVisibleWhenSidebarClosed {
                                StatusBarView(viewModel: viewModel)
                                    .transition(.move(edge: .bottom).combined(with: .opacity))
                            }
                        }
                        .overlayPreferenceValue(AutosaveIndicatorAnchorKey.self) { anchor in
                            ExternalUpdateTooltipOverlay(viewModel: viewModel, anchor: anchor)
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
                    .ignoresSafeArea(.container, edges: editorBleedEdges)

                    DocumentBannerStack(viewModel: viewModel)
                }
                .background(viewModel.theme.editorBackgroundColor.ignoresSafeArea(.container, edges: [.top, .bottom, .leading]))
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
                .background(
                    CommentsTitlebarAccessory(viewModel: viewModel)
                        .frame(width: 0, height: 0)
                        .allowsHitTesting(false)
                )
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
        .readsWindowTabBarVisibility($isWindowTabBarVisible)
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
        .sheet(isPresented: updateSheetBinding) {
            AppUpdateModalView(updateManager: updateManager)
        }
    }
}

@MainActor
public final class FolioAppDelegate: NSObject, NSApplicationDelegate {
    public var registry: DocumentWindowRegistry = .shared

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        registry.isTerminating = true
        return .terminateNow
    }

    public func application(_ application: NSApplication, open urls: [URL]) {
        let paths = urls.filter(\.isFileURL).map(\.path)
        handleOpenPaths(paths)
    }

    public func application(_ sender: NSApplication, openFiles filenames: [String]) {
        handleOpenPaths(filenames)
        sender.reply(toOpenOrPrint: .success)
    }

    private func handleOpenPaths(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        registry.openPaths(paths)
        if registry.activeViewModel != nil {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }
}

#if !FOLIO_NO_MAIN
@main
#endif
public struct FolioApp: App {
    @NSApplicationDelegateAdaptor(FolioAppDelegate.self) var appDelegate
    @ObservedObject var updateManager = AppUpdateManager.shared
    private let registry = DocumentWindowRegistry.shared

    public init() {
        FolioCLIManager.handleImmediateCLIFlagsIfNeeded()
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.applicationIconImage = FolioBrandIcon.makeCurrentAppIconImage(pixelSize: 512)
    }

    public var body: some Scene {
        WindowGroup("Folio", for: DocumentWindowValue.self) { $value in
            DocumentWindowRoot(value: value, registry: registry, onAppear: performLaunchSetupIfNeeded)
        } defaultValue: {
            DocumentWindowValue()
        }
        .defaultSize(width: 1120, height: 760)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            FolioCommands(registry: registry, updateManager: updateManager)
        }
    }

    /// Opens launch paths in the first window and starts app-wide services, once per launch.
    private func performLaunchSetupIfNeeded(_ viewModel: EditorWorkspaceViewModel) {
        guard registry.claimLaunchSetup(for: viewModel) else { return }
        appDelegate.registry = registry
        NSApplication.shared.activate(ignoringOtherApps: true)
        FolioCLIManager.shared.setupCLIOnFirstLaunchIfNeeded(userDefaults: registry.userDefaults)
        let cliArgs = FolioCLIManager.extractCommandLinePaths(from: ProcessInfo.processInfo.arguments)
        let queuedPaths = FolioCLIManager.drainPendingOpenRequests()
        registry.openPaths(FolioCLIManager.deduplicateCommandLinePaths(cliArgs + queuedPaths))
        FolioCLIManager.shared.startListeningForCLIOpenSignal { [registry] paths in
            registry.openPaths(FolioCLIManager.deduplicateCommandLinePaths(paths))
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        updateManager.checkForUpdatesOnLaunchIfNeeded()
        registry.remoteWorkspaceManager.startBackgroundSyncLoop()
    }
}
