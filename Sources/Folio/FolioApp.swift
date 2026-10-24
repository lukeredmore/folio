import AppKit
import SwiftUI

public struct MainWindowView: View {
    @ObservedObject var viewModel: EditorWorkspaceViewModel
    @ObservedObject var updateManager: AppUpdateManager = .shared

    public init(viewModel: EditorWorkspaceViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        ZStack {
            HStack(spacing: 0) {
                if viewModel.showSidebar {
                    SidebarView(viewModel: viewModel)
                    Divider()
                        .overlay(viewModel.theme.borderColor)
                }

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
            }
            .background(viewModel.theme.editorBackgroundColor)

            // Floating Quick Open overlay (Shift+Shift)
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
        .navigationTitle(viewModel.documentTitle + (viewModel.activeConflict != nil ? " — Conflict" : ""))
        .background(WindowStatePersistenceAccessor(userDefaults: viewModel.userDefaults))
        .background(DoubleShiftEventMonitorAccessor(viewModel: viewModel))
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
                    viewModel.openPathsFromCLI(cliArgs + queuedPaths + delegatePaths)
                    FolioCLIManager.shared.startListeningForCLIOpenSignal { paths in
                        viewModel.openPathsFromCLI(paths)
                        NSApplication.shared.activate(ignoringOtherApps: true)
                    }
                    updateManager.checkForUpdatesOnLaunchIfNeeded()
                    viewModel.remoteWorkspaceManager.startBackgroundSyncLoop()
                }
        }
        .defaultSize(width: 1120, height: 760)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unifiedCompact(showsTitle: true))
        .commands {
            FolioAppCommands(viewModel: viewModel, updateManager: updateManager)
        }
    }
}
