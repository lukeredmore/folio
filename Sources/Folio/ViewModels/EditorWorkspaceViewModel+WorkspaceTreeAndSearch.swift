import AppKit
import Combine
import Foundation
import SwiftUI

public enum SidebarTab: String, CaseIterable, Identifiable {
    case files = "Files"
    case outline = "Outline"
    case search = "Search"

    public var id: String { rawValue }

    public var systemImage: String {
        switch self {
        case .files: return "folder"
        case .outline: return "list.bullet.indent"
        case .search: return "magnifyingglass"
        }
    }
}

public enum FileDisplayStyle: String, CaseIterable {
    case tree = "Tree"
    case list = "List"
}

extension EditorWorkspaceViewModel {

    // MARK: - Workspace Folder Tree & Multi-file Search
    /// Adds `folderURL` to the sidebar and makes it the primary folder.
    public func loadWorkspaceFolder(_ folderURL: URL) {
        addLocalFolder(folderURL)
    }

    public func reloadWorkspaceTree() {
        var flatList: [WorkspaceFileNode] = []
        var combinedRoots: [WorkspaceFileNode] = []

        for folderURL in sidebarLocalFolderURLs {
            let rv = try? folderURL.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
            combinedRoots.append(
                WorkspaceFileNode(
                    url: folderURL,
                    name: folderURL.lastPathComponent,
                    isDirectory: true,
                    modificationDate: rv?.contentModificationDate ?? Date(),
                    creationDate: rv?.creationDate ?? Date(),
                    children: scanDirectory(at: folderURL, depth: 0, remoteMountID: nil, flatAccumulator: &flatList),
                    isLocalRoot: true
                ))
        }

        for mount in remoteWorkspaceManager.mounts {
            let mirrorDir = remoteWorkspaceManager.localMirrorDirectory(for: mount)
            switch mount.targetKind {
            case .folder:
                let remoteChildren = scanDirectory(at: mirrorDir, depth: 0, remoteMountID: mount.id, flatAccumulator: &flatList)
                let rootNode = WorkspaceFileNode(
                    url: mirrorDir,
                    name: mount.effectiveDisplayName,
                    isDirectory: true,
                    modificationDate: Date(),
                    creationDate: Date(),
                    children: remoteChildren,
                    remoteMountID: mount.id,
                    isRemoteRoot: true,
                    remoteConnectionString: mount.connectionSpecString,
                    syncStatus: nil
                )
                combinedRoots.append(rootNode)

            case .file:
                let filename = (mount.remotePath as NSString).lastPathComponent
                let fileURL = remoteWorkspaceManager.localFileURL(for: filename, in: mount)
                if !FileManager.default.fileExists(atPath: fileURL.path) {
                    try? FileManager.default.createDirectory(at: mirrorDir, withIntermediateDirectories: true)
                    try? "".write(to: fileURL, atomically: true, encoding: .utf8)
                }
                let rv = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
                let fileNode = WorkspaceFileNode(
                    url: fileURL,
                    name: mount.displayName ?? filename,
                    isDirectory: false,
                    modificationDate: rv?.contentModificationDate ?? Date(),
                    creationDate: rv?.creationDate ?? Date(),
                    children: nil,
                    remoteMountID: mount.id,
                    isRemoteRoot: true,
                    remoteConnectionString: mount.connectionSpecString,
                    syncStatus: remoteWorkspaceManager.fileSyncStatuses[fileURL.standardizedFileURL] ?? .synced
                )
                combinedRoots.append(fileNode)
                if fileNode.isSupportedDocumentFile {
                    flatList.append(fileNode)
                }
            }
        }

        rootFileNodes = combinedRoots
        sortFileNodes()
        flatMarkdownFiles = sortNodesArray(flatList, by: fileSortOrder)
    }

    func scanDirectory(
        at url: URL,
        depth: Int,
        remoteMountID: UUID?,
        flatAccumulator: inout [WorkspaceFileNode]
    ) -> [WorkspaceFileNode] {
        guard depth < 4 else { return [] }
        let fm = FileManager.default
        guard
            let contents = try? fm.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey, .creationDateKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return []
        }

        let ignoredDirs: Set<String> = [
            ".build", ".git", "node_modules", "DerivedData", ".swiftpm",
            "target", "bazel-bin", "bazel-out", "bazel-testlogs", "bazel-Folio",
            "Folio.app", "vendor", "dist", "build"
        ]
        var nodes: [WorkspaceFileNode] = []

        for itemURL in contents {
            let name = itemURL.lastPathComponent
            if ignoredDirs.contains(name) || name.hasPrefix("bazel-") || name.hasSuffix(".app") { continue }

            let resourceValues = try? itemURL.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey, .creationDateKey])
            let isDir = resourceValues?.isDirectory ?? false
            let modDate = resourceValues?.contentModificationDate ?? Date.distantPast
            let createDate = resourceValues?.creationDate ?? Date.distantPast

            if isDir {
                let children = scanDirectory(at: itemURL, depth: depth + 1, remoteMountID: remoteMountID, flatAccumulator: &flatAccumulator)
                if !children.isEmpty {
                    let node = WorkspaceFileNode(
                        url: itemURL,
                        name: name,
                        isDirectory: true,
                        modificationDate: modDate,
                        creationDate: createDate,
                        children: children,
                        remoteMountID: remoteMountID
                    )
                    nodes.append(node)
                }
            } else {
                let stdURL = itemURL.standardizedFileURL
                let syncStat = remoteMountID != nil ? (remoteWorkspaceManager.fileSyncStatuses[stdURL] ?? .synced) : nil
                let node = WorkspaceFileNode(
                    url: itemURL,
                    name: name,
                    isDirectory: false,
                    modificationDate: modDate,
                    creationDate: createDate,
                    children: nil,
                    remoteMountID: remoteMountID,
                    syncStatus: syncStat
                )
                if node.isSupportedDocumentFile {
                    nodes.append(node)
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

    func sortNodesArray(_ nodes: [WorkspaceFileNode], by order: FileSortOrder) -> [WorkspaceFileNode] {
        nodes.map { node in
            var copy = node
            if let children = copy.children {
                copy.children = sortNodesArray(children, by: order)
            }
            return copy
        }.sorted { a, b in
            // Local and remote roots share one level, sorted by name.
            if a.isSidebarRoot != b.isSidebarRoot {
                return a.isSidebarRoot
            }
            if a.isSidebarRoot {
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
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
        guard let regex = makeWorkspaceSearchRegex() else {
            workspaceSearchMatches = []
            return
        }

        var results: [WorkspaceSearchMatch] = []

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

        let currentStdURL = currentFileURL?.standardizedFileURL
        for fileNode in flatMarkdownFiles {
            let text: String
            if let currentStdURL, fileNode.url.standardizedFileURL == currentStdURL {
                text = markdownText
            } else if let diskText = try? String(contentsOf: fileNode.url, encoding: .utf8) {
                text = diskText
            } else {
                continue
            }
            searchInText(text, fileURL: fileNode.url, fileName: fileNode.name, regex: regex, results: &results)
            if results.count >= 200 { break }
        }

        workspaceSearchMatches = results
    }

    func searchInText(
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
                results.append(
                    WorkspaceSearchMatch(
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
}
