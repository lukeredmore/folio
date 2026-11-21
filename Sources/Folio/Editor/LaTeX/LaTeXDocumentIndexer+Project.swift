import Foundation

extension LaTeXDocumentIndexer {
    private struct CacheKey: Equatable {
        let string: String
        let project: LaTeXProjectContext.Key
        let projectVersion: UInt64
        let sourceCodeMode: Bool
    }

    private struct PreambleCacheKey: Hashable {
        let project: LaTeXProjectContext.Key
        let projectVersion: UInt64
        let sourceCodeMode: Bool
    }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var lastKey: CacheKey?
    nonisolated(unsafe) private static var lastIndex = LaTeXDocumentIndex()
    nonisolated(unsafe) private static var lastMacros: [String: LaTeXMacroDefinition] = [:]
    nonisolated(unsafe) private static var preambleCheckpoints: [PreambleCacheKey: PreambleScanCheckpoint] = [:]

    static func invalidateCache() {
        cacheLock.lock()
        lastKey = nil
        preambleCheckpoints.removeAll()
        cacheLock.unlock()
    }

    /// The document index and every macro the document can use. Macros come, in falling
    /// priority, from the document, from its preamble inputs, and from its master file.
    ///
    /// Project files come from `LaTeXProjectContext`. Only the first styling of a document
    /// resolves them on this thread; after that this reads the stored snapshot, and when the
    /// document's inputs, bibliography, or master comment change it queues a background refresh,
    /// which posts `LaTeXProjectContext.didUpdateNotification` so the editor restyles.
    static func cachedIndexAndMacros(
        string: String,
        nsString: NSString,
        baseDirectoryURL: URL?,
        fileURL: URL?,
        sourceCodeMode: Bool
    ) -> (index: LaTeXDocumentIndex, macros: [String: LaTeXMacroDefinition]) {
        let projectKey = LaTeXProjectContext.Key(fileURL: fileURL, baseDirectoryURL: baseDirectoryURL)
        let hasProject = fileURL != nil || baseDirectoryURL != nil
        let stored = hasProject ? LaTeXProjectContext.snapshot(for: projectKey) : nil
        var project = stored ?? .empty
        let key = CacheKey(string: string, project: projectKey, projectVersion: project.version, sourceCodeMode: sourceCodeMode)
        var preambleKey = PreambleCacheKey(project: projectKey, projectVersion: project.version, sourceCodeMode: sourceCodeMode)
        cacheLock.lock()
        if lastKey == key {
            let cached = (lastIndex, lastMacros)
            cacheLock.unlock()
            return cached
        }
        let existingCheckpoint = preambleCheckpoints[preambleKey]
        cacheLock.unlock()

        var built = buildIndexWithCheckpoint(
            string: string,
            nsString: nsString,
            project: project,
            sourceCodeMode: sourceCodeMode,
            reusableCheckpoint: existingCheckpoint
        )
        var docIndex = built.index
        if hasProject && (stored == nil || docIndex.projectSignature != project.signature) {
            if stored == nil {
                project = LaTeXProjectContext.refresh(projectKey, signature: docIndex.projectSignature)
                preambleKey = PreambleCacheKey(project: projectKey, projectVersion: project.version, sourceCodeMode: sourceCodeMode)
                built = buildIndexWithCheckpoint(
                    string: string,
                    nsString: nsString,
                    project: project,
                    sourceCodeMode: sourceCodeMode,
                    reusableCheckpoint: nil
                )
                docIndex = built.index
            } else {
                LaTeXProjectContext.scheduleRefresh(projectKey, signature: docIndex.projectSignature)
            }
        }

        var docMacros: [String: LaTeXMacroDefinition]
        if sourceCodeMode {
            docMacros = [:]
        } else if let cp = built.checkpoint {
            docMacros = cp.preambleMacros
            if nsString.length > cp.prefixUTF16Length {
                let bodyText = nsString.substring(from: cp.prefixUTF16Length)
                if bodyText.contains("\\") {
                    for (name, def) in LaTeXMacroExpander.extractDocumentMacros(from: bodyText) {
                        docMacros[name] = def
                    }
                }
            }
        } else {
            docMacros = string.contains("\\") ? LaTeXMacroExpander.extractDocumentMacros(from: string) : [:]
        }
        docMacros.merge(docIndex.extraMacros) { current, _ in current }
        if !sourceCodeMode {
            docMacros.merge(project.inheritedMacros) { current, _ in current }
            docMacros.merge(project.classAndPackageMacros) { current, _ in current }
        }
        docIndex.documentMacros = docMacros

        cacheLock.lock()
        lastKey = CacheKey(string: string, project: projectKey, projectVersion: project.version, sourceCodeMode: sourceCodeMode)
        lastIndex = docIndex
        lastMacros = docMacros
        if let cp = built.checkpoint {
            if preambleCheckpoints.count >= 8 && preambleCheckpoints[preambleKey] == nil {
                preambleCheckpoints.removeAll(keepingCapacity: true)
            }
            preambleCheckpoints[preambleKey] = cp
        }
        cacheLock.unlock()
        return (docIndex, docMacros)
    }
}
