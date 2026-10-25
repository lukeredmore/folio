import AppKit
import Foundation
import SwiftUI

public struct QuickOpenPathCandidate: Equatable {
    public let url: URL
    public let isDirectory: Bool
    public let exists: Bool
    public let lineNumber: Int?
    public let columnNumber: Int?

    public init(url: URL, isDirectory: Bool, exists: Bool, lineNumber: Int? = nil, columnNumber: Int? = nil) {
        self.url = url
        self.isDirectory = isDirectory
        self.exists = exists
        self.lineNumber = lineNumber
        self.columnNumber = columnNumber
    }
}

extension EditorWorkspaceViewModel {

    // MARK: - Quick Open (Shift-Shift) & Path Opening

    public func toggleQuickOpen() {
        if showQuickOpen {
            closeQuickOpen()
        } else {
            quickOpenQuery = ""
            quickOpenSelectedIndex = 0
            showQuickOpen = true
        }
    }

    public func closeQuickOpen() {
        showQuickOpen = false
        if let tv = activeTextView, let window = tv.window {
            window.makeFirstResponder(tv)
        }
    }

    public func moveQuickOpenSelection(by delta: Int) {
        let count = quickOpenFilteredFiles.count
        guard count > 0 else {
            quickOpenSelectedIndex = 0
            return
        }
        let next = (quickOpenSelectedIndex + delta) % count
        quickOpenSelectedIndex = next < 0 ? next + count : next
    }

    public var quickOpenFilteredFiles: [WorkspaceFileNode] {
        let q = quickOpenQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty {
            return Array(flatMarkdownFiles.prefix(25))
        }
        let cleaned = Self.stripSurroundingQuotes(from: q)
        let expanded = (cleaned as NSString).expandingTildeInPath
        return flatMarkdownFiles.filter { node in
            node.name.localizedCaseInsensitiveContains(q) ||
            node.url.path.localizedCaseInsensitiveContains(q) ||
            node.url.path.localizedCaseInsensitiveContains(expanded) ||
            node.url.resolvingSymlinksInPath().path.localizedCaseInsensitiveContains(expanded) ||
            (node.remoteConnectionString?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }

    public func resolveQuickOpenPathCandidate(
        for rawQuery: String,
        preferWorkingDirectory: Bool = false
    ) -> QuickOpenPathCandidate? {
        let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var cleaned = Self.stripSurroundingQuotes(from: trimmed)
        if cleaned.hasPrefix("file://") {
            if let fileURL = URL(string: cleaned), fileURL.isFileURL {
                cleaned = fileURL.path
            } else if let encoded = cleaned.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                      let fileURL = URL(string: encoded), fileURL.isFileURL {
                cleaned = fileURL.path
            }
        }

        let (pathPart, parsedLine, parsedCol, _) = FolioCLIManager.splitPathAndLineColumnSuffix(cleaned)
        let candidatePaths = [pathPart, pathPart.replacingOccurrences(of: "\\ ", with: " ")]
        let cwdURL = URL(fileURLWithPath: FolioCLIManager.effectiveWorkingDirectoryPath())

        for candidatePath in candidatePaths {
            let expanded = (candidatePath as NSString).expandingTildeInPath
            guard !expanded.isEmpty else { continue }

            if expanded.hasPrefix("/") {
                let url = URL(fileURLWithPath: expanded).standardizedFileURL
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
                    return QuickOpenPathCandidate(
                        url: url,
                        isDirectory: isDir.boolValue,
                        exists: true,
                        lineNumber: parsedLine,
                        columnNumber: parsedCol
                    )
                }
            } else {
                let baseDirs: [URL] = preferWorkingDirectory
                    ? [cwdURL, workspaceFolderURL, currentFileURL?.deletingLastPathComponent()].compactMap { $0 }
                    : [workspaceFolderURL, currentFileURL?.deletingLastPathComponent(), cwdURL].compactMap { $0 }

                for base in baseDirs {
                    let url = base.appendingPathComponent(expanded).standardizedFileURL
                    var isDir: ObjCBool = false
                    if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
                        return QuickOpenPathCandidate(
                            url: url,
                            isDirectory: isDir.boolValue,
                            exists: true,
                            lineNumber: parsedLine,
                            columnNumber: parsedCol
                        )
                    }
                }
            }
        }

        if Self.looksLikeExplicitFilesystemPath(trimmed) {
            let unescaped = pathPart.replacingOccurrences(of: "\\ ", with: " ")
            let expanded = (unescaped as NSString).expandingTildeInPath
            let url: URL
            if expanded.hasPrefix("/") {
                url = URL(fileURLWithPath: expanded).standardizedFileURL
            } else {
                let base = preferWorkingDirectory
                    ? cwdURL
                    : (workspaceFolderURL ?? currentFileURL?.deletingLastPathComponent() ?? cwdURL)
                url = base.appendingPathComponent(expanded).standardizedFileURL
            }
            if url.path != "/" {
                return QuickOpenPathCandidate(
                    url: url,
                    isDirectory: false,
                    exists: false,
                    lineNumber: parsedLine,
                    columnNumber: parsedCol
                )
            }
        }

        return nil
    }

