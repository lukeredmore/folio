import AppKit
import Combine
import Foundation
import SwiftUI

public enum SidebarTab: String, CaseIterable, Identifiable {
    case files = "Files"
    case outline = "Outline"
    case search = "Search"

    public var id: String { rawValue }
}

public enum FileDisplayStyle: String, CaseIterable {
    case tree = "Tree"
    case list = "List"
}

public final class EditorWorkspaceViewModel: ObservableObject {

    // MARK: - Document & Editor State
    @Published public var markdownText: String
    @Published public var currentFileURL: URL?
    @Published public var isDirty: Bool = false

    // MARK: - Editor Modes, Theme & Typography
    @Published public var theme: EditorTheme = .daylight
    @Published public var typography: EditorTypographySettings = .default {
        didSet {
            if let encoded = try? JSONEncoder().encode(typography) {
                UserDefaults.standard.set(encoded, forKey: Self.typographyDefaultsKey)
            }
        }
    }
    @Published public var sourceCodeMode: Bool = false
    @Published public var focusMode: Bool = false
    @Published public var typewriterMode: Bool = false
    @Published public var spellCheckEnabled: Bool = false

    // MARK: - Sidebar & Panels
    @Published public var showSidebar: Bool = true
    @Published public var activeSidebarTab: SidebarTab = .outline
    @Published public var fileDisplayStyle: FileDisplayStyle = .tree
    @Published public var fileSortOrder: FileSortOrder = .name
    @Published public var outlineFilterText: String = ""

    // MARK: - Modals & Banners
    @Published public var showQuickOpen: Bool = false
    @Published public var quickOpenQuery: String = ""
    @Published public var showWordCountPopover: Bool = false
    @Published public var showInsertTableSheet: Bool = false
    @Published public var showSettingsModal: Bool = false
    @Published public var showFindReplaceBar: Bool = false
    @Published public var findQuery: String = ""
    @Published public var replaceQuery: String = ""

    // MARK: - Outline & Statistics
    @Published public var headings: [OutlineHeading] = []
    @Published public var activeHeadingID: String?
    @Published public var stats: DocumentStats = DocumentStats()
    @Published public var pendingScrollToCharacterLocation: Int?

    // MARK: - Workspace Files & Search
    @Published public var workspaceFolderURL: URL?
    @Published public var rootFileNodes: [WorkspaceFileNode] = []
    @Published public var flatMarkdownFiles: [WorkspaceFileNode] = []
    @Published public var recentFileURLs: [URL] = []

    @Published public var workspaceSearchQuery: String = ""
    @Published public var searchCaseSensitive: Bool = false
    @Published public var searchWholeWord: Bool = false
    @Published public var searchUseRegex: Bool = false
    @Published public var workspaceSearchMatches: [WorkspaceSearchMatch] = []

    public weak var activeTextView: HybridMarkdownTextView?

    private static let typographyDefaultsKey = "OpenType.EditorTypographySettings.v2"

    private var fileWatchSource: DispatchSourceFileSystemObject?
    private var fileWatchDescriptor: Int32 = -1

    public init() {
        if let data = UserDefaults.standard.data(forKey: Self.typographyDefaultsKey),
           let decoded = try? JSONDecoder().decode(EditorTypographySettings.self, from: data) {
            self.typography = decoded
        } else {
            self.typography = .default
        }

        let initialContent = Self.defaultWelcomeDocument
        self.markdownText = initialContent
        self.stats = DocumentStats.compute(for: initialContent)

        let analysis = MarkdownLiveStyler.applyStyles(
            to: NSTextStorage(string: initialContent),
            theme: .daylight,
            typography: self.typography,
            sourceCodeMode: false,
            focusMode: false,
            selectedRange: NSRange(location: 0, length: 0)
        )
        self.headings = analysis.headings

        let cwdPath = FileManager.default.currentDirectoryPath
        let initialWorkspaceURL: URL
        if cwdPath == "/" || cwdPath.isEmpty {
            let bundleURL = Bundle.main.bundleURL
            if bundleURL.pathExtension == "app" {
                let parentDir = bundleURL.deletingLastPathComponent()
                if parentDir.path != "/" && parentDir.path != "/Applications" {
                    initialWorkspaceURL = parentDir
                } else {
                    initialWorkspaceURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
                        ?? FileManager.default.homeDirectoryForCurrentUser
                }
            } else {
                initialWorkspaceURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
                    ?? FileManager.default.homeDirectoryForCurrentUser
            }
        } else {
            initialWorkspaceURL = URL(fileURLWithPath: cwdPath)
        }
        self.loadWorkspaceFolder(initialWorkspaceURL)
    }

