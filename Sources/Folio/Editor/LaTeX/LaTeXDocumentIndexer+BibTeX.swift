import FolioEngineFFI
import Foundation

extension LaTeXDocumentIndexer {
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

    /// The URL TeX would try first for `path`, without checking that it exists. For styling,
    /// which must not touch the file system.
    static func defaultTeXFileURL(path: String, baseDirectoryURL: URL?) -> URL? {
        guard let base = baseDirectoryURL else { return nil }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return base.appendingPathComponent(trimmed.hasSuffix(".tex") ? trimmed : trimmed + ".tex").standardizedFileURL
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
