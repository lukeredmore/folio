import AppKit
import FolioEngineFFI
import Foundation

public struct BibTeXEntry: Equatable, Sendable {
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
        let cleaned =
            rawAuthor
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
    public let kind: String // e.g. "Section", "Eq.", "Theorem", "Figure", "Table"
    public let number: String // e.g. "1.2", "1", "Theorem 1"
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
    /// Every macro the document can use: its own, its inputs', and its master file's.
    public var documentMacros: [String: LaTeXMacroDefinition] = [:]
    /// Resolved files of the preamble's `\input` paths, from the project snapshot.
    var inputURLs: [String: URL] = [:]
    /// What this document needs from disk. The styler refreshes the project when it changes.
    var projectSignature = LaTeXProjectSignature()
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
    struct PreambleScanCheckpoint {
        let prefix: String
        let prefixUTF16Length: Int
        let index: LaTeXDocumentIndex
        let masterDirectives: [LaTeXMasterDirective]
        let signature: LaTeXProjectSignature
        let secCounters: [Int]
        let eqCounter: Int
        let thmCounters: [String: Int]
        let figCounter: Int
        let tabCounter: Int
        let currentContext: (kind: String, number: String, title: String, loc: Int)
        let preambleMacros: [String: LaTeXMacroDefinition]
    }

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

    /// Indexes the document. Input macros, input files, and bibliography entries come from
    /// `project`, so this does no file I/O.
    static func buildIndex(
        string: String,
        nsString: NSString,
        project: LaTeXProjectSnapshot = .empty
    ) -> LaTeXDocumentIndex {
        buildIndexWithCheckpoint(
            string: string,
            nsString: nsString,
            project: project,
            sourceCodeMode: false,
            reusableCheckpoint: nil
        ).index
    }