    deinit {
        stopWatchingCurrentFile()
    }

    public func resetTypographyToDefaults() {
        typography = .default
    }

    // MARK: - Document Title
    public var documentTitle: String {
        if let url = currentFileURL {
            return url.lastPathComponent
        }
        if let firstH1 = headings.first(where: { $0.level == 1 }) {
            return "\(firstH1.title).md"
        }
        return "Untitled.md"
    }

    // MARK: - Live Editor Updates
    public func handleEditorTextEdited(_ newText: String, selectedRange: NSRange) {
        if markdownText != newText {
            markdownText = newText
            isDirty = true
        }
        stats = DocumentStats.compute(for: newText, selectedRange: selectedRange)
    }

    public func updateSelectionStats(selectedRange: NSRange) {
        stats = DocumentStats.compute(for: markdownText, selectedRange: selectedRange)
    }

    // MARK: - Task Checkbox Toggling
    public func toggleTaskCheckbox(at boxCharacterLocation: Int) {
        let nsStr = markdownText as NSString
        let boxRange = NSRange(location: boxCharacterLocation, length: 3)
        guard boxCharacterLocation >= 0, NSMaxRange(boxRange) <= nsStr.length else { return }

        let currentBox = nsStr.substring(with: boxRange)
        let replacement: String
        if currentBox.lowercased() == "[x]" {
            replacement = "[ ]"
        } else if currentBox == "[ ]" {
            replacement = "[x]"
        } else {
            return
        }

        if let tv = activeTextView, tv.shouldChangeText(in: boxRange, replacementString: replacement) {
            tv.replaceCharacters(in: boxRange, with: replacement)
            tv.didChangeText()
        } else {
            markdownText = nsStr.replacingCharacters(in: boxRange, with: replacement)
            isDirty = true
        }
    }

    // MARK: - Navigation
    public func scrollToHeading(_ heading: OutlineHeading) {
        pendingScrollToCharacterLocation = heading.characterLocation
        activeHeadingID = heading.id
    }

    public func jumpToSearchMatch(_ match: WorkspaceSearchMatch) {
        if currentFileURL != match.fileURL {
            openFile(at: match.fileURL)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.pendingScrollToCharacterLocation = match.matchRangeInFile.location
        }
    }

    // MARK: - Formatting & Markdown Insertion Commands
    public func applyInlineFormatting(prefix: String, suffix: String, placeholder: String) {
        guard let tv = activeTextView else {
            markdownText += "\(prefix)\(placeholder)\(suffix)"
            return
        }
        let sel = tv.selectedRange()
        let nsStr = tv.string as NSString
        let selectedText = sel.length > 0 ? nsStr.substring(with: sel) : placeholder
        let replacement = "\(prefix)\(selectedText)\(suffix)"

        if tv.shouldChangeText(in: sel, replacementString: replacement) {
            tv.replaceCharacters(in: sel, with: replacement)
            tv.didChangeText()
            let innerRange = NSRange(location: sel.location + (prefix as NSString).length, length: (selectedText as NSString).length)
            tv.setSelectedRange(innerRange)
        }
    }

