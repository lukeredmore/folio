import Foundation

extension LaTeXDocumentIndexer {
    private struct CacheKey: Equatable {
        let string: String
        let project: LaTeXProjectContext.Key
        let projectVersion: UInt64
        let sourceCodeMode: Bool
    }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var lastKey: CacheKey?
    nonisolated(unsafe) private static var lastIndex = LaTeXDocumentIndex()
    nonisolated(unsafe) private static var lastMacros: [String: LaTeXMacroDefinition] = [:]

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
        cacheLock.lock()
        if lastKey == key {
            let cached = (lastIndex, lastMacros)
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        var docIndex = buildIndex(string: string, nsString: nsString, project: project)
        if hasProject && (stored == nil || docIndex.projectSignature != project.signature) {
            if stored == nil {
                project = LaTeXProjectContext.refresh(projectKey, signature: docIndex.projectSignature)
                docIndex = buildIndex(string: string, nsString: nsString, project: project)
            } else {
                LaTeXProjectContext.scheduleRefresh(projectKey, signature: docIndex.projectSignature)
            }
        }

        var docMacros = (!sourceCodeMode && string.contains("\\")) ? LaTeXMacroExpander.extractDocumentMacros(from: string) : [:]
        docMacros.merge(docIndex.extraMacros) { current, _ in current }
        if !sourceCodeMode {
            docMacros.merge(project.inheritedMacros) { current, _ in current }
        }
        docIndex.documentMacros = docMacros

        cacheLock.lock()
        lastKey = CacheKey(string: string, project: projectKey, projectVersion: project.version, sourceCodeMode: sourceCodeMode)
        lastIndex = docIndex
        lastMacros = docMacros
        cacheLock.unlock()
        return (docIndex, docMacros)
    }
}
