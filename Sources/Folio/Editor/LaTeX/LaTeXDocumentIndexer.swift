import AppKit
import Foundation

public struct BibTeXEntry: Equatable {
    public let key: String
    public let entryType: String
    public let author: String
    public let year: String
    public let title: String
    public let fileURL: URL?
    public let characterLocation: Int

    public var shortCitation: String {
        let lastAuthor = Self.extractPrimarySurname(from: author)
        if !lastAuthor.isEmpty && !year.isEmpty {
            return "\(lastAuthor), \(year)"
        } else if !lastAuthor.isEmpty {
            return lastAuthor
        } else if !title.isEmpty {
            return String(title.prefix(20))
        }
        return key
    }

    public var tooltipSummary: String {
        var parts: [String] = []
        if !title.isEmpty { parts.append("“\(title)”") }
        if !author.isEmpty { parts.append(author) }
        if !year.isEmpty { parts.append("(\(year))") }
        return parts.isEmpty ? key : parts.joined(separator: " — ")
    }

    private static func extractPrimarySurname(from rawAuthor: String) -> String {
        let cleaned = rawAuthor
            .replacingOccurrences(of: "{", with: "")
            .replacingOccurrences(of: "}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return "" }
        let authors = cleaned.components(separatedBy: " and ")
        let first = authors[0].trimmingCharacters(in: .whitespaces)
        let surname: String
        if let commaIdx = first.firstIndex(of: ",") {
            surname = String(first[..<commaIdx]).trimmingCharacters(in: .whitespaces)
        } else {
            surname = first.split(separator: " ").last.map(String.init) ?? first
        }
        return authors.count > 1 ? "\(surname) et al." : surname
    }
}

public struct LaTeXLabelTarget: Equatable {
    public let key: String
    public let kind: String      // e.g. "Section", "Eq.", "Theorem", "Figure", "Table"
    public let number: String    // e.g. "1.2", "1", "Theorem 1"
    public let title: String
    public let characterLocation: Int

    public var displayBadge: String {
        if kind == "Eq." { return "(\(number))" }
        if kind == "Section" { return "§\(number)" }
        return "\(kind) \(number)"
    }
}

public struct LaTeXDocumentIndex {
    public var documentClass: String = "article"
    public var documentClassOptions: String = ""
    public var packageNames: [String] = []
    public var macroCount: Int = 0
    public var preambleRange: NSRange?
    public var beginDocumentLineRange: NSRange?
    public var endDocumentLineRange: NSRange?
    public var title: String?
    public var author: String?
    public var date: String?
    public var labels: [String: LaTeXLabelTarget] = [:]
    public var lineSectionNumbers: [Int: (level: Int, number: String, title: String, starred: Bool)] = [:]
    public var blockEquationNumbers: [Int: String] = [:]
    public var blockTheoremHeaders: [Int: (header: String, isProof: Bool)] = [:]
    public var blockFigureNumbers: [Int: String] = [:]
    public var blockTableNumbers: [Int: String] = [:]
    public var bibEntries: [String: BibTeXEntry] = [:]
    public var extraMacros: [String: LaTeXMacroDefinition] = [:]
    public var documentStyle = LaTeXDocumentStyle()

    public var preambleSummaryTitle: String {
        let opt = documentClassOptions.isEmpty ? "" : " (\(documentClassOptions))"
        return "LaTeX Preamble • \(documentClass)\(opt)"
    }

    public var preambleSummarySubtitle: String {
        let pkgLabel = packageNames.count == 1 ? "1 package" : "\(packageNames.count) packages"
        let macLabel = macroCount == 1 ? "1 macro" : "\(macroCount) macros"
        return "\(pkgLabel) • \(macLabel) — Click to expand"
    }
}

enum LaTeXDocumentIndexer {
    static let docClassRegex = try! NSRegularExpression(
        pattern: #"\\documentclass(?:\[([^\]]*)\])?\{([^}]+)\}"#
    )
    static let usepackageRegex = try! NSRegularExpression(
        pattern: #"\\usepackage(?:\[([^\]]*)\])?\{([^}]+)\}"#
    )
    static let sectionRegex = try! NSRegularExpression(
        pattern: #"^\s*\\(part|chapter|section|sectiontitle|subsection|subsubsection|paragraph|subparagraph)(\*?)(?:\[[^\]]*\])?\{((?:[^{}]|\{[^{}]*\})*)\}"#
    )
    static let labelRegex = try! NSRegularExpression(
        pattern: #"\\label\{([^}]+)\}"#
    )
    static let bibResourceRegex = try! NSRegularExpression(
        pattern: #"\\(?:bibliography|addbibresource)\{([^}]+)\}"#
    )
    static let inputRegex = try! NSRegularExpression(
        pattern: #"^\s*\\(input|include)\{([^}]+)\}"#
    )
    static let frontmatterCmdRegex = try! NSRegularExpression(
        pattern: #"^\s*\\(title|author|date)(?:\[[^\]]*\])?\{((?:[^{}]|\{[^{}]*\})*)\}"#
    )

