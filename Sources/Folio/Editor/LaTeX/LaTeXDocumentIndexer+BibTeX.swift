import Foundation

extension LaTeXDocumentIndexer {

    static func sectionLevel(for cmd: String) -> Int {
        switch cmd {
        case "part", "chapter", "section": return 1
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
        s = s.replacingOccurrences(of: "~", with: " ")
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
        let candidates = trimmed.hasSuffix(".tex")
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
           let items = try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) {
            for item in items where item.pathExtension.lowercased() == "bib" {
                urls.append(item.standardizedFileURL)
            }
        }

        var map: [String: BibTeXEntry] = [:]
        for url in urls {
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for entry in parseBibTeXEntries(from: content, fileURL: url) {
                map[entry.key] = entry
            }
        }
        return map
    }

    static let bibEntryHeaderRegex = try! NSRegularExpression(
        pattern: #"@([A-Za-z]+)\s*\{\s*([^,\s]+)\s*,"#
    )
    static let bibFieldRegex = try! NSRegularExpression(
        pattern: #"(?m)^\s*([A-Za-z_]+)\s*=\s*(?:\{((?:[^{}]|\{[^{}]*\})*)\}|"([^"]*)"|(\d+))"#
    )

    public static func parseBibTeXEntries(from content: String, fileURL: URL? = nil) -> [BibTeXEntry] {
        let ns = content as NSString
        let matches = bibEntryHeaderRegex.matches(in: content, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return [] }

        var results: [BibTeXEntry] = []
        for (i, match) in matches.enumerated() {
            let entryType = ns.substring(with: match.range(at: 1)).lowercased()
            if entryType == "comment" || entryType == "preamble" || entryType == "string" {
                continue
            }
            let key = ns.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
            let startLoc = match.range.location
            let endLoc = (i + 1 < matches.count) ? matches[i + 1].range.location : ns.length
            let blockRange = NSRange(location: startLoc, length: max(0, endLoc - startLoc))
            let blockStr = ns.substring(with: blockRange)
            let blockNS = blockStr as NSString

            var author = ""
            var year = ""
            var title = ""

            bibFieldRegex.enumerateMatches(in: blockStr, range: NSRange(location: 0, length: blockNS.length)) { fm, _, _ in
                guard let fm = fm else { return }
                let fieldName = blockNS.substring(with: fm.range(at: 1)).lowercased()
                let valRange: NSRange
                if fm.range(at: 2).location != NSNotFound {
                    valRange = fm.range(at: 2)
                } else if fm.range(at: 3).location != NSNotFound {
                    valRange = fm.range(at: 3)
                } else if fm.range(at: 4).location != NSNotFound {
                    valRange = fm.range(at: 4)
                } else {
                    return
                }
                let val = cleanTeXInlineText(blockNS.substring(with: valRange))
                switch fieldName {
                case "author", "editor":
                    if author.isEmpty || fieldName == "author" { author = val }
                case "year", "date":
                    if year.isEmpty { year = String(val.prefix(4)) }
                case "title":
                    title = val
                default:
                    break
                }
            }

            results.append(BibTeXEntry(
                key: key,
                entryType: entryType,
                author: author,
                year: year,
                title: title,
                fileURL: fileURL,
                characterLocation: startLoc
            ))
        }
        return results
    }
}