    static func buildIndexWithCheckpoint(
        string: String,
        nsString: NSString,
        project: LaTeXProjectSnapshot,
        sourceCodeMode: Bool,
        reusableCheckpoint: PreambleScanCheckpoint?
    ) -> (index: LaTeXDocumentIndex, checkpoint: PreambleScanCheckpoint?) {
        _ = string
        let fullLength = nsString.length
        var idx: LaTeXDocumentIndex
        var masterDirectives: [LaTeXMasterDirective]
        var charIndex: Int
        var inPreamble: Bool
        var secCounters: [Int]
        var eqCounter: Int
        var thmCounters: [String: Int]
        var figCounter: Int
        var tabCounter: Int
        var currentContext: (kind: String, number: String, title: String, loc: Int)
        var signature: LaTeXProjectSignature
        var capturedCheckpoint: PreambleScanCheckpoint?
        var preambleCondStack: [(cond: Bool, inElse: Bool)] = []

        if let cp = reusableCheckpoint,
            fullLength >= cp.prefixUTF16Length,
            nsString.substring(to: cp.prefixUTF16Length) == cp.prefix
        {
            idx = cp.index
            idx.inputURLs = project.inputURLs
            masterDirectives = cp.masterDirectives
            charIndex = cp.prefixUTF16Length
            inPreamble = false
            secCounters = cp.secCounters
            eqCounter = cp.eqCounter
            thmCounters = cp.thmCounters
            figCounter = cp.figCounter
            tabCounter = cp.tabCounter
            currentContext = cp.currentContext
            signature = cp.signature
            capturedCheckpoint = cp
        } else {
            idx = LaTeXDocumentIndex()
            idx.inputURLs = project.inputURLs
            if !project.inheritedStylePreamble.isEmpty {
                applyStylePreamble(project.inheritedStylePreamble, into: &idx.documentStyle)
            }
            masterDirectives = []
            charIndex = 0
            inPreamble = true
            secCounters = [0, 0, 0, 0]
            eqCounter = 0
            thmCounters = [:]
            figCounter = 0
            tabCounter = 0
            currentContext = ("Section", "1", "Document", 0)
            signature = LaTeXProjectSignature()
        }

        while charIndex < fullLength {
            let lineRange = nsString.lineRange(for: NSRange(location: charIndex, length: 0))
            let line = nsString.substring(with: lineRange)
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let wasInPreamble = inPreamble

            if inPreamble && trimmed.hasPrefix("\\begin{document}") {
                idx.beginDocumentLineRange = lineRange
                if lineRange.location > 0 {
                    idx.preambleRange = NSRange(location: 0, length: lineRange.location)
                }
                inPreamble = false
            } else if trimmed.hasPrefix("\\end{document}") {
                idx.endDocumentLineRange = lineRange
            }

            var preambleBranchActive = true
            if inPreamble {
                if let condVal = LaTeXStylePass.parseIfDirective(trimmed, conditionals: idx.documentStyle.conditionals) {
                    preambleCondStack.append((condVal, false))
                    preambleBranchActive = false
                } else if LaTeXStylePass.isElseDirective(trimmed), !preambleCondStack.isEmpty {
                    preambleCondStack[preambleCondStack.count - 1].inElse = true
                    preambleBranchActive = false
                } else if LaTeXStylePass.isFiDirective(trimmed), !preambleCondStack.isEmpty {
                    preambleCondStack.removeLast()
                    preambleBranchActive = false
                } else {
                    preambleBranchActive = preambleCondStack.allSatisfy { $0.inElse ? !$0.cond : $0.cond }
                }
            }

            if inPreamble && preambleBranchActive
                && (trimmed.hasPrefix("\\newcommand") || trimmed.hasPrefix("\\renewcommand")
                    || trimmed.hasPrefix("\\DeclareMathOperator") || trimmed.hasPrefix("\\def\\")
                    || trimmed.hasPrefix("\\providecommand") || trimmed.hasPrefix("\\DeclareRobustCommand")
                    || trimmed.hasPrefix("\\newfontfamily") || trimmed.hasPrefix("\\renewfontfamily")
                    || trimmed.hasPrefix("\\providefontfamily") || trimmed.hasPrefix("\\newfontface")
                    || trimmed.hasPrefix("\\renewfontface") || trimmed.hasPrefix("\\providefontface"))
            {
                idx.macroCount += 1
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

            if trimmed.hasPrefix("%"), let directive = LaTeXMasterDirective.parse(line: trimmed) {
                masterDirectives.append(directive)
            }

            if line.contains("\\") && (!inPreamble || preambleBranchActive) {
                applyScannedDirectives(
                    in: line,
                    lineLocation: lineRange.location,
                    inPreamble: inPreamble,
                    project: project,
                    secCounters: &secCounters,
                    currentContext: &currentContext,
                    signature: &signature,
                    into: &idx
                )
            }

            let nextIndex = NSMaxRange(lineRange)
            if wasInPreamble && !inPreamble && capturedCheckpoint == nil {
                let prefix = nsString.substring(to: nextIndex)
                if LaTeXLexer.hasBalancedBraces(prefix) {
                    let preambleMacros =
                        (!sourceCodeMode && prefix.contains("\\"))
                        ? LaTeXMacroExpander.extractDocumentMacros(from: prefix)
                        : [:]
                    capturedCheckpoint = PreambleScanCheckpoint(
                        prefix: prefix,
                        prefixUTF16Length: nextIndex,
                        index: idx,
                        masterDirectives: masterDirectives,
                        signature: signature,
                        secCounters: secCounters,
                        eqCounter: eqCounter,
                        thmCounters: thmCounters,
                        figCounter: figCounter,
                        tabCounter: tabCounter,
                        currentContext: currentContext,
                        preambleMacros: preambleMacros
                    )
                }
            }
            charIndex = nextIndex
        }

        signature.masterDirective = LaTeXMasterDirective.preferred(masterDirectives)
        idx.projectSignature = signature
        idx.bibEntries = project.bibEntries
        return (idx, capturedCheckpoint)
    }
}