    static let theoremEnvironments: [String: String] = [
        "theorem": "Theorem",
        "lemma": "Lemma",
        "proposition": "Proposition",
        "corollary": "Corollary",
        "definition": "Definition",
        "remark": "Remark",
        "example": "Example",
        "claim": "Claim",
        "assumption": "Assumption"
    ]

    static let numberedMathEnvironments: Set<String> = [
        "equation", "align", "gather", "multline", "flalign", "alignat"
    ]

    static func buildIndex(
        string: String,
        nsString: NSString,
        baseDirectoryURL: URL?
    ) -> LaTeXDocumentIndex {
        var idx = LaTeXDocumentIndex()
        let fullLength = nsString.length
        var charIndex = 0
        var inPreamble = true
        var secCounters = [0, 0, 0, 0] // section, subsection, subsubsection, paragraph
        var eqCounter = 0
        var thmCounters: [String: Int] = [:]
        var figCounter = 0
        var tabCounter = 0
        var currentContext: (kind: String, number: String, title: String, loc: Int) = ("Section", "1", "Document", 0)
        var bibFiles: [String] = []

        while charIndex < fullLength {
            let lineRange = nsString.lineRange(for: NSRange(location: charIndex, length: 0))
            let line = nsString.substring(with: lineRange)
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmed.hasPrefix("\\documentclass") {
                if let m = docClassRegex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) {
                    if m.range(at: 1).location != NSNotFound {
                        idx.documentClassOptions = (line as NSString).substring(with: m.range(at: 1))
                        parseDocumentClassOptions(idx.documentClassOptions, into: &idx.documentStyle)
                    }
                    idx.documentClass = (line as NSString).substring(with: m.range(at: 2))
                }
            }
            if trimmed.hasPrefix("\\begin{document}") {
                idx.beginDocumentLineRange = lineRange
                if lineRange.location > 0 {
                    idx.preambleRange = NSRange(location: 0, length: lineRange.location)
                }
                inPreamble = false
            } else if trimmed.hasPrefix("\\end{document}") {
                idx.endDocumentLineRange = lineRange
            }

            if inPreamble {
                if line.contains("\\usepackage") {
                    usepackageRegex.enumerateMatches(in: line, range: NSRange(location: 0, length: (line as NSString).length)) { m, _, _ in
                        guard let m = m else { return }
                        let pkgOpts = m.range(at: 1).location != NSNotFound
                            ? (line as NSString).substring(with: m.range(at: 1))
                            : nil
                        let raw = (line as NSString).substring(with: m.range(at: 2))
                        for pkg in raw.split(separator: ",") {
                            let pkgName = pkg.trimmingCharacters(in: .whitespaces)
                            idx.packageNames.append(pkgName)
                            applyPackageStyleDefaults(packageName: pkgName, options: pkgOpts, into: &idx.documentStyle)
                        }
                    }
                }
                parsePreambleStyleDirectives(in: line, trimmed: trimmed, into: &idx.documentStyle)
                if trimmed.hasPrefix("\\newcommand") || trimmed.hasPrefix("\\renewcommand")
                    || trimmed.hasPrefix("\\DeclareMathOperator") || trimmed.hasPrefix("\\def\\")
                    || trimmed.hasPrefix("\\providecommand") {
                    idx.macroCount += 1
                }
                if (trimmed.hasPrefix("\\input") || trimmed.hasPrefix("\\include")),
                   let im = inputRegex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)),
                   let baseDir = baseDirectoryURL {
                    let relPath = (line as NSString).substring(with: im.range(at: 2))
                    if let inputURL = resolveTeXFileURL(path: relPath, baseDirectoryURL: baseDir) {
                        let imported = loadInputMacros(from: inputURL)
                        idx.extraMacros.merge(imported) { _, new in new }
                    }
                }
            }

