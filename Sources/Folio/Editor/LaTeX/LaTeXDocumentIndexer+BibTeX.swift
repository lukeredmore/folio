import FolioEngineFFI
import Foundation

extension LaTeXDocumentIndexer {
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var lastIndexedString: String?
    nonisolated(unsafe) private static var lastIndexedBaseDir: URL?
    nonisolated(unsafe) private static var lastIndexedSourceMode: Bool?
    nonisolated(unsafe) private static var lastCachedIndex = LaTeXDocumentIndex()
    nonisolated(unsafe) private static var lastCachedMacros: [String: LaTeXMacroDefinition] = [:]
    nonisolated(unsafe) private static var bibFileCache: [URL: (modDate: Date?, entries: [BibTeXEntry])] = [:]
    nonisolated(unsafe) private static var inputMacrosCache: [URL: (modDate: Date?, macros: [String: LaTeXMacroDefinition])] = [:]

    static func cachedIndexAndMacros(
        string: String,
        nsString: NSString,
        baseDirectoryURL: URL?,
        sourceCodeMode: Bool
    ) -> (index: LaTeXDocumentIndex, macros: [String: LaTeXMacroDefinition]) {
        cacheLock.lock()
        if lastIndexedString == string,
            lastIndexedBaseDir == baseDirectoryURL,
            lastIndexedSourceMode == sourceCodeMode
        {
            let idx = lastCachedIndex
            let mac = lastCachedMacros
            cacheLock.unlock()
            return (idx, mac)
        }
        cacheLock.unlock()

        var docMacros =
            (!sourceCodeMode && string.contains("\\"))
            ? LaTeXMacroExpander.extractDocumentMacros(from: string)
            : [:]
        let docIndex = buildIndex(
            string: string,
            nsString: nsString,
            baseDirectoryURL: baseDirectoryURL
        )
        if !docIndex.extraMacros.isEmpty {
            docMacros.merge(docIndex.extraMacros) { current, _ in current }
        }

        cacheLock.lock()
        lastIndexedString = string
        lastIndexedBaseDir = baseDirectoryURL
        lastIndexedSourceMode = sourceCodeMode
        lastCachedIndex = docIndex
        lastCachedMacros = docMacros
        cacheLock.unlock()
        return (docIndex, docMacros)
    }

    static func loadInputMacros(from inputURL: URL) -> [String: LaTeXMacroDefinition] {
        let modDate = (try? FileManager.default.attributesOfItem(atPath: inputURL.path))?[.modificationDate] as? Date
        cacheLock.lock()
        if let cached = inputMacrosCache[inputURL], cached.modDate == modDate {
            cacheLock.unlock()
            return cached.macros
        }
        cacheLock.unlock()
        guard let inputText = try? String(contentsOf: inputURL, encoding: .utf8) else { return [:] }
        let imported = LaTeXMacroExpander.extractDocumentMacros(from: inputText)
        cacheLock.lock()
        inputMacrosCache[inputURL] = (modDate, imported)
        cacheLock.unlock()
        return imported
    }

    static func sectionLevel(for cmd: String) -> Int {
        switch cmd {
        case "part", "chapter", "section", "sectiontitle": return 1
        case "subsection": return 2
        case "subsubsection": return 3
        case "paragraph": return 4
        default: return 5
        }
    }

    static func parseBeginEnvironment(_ trimmedLine: String) -> String? {
        guard trimmedLine.hasPrefix("\\begin{") else { return nil }
        let after = trimmedLine.dropFirst(7)
        guard let closeBrace = after.firstIndex(of: "}") else { return nil }
        return String(after[..<closeBrace]).trimmingCharacters(in: .whitespaces)
    }

    static func parseEndEnvironment(_ trimmedLine: String) -> String? {
        guard trimmedLine.hasPrefix("\\end{") else { return nil }
        let after = trimmedLine.dropFirst(5)
        guard let closeBrace = after.firstIndex(of: "}") else { return nil }
        return String(after[..<closeBrace]).trimmingCharacters(in: .whitespaces)
    }

    static func parseOptionalBracketArg(afterBeginEnv trimmedLine: String) -> String? {
        guard let closeBrace = trimmedLine.firstIndex(of: "}") else { return nil }
        let rest = trimmedLine[trimmedLine.index(after: closeBrace)...].trimmingCharacters(in: .whitespaces)
        guard rest.hasPrefix("["), let closeBracket = rest.firstIndex(of: "]") else { return nil }
        let inner = String(rest[rest.index(after: rest.startIndex)..<closeBracket])
        return cleanTeXInlineText(inner)
    }