    public func setHeadingLevel(_ level: Int) {
        guard let tv = activeTextView else { return }
        let sel = tv.selectedRange()
        let nsStr = tv.string as NSString
        let lineRange = nsStr.lineRange(for: NSRange(location: min(sel.location, nsStr.length), length: 0))
        var contentRange = lineRange
        while contentRange.length > 0 {
            let ch = nsStr.character(at: contentRange.location + contentRange.length - 1)
            if ch == 10 || ch == 13 { contentRange.length -= 1 } else { break }
        }
        let lineText = nsStr.substring(with: contentRange)
        let stripped = lineText.replacingOccurrences(of: #"^#{1,6}\s*"#, with: "", options: .regularExpression)

        let replacement: String
        if level == 0 {
            replacement = stripped
        } else {
            let hashes = String(repeating: "#", count: min(6, max(1, level)))
            replacement = "\(hashes) \(stripped.isEmpty ? "Heading \(level)" : stripped)"
        }

        if tv.shouldChangeText(in: contentRange, replacementString: replacement) {
            tv.replaceCharacters(in: contentRange, with: replacement)
            tv.didChangeText()
            tv.setSelectedRange(NSRange(location: contentRange.location + (replacement as NSString).length, length: 0))
        }
    }

    public func insertBlockquote() {
        prefixCurrentLine(with: "> ")
    }

    public func insertUnorderedList() {
        prefixCurrentLine(with: "- ")
    }

    public func insertOrderedList() {
        prefixCurrentLine(with: "1. ")
    }

    public func insertTaskList() {
        prefixCurrentLine(with: "- [ ] ")
    }

    private func prefixCurrentLine(with prefix: String) {
        guard let tv = activeTextView else { return }
        let sel = tv.selectedRange()
        let nsStr = tv.string as NSString
        let lineRange = nsStr.lineRange(for: NSRange(location: min(sel.location, nsStr.length), length: 0))
        let insertRange = NSRange(location: lineRange.location, length: 0)
        if tv.shouldChangeText(in: insertRange, replacementString: prefix) {
            tv.replaceCharacters(in: insertRange, with: prefix)
            tv.didChangeText()
            tv.setSelectedRange(NSRange(location: sel.location + (prefix as NSString).length, length: 0))
        }
    }

    public func insertCodeFence(language: String = "swift") {
        let snippet = "\n```\(language)\n\n```\n"
        insertSnippetAtCursor(snippet, cursorOffsetFromStart: 5 + language.count)
    }

    public func insertMathBlock() {
        let snippet = "\n$$\n\\int_{-\\infty}^{\\infty} e^{-x^2} dx = \\sqrt{\\pi}\n$$\n"
        insertSnippetAtCursor(snippet, cursorOffsetFromStart: 4)
    }

    public func insertHorizontalRule() {
        let snippet = "\n---\n"
        insertSnippetAtCursor(snippet, cursorOffsetFromStart: snippet.count)
    }

    public func insertTable(rows: Int, columns: Int) {
        let r = max(1, min(30, rows))
        let c = max(1, min(12, columns))
        let headers = (1...c).map { "Header \($0)" }.joined(separator: " | ")
        let sep = (1...c).map { _ in "---" }.joined(separator: " | ")
        var tableLines = [
            "| \(headers) |",
            "| \(sep) |"
        ]
        for rowIdx in 1...r {
            let cells = (1...c).map { "Row \(rowIdx) Col \($0)" }.joined(separator: " | ")
            tableLines.append("| \(cells) |")
        }
        let snippet = "\n" + tableLines.joined(separator: "\n") + "\n"
        insertSnippetAtCursor(snippet, cursorOffsetFromStart: 3)
    }

    private func insertSnippetAtCursor(_ snippet: String, cursorOffsetFromStart: Int) {
        guard let tv = activeTextView else {
            markdownText += snippet
            return
        }
        let sel = tv.selectedRange()
        if tv.shouldChangeText(in: sel, replacementString: snippet) {
            tv.replaceCharacters(in: sel, with: snippet)
            tv.didChangeText()
            let newCursor = min((tv.string as NSString).length, sel.location + cursorOffsetFromStart)
            tv.setSelectedRange(NSRange(location: newCursor, length: 0))
        }
    }

    // MARK: - Find & Replace in Current Document
    public func findNextInDocument() {
        guard !findQuery.isEmpty, let tv = activeTextView else { return }
        let nsStr = tv.string as NSString
        let startLoc = min(NSMaxRange(tv.selectedRange()), nsStr.length)
        let searchRange = NSRange(location: startLoc, length: nsStr.length - startLoc)

        var found = nsStr.range(of: findQuery, options: [.caseInsensitive], range: searchRange)
        if found.location == NSNotFound && startLoc > 0 {
            found = nsStr.range(of: findQuery, options: [.caseInsensitive], range: NSRange(location: 0, length: startLoc))
        }
        if found.location != NSNotFound {
            tv.setSelectedRange(found)
            tv.scrollRangeToVisible(found)
        }
    }

    public func replaceCurrentMatch() {
        guard !findQuery.isEmpty, let tv = activeTextView else { return }
        let sel = tv.selectedRange()
        let nsStr = tv.string as NSString
        if sel.length > 0 && nsStr.substring(with: sel).caseInsensitiveCompare(findQuery) == .orderedSame {
            if tv.shouldChangeText(in: sel, replacementString: replaceQuery) {
                tv.replaceCharacters(in: sel, with: replaceQuery)
                tv.didChangeText()
            }
        }
        findNextInDocument()
    }

    public func replaceAllInDocument() {
        guard !findQuery.isEmpty else { return }
        let updated = markdownText.replacingOccurrences(of: findQuery, with: replaceQuery, options: [.caseInsensitive])
        if updated != markdownText {
            markdownText = updated
            isDirty = true
        }
    }

    // MARK: - File & Workspace Operations
    public func newDocument() {
        stopWatchingCurrentFile()
        currentFileURL = nil
        markdownText = "# Untitled\n\n"
        isDirty = false
        stats = DocumentStats.compute(for: markdownText)
    }

    public func openDocumentPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        if panel.runModal() == .OK, let url = panel.url {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                loadWorkspaceFolder(url)
                showSidebar = true
                activeSidebarTab = .files
            } else {
                openFile(at: url)
            }
        }
    }

    public func openFolderPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Open Folder"
        if panel.runModal() == .OK, let url = panel.url {
            loadWorkspaceFolder(url)
            showSidebar = true
            activeSidebarTab = .files
        }
    }

    public func openFile(at url: URL) {
        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            currentFileURL = url
            markdownText = content
            isDirty = false
            stats = DocumentStats.compute(for: content)
            addRecentFile(url)
            watchCurrentFile(url)
        } catch {
            NSSound.beep()
        }
    }

    public func saveDocument() {
        if let url = currentFileURL {
            writeDocument(to: url)
        } else {
            saveDocumentAs()
        }
    }

    public func saveDocumentAs() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = documentTitle
        panel.allowedContentTypes = [.plainText]
        if panel.runModal() == .OK, let url = panel.url {
            writeDocument(to: url)
            currentFileURL = url
            addRecentFile(url)
            watchCurrentFile(url)
            if let folder = workspaceFolderURL {
                loadWorkspaceFolder(folder)
            }
        }
    }

    public func createNewFileInWorkspace() {
        guard let folder = workspaceFolderURL else {
            newDocument()
            return
        }
        var candidateIndex = 1
        var targetURL = folder.appendingPathComponent("Untitled.md")
        while FileManager.default.fileExists(atPath: targetURL.path) {
            candidateIndex += 1
            targetURL = folder.appendingPathComponent("Untitled \(candidateIndex).md")
        }
        let template = "# \(targetURL.deletingPathExtension().lastPathComponent)\n\n"
        try? template.write(to: targetURL, atomically: true, encoding: .utf8)
        loadWorkspaceFolder(folder)
        openFile(at: targetURL)
    }

    private func writeDocument(to url: URL) {
        do {
            try markdownText.write(to: url, atomically: true, encoding: .utf8)
            isDirty = false
        } catch {
            NSSound.beep()
        }
    }

    private func addRecentFile(_ url: URL) {
        recentFileURLs.removeAll(where: { $0 == url })
        recentFileURLs.insert(url, at: 0)
        if recentFileURLs.count > 15 {
            recentFileURLs = Array(recentFileURLs.prefix(15))
        }
    }

    // MARK: - POSIX DispatchSource File Watcher
    private func watchCurrentFile(_ url: URL) {
        stopWatchingCurrentFile()
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        fileWatchDescriptor = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .extend],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self = self, !self.isDirty, let currentURL = self.currentFileURL else { return }
            if let diskContent = try? String(contentsOf: currentURL, encoding: .utf8),
               diskContent != self.markdownText {
                self.markdownText = diskContent
                self.stats = DocumentStats.compute(for: diskContent)
            }
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        fileWatchSource = source
    }

    private func stopWatchingCurrentFile() {
        fileWatchSource?.cancel()
        fileWatchSource = nil
        fileWatchDescriptor = -1
    }

    // MARK: - Workspace Folder Tree & Multi-file Search
    public func loadWorkspaceFolder(_ folderURL: URL) {
        workspaceFolderURL = folderURL
        var flatList: [WorkspaceFileNode] = []
        rootFileNodes = scanDirectory(at: folderURL, depth: 0, flatAccumulator: &flatList)
        sortFileNodes()
        flatMarkdownFiles = flatList
    }

    private func scanDirectory(at url: URL, depth: Int, flatAccumulator: inout [WorkspaceFileNode]) -> [WorkspaceFileNode] {
        guard depth < 4 else { return [] }
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let ignoredDirs: Set<String> = [".build", ".git", "node_modules", "DerivedData", ".swiftpm"]
        var nodes: [WorkspaceFileNode] = []

        for itemURL in contents {
            let name = itemURL.lastPathComponent
            if ignoredDirs.contains(name) { continue }

            let resourceValues = try? itemURL.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey, .creationDateKey])
            let isDir = resourceValues?.isDirectory ?? false
            let modDate = resourceValues?.contentModificationDate ?? Date.distantPast
            let createDate = resourceValues?.creationDate ?? Date.distantPast

            if isDir {
                let children = scanDirectory(at: itemURL, depth: depth + 1, flatAccumulator: &flatAccumulator)
                let node = WorkspaceFileNode(
                    url: itemURL,
                    name: name,
                    isDirectory: true,
                    modificationDate: modDate,
                    creationDate: createDate,
                    children: children
                )
                nodes.append(node)
            } else {
                let node = WorkspaceFileNode(
                    url: itemURL,
                    name: name,
                    isDirectory: false,
                    modificationDate: modDate,
                    creationDate: createDate,
                    children: nil
                )
                nodes.append(node)
                if node.isMarkdownFile || ["swift", "json", "yml", "yaml", "css", "html"].contains(itemURL.pathExtension.lowercased()) {
                    flatAccumulator.append(node)
                }
            }
        }

        return sortNodesArray(nodes, by: fileSortOrder)
    }

    public func sortFileNodes() {
        rootFileNodes = sortNodesArray(rootFileNodes, by: fileSortOrder)
        flatMarkdownFiles = sortNodesArray(flatMarkdownFiles, by: fileSortOrder)
    }

    private func sortNodesArray(_ nodes: [WorkspaceFileNode], by order: FileSortOrder) -> [WorkspaceFileNode] {
        nodes.map { node in
            var copy = node
            if let children = copy.children {
                copy.children = sortNodesArray(children, by: order)
            }
            return copy
        }.sorted { a, b in
            if a.isDirectory != b.isDirectory {
                return a.isDirectory
            }
            switch order {
            case .name:
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            case .modificationDate:
                return a.modificationDate > b.modificationDate
            case .creationDate:
                return a.creationDate > b.creationDate
            }
        }
    }

    public func performWorkspaceSearch() {
        let query = workspaceSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            workspaceSearchMatches = []
            return
        }

        var results: [WorkspaceSearchMatch] = []
        let pattern: String
        if searchUseRegex {
            pattern = query
        } else if searchWholeWord {
            pattern = "\\b\(NSRegularExpression.escapedPattern(for: query))\\b"
        } else {
            pattern = NSRegularExpression.escapedPattern(for: query)
        }

        let regexOptions: NSRegularExpression.Options = searchCaseSensitive ? [] : [.caseInsensitive]
        guard let regex = try? NSRegularExpression(pattern: pattern, options: regexOptions) else {
            workspaceSearchMatches = []
            return
        }

        // Also search current active buffer first if unsaved
        if currentFileURL == nil {
            searchInText(
                markdownText,
                fileURL: URL(fileURLWithPath: "/Untitled.md"),
                fileName: documentTitle,
                regex: regex,
                results: &results
            )
        }

        for fileNode in flatMarkdownFiles {
            guard let text = try? String(contentsOf: fileNode.url, encoding: .utf8) else { continue }
            searchInText(text, fileURL: fileNode.url, fileName: fileNode.name, regex: regex, results: &results)
            if results.count >= 200 { break }
        }

        workspaceSearchMatches = results
    }

    private func searchInText(
        _ text: String,
        fileURL: URL,
        fileName: String,
        regex: NSRegularExpression,
        results: inout [WorkspaceSearchMatch]
    ) {
        let nsStr = text as NSString
        var index = 0
        var lineNum = 1
        while index < nsStr.length {
            let lineRange = nsStr.lineRange(for: NSRange(location: index, length: 0))
            if let match = regex.firstMatch(in: text, options: [], range: lineRange) {
                let snippet = nsStr.substring(with: lineRange).trimmingCharacters(in: .whitespacesAndNewlines)
                results.append(WorkspaceSearchMatch(
                    fileURL: fileURL,
                    fileName: fileName,
                    lineNumber: lineNum,
                    lineSnippet: snippet,
                    matchRangeInFile: match.range
                ))
            }
            index = NSMaxRange(lineRange)
            lineNum += 1
        }
    }

    // MARK: - HTML & PDF Export
    public func exportToHTML() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = documentTitle.replacingOccurrences(of: ".md", with: "") + ".html"
        panel.allowedContentTypes = [.html]
        if panel.runModal() == .OK, let url = panel.url {
            let html = generateStandaloneHTML()
            try? html.write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    public func exportToPDF() {
        guard let tv = activeTextView else { return }
        let printInfo = NSPrintInfo.shared
        printInfo.topMargin = 36
        printInfo.bottomMargin = 36
        printInfo.leftMargin = 36
        printInfo.rightMargin = 36
        let op = NSPrintOperation(view: tv, printInfo: printInfo)
        op.RunModal()
    }

    public func generateStandaloneHTML() -> String {
        let escapedLines = markdownText.components(separatedBy: .newlines).map { line -> String in
            if line.hasPrefix("# ") { return "<h1>\(line.dropFirst(2))</h1>" }
            if line.hasPrefix("## ") { return "<h2>\(line.dropFirst(3))</h2>" }
            if line.hasPrefix("### ") { return "<h3>\(line.dropFirst(4))</h3>" }
            if line.hasPrefix("> ") { return "<blockquote>\(line.dropFirst(2))</blockquote>" }
            if line.trimmingCharacters(in: .whitespaces) == "---" { return "<hr/>" }
            if line.isEmpty { return "" }
            return "<p>\(line)</p>"
        }.joined(separator: "\n")

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <title>\(documentTitle)</title>
        <style>
        body {
            max-width: \(Int(theme.maxWriteWidth))px;
            margin: 40px auto;
            padding: 0 24px;
            font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", Georgia, serif;
            font-size: \(Int(theme.baseFontSize))px;
            line-height: 1.6;
        }
        blockquote { border-left: 4px solid #dfe2e5; padding-left: 16px; color: #6a737d; }
        pre, code { background: #f6f8fa; border-radius: 4px; padding: 2px 6px; font-family: ui-monospace, Menlo, monospace; }
        </style>
        </head>
        <body>
        \(escapedLines)
        </body>
        </html>
        """
    }

    // MARK: - Default Showcase Document
    public static let defaultWelcomeDocument = """
    # OpenType — Native macOS Markdown Editor
    Welcome to **OpenType**, a lightning-fast **100% native macOS** (`AppKit` + `TextKit` + `SwiftUI`) Markdown editor built for distraction-free writing.
    > **Seamless Live Rendering**: Place your cursor on any line to reveal and edit its raw Markdown tokens (`#`, `**`, `` ` ``, `[link](url)`). Move the cursor away and the syntax markers collapse cleanly into live typography—with zero WebView overhead.
    ---
    ## Key Features
    - [x] **Seamless Hybrid WYSIWYG Editor** (`HybridMarkdownTextView`) with zero-latency native TextKit layout
    - [x] **6 Curated Themes**: *Daylight*, *Midnight*, *Parchment*, *Editorial*, *Classic*, and *Modernist*
    - [x] **Focus Mode** (`F8`) & **Typewriter Mode** (`F9`) & **Source Code Mode** (`Cmd+/`)
    - [x] **Hierarchical Sidebar** (`Cmd+Shift+L`): Document **Outline**, **Files** (Tree & List views), and **Global Search**
    - [x] **Quick Open Modal** (`Cmd+P`) for instant fuzzy file switching
    - [x] **Live Word Count Popover** showing Words, Lines, Characters, and Reading Time
    ### Inline Typography & Math
    You can write **bold text**, *italicized emphasis*, ~~strikethrough~~, ==highlighted notes==, `inline code`, and [clickable links](https://example.com) effortlessly. Inline math like $E = mc^2$ and $\\nabla \\cdot \\mathbf{E} = \\frac{\\rho}{\\varepsilon_0}$ is styled live.
    $$
    \\mathcal{L}_{\\text{OpenType}} = \\int_{-\\infty}^{\\infty} \\psi^*(x) \\left( -\\frac{\\hbar^2}{2m}\\nabla^2 + V(x) \\right) \\psi(x)\\,dx
    $$
    ### Native Code Fences with Syntax Highlighting
    ```swift
    import AppKit

    // Pure native TextKit rendering — 0 MB WebView footprint
    final class OpenTypeEngine {
        func renderLiveMarkdown(in storage: NSTextStorage) -> Bool {
            let latencyMs = 0.15
            return latencyMs < 1.0
        }
    }
    ```
    ### Live Markdown Tables
    | Subsystem | Architecture | Performance |
    | :--- | :--- | :--- |
    | **UI Layer** | Pure `AppKit` + `SwiftUI` | Native 120Hz ProMotion |
    | **Editor Engine** | Native `NSTextStorage` + `TextKit` | Sub-millisecond restyling |
    | **State Sync** | Direct in-memory Swift state | Zero IPC serialization |
    | **Themes** | 6 Native `EditorTheme` Palettes | Instant switching |
    """
}

private extension NSPrintOperation {
    func RunModal() {
        run()
    }
}
