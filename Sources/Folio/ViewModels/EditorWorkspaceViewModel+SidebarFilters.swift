import Foundation

extension EditorWorkspaceViewModel {

    // MARK: - Sidebar Root Filters

    /// The sidebar root folder that contains `url`, and the path of `url` relative to it.
    func sidebarRoot(containing url: URL) -> (rootURL: URL, relativePath: String, mountID: UUID?)? {
        if let resolved = remoteWorkspaceManager.resolveMount(for: url) {
            guard resolved.mount.targetKind == .folder else { return nil }
            return (remoteWorkspaceManager.localMirrorDirectory(for: resolved.mount), resolved.relativePath, resolved.mount.id)
        }
        let path = url.standardizedFileURL.path
        for root in sidebarLocalFolderURLs {
            let rootPath = root.standardizedFileURL.path
            if path == rootPath {
                return (root, "", nil)
            }
            if path.hasPrefix(rootPath + "/") {
                return (root, String(path.dropFirst(rootPath.count + 1)), nil)
            }
        }
        return nil
    }

    /// The filter of the sidebar root folder at `rootURL`.
    public func sidebarFilter(forRoot rootURL: URL) -> SidebarRootFilter {
        guard let root = sidebarRoot(containing: rootURL) else { return SidebarRootFilter() }
        if let mountID = root.mountID {
            return remoteWorkspaceManager.sidebarFilter(for: mountID)
        }
        return localSidebarFilters[root.rootURL.standardizedFileURL.path] ?? SidebarRootFilter()
    }

    /// Shows or hides one file type in the sidebar root folder at `rootURL`.
    public func setFileType(_ type: SidebarFileType, shown: Bool, forRoot rootURL: URL) {
        updateSidebarFilter(forRoot: rootURL) { filter in
            if shown {
                filter.hiddenFileTypes.remove(type)
            } else {
                filter.hiddenFileTypes.insert(type)
            }
        }
    }

    /// Hides the folder at `url`, and everything inside it, from its sidebar root.
    public func excludeFolderFromSidebar(_ url: URL) {
        guard let root = sidebarRoot(containing: url), !root.relativePath.isEmpty else { return }
        updateSidebarFilter(forRoot: root.rootURL) { $0.excludedPaths.insert(root.relativePath) }
    }

    /// Shows an excluded folder of the sidebar root folder at `rootURL` again.
    public func includeExcludedFolder(_ relativePath: String, forRoot rootURL: URL) {
        updateSidebarFilter(forRoot: rootURL) { $0.excludedPaths.remove(relativePath) }
    }

    func updateSidebarFilter(forRoot rootURL: URL, _ change: (inout SidebarRootFilter) -> Void) {
        guard let root = sidebarRoot(containing: rootURL) else { return }
        var filter = sidebarFilter(forRoot: root.rootURL)
        change(&filter)
        if let mountID = root.mountID {
            remoteWorkspaceManager.setSidebarFilter(filter, for: mountID)
        } else {
            localSidebarFilters[root.rootURL.standardizedFileURL.path] = filter
        }
        reloadWorkspaceTree()
    }
}
