import Foundation

/// Bounds on the file work that one project resolution may do.
struct LaTeXProjectLimits: Sendable {
    /// Larger `.tex` files are skipped.
    var maxTeXFileBytes = 1_048_576
    /// Larger `.bib` files are skipped.
    var maxBibFileBytes = 8_388_608
    /// File reads per resolution. Files whose cached facts are current do not count.
    var maxFilesRead = 64
    /// `.tex` files examined per directory when searching for a master.
    var maxDirectoryEntries = 256
    /// Nesting depth of `\input` files followed for macros.
    var maxIncludeDepth = 6
    /// Master-of-master links followed.
    var maxMasterHops = 4
}

/// How a master file was found.
enum LaTeXMasterRule: String, Sendable {
    case texRoot
    case texMaster
    case siblingDocument
    case parentDocument
}

struct LaTeXMasterResolution: Hashable, Sendable {
    let url: URL
    /// The rule that found the first link of the chain.
    let rule: LaTeXMasterRule
}

/// Parsed facts and BibTeX entries of project files, reused while a file's stamp is unchanged.
final class LaTeXFileFactsCache: @unchecked Sendable {
    private let lock = NSLock()
    private var facts: [String: (stamp: LaTeXFileStamp, facts: LaTeXFileFacts)] = [:]
    private var bibs: [String: (stamp: LaTeXFileStamp, entries: [BibTeXEntry])] = [:]

    func facts(for url: URL, stamp: LaTeXFileStamp) -> LaTeXFileFacts? {
        lock.lock()
        defer { lock.unlock() }
        guard let cached = facts[url.path], cached.stamp == stamp else { return nil }
        return cached.facts
    }

    func store(_ value: LaTeXFileFacts, for url: URL, stamp: LaTeXFileStamp) {
        lock.lock()
        facts[url.path] = (stamp, value)
        lock.unlock()
    }

    func bibEntries(for url: URL, stamp: LaTeXFileStamp) -> [BibTeXEntry]? {
        lock.lock()
        defer { lock.unlock() }
        guard let cached = bibs[url.path], cached.stamp == stamp else { return nil }
        return cached.entries
    }

    func store(_ entries: [BibTeXEntry], for url: URL, stamp: LaTeXFileStamp) {
        lock.lock()
        bibs[url.path] = (stamp, entries)
        lock.unlock()
    }

    func removeAll() {
        lock.lock()
        facts.removeAll()
        bibs.removeAll()
        lock.unlock()
    }
}

/// Finds a document's master file and the macros, inputs, and bibliography it uses. Every call
/// does file-system work, so callers run it on open, on file changes, and off the restyle path.
struct LaTeXProjectResolver {
    let fileSystem: LaTeXProjectFileSystem
    let limits: LaTeXProjectLimits
    let cache: LaTeXFileFactsCache
    private(set) var filesRead = 0

    init(fileSystem: LaTeXProjectFileSystem, limits: LaTeXProjectLimits, cache: LaTeXFileFactsCache) {
        self.fileSystem = fileSystem
        self.limits = limits
        self.cache = cache
    }

    mutating func facts(for url: URL) -> LaTeXFileFacts? {
        guard let stamp = fileSystem.stamp(url), stamp.size <= limits.maxTeXFileBytes else { return nil }
        if let cached = cache.facts(for: url, stamp: stamp) { return cached }
        guard filesRead < limits.maxFilesRead else { return nil }
        filesRead += 1
        guard let text = fileSystem.readText(url) else { return nil }
        let parsed = LaTeXFileFacts.parse(text)
        cache.store(parsed, for: url, stamp: stamp)
        return parsed
    }

