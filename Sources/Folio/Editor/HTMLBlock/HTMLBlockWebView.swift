import AppKit
import UniformTypeIdentifiers
import WebKit

@MainActor
protocol HTMLBlockWebViewDelegate: AnyObject {
    func htmlBlockWebView(_ view: HTMLBlockWebView, didMeasureHeight height: CGFloat)
    func htmlBlockWebView(_ view: HTMLBlockWebView, didChangeSelection selection: HTMLBlockWebView.Selection?)
    func htmlBlockWebView(_ view: HTMLBlockWebView, didClickSourceOffset offset: Int?, clickCount: Int)
    func htmlBlockWebViewDidBecomeReady(_ view: HTMLBlockWebView)
    func htmlBlockWebViewRequestsSourceEditing(_ view: HTMLBlockWebView)
    func htmlBlockWebViewRequestsComment(_ view: HTMLBlockWebView)
    func htmlBlockWebViewRequestsRawCopy(_ view: HTMLBlockWebView)
    func htmlBlockWebViewRequestsTextFocus(_ view: HTMLBlockWebView)
}

/// A live web view that renders one CommonMark HTML block over its hidden source lines.
///
/// Page scripts are off. A bridge script in the client content world reports the content
/// height, maps the DOM selection to offsets in the block source, and draws comment
/// highlights. Navigation is limited to the initial load; clicked links open in the browser.
@MainActor
final class HTMLBlockWebView: WKWebView, WKNavigationDelegate {

    /// A selection in the block. Offsets index the block source; rects are in view points.
    struct Selection: Equatable {
        let start: Int
        let end: Int
        let rects: [NSRect]
        let isBackward: Bool
    }

    /// A highlighted source range in the block (`kind` is a `::highlight` name in the page).
    struct Highlight: Equatable {
        let start: Int
        let end: Int
        let kind: String
    }

    weak var blockDelegate: HTMLBlockWebViewDelegate?
    let source: String
    private(set) var style: HTMLBlockPageStyle
    /// Range of the block's source lines in the text view, updated as the text changes.
    var blockRange: NSRange
    var layoutWidth: CGFloat
    private(set) var isReady = false
    private(set) var selection: Selection?
    private(set) var measuredHeight: CGFloat?

    private let assetHandler: HTMLBlockAssetSchemeHandler
    private let messageProxy: HTMLBlockMessageProxy
    private var allowsInitialNavigation = true
    private var appliedHighlights: [Highlight] = []
    private var pendingHighlights: [Highlight]?
    private var pendingSelection: (start: Int, end: Int)?
    private var appliedOpacity: CGFloat = 1.0
    private var snapshotTask: Task<Void, Never>?

    private static let sharedDataStore = WKWebsiteDataStore.nonPersistent()

    init(source: String, style: HTMLBlockPageStyle, baseDirectoryURL: URL?, blockRange: NSRange, layoutWidth: CGFloat) {
        self.source = source
        self.style = style
        self.blockRange = blockRange
        self.layoutWidth = layoutWidth
        let assetHandler = HTMLBlockAssetSchemeHandler(baseDirectoryURL: baseDirectoryURL)
        let messageProxy = HTMLBlockMessageProxy()
        self.assetHandler = assetHandler
        self.messageProxy = messageProxy

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = Self.sharedDataStore
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.suppressesIncrementalRendering = true
        configuration.setURLSchemeHandler(assetHandler, forURLScheme: HTMLBlockPage.assetScheme)
        let contentController = WKUserContentController()
        contentController.addUserScript(
            WKUserScript(
                source: HTMLBlockPage.bridgeScript(source: source),
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true,
                in: .defaultClient
            ))
        contentController.add(messageProxy, contentWorld: .defaultClient, name: HTMLBlockPage.messageHandlerName)
        configuration.userContentController = contentController

        super.init(frame: NSRect(x: 0, y: 0, width: layoutWidth, height: 1), configuration: configuration)
        messageProxy.owner = self
        navigationDelegate = self
        allowsMagnification = false
        allowsBackForwardNavigationGestures = false
        allowsLinkPreview = false
        underPageBackgroundColor = .clear
        alphaValue = 0
        loadPage()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Reloads the page when the theme or the document folder changed.
    func update(style newStyle: HTMLBlockPageStyle, baseDirectoryURL: URL?) {
        assetHandler.baseDirectoryURL = baseDirectoryURL
        guard newStyle != style else { return }
        style = newStyle
        isReady = false
        pendingHighlights = pendingHighlights ?? appliedHighlights
        appliedHighlights = []
        loadPage()
    }

    private func loadPage() {
        allowsInitialNavigation = true
        loadHTMLString(HTMLBlockPage.document(source: source, style: style), baseURL: HTMLBlockPage.baseURL)
    }

    // MARK: - Commands from the text view

    func setHighlights(_ highlights: [Highlight]) {
        guard isReady else {
            pendingHighlights = highlights
            return
        }
        guard highlights != appliedHighlights else { return }
        appliedHighlights = highlights
        let items = highlights.map { ["start": $0.start, "end": $0.end, "kind": $0.kind] as [String: Any] }
        guard let data = try? JSONSerialization.data(withJSONObject: items) else { return }
        runBridge("window.__folioSetHighlights(\(String(decoding: data, as: UTF8.self)))")
    }

    /// Selects a range of the block source in the page, once the page is ready.
    func selectSource(start: Int, end: Int) {
        guard isReady else {
            pendingSelection = (start, end)
            return
        }
        runBridge("window.__folioSelect(\(start), \(end))")
    }

    func clearSelection() {
        selection = nil
        pendingSelection = nil
        if isReady {
            runBridge("window.__folioClearSelection()")
        }
    }

    func setDimFactor(_ dimFactor: CGFloat) {
        guard abs(dimFactor - appliedOpacity) > 0.01 else { return }
        appliedOpacity = dimFactor
        if isReady {
            runBridge("window.__folioSetOpacity(\(Double(dimFactor)))")
        }
    }

    private func runBridge(_ expression: String) {
        evaluateJavaScript("\(expression); void 0", in: nil, in: .defaultClient, completionHandler: nil)
    }

    /// Number of ranges in each highlight that the page paints, by highlight name.
    func paintedHighlightCounts() async -> [String: Int] {
        let script = """
            const counts = {};
            for (const name of ['folio-comment', 'folio-comment-active', 'folio-draft']) {
              const highlight = CSS.highlights.get(name);
              counts[name] = highlight ? highlight.size : 0;
            }
            return counts;
            """
        let result = try? await callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .defaultClient)
        return (result as? [String: Int]) ?? [:]
    }

