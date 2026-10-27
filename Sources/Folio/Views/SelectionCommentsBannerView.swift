import AppKit
import SwiftUI

public typealias SelectionCommentsBannerView = SelectionCommentsSidebarView

public struct SelectionCommentsSidebarView: View {
    @ObservedObject var viewModel: EditorWorkspaceViewModel

    public init(viewModel: EditorWorkspaceViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    Text("Comments (\(viewModel.selectionComments.count))")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.top, 10)
                        .padding(.bottom, 2)

                    ForEach(viewModel.selectionComments) { comment in
                        commentRow(for: comment)
                            .id(comment.id)
                    }
                }
                .padding(.top, 52)
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
            .ignoresSafeArea(.container, edges: .top)
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            .onChange(of: viewModel.activeCommentID) { _, newID in
                guard let newID else { return }
                withAnimation(.easeInOut(duration: 0.18)) {
                    proxy.scrollTo(newID, anchor: .center)
                }
            }
        }
    }

    private func commentRow(for comment: SelectionComment) -> some View {
        let isActive = (viewModel.activeCommentID == comment.id)
        let excerpt = comment.selectedFormattedText
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 4) {
                if !excerpt.isEmpty {
                    HStack(alignment: .top, spacing: 6) {
                        RoundedRectangle(cornerRadius: 1.25)
                            .fill(viewModel.theme.linkColor.opacity(0.65))
                            .frame(width: 2.5)
                        Text(excerpt)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                Text(comment.commentText)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 4) {
                Button {
                    viewModel.selectComment(comment)
                } label: {
                    Image(systemName: "pencil")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Edit comment")

                Button {
                    viewModel.removeSelectionComment(id: comment.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Delete comment")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isActive ? Color.accentColor.opacity(0.14) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.focusComment(comment, scrollEditor: true)
        }
        .contextMenu {
            Button("Copy Comment") {
                viewModel.copySingleSelectionComment(comment)
            }
            Button("Edit Comment…") {
                viewModel.selectComment(comment)
            }
            Divider()
            Button("Delete Comment", role: .destructive) {
                viewModel.removeSelectionComment(id: comment.id)
            }
        }
    }
}

final class CommentsTitlebarAnchorView: NSView {
    let glassView = NSGlassEffectView(frame: .zero)
    let containerView = NSView(frame: .zero)
    let hideButton = NSButton(frame: .zero)
    let copyButton = NSButton(frame: .zero)
    let deleteButton = NSButton(frame: .zero)
    let showButton = NSButton(frame: .zero)

    var hasComments: Bool = false { didSet { syncTitlebarPill() } }
    var isCommentsSidebarVisible: Bool = false { didSet { syncTitlebarPill() } }
    var didCopyAll: Bool = false { didSet { updateCopyButtonAppearance() } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        glassView.cornerRadius = 14
        containerView.autoresizingMask = [.width, .height]
        glassView.contentView = containerView
        configureButton(hideButton, symbol: "sidebar.right", label: "Hide Comments", toolTip: "Hide comments sidebar")
        configureButton(copyButton, symbol: "doc.on.doc", label: "Copy All Comments", toolTip: "Copy all comments (Cmd+Ctrl+C)")
        configureButton(deleteButton, symbol: "trash", label: "Delete All Comments", toolTip: "Clear all comments and remove companion file")
        configureButton(showButton, symbol: "text.bubble", label: "Show Comments", toolTip: "Show comments sidebar")
        containerView.addSubview(hideButton)
        containerView.addSubview(copyButton)
        containerView.addSubview(deleteButton)
        containerView.addSubview(showButton)
    }

    required init?(coder: NSCoder) { nil }

    private func configureButton(_ button: NSButton, symbol: String, label: String, toolTip: String) {
        button.bezelStyle = .toolbar
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?.withSymbolConfiguration(config)
        button.setAccessibilityLabel(label)
        button.toolTip = toolTip
    }

    private func updateCopyButtonAppearance() {
        let symbol = didCopyAll ? "checkmark" : "doc.on.doc"
        let label = didCopyAll ? "Copied" : "Copy All Comments"
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        copyButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?.withSymbolConfiguration(config)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        if let window {
            NotificationCenter.default.addObserver(
                self, selector: #selector(handleWindowLayout(_:)),
                name: NSWindow.didResizeNotification, object: window
            )
            NotificationCenter.default.addObserver(
                self, selector: #selector(handleWindowLayout(_:)),
                name: NSSplitView.didResizeSubviewsNotification, object: nil
            )
            syncTitlebarPill()
            DispatchQueue.main.async { [weak self] in self?.syncTitlebarPill() }
        } else {
            glassView.removeFromSuperview()
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handleWindowLayout(_ notification: Notification) { syncTitlebarPill() }
    override func layout() {
        super.layout()
        syncTitlebarPill()
    }

    func syncTitlebarPill() {
        guard let window, let themeFrame = window.contentView?.superview else {
            glassView.removeFromSuperview()
            return
        }
        let hostView = Self.findSubview(named: "NSTitlebarView", in: themeFrame) ?? themeFrame
        if glassView.superview !== hostView || hostView.subviews.last !== glassView {
            hostView.addSubview(glassView, positioned: .above, relativeTo: nil)
        }
        glassView.isHidden = !hasComments
        guard hasComments else { return }

        let pillHeight: CGFloat = 28
        let pillWidth: CGFloat = isCommentsSidebarVisible ? 104 : 36
        let y = Self.toolbarRowCenterY(in: hostView, window: window, themeFrame: themeFrame) - round(pillHeight / 2.0)
        let x = max(280.0, round(hostView.bounds.width - pillWidth - 12.0))
        glassView.frame = NSRect(x: x, y: y, width: pillWidth, height: pillHeight)
        glassView.layoutSubtreeIfNeeded()
        containerView.frame = glassView.bounds

        if isCommentsSidebarVisible {
            hideButton.isHidden = false
            copyButton.isHidden = false
            deleteButton.isHidden = false
            showButton.isHidden = true
            hideButton.frame = NSRect(x: 4, y: 2, width: 30, height: 24)
            copyButton.frame = NSRect(x: 37, y: 2, width: 30, height: 24)
            deleteButton.frame = NSRect(x: 70, y: 2, width: 30, height: 24)
        } else {
            hideButton.isHidden = true
            copyButton.isHidden = true
            deleteButton.isHidden = true
            showButton.isHidden = false
            showButton.frame = NSRect(x: 3, y: 2, width: 30, height: 24)
        }
    }

    /// Vertical center of the toolbar row, which matches the traffic lights even when a tab bar
    /// makes the titlebar view taller.
    private static func toolbarRowCenterY(in hostView: NSView, window: NSWindow, themeFrame: NSView) -> CGFloat {
        if let close = window.standardWindowButton(.closeButton), close.window === window, !close.isHidden {
            return round(hostView.convert(close.bounds, from: close).midY)
        }
        return hostView === themeFrame ? round(themeFrame.bounds.height - 26.0) : round(hostView.bounds.height / 2.0)
    }

    private static func findSubview(named classSubstring: String, in root: NSView) -> NSView? {
        if String(describing: type(of: root)).contains(classSubstring) { return root }
        for child in root.subviews {
            if let match = findSubview(named: classSubstring, in: child) { return match }
        }
        return nil
    }
}

struct CommentsTitlebarAccessory: NSViewRepresentable {
    @ObservedObject var viewModel: EditorWorkspaceViewModel

    final class Coordinator: NSObject {
        var viewModel: EditorWorkspaceViewModel
        weak var anchorView: CommentsTitlebarAnchorView?
        init(viewModel: EditorWorkspaceViewModel) { self.viewModel = viewModel }

        @MainActor @objc func hideComments(_ sender: NSButton) {
            viewModel.showCommentsSidebar = false
        }

        @MainActor @objc func copyAllComments(_ sender: NSButton) {
            if viewModel.copyAllSelectionComments() != nil {
                anchorView?.didCopyAll = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak self] in
                    self?.anchorView?.didCopyAll = false
                }
            }
        }

        @MainActor @objc func deleteAllComments(_ sender: NSButton) {
            viewModel.clearAllSelectionComments()
        }

        @MainActor @objc func showComments(_ sender: NSButton) {
            viewModel.showCommentsSidebar = true
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(viewModel: viewModel) }

    func makeNSView(context: Context) -> CommentsTitlebarAnchorView {
        let anchor = CommentsTitlebarAnchorView(frame: .zero)
        context.coordinator.anchorView = anchor
        anchor.hideButton.target = context.coordinator
        anchor.hideButton.action = #selector(Coordinator.hideComments(_:))
        anchor.copyButton.target = context.coordinator
        anchor.copyButton.action = #selector(Coordinator.copyAllComments(_:))
        anchor.deleteButton.target = context.coordinator
        anchor.deleteButton.action = #selector(Coordinator.deleteAllComments(_:))
        anchor.showButton.target = context.coordinator
        anchor.showButton.action = #selector(Coordinator.showComments(_:))
        anchor.hasComments = !viewModel.selectionComments.isEmpty
        anchor.isCommentsSidebarVisible = viewModel.isCommentsSidebarVisible
        return anchor
    }

    func updateNSView(_ nsView: CommentsTitlebarAnchorView, context: Context) {
        context.coordinator.viewModel = viewModel
        context.coordinator.anchorView = nsView
        nsView.hasComments = !viewModel.selectionComments.isEmpty
        nsView.isCommentsSidebarVisible = viewModel.isCommentsSidebarVisible
        nsView.syncTitlebarPill()
    }
}
