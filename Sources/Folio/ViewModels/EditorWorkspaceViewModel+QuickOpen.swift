import AppKit
import Foundation
import SwiftUI

public struct QuickOpenPathCandidate: Equatable {
    public let url: URL
    public let isDirectory: Bool
    public let exists: Bool
    public let lineNumber: Int?

    public init(url: URL, isDirectory: Bool, exists: Bool, lineNumber: Int? = nil) {
        self.url = url
        self.isDirectory = isDirectory
        self.exists = exists
        self.lineNumber = lineNumber
    }
}

extension EditorWorkspaceViewModel {

    // MARK: - Quick Open (Shift-Shift) & Path Opening

    public func toggleQuickOpen() {
        quickOpenQuery = ""
        showQuickOpen.toggle()
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

    public func resolveQuickOpenPathCandidate(for rawQuery: String) -> QuickOpenPathCandidate? {
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

        let (pathPart, parsedLine) = Self.splitOptionalLineSuffix(from: cleaned)
        let candidatePaths = [pathPart, pathPart.replacingOccurrences(of: "\\ ", with: " ")]

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
                        lineNumber: parsedLine
                    )
                }
            } else {
                let baseDirs: [URL] = [
                    workspaceFolderURL,
                    currentFileURL?.deletingLastPathComponent(),
                    URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                ].compactMap { $0 }

                for base in baseDirs {
                    let url = base.appendingPathComponent(expanded).standardizedFileURL
                    var isDir: ObjCBool = false
                    if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
                        return QuickOpenPathCandidate(
                            url: url,
                            isDirectory: isDir.boolValue,
                            exists: true,
                            lineNumber: parsedLine
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
                let base = workspaceFolderURL
                    ?? currentFileURL?.deletingLastPathComponent()
                    ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                url = base.appendingPathComponent(expanded).standardizedFileURL
            }
            if url.path != "/" {
                return QuickOpenPathCandidate(
                    url: url,
                    isDirectory: false,
                    exists: false,
                    lineNumber: parsedLine
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
            showQuickOpen = false
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
            showQuickOpen = false
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
        if let line = candidate.lineNumber, line > 1 {
            navigateToLineNumber(line)
        }
        showQuickOpen = false
    }

    // MARK: - CLI Path Opening (`folio <path>`)

    public func openPathsFromCLI(_ paths: [String]) {
        for rawPath in paths {
            openPathFromCLI(rawPath)
        }
    }

    public func openPathFromCLI(_ rawPath: String) {
        guard let candidate = resolveQuickOpenPathCandidate(for: rawPath) ?? {
            let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let expanded = (trimmed as NSString).expandingTildeInPath
            let url = expanded.hasPrefix("/")
                ? URL(fileURLWithPath: expanded).standardizedFileURL
                : URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                    .appendingPathComponent(expanded).standardizedFileURL
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            return QuickOpenPathCandidate(url: url, isDirectory: isDir.boolValue, exists: exists)
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
        if let line = candidate.lineNumber, line > 1 {
            navigateToLineNumber(line)
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

    private static func splitOptionalLineSuffix(from path: String) -> (String, Int?) {
        let parts = path.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return (path, nil) }
        if let lastNum = Int(parts[parts.count - 1]) {
            if parts.count >= 3, let secondLastNum = Int(parts[parts.count - 2]) {
                let basePath = parts.dropLast(2).joined(separator: ":")
                if !basePath.isEmpty {
                    return (basePath, secondLastNum)
                }
            }
            let basePath = parts.dropLast(1).joined(separator: ":")
            if !basePath.isEmpty {
                return (basePath, lastNum)
            }
        }
        return (path, nil)
    }

    private func navigateToLineNumber(_ lineNumber: Int) {
        let lines = markdownText.components(separatedBy: "\n")
        let targetIdx = max(0, min(lineNumber - 1, lines.count - 1))
        var charOffset = 0
        for idx in 0..<targetIdx {
            charOffset += (lines[idx] as NSString).length + 1
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