    /// Renders the visible page into an image for printing and for drawing before load.
    func captureSnapshot() async -> NSImage? {
        try? await takeSnapshot(configuration: nil)
    }

    /// Caches a snapshot once the page has stopped changing size.
    private func scheduleSnapshot() {
        snapshotTask?.cancel()
        snapshotTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self, self.isReady, self.window != nil, !self.bounds.isEmpty else { return }
            if let image = await self.captureSnapshot() {
                HTMLBlockLayoutCache.shared.setSnapshot(image, for: self.source)
            }
        }
    }

    // MARK: - Bridge messages

    fileprivate func handleMessage(_ body: Any) {
        guard let message = body as? [String: Any], let type = message["type"] as? String else { return }
        switch type {
        case "ready":
            isReady = true
            alphaValue = 1
            if abs(appliedOpacity - 1.0) > 0.01 {
                runBridge("window.__folioSetOpacity(\(Double(appliedOpacity)))")
            }
            if let pending = pendingHighlights {
                pendingHighlights = nil
                appliedHighlights = []
                setHighlights(pending)
            }
            if let pending = pendingSelection {
                pendingSelection = nil
                selectSource(start: pending.start, end: pending.end)
            }
            blockDelegate?.htmlBlockWebViewDidBecomeReady(self)
        case "height":
            guard let height = (message["height"] as? NSNumber)?.doubleValue, height >= 0 else { return }
            measuredHeight = CGFloat(height)
            blockDelegate?.htmlBlockWebView(self, didMeasureHeight: CGFloat(height))
            scheduleSnapshot()
        case "selection":
            let next = Self.selection(from: message, sourceLength: (source as NSString).length)
            // WebKit collapses the page selection when the view loses focus (for example to the
            // comment field). Keep it, as NSTextView keeps its selection; the text view clears
            // it when the user selects elsewhere.
            if next == nil, window?.firstResponder !== self { return }
            guard next != selection else { return }
            selection = next
            blockDelegate?.htmlBlockWebView(self, didChangeSelection: next)
        case "click":
            let offset = (message["offset"] as? NSNumber)?.intValue
            let clickCount = (message["count"] as? NSNumber)?.intValue ?? 1
            blockDelegate?.htmlBlockWebView(self, didClickSourceOffset: offset, clickCount: clickCount)
        default:
            break
        }
    }

    static func selection(from message: [String: Any], sourceLength: Int) -> Selection? {
        guard (message["empty"] as? Bool) == false,
            let start = (message["start"] as? NSNumber)?.intValue,
            let end = (message["end"] as? NSNumber)?.intValue
        else {
            return nil
        }
        let clampedStart = max(0, min(start, sourceLength))
        let clampedEnd = max(clampedStart, min(end, sourceLength))
        guard clampedEnd > clampedStart else { return nil }
        let rects = (message["rects"] as? [[NSNumber]] ?? []).compactMap { values -> NSRect? in
            guard values.count == 4 else { return nil }
            return NSRect(x: values[0].doubleValue, y: values[1].doubleValue, width: values[2].doubleValue, height: values[3].doubleValue)
        }
        return Selection(start: clampedStart, end: clampedEnd, rects: rects, isBackward: (message["backward"] as? Bool) ?? false)
    }

    // MARK: - Navigation

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard navigationAction.targetFrame?.isMainFrame ?? false else { return .cancel }
        if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
            if url.fragment != nil, url.scheme == HTMLBlockPage.assetScheme {
                return .allow
            }
            if ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                NSWorkspace.shared.open(url)
            }
            return .cancel
        }
        guard allowsInitialNavigation else { return .cancel }
        allowsInitialNavigation = false
        return .allow
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        isReady = false
        pendingHighlights = appliedHighlights
        appliedHighlights = []
        loadPage()
    }

    // MARK: - Events

    /// Vertical scrolling moves the document, not the page (the page never scrolls).
    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
            super.scrollWheel(with: event)
        } else {
            nextResponder?.scrollWheel(with: event)
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            blockDelegate?.htmlBlockWebViewRequestsTextFocus(self)
            return
        }
        super.keyDown(with: event)
    }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        var items: [NSMenuItem] = []
        if selection != nil {
            items.append(NSMenuItem(title: "Add Comment on Selection…", action: #selector(handleAddComment(_:)), keyEquivalent: ""))
            items.append(NSMenuItem(title: "Copy Raw Markdown", action: #selector(handleCopyRaw(_:)), keyEquivalent: ""))
        }
        items.append(NSMenuItem(title: "Edit HTML Source", action: #selector(handleEditSource(_:)), keyEquivalent: ""))
        menu.insertItem(.separator(), at: 0)
        for item in items.reversed() {
            item.target = self
            menu.insertItem(item, at: 0)
        }
    }

    @objc private func handleAddComment(_ sender: Any?) {
        blockDelegate?.htmlBlockWebViewRequestsComment(self)
    }

    @objc private func handleCopyRaw(_ sender: Any?) {
        blockDelegate?.htmlBlockWebViewRequestsRawCopy(self)
    }

    @objc private func handleEditSource(_ sender: Any?) {
        blockDelegate?.htmlBlockWebViewRequestsSourceEditing(self)
    }
}

/// Forwards bridge messages without the content controller retaining the web view.
@MainActor
private final class HTMLBlockMessageProxy: NSObject, WKScriptMessageHandler {
    weak var owner: HTMLBlockWebView?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        owner?.handleMessage(message.body)
    }
}

/// Serves `folio-doc://local/<path>` from the document's folder. Paths that leave the folder
/// fail, so a block can only load files next to (or below) its document.
@MainActor
final class HTMLBlockAssetSchemeHandler: NSObject, WKURLSchemeHandler {
    var baseDirectoryURL: URL?
    private var activeTasks: [ObjectIdentifier: any WKURLSchemeTask] = [:]

    init(baseDirectoryURL: URL?) {
        self.baseDirectoryURL = baseDirectoryURL
    }

    static func fileURL(for url: URL?, baseDirectoryURL: URL?) -> URL? {
        guard let url, url.scheme == HTMLBlockPage.assetScheme, let base = baseDirectoryURL?.standardizedFileURL else { return nil }
        let relative = url.path(percentEncoded: false)
        let candidate = base.appending(path: relative).standardizedFileURL
        let basePath = base.path(percentEncoded: false)
        let prefix = basePath.hasSuffix("/") ? basePath : basePath + "/"
        guard candidate.path(percentEncoded: false).hasPrefix(prefix) else { return nil }
        return candidate
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let id = ObjectIdentifier(urlSchemeTask)
        guard let fileURL = Self.fileURL(for: urlSchemeTask.request.url, baseDirectoryURL: baseDirectoryURL) else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        activeTasks[id] = urlSchemeTask
        Task { [weak self] in
            let data = await Task.detached(priority: .userInitiated) { try? Data(contentsOf: fileURL) }.value
            guard let self, let task = self.activeTasks.removeValue(forKey: id) else { return }
            guard let data else {
                task.didFailWithError(URLError(.fileDoesNotExist))
                return
            }
            let mimeType = UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            task.didReceive(URLResponse(url: task.request.url ?? fileURL, mimeType: mimeType, expectedContentLength: data.count, textEncodingName: nil))
            task.didReceive(data)
            task.didFinish()
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        activeTasks.removeValue(forKey: ObjectIdentifier(urlSchemeTask))
    }
}