    @discardableResult
    public func submitQuickOpen() -> Bool {
        let q = quickOpenQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = quickOpenFilteredFiles
        let candidate = resolveQuickOpenPathCandidate(for: q)

        if quickOpenSelectedIndex > 0, quickOpenSelectedIndex < filtered.count {
            openFile(at: filtered[quickOpenSelectedIndex].url)
            closeQuickOpen()
            return true
        }

        if let candidate, candidate.exists {
            let isExplicitPath = Self.looksLikeExplicitFilesystemPath(q) || q.contains("/")
            let matchesFirst = filtered.first.map {
                $0.url.resolvingSymlinksInPath() == candidate.url.resolvingSymlinksInPath()
            } ?? false
            if isExplicitPath || filtered.isEmpty || matchesFirst {
                openQuickOpenCandidate(candidate)
                return true
            }
        }

        if let first = filtered.first {
            openFile(at: first.url)
            closeQuickOpen()
            return true
        }

        if let candidate {
            openQuickOpenCandidate(candidate)
            return true
        }

        return false
    }

    public func openQuickOpenCandidate(_ candidate: QuickOpenPathCandidate) {
        if candidate.exists && candidate.isDirectory {
            loadWorkspaceFolder(candidate.url)
            showSidebar = true
            activeSidebarTab = .files
            closeQuickOpen()
            return
        }

        let targetURL = candidate.url
        if !candidate.exists {
            let parentDir = targetURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
            try? "".write(to: targetURL, atomically: true, encoding: .utf8)
        }

        if workspaceFolderURL == nil {
            loadWorkspaceFolder(targetURL.deletingLastPathComponent().standardizedFileURL)
        } else if let currentFolder = workspaceFolderURL?.resolvingSymlinksInPath(),
                  targetURL.resolvingSymlinksInPath().path.hasPrefix(currentFolder.path + "/") {
            reloadWorkspaceTree()
        }

        openFile(at: targetURL)
        if let line = candidate.lineNumber, line >= 1 {
            navigateToLineNumber(line, columnNumber: candidate.columnNumber)
        }
        closeQuickOpen()
    }

    // MARK: - CLI Path Opening (`folio <path>`)

    public func openPathsFromCLI(_ paths: [String]) {
        for rawPath in FolioCLIManager.deduplicateCommandLinePaths(paths) {
            openPathFromCLI(rawPath)
        }
    }

    public func openPathFromCLI(_ rawPath: String) {
        guard let candidate = resolveQuickOpenPathCandidate(for: rawPath, preferWorkingDirectory: true) ?? {
            let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let unquoted = Self.stripSurroundingQuotes(from: trimmed)
            let (pathPart, parsedLine, parsedCol, _) = FolioCLIManager.splitPathAndLineColumnSuffix(unquoted)
            let expanded = (pathPart as NSString).expandingTildeInPath
            let cwd = FolioCLIManager.effectiveWorkingDirectoryPath()
            let url = expanded.hasPrefix("/")
                ? URL(fileURLWithPath: expanded).standardizedFileURL
                : URL(fileURLWithPath: cwd)
                    .appendingPathComponent(expanded).standardizedFileURL
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            return QuickOpenPathCandidate(
                url: url,
                isDirectory: isDir.boolValue,
                exists: exists,
                lineNumber: parsedLine,
                columnNumber: parsedCol
            )
        }() else {
            return
        }

        if candidate.exists && candidate.isDirectory {
            loadWorkspaceFolder(candidate.url)
            showSidebar = true
            activeSidebarTab = .files
            return
        }

        if !candidate.exists {
            let parentDir = candidate.url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
            try? "".write(to: candidate.url, atomically: true, encoding: .utf8)
        }

        let parentFolder = candidate.url.deletingLastPathComponent().standardizedFileURL
        if let currentFolder = workspaceFolderURL?.resolvingSymlinksInPath(),
           candidate.url.resolvingSymlinksInPath().path.hasPrefix(currentFolder.path + "/") {
            reloadWorkspaceTree()
        } else {
            loadWorkspaceFolder(parentFolder)
        }
        openFile(at: candidate.url)
        if let line = candidate.lineNumber, line >= 1 {
            navigateToLineNumber(line, columnNumber: candidate.columnNumber)
        }
    }

    // MARK: - Path Parsing Helpers

    private static func stripSurroundingQuotes(from text: String) -> String {
        guard text.count >= 2 else { return text }
        if (text.hasPrefix("\"") && text.hasSuffix("\"")) ||
           (text.hasPrefix("'") && text.hasSuffix("'")) {
            return String(text.dropFirst().dropLast())
        }
        return text
    }

    private static func looksLikeExplicitFilesystemPath(_ text: String) -> Bool {
        let unquoted = stripSurroundingQuotes(from: text)
        return unquoted.hasPrefix("/") ||
            unquoted.hasPrefix("~/") ||
            unquoted == "~" ||
            unquoted.hasPrefix("./") ||
            unquoted.hasPrefix("../") ||
            unquoted.hasPrefix("file://")
    }

    private func navigateToLineNumber(_ lineNumber: Int, columnNumber: Int? = nil) {
        let lines = markdownText.components(separatedBy: "\n")
        let targetIdx = max(0, min(lineNumber - 1, lines.count - 1))
        var charOffset = 0
        for idx in 0..<targetIdx {
            charOffset += (lines[idx] as NSString).length + 1
        }
        if let col = columnNumber, col > 1, targetIdx < lines.count {
            let lineLen = (lines[targetIdx] as NSString).length
            charOffset += min(col - 1, lineLen)
        }
        let clampedOffset = min(charOffset, (markdownText as NSString).length)
        let range = NSRange(location: clampedOffset, length: 0)
        currentSelectedRange = range
        pendingScrollToCharacterLocation = clampedOffset
        if let tv = activeTextView {
            tv.setSelectedRange(range)
            tv.scrollRangeToVisible(range)
        }
    }
}
