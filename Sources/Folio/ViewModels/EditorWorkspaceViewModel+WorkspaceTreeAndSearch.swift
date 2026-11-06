import AppKit
import Combine
import Foundation
import SwiftUI

public enum SidebarTab: String, CaseIterable, Identifiable {
    case files = "Files"
    case outline = "Outline"

    public var id: String { rawValue }

    public var systemImage: String {
        switch self {
        case .files: return "folder"
        case .outline: return "list.bullet.indent"
        }
    }
}

public enum FileDisplayStyle: String, CaseIterable {
    case tree = "Tree"
    case list = "List"
}

/// The sidebar root that a tree scan is inside.
struct SidebarScanScope {
    /// The mount of a remote root. Nil for a local folder.
    let remoteMountID: UUID?
    let filter: SidebarRootFilter
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
        var activeWatchedDirectoryKeys: Set<String> = []

        for folderURL in sidebarLocalFolderURLs {
            let children = scanDirectory(
                at: folderURL,
                relativePath: "",
                scope: SidebarScanScope(
                    remoteMountID: nil,
                    filter: localSidebarFilters[folderURL.standardizedFileURL.path] ?? SidebarRootFilter()
                ),
                flatAccumulator: &flatList,
                watchedDirectoryKeys: &activeWatchedDirectoryKeys
            )
            combinedRoots.append(
                WorkspaceFileNode(
                    url: folderURL,
                    name: folderURL.lastPathComponent,
                    isDirectory: true,
                    modificationDate: children.map(\.modificationDate).max() ?? Date.distantPast,
                    creationDate: children.map(\.creationDate).max() ?? Date.distantPast,
                    children: children,
                    isLocalRoot: true
                ))
        }

        for mount in remoteWorkspaceManager.mounts {
            let mirrorDir = remoteWorkspaceManager.localMirrorDirectory(for: mount)
            switch mount.targetKind {
            case .folder:
                let remoteChildren =
                    remoteDirectoryChildren(
                        at: mirrorDir,
                        relativePath: "",
                        scope: SidebarScanScope(remoteMountID: mount.id, filter: remoteWorkspaceManager.sidebarFilter(for: mount.id)),
                        flatAccumulator: &flatList,
                        watchedDirectoryKeys: &activeWatchedDirectoryKeys
                    ) ?? []
                let rootNode = WorkspaceFileNode(
                    url: mirrorDir,
                    name: mount.effectiveDisplayName,
                    isDirectory: true,
                    modificationDate: remoteChildren.map(\.modificationDate).max() ?? Date.distantPast,
                    creationDate: remoteChildren.map(\.creationDate).max() ?? Date.distantPast,
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
                    modificationDate: rv?.contentModificationDate ?? Date.distantPast,
                    creationDate: rv?.creationDate ?? Date.distantPast,
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

        pruneWatchedWorkspaceDirectories(keeping: activeWatchedDirectoryKeys)

        let sortedRoots = sortNodesArray(combinedRoots, by: fileSortOrder)
        let sortedFlat = sortNodesArray(flatList, by: fileSortOrder)
        if rootFileNodes != sortedRoots {
            rootFileNodes = sortedRoots
        }
        if flatMarkdownFiles != sortedFlat {
            flatMarkdownFiles = sortedFlat
        }
    }

    /// Lists the documents and folders at `url`, which is `relativePath` inside a sidebar root.
    func scanDirectory(
        at url: URL,
        relativePath: String,
        scope: SidebarScanScope,
        flatAccumulator: inout [WorkspaceFileNode],
        watchedDirectoryKeys: inout Set<String>
    ) -> [WorkspaceFileNode] {
        let remoteMountID = scope.remoteMountID
        if remoteMountID == nil {
            let depth = relativePath.isEmpty ? 0 : relativePath.split(separator: "/").count
            guard depth < 4 else { return [] }
            recordWatchedWorkspaceDirectory(url, activeKeys: &watchedDirectoryKeys)
        }
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

        var nodes: [WorkspaceFileNode] = []

        for itemURL in contents {
            let name = itemURL.lastPathComponent
            if WorkspaceFileNode.isIgnoredDirectoryName(name) { continue }
            let itemRelativePath = relativePath.isEmpty ? name : relativePath + "/" + name

            let resourceValues = try? itemURL.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey, .creationDateKey])
            let isDir = resourceValues?.isDirectory ?? false
            let modDate = resourceValues?.contentModificationDate ?? Date.distantPast
            let createDate = resourceValues?.creationDate ?? Date.distantPast

            if isDir {
                if scope.filter.excludedPaths.contains(itemRelativePath) { continue }
                let children: [WorkspaceFileNode]?
                if remoteMountID != nil {
                    children = remoteDirectoryChildren(
                        at: itemURL,
                        relativePath: itemRelativePath,
                        scope: scope,
                        flatAccumulator: &flatAccumulator,
                        watchedDirectoryKeys: &watchedDirectoryKeys
                    )
                } else {
                    children = scanDirectory(
                        at: itemURL,
                        relativePath: itemRelativePath,
                        scope: scope,
                        flatAccumulator: &flatAccumulator,
                        watchedDirectoryKeys: &watchedDirectoryKeys
                    )
                }
                if let children, !children.isEmpty {
                    let node = WorkspaceFileNode(
                        url: itemURL,
                        name: name,
                        isDirectory: true,
                        modificationDate: children.map(\.modificationDate).max() ?? Date.distantPast,
                        creationDate: children.map(\.creationDate).max() ?? Date.distantPast,
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
                if node.isSupportedDocumentFile, scope.filter.showsFile(named: name) {
                    nodes.append(node)
                    flatAccumulator.append(node)
                }
            }
        }

        return sortNodesArray(nodes, by: fileSortOrder)
    }

    /// Children of a remote mirror directory. A directory that is not listed yet gets one loading row.
    /// Returns nil for a directory with no shown documents, so the tree hides it.
    func remoteDirectoryChildren(
        at url: URL,
        relativePath: String,
        scope: SidebarScanScope,
        flatAccumulator: inout [WorkspaceFileNode],
        watchedDirectoryKeys: inout Set<String>
    ) -> [WorkspaceFileNode]? {
        let placeholder = [
            WorkspaceFileNode(
                url: url.appendingPathComponent(".folio-loading", isDirectory: false),
                name: "Loading…",
                isDirectory: false,
                modificationDate: Date.distantPast,
                creationDate: Date.distantPast,
                children: nil,
                remoteMountID: scope.remoteMountID,
                isLoadingPlaceholder: true
            )
        ]
        guard remoteWorkspaceManager.isRemoteDirectoryLoaded(at: url) else {
            return remoteWorkspaceManager.remoteDirectoryHasDocuments(at: url) == false ? nil : placeholder
        }
        let children = scanDirectory(
            at: url,
            relativePath: relativePath,
            scope: scope,
            flatAccumulator: &flatAccumulator,
            watchedDirectoryKeys: &watchedDirectoryKeys
        )
        if !children.isEmpty { return children }
        return remoteWorkspaceManager.hasListedRemoteDirectory(at: url) ? nil : placeholder
    }

    /// Lists a remote folder after the sidebar shows its loading row.
    public func loadRemoteDirectory(at url: URL) {
        Task { @MainActor in
            await remoteWorkspaceManager.loadRemoteDirectory(at: url)
        }
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
