import Foundation

extension EditorWorkspaceViewModel {

    // MARK: - Local Sidebar Folders

    /// Local folders shown as sidebar roots: the added folders, then the primary folder if it is not already covered.
    public var sidebarLocalFolderURLs: [URL] {
        var urls = localFolderURLs
        if let primary = workspaceFolderURL { urls.append(primary) }
        return Self.collapsingNestedFolders(urls).filter { !Self.isSystemTemporaryRootDirectory($0) }
    }

    /// Adds `folderURL` as a sidebar root and makes it the primary folder.
    public func addLocalFolder(_ folderURL: URL) {
        localFolderURLs = Self.collapsingNestedFolders(localFolderURLs + [folderURL.standardizedFileURL])
        workspaceFolderURL = folderURL
        reloadWorkspaceTree()
    }

    /// Removes the sidebar root at `folderURL`. The files on disk do not change.
    public func removeLocalFolder(_ folderURL: URL) {
        let removedPath = folderURL.standardizedFileURL.path
        localFolderURLs.removeAll { $0.standardizedFileURL.path == removedPath }
        if workspaceFolderURL?.standardizedFileURL.path == removedPath {
            workspaceFolderURL = localFolderURLs.last
        }
        reloadWorkspaceTree()
    }

    /// True when `url` is a sidebar local folder or is inside one.
    public func isInsideSidebarLocalFolder(_ url: URL) -> Bool {
        let path = url.resolvingSymlinksInPath().path
        return sidebarLocalFolderURLs.contains { root in
            let rootPath = root.resolvingSymlinksInPath().path
            return path == rootPath || path.hasPrefix(rootPath + "/")
        }
    }

    /// Removes duplicates and folders inside another folder in the list, and keeps the first position of each.
    static func collapsingNestedFolders(_ urls: [URL]) -> [URL] {
        let standardized = urls.map(\.standardizedFileURL)
        var result: [URL] = []
        for url in standardized {
            let path = url.path
            let isCovered = standardized.contains { other in
                other.path != path && path.hasPrefix(other.path.hasSuffix("/") ? other.path : other.path + "/")
            }
            if !isCovered, !result.contains(where: { $0.path == path }) {
                result.append(url)
            }
        }
        return result
    }

    // MARK: - Persistence

    func persistLocalFolders() {
        guard !isRestoringState else { return }
        setSessionValue(localFolderURLs.map(\.path), forKey: Self.localFolderPathsDefaultsKey)
    }

    /// This window's saved folders, else the last active window's folders. Nil when no list was saved.
    func restoredLocalFolderURLs(from defaults: UserDefaults, source: DocumentSessionSource) -> [URL]? {
        let ownKey = windowSessionKey(Self.localFolderPathsDefaultsKey)
        let paths: [String]?
        if source == .window, documentWindow != nil, let own = defaults.stringArray(forKey: ownKey) {
            paths = own
        } else {
            paths = defaults.stringArray(forKey: Self.localFolderPathsDefaultsKey)
        }
        guard let paths else { return nil }
        return paths.compactMap { path in
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return nil }
            return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        }
    }
}
