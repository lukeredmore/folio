import Foundation

/// A magic comment that names a file's master document.
enum LaTeXMasterDirective: Hashable, Sendable {
    /// `% !TEX root = path`
    case texRoot(String)
    /// Emacs `%%% TeX-master: "name"`
    case texMaster(String)
    /// Emacs `%%% TeX-master: t`: this file is the master.
    case isMaster

    /// Parses one source line. Returns nil when the line is not one of the magic comments.
    static func parse(line: String) -> LaTeXMasterDirective? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("%") else { return nil }
        let body = trimmed.drop { $0 == "%" }.trimmingCharacters(in: .whitespaces)
        if body.lowercased().hasPrefix("!tex root"), let equals = body.firstIndex(of: "=") {
            let path = body[body.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            return path.isEmpty ? nil : .texRoot(path)
        }
        guard let key = body.range(of: "TeX-master:") else { return nil }
        let value = body[key.upperBound...].trimmingCharacters(in: .whitespaces)
        if value == "t" { return .isMaster }
        guard value.hasPrefix("\""), let close = value.dropFirst().firstIndex(of: "\"") else { return nil }
        let name = String(value[value.index(after: value.startIndex)..<close])
        return name.isEmpty ? nil : .texMaster(name)
    }

    /// The directive that wins among `directives`: the first `!TEX root`, else the first
    /// `TeX-master` value.
    static func preferred(_ directives: [LaTeXMasterDirective]) -> LaTeXMasterDirective? {
        directives.first { if case .texRoot = $0 { return true } else { return false } } ?? directives.first
    }
}

/// The parts of an open document that decide which project files it needs. When these change,
/// the project snapshot is refreshed off the restyle path.
struct LaTeXProjectSignature: Hashable, Sendable {
    /// `\input` and `\include` arguments in the preamble, in source order.
    var inputPaths: [String] = []
    /// `\bibliography` and `\addbibresource` files.
    var bibFiles: [String] = []
    var masterDirective: LaTeXMasterDirective?
    var declaresDocumentClass = false
}

/// What project resolution needs to know about a file on disk. Parsed once per file stamp.
struct LaTeXFileFacts: Sendable {
    let masterDirective: LaTeXMasterDirective?
    let declaresDocumentClass: Bool
    /// `\input{...}` and `\include{...}` arguments anywhere outside comments.
    let includeTargets: [String]
    /// The same, before `\begin{document}`.
    let preambleIncludeTargets: [String]
    /// Macros defined before `\begin{document}`, or in the whole file when it has none.
    let preambleMacros: [String: LaTeXMacroDefinition]
    let allMacros: [String: LaTeXMacroDefinition]

    static func parse(_ text: String) -> LaTeXFileFacts {
        var directives: [LaTeXMasterDirective] = []
        var declaresClass = false
        var includes: [String] = []
        var preambleIncludes: [String] = []
        var preambleEnd: String.Index?
        var inPreamble = true
        var lineStart = text.startIndex
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if let directive = LaTeXMasterDirective.parse(line: String(line)) { directives.append(directive) }
            let code = stripComment(line)
            if inPreamble, code.contains("\\begin{document}") {
                inPreamble = false
                preambleEnd = lineStart
            }
            if code.contains("\\documentclass") { declaresClass = true }
            let targets = includeArguments(in: code)
            includes += targets
            if inPreamble { preambleIncludes += targets }
            lineStart = text.index(line.endIndex, offsetBy: line.endIndex < text.endIndex ? 1 : 0)
        }
        let all = LaTeXMacroExpander.extractDocumentMacros(from: text)
        let preamble = preambleEnd.map { LaTeXMacroExpander.extractDocumentMacros(from: String(text[..<$0])) } ?? all
        return LaTeXFileFacts(
            masterDirective: LaTeXMasterDirective.preferred(directives),
            declaresDocumentClass: declaresClass,
            includeTargets: includes,
            preambleIncludeTargets: preambleIncludes,
            preambleMacros: preamble,
            allMacros: all
        )
    }

    /// The line up to its first unescaped `%`.
    static func stripComment(_ line: Substring) -> Substring {
        var idx = line.startIndex
        var backslashes = 0
        while idx < line.endIndex {
            let ch = line[idx]
            if ch == "%" && backslashes % 2 == 0 { return line[..<idx] }
            backslashes = ch == "\\" ? backslashes + 1 : 0
            idx = line.index(after: idx)
        }
        return line
    }

    /// Arguments of `\input{...}` and `\include{...}` in `code`, in source order.
    static func includeArguments(in code: Substring) -> [String] {
        guard code.contains("\\in") else { return [] }
        var found: [(String.Index, String)] = []
        for command in ["\\input{", "\\include{"] {
            var search = code.startIndex
            while let match = code.range(of: command, range: search..<code.endIndex) {
                guard let close = code[match.upperBound...].firstIndex(of: "}") else { break }
                let target = code[match.upperBound..<close].trimmingCharacters(in: .whitespaces)
                if !target.isEmpty { found.append((match.lowerBound, target)) }
                search = close
            }
        }
        return found.sorted { $0.0 < $1.0 }.map(\.1)
    }
}