    /// Resolves `path` in `directory` as TeX does: `path.tex` first, unless `path` ends in `.tex`.
    func resolveTeXPath(_ path: String, in directory: URL) -> URL? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidates = trimmed.lowercased().hasSuffix(".tex") ? [trimmed] : [trimmed + ".tex", trimmed]
        for candidate in candidates {
            let url = directory.appendingPathComponent(candidate).standardizedFileURL
            if fileSystem.stamp(url) != nil { return url }
        }
        return nil
    }

    /// The master of `fileURL`. Rules, in order: a `% !TEX root` comment, an Emacs `TeX-master`
    /// variable (`t` means the file is its own master), then a `.tex` file with `\documentclass`
    /// in the same directory, then the parent directory, that inputs or includes the file. A
    /// master's own directive is followed up to `maxMasterHops`; a link back to a visited file
    /// ends the chain at the last new file.
    mutating func resolveMaster(for fileURL: URL, signature: LaTeXProjectSignature) -> LaTeXMasterResolution? {
        let child = fileURL.standardizedFileURL
        var visited: Set<String> = [child.path]
        var resolution: LaTeXMasterResolution?
        var current = child
        var directive = signature.masterDirective
        for hop in 0..<limits.maxMasterHops {
            let next: (url: URL, rule: LaTeXMasterRule)?
            switch directive {
            case .isMaster?:
                return resolution
            case .texRoot(let path)?:
                next = resolveTeXPath(path, in: current.deletingLastPathComponent()).map { ($0, .texRoot) }
            case .texMaster(let name)?:
                next = resolveTeXPath(name, in: current.deletingLastPathComponent()).map { ($0, .texMaster) }
            case nil:
                guard hop == 0, !signature.declaresDocumentClass else { return resolution }
                next = findIncludingDocument(for: child)
            }
            guard let next, visited.insert(next.url.path).inserted else { return resolution }
            resolution = LaTeXMasterResolution(url: next.url, rule: resolution?.rule ?? next.rule)
            current = next.url
            directive = facts(for: next.url)?.masterDirective
        }
        return resolution
    }

    private mutating func findIncludingDocument(for child: URL) -> (url: URL, rule: LaTeXMasterRule)? {
        let directory = child.deletingLastPathComponent()
        let searches: [(URL, LaTeXMasterRule)] = [(directory, .siblingDocument), (directory.deletingLastPathComponent(), .parentDocument)]
        for (searchDirectory, rule) in searches {
            let candidates = fileSystem.listDirectory(searchDirectory)
                .filter { $0.pathExtension.lowercased() == "tex" && $0.path != child.path }
                .prefix(limits.maxDirectoryEntries)
            for candidate in candidates {
                guard let facts = facts(for: candidate), facts.declaresDocumentClass else { continue }
                let candidateDirectory = candidate.deletingLastPathComponent()
                if facts.includeTargets.contains(where: { Self.target($0, in: candidateDirectory, names: child) }) {
                    return (candidate, rule)
                }
            }
        }
        return nil
    }

    /// True when `\input{target}` in `directory` names `file`, with or without `.tex`.
    static func target(_ target: String, in directory: URL, names file: URL) -> Bool {
        let base = directory.appendingPathComponent(target).standardizedFileURL
        if base.path == file.path { return true }
        return !target.lowercased().hasSuffix(".tex") && base.appendingPathExtension("tex").path == file.path
    }

    /// Macros from the master's preamble and, recursively, from the files its preamble inputs.
    /// Later definitions win. `\input` paths resolve against the master's directory, as in TeX.
    mutating func inheritedMacros(from master: URL, excluding child: URL) -> [String: LaTeXMacroDefinition] {
        guard let masterFacts = facts(for: master) else { return [:] }
        var macros = masterFacts.preambleMacros
        var visited: Set<String> = [master.path, child.standardizedFileURL.path]
        collectMacros(
            includes: masterFacts.preambleIncludeTargets, root: master.deletingLastPathComponent(), depth: 1,
            visited: &visited, into: &macros
        )
        return macros
    }

    /// Macros of one input file and of the files it inputs.
    mutating func macros(ofInput url: URL, root: URL) -> [String: LaTeXMacroDefinition] {
        guard let inputFacts = facts(for: url) else { return [:] }
        var macros = inputFacts.allMacros
        var visited: Set<String> = [url.path]
        collectMacros(includes: inputFacts.includeTargets, root: root, depth: 2, visited: &visited, into: &macros)
        return macros
    }

    private mutating func collectMacros(
        includes: [String],
        root: URL,
        depth: Int,
        visited: inout Set<String>,
        into macros: inout [String: LaTeXMacroDefinition]
    ) {
        guard depth <= limits.maxIncludeDepth else { return }
        for include in includes {
            guard let url = resolveTeXPath(include, in: root), visited.insert(url.path).inserted, let includeFacts = facts(for: url) else {
                continue
            }
            macros.merge(includeFacts.allMacros) { _, new in new }
            collectMacros(includes: includeFacts.includeTargets, root: root, depth: depth + 1, visited: &visited, into: &macros)
        }
    }

    /// Entries of the named `.bib` files in `directory`, or of every `.bib` file there when none
    /// of the names exists.
    mutating func bibEntries(files: [String], in directory: URL) -> [String: BibTeXEntry] {
        var urls: [URL] = []
        for file in files {
            let name = file.hasSuffix(".bib") ? file : file + ".bib"
            let url = directory.appendingPathComponent(name).standardizedFileURL
            if !urls.contains(url), fileSystem.stamp(url) != nil { urls.append(url) }
        }
        if urls.isEmpty {
            urls = fileSystem.listDirectory(directory).filter { $0.pathExtension.lowercased() == "bib" }
        }
        var map: [String: BibTeXEntry] = [:]
        for url in urls {
            guard let stamp = fileSystem.stamp(url), stamp.size <= limits.maxBibFileBytes else { continue }
            var entries = cache.bibEntries(for: url, stamp: stamp)
            if entries == nil, filesRead < limits.maxFilesRead, let text = fileSystem.readText(url) {
                filesRead += 1
                let parsed = LaTeXDocumentIndexer.parseBibTeXEntries(from: text, fileURL: url)
                cache.store(parsed, for: url, stamp: stamp)
                entries = parsed
            }
            for entry in entries ?? [] { map[entry.key] = entry }
        }
        return map
    }
}