    static func cleanTeXInlineText(_ raw: String) -> String {
        var s = raw
        let wrappers = ["\\textbf{", "\\textit{", "\\emph{", "\\texttt{", "\\textsc{", "\\underline{"]
        for w in wrappers {
            while let r = s.range(of: w) {
                s.removeSubrange(r)
                if let lastBrace = s.lastIndex(of: "}") {
                    s.remove(at: lastBrace)
                }
            }
        }
        s = s.replacingOccurrences(of: "\\LaTeX{}", with: "LaTeX")
            .replacingOccurrences(of: "\\LaTeX", with: "LaTeX")
            .replacingOccurrences(of: "\\TeX{}", with: "TeX")
            .replacingOccurrences(of: "\\TeX", with: "TeX")
            .replacingOccurrences(of: "\\&", with: "&")
            .replacingOccurrences(of: "\\%", with: "%")
            .replacingOccurrences(of: "\\_", with: "_")
            .replacingOccurrences(of: "\\#", with: "#")
            .replacingOccurrences(of: "\\$", with: "$")
            .replacingOccurrences(of: "~", with: " ")
            .replacingOccurrences(of: "---", with: "—")
            .replacingOccurrences(of: "--", with: "–")
            .replacingOccurrences(of: "``", with: "“")
            .replacingOccurrences(of: "''", with: "”")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func formattedToday() -> String {
        let df = DateFormatter()
        df.dateStyle = .long
        df.timeStyle = .none
        return df.string(from: Date())
    }

    static func resolveTeXFileURL(path: String, baseDirectoryURL: URL?) -> URL? {
        guard let base = baseDirectoryURL else { return nil }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidates =
            trimmed.hasSuffix(".tex")
            ? [trimmed]
            : [trimmed + ".tex", trimmed]
        for c in candidates {
            let url = base.appendingPathComponent(c).standardizedFileURL
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return base.appendingPathComponent(candidates[0]).standardizedFileURL
    }

    static func loadBibEntries(
        referencedFiles: [String],
        baseDirectoryURL: URL?
    ) -> [String: BibTeXEntry] {
        guard let base = baseDirectoryURL else { return [:] }
        var urls: [URL] = []
        for ref in referencedFiles {
            let name = ref.hasSuffix(".bib") ? ref : (ref + ".bib")
            let candidate = base.appendingPathComponent(name).standardizedFileURL
            if FileManager.default.fileExists(atPath: candidate.path), !urls.contains(candidate) {
                urls.append(candidate)
            }
        }
        if urls.isEmpty,
            let items = try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)
        {
            for item in items where item.pathExtension.lowercased() == "bib" {
                urls.append(item.standardizedFileURL)
            }
        }

        var map: [String: BibTeXEntry] = [:]
        for url in urls {
            let modDate = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            cacheLock.lock()
            let cached = bibFileCache[url]
            cacheLock.unlock()
            let entries: [BibTeXEntry]
            if let cached, cached.modDate == modDate {
                entries = cached.entries
            } else if let content = try? String(contentsOf: url, encoding: .utf8) {
                entries = parseBibTeXEntries(from: content, fileURL: url)
                cacheLock.lock()
                bibFileCache[url] = (modDate, entries)
                cacheLock.unlock()
            } else {
                continue
            }
            for entry in entries {
                map[entry.key] = entry
            }
        }
        return map
    }

    public static func parseBibTeXEntries(from content: String, fileURL: URL? = nil) -> [BibTeXEntry] {
        content.withCString { cStr in
            guard let resPtr = ot_engine_parse_bibtex(cStr) else { return [] }
            defer { ot_engine_free_bibtex(resPtr) }
            let count = Int(resPtr.pointee.count)
            guard count > 0, let entries = resPtr.pointee.entries else { return [] }
            var results: [BibTeXEntry] = []
            results.reserveCapacity(count)
            for i in 0..<count {
                let e = entries[i]
                results.append(
                    BibTeXEntry(
                        key: e.key.map { String(cString: $0) } ?? "",
                        entryType: e.entry_type.map { String(cString: $0) } ?? "",
                        author: e.author.map { String(cString: $0) } ?? "",
                        year: e.year.map { String(cString: $0) } ?? "",
                        title: e.title.map { String(cString: $0) } ?? "",
                        fileURL: fileURL,
                        characterLocation: Int(e.utf16_loc)
                    ))
            }
            return results
        }
    }
}