            if (trimmed.hasPrefix("\\title") || trimmed.hasPrefix("\\author") || trimmed.hasPrefix("\\date")),
               let fm = frontmatterCmdRegex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) {
                let cmd = (line as NSString).substring(with: fm.range(at: 1))
                let val = cleanTeXInlineText((line as NSString).substring(with: fm.range(at: 2)))
                if cmd == "title" { idx.title = val }
                else if cmd == "author" { idx.author = val }
                else if cmd == "date" { idx.date = val == "\\today" ? formattedToday() : val }
            }

            if trimmed.hasPrefix("\\"),
               let sm = sectionRegex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) {
                let cmd = (line as NSString).substring(with: sm.range(at: 1))
                let starred = cmd == "sectiontitle" || !((line as NSString).substring(with: sm.range(at: 2))).isEmpty
                let rawTitle = cleanTeXInlineText((line as NSString).substring(with: sm.range(at: 3)))
                let level = sectionLevel(for: cmd)
                var numStr = ""
                if !starred && level <= 4 {
                    let cIdx = max(0, level - 1)
                    secCounters[cIdx] += 1
                    for j in (cIdx + 1)..<secCounters.count { secCounters[j] = 0 }
                    numStr = secCounters[0...cIdx].map(String.init).joined(separator: ".")
                    currentContext = ("Section", numStr, rawTitle, lineRange.location)
                }
                idx.lineSectionNumbers[lineRange.location] = (level, numStr, rawTitle, starred)
            }

            if let envName = parseBeginEnvironment(trimmed) {
                let baseEnv = envName.hasSuffix("*") ? String(envName.dropLast()) : envName
                let starred = envName.hasSuffix("*")
                if numberedMathEnvironments.contains(baseEnv) && !starred {
                    eqCounter += 1
                    let num = "\(eqCounter)"
                    idx.blockEquationNumbers[lineRange.location] = num
                    currentContext = ("Eq.", num, "Equation (\(num))", lineRange.location)
                } else if let thmLabel = theoremEnvironments[baseEnv] {
                    let optTitle = parseOptionalBracketArg(afterBeginEnv: trimmed)
                    if starred {
                        let header = optTitle.map { "\(thmLabel) (\($0))." } ?? "\(thmLabel)."
                        idx.blockTheoremHeaders[lineRange.location] = (header, false)
                    } else {
                        let next = (thmCounters[baseEnv] ?? 0) + 1
                        thmCounters[baseEnv] = next
                        let header = optTitle.map { "\(thmLabel) \(next) (\($0))." } ?? "\(thmLabel) \(next)."
                        idx.blockTheoremHeaders[lineRange.location] = (header, false)
                        currentContext = (thmLabel, "\(next)", header, lineRange.location)
                    }
                } else if baseEnv == "proof" {
                    let optTitle = parseOptionalBracketArg(afterBeginEnv: trimmed)
                    let header = optTitle.map { "\($0)." } ?? "Proof."
                    idx.blockTheoremHeaders[lineRange.location] = (header, true)
                } else if baseEnv == "figure" && !starred {
                    figCounter += 1
                    idx.blockFigureNumbers[lineRange.location] = "\(figCounter)"
                    currentContext = ("Figure", "\(figCounter)", "Figure \(figCounter)", lineRange.location)
                } else if baseEnv == "table" && !starred {
                    tabCounter += 1
                    idx.blockTableNumbers[lineRange.location] = "\(tabCounter)"
                    currentContext = ("Table", "\(tabCounter)", "Table \(tabCounter)", lineRange.location)
                }
            }

            if line.contains("\\label{") {
                labelRegex.enumerateMatches(in: line, range: NSRange(location: 0, length: (line as NSString).length)) { m, _, _ in
                    guard let m = m else { return }
                    let key = (line as NSString).substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
                    idx.labels[key] = LaTeXLabelTarget(
                        key: key,
                        kind: currentContext.kind,
                        number: currentContext.number,
                        title: currentContext.title,
                        characterLocation: currentContext.loc
                    )
                }
            }

            if line.contains("\\bibliography{") || line.contains("\\addbibresource{") {
                bibResourceRegex.enumerateMatches(in: line, range: NSRange(location: 0, length: (line as NSString).length)) { m, _, _ in
                    guard let m = m else { return }
                    let raw = (line as NSString).substring(with: m.range(at: 1))
                    for part in raw.split(separator: ",") {
                        bibFiles.append(part.trimmingCharacters(in: .whitespaces))
                    }
                }
            }

            charIndex = NSMaxRange(lineRange)
        }

        idx.bibEntries = loadBibEntries(referencedFiles: bibFiles, baseDirectoryURL: baseDirectoryURL)
        return idx
    }
}
