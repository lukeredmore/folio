import AppKit
import SwiftUI

public struct MainWindowView: View {
    @ObservedObject var viewModel: EditorWorkspaceViewModel
    @ObservedObject var updateManager: AppUpdateManager = .shared
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    public init(viewModel: EditorWorkspaceViewModel) {
        self.viewModel = viewModel
        self._columnVisibility = State(initialValue: viewModel.showSidebar ? .all : .detailOnly)
    }

    private var navigationSubtitleText: String {
        var parts: [String] = []
        if let fileURL = viewModel.currentFileURL,
           let mount = viewModel.remoteWorkspaceManager.mount(forLocalURL: fileURL) {
            parts.append("SSH: \(mount.host)")
        } else if let folder = viewModel.workspaceFolderURL {
            parts.append(folder.lastPathComponent)
        }
        if viewModel.activeConflict != nil {
            parts.append("Conflict")
        } else if viewModel.isDirty {
            parts.append("Edited")
        }
        return parts.joined(separator: " • ")
    }

    public var body: some View {
        ZStack {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                SidebarView(viewModel: viewModel)
                    .navigationSplitViewColumnWidth(min: 220, ideal: 265, max: 380)
            } detail: {
                VStack(spacing: 0) {
                    RemoteConnectionBannerView(viewModel: viewModel)

                    DocumentConflictBannerView(viewModel: viewModel)

                    ExternalUpdateBannerView(viewModel: viewModel)

                    if viewModel.showFindReplaceBar {
                        FindReplaceBannerView(viewModel: viewModel)
                    }

                    HybridMarkdownEditorRepresentable(viewModel: viewModel)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    StatusBarView(viewModel: viewModel)
                }
                .background(viewModel.theme.editorBackgroundColor)
                .navigationTitle(viewModel.documentTitle)
                .navigationSubtitle(navigationSubtitleText)
                .toolbar {
                    ToolbarItemGroup(placement: .navigation) {
                        Button {
                            viewModel.quickOpenQuery = ""
                            viewModel.showQuickOpen.toggle()
                        } label: {
                            Label("Quick Open", systemImage: "magnifyingglass")
                        }
                        .help("Quick Open File (Cmd+P)")
                    }

                    ToolbarItemGroup(placement: .primaryAction) {
                        Button {
                            viewModel.createNewFileInWorkspace()
                        } label: {
                            Label("New Document", systemImage: "square.and.pencil")
                        }
                        .help("New Markdown File in Workspace")

                        Button {
                            viewModel.sourceCodeMode.toggle()
                        } label: {
                            Label(
                                viewModel.sourceCodeMode ? "Live WYSIWYG" : "Source Code",
                                systemImage: "chevron.left.forwardslash.chevron.right"
                            )
                        }
                        .help("Toggle Source Code Mode (Cmd+/)")
                    }

                    ToolbarSpacer(.fixed)

                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            viewModel.showFindReplaceBar.toggle()
                        } label: {
                            Label("Find and Replace", systemImage: "doc.text.magnifyingglass")
                        }
                        .help("Find and Replace in Document (Opt+Cmd+F)")
                    }
                }
            }

            // Floating Quick Open overlay (Cmd+P)
            if viewModel.showQuickOpen {
                Color.black.opacity(0.18)
                    .ignoresSafeArea()
                    .onTapGesture {
                        viewModel.showQuickOpen = false
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
            let target: NavigationSplitViewVisibility = shouldShow ? .all : .detailOnly
            if columnVisibility != target {
                columnVisibility = target
            }
        }
        .background(WindowStatePersistenceAccessor(userDefaults: viewModel.userDefaults))
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

struct WindowStatePersistenceAccessor: NSViewRepresentable {
    let userDefaults: UserDefaults
    static let windowFrameDefaultsKey = "Folio.MainWindowFrame.v1"

    func makeCoordinator() -> Coordinator {
        Coordinator(userDefaults: userDefaults)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            if let window = view.window {
                context.coordinator.attach(to: window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window {
                context.coordinator.attach(to: window)
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        let userDefaults: UserDefaults
        weak var attachedWindow: NSWindow?

        init(userDefaults: UserDefaults) {
            self.userDefaults = userDefaults
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        func attach(to window: NSWindow) {
            guard attachedWindow !== window else { return }
            if let oldWindow = attachedWindow {
                NotificationCenter.default.removeObserver(self, name: NSWindow.didResizeNotification, object: oldWindow)
                NotificationCenter.default.removeObserver(self, name: NSWindow.didMoveNotification, object: oldWindow)
            }
            attachedWindow = window

            window.setFrameAutosaveName("FolioMainWindow")
            if let savedFrameString = userDefaults.string(forKey: WindowStatePersistenceAccessor.windowFrameDefaultsKey) {
                let rect = NSRectFromString(savedFrameString)
                if rect.width >= 720, rect.height >= 480 {
                    window.setFrame(rect, display: true)
                }
            }

            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowDidChangeFrame(_:)),
                name: NSWindow.didResizeNotification,
                object: window
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowDidChangeFrame(_:)),
                name: NSWindow.didMoveNotification,
                object: window
            )
        }

        @objc func windowDidChangeFrame(_ notification: Notification) {
            guard let window = attachedWindow else { return }
            let frameString = NSStringFromRect(window.frame)
            userDefaults.set(frameString, forKey: WindowStatePersistenceAccessor.windowFrameDefaultsKey)
        }
    }
}

@MainActor
public final class FolioAppDelegate: NSObject, NSApplicationDelegate {
    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
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
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.applicationIconImage = FolioBrandIcon.makeCurrentAppIconImage(pixelSize: 512)
    }

    public var body: some Scene {
        WindowGroup("Folio") {
            MainWindowView(viewModel: viewModel)
                .frame(minWidth: 720, minHeight: 480)
                .onAppear {
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    updateManager.checkForUpdatesOnLaunchIfNeeded()
                    viewModel.remoteWorkspaceManager.startBackgroundSyncLoop()
                }
        }
        .defaultSize(width: 1120, height: 760)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            FolioAppCommands(viewModel: viewModel, updateManager: updateManager)
        }
    }
}
