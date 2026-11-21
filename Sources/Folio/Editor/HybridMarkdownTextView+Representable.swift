import AppKit
import SwiftUI

public struct HybridMarkdownEditorRepresentable: NSViewRepresentable {
    public typealias Coordinator = MarkdownEditorCoordinator

    @ObservedObject var viewModel: EditorWorkspaceViewModel

    public init(viewModel: EditorWorkspaceViewModel) {
        self.viewModel = viewModel
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }

    private func applyTheme(_ theme: EditorTheme, to scrollView: NSScrollView, textView: HybridMarkdownTextView) {
        scrollView.backgroundColor = theme.editorBackgroundNSColor
        textView.backgroundColor = theme.editorBackgroundNSColor
        textView.insertionPointColor = theme.linkNSColor
        textView.currentTheme = theme
    }

    public func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsetsZero
        if scrollView.responds(to: NSSelectorFromString("setAllowedPocketEdges:")) {
            scrollView.setValue(0, forKey: "allowedPocketEdges")
        }
        scrollView.hasVerticalScroller = true
        // The column is always centered and never scrolls sideways, while wide tables scroll on their own.
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = viewModel.theme.editorBackgroundNSColor

        let textStorage = NSTextStorage()
        let layoutManager = WideBlockLayoutManager()
        layoutManager.delegate = context.coordinator.softLineBreakLayoutDelegate
        textStorage.addLayoutManager(layoutManager)
        context.coordinator.observeTextStorage(textStorage)

        let textContainer = WideBlockTextContainer(containerSize: NSSize(width: 800, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = false
        textContainer.lineFragmentPadding = 0.0
        layoutManager.addTextContainer(textContainer)

        let textView = HybridMarkdownTextView(frame: .zero, textContainer: textContainer)
        textView.minSize = NSSize(width: 0, height: 400)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.allowsUndo = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isContinuousSpellCheckingEnabled = viewModel.spellCheckEnabled
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true

        textView.delegate = context.coordinator
        textView.workspaceViewModel = viewModel
        textView.editorCoordinator = context.coordinator
        textView.externalUpdateHighlightRanges = viewModel.externalUpdateHighlightRanges
        context.coordinator.textView = textView
        viewModel.activeTextView = textView

        textView.onToggleCheckboxAtCharacterIndex = { [weak viewModel] boxLocation in
            viewModel?.toggleTaskCheckbox(at: boxLocation)
        }

        scrollView.documentView = textView

        context.coordinator.isProgrammaticUpdate = true
        textView.string = viewModel.markdownText
        let initialLen = (viewModel.markdownText as NSString).length
        let initialLoc = max(0, min(viewModel.currentSelectedRange.location, initialLen))
        let initialRange = NSRange(location: initialLoc, length: 0)
        textView.setSelectedRange(initialRange)
        context.coordinator.lastKnownTextHash = viewModel.markdownText.hashValue
        context.coordinator.isProgrammaticUpdate = false
        applyTheme(viewModel.theme, to: scrollView, textView: textView)
        textView.typographySettings = viewModel.typography
        textView.isTypewriterMode = viewModel.typewriterMode
        textView.isSourceCodeMode = viewModel.sourceCodeMode
        context.coordinator.updateInsets(for: scrollView, textView: textView, theme: viewModel.theme)
        context.coordinator.restyle(textView: textView)
        textView.scrollRangeToVisible(initialRange)

        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.scrollViewFrameDidChange(_:)),
            name: NSView.frameDidChangeNotification,
            object: scrollView
        )
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.clipViewFrameDidChange(_:)),
            name: NSView.frameDidChangeNotification,
            object: scrollView.contentView
        )
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.clipViewBoundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.mediaImageDidLoad(_:)),
            name: FolioMediaImageCache.imageDidLoadNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.latexProjectDidUpdate(_:)),
            name: LaTeXProjectContext.didUpdateNotification,
            object: nil
        )
        scrollView.postsFrameChangedNotifications = true
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.contentView.postsFrameChangedNotifications = true

        return scrollView
    }

    public func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? HybridMarkdownTextView else { return }
        context.coordinator.viewModel = viewModel
        textView.workspaceViewModel = viewModel
        textView.editorCoordinator = context.coordinator
        viewModel.activeTextView = textView

        let currentConfiguration = Coordinator.SyncedStyleConfiguration(viewModel: viewModel)
        let previousConfiguration = context.coordinator.lastSyncedConfiguration

        if previousConfiguration?.theme != currentConfiguration.theme
            || textView.currentTheme != currentConfiguration.theme
        {
            applyTheme(currentConfiguration.theme, to: scrollView, textView: textView)
        }
        if previousConfiguration?.typography != currentConfiguration.typography {
            textView.typographySettings = currentConfiguration.typography
        }
        textView.isTypewriterMode = viewModel.typewriterMode
        textView.isSourceCodeMode = viewModel.sourceCodeMode
        if textView.isContinuousSpellCheckingEnabled != viewModel.spellCheckEnabled {
            textView.isContinuousSpellCheckingEnabled = viewModel.spellCheckEnabled
        }
        if textView.externalUpdateHighlightRanges != viewModel.externalUpdateHighlightRanges {
            textView.externalUpdateHighlightRanges = viewModel.externalUpdateHighlightRanges
        }

        context.coordinator.updateInsets(for: scrollView, textView: textView, theme: viewModel.theme)

        if !context.coordinator.isUpdatingFromTextView
            && context.coordinator.lastKnownTextHash != viewModel.markdownText.hashValue
            && textView.string != viewModel.markdownText
        {
            let fileChanged = previousConfiguration?.fileURL != currentConfiguration.fileURL
            let savedSelection = fileChanged ? viewModel.currentSelectedRange : textView.selectedRange()
            textView.applyProgrammaticDocumentText(viewModel.markdownText, selectedRange: savedSelection)
            if fileChanged {
                scrollView.contentView.scroll(to: .zero)
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        } else if previousConfiguration != currentConfiguration {
            context.coordinator.restyle(textView: textView)
        }

        if let scrollTarget = viewModel.pendingScrollToCharacterLocation {
            DispatchQueue.main.async {
                viewModel.pendingScrollToCharacterLocation = nil
                let nsLen = (textView.string as NSString).length
                let safeLoc = max(0, min(scrollTarget, nsLen))
                let targetRange = NSRange(location: safeLoc, length: 0)
                textView.window?.makeFirstResponder(textView)
                textView.setSelectedRange(targetRange)
                textView.scrollRangeToVisible(targetRange)
                context.coordinator.restyle(textView: textView, incremental: true)
            }
        }
    }
}
