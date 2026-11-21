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
    /// `\documentclass` argument in the preamble, if any.
    var documentClassName: String?
    /// `\usepackage` arguments in the preamble, in source order.
    var packageNames: [String] = []
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
    /// `\documentclass{...}` and `\LoadClass{...}` arguments in order.
    let classNames: [String]
    /// `\usepackage{...}` and `\RequirePackage{...}` arguments in preamble/class/style order.
    let packageNames: [String]
    /// `\input{...}` and `\include{...}` arguments anywhere outside comments.
    let includeTargets: [String]
    /// The same, before `\begin{document}`.
    let preambleIncludeTargets: [String]
    /// Simple relative-path-like tokens appearing in `[...]` or `{...}` outside comments,
    /// used as a fallback to match sidebar inputs such as `\cvsection[page1sidebar]{...}`.
    let bracketAndBraceTokens: Set<String>
    /// Text before `\begin{document}`, or the full text when no `\begin{document}` exists.
    let stylePreambleText: String
    /// Macros defined before `\begin{document}`, or in the whole file when it has none.
    let preambleMacros: [String: LaTeXMacroDefinition]
    let allMacros: [String: LaTeXMacroDefinition]

    static func parse(_ text: String) -> LaTeXFileFacts {
        var directives: [LaTeXMasterDirective] = []
        var declaresClass = false
        var classNames: [String] = []
        var packageNames: [String] = []
        var includes: [String] = []
        var preambleIncludes: [String] = []
        var tokens: Set<String> = []
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
            if inPreamble {
                if code.contains("\\documentclass") || code.contains("\\LoadClass") {
                    classNames += bracedArguments(forAnyOf: ["\\documentclass", "\\LoadClass"], in: code)
                }
                if code.contains("\\usepackage") || code.contains("\\RequirePackage") {
                    for arg in bracedArguments(forAnyOf: ["\\usepackage", "\\RequirePackage"], in: code) {
                        for pkg in arg.split(separator: ",") {
                            let trimmed = pkg.trimmingCharacters(in: .whitespaces)
                            if !trimmed.isEmpty { packageNames.append(trimmed) }
                        }
                    }
                }
            }
            let targets = includeArguments(in: code)
            includes += targets
            if inPreamble { preambleIncludes += targets }
            if !inPreamble && (code.contains("[") || code.contains("{")) {
                tokens.formUnion(candidateReferenceTokens(in: code))
            }
            lineStart = text.index(line.endIndex, offsetBy: line.endIndex < text.endIndex ? 1 : 0)
        }
        let stylePreamble = preambleEnd.map { String(text[..<$0]) } ?? text
        let all = LaTeXMacroExpander.extractDocumentMacros(from: text)
        let preamble = preambleEnd.map { LaTeXMacroExpander.extractDocumentMacros(from: String(text[..<$0])) } ?? all
        return LaTeXFileFacts(
            masterDirective: LaTeXMasterDirective.preferred(directives),
            declaresDocumentClass: declaresClass,
            classNames: classNames,
            packageNames: packageNames,
            includeTargets: includes,
            preambleIncludeTargets: preambleIncludes,
            bracketAndBraceTokens: tokens,
            stylePreambleText: stylePreamble,
            preambleMacros: preamble,
            allMacros: all
        )
    }

    /// The line up to its first unescaped `%`.
    static func stripComment(_ line: Substring) -> Substring {
        LaTeXLexer.stripLineComment(line)
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

    private static func bracedArguments(forAnyOf commands: [String], in code: Substring) -> [String] {
        var found: [(String.Index, String)] = []
        for command in commands {
            var search = code.startIndex
            while let match = code.range(of: command, range: search..<code.endIndex) {
                var pos = match.upperBound
                while pos < code.endIndex && (code[pos] == " " || code[pos] == "\t") { pos = code.index(after: pos) }
                if pos < code.endIndex && code[pos] == "*" { pos = code.index(after: pos) }
                while pos < code.endIndex && (code[pos] == " " || code[pos] == "\t") { pos = code.index(after: pos) }
                if pos < code.endIndex && code[pos] == "[", let closeBracket = code[pos...].firstIndex(of: "]") {
                    pos = code.index(after: closeBracket)
                    while pos < code.endIndex && (code[pos] == " " || code[pos] == "\t") { pos = code.index(after: pos) }
                }
                if pos < code.endIndex && code[pos] == "{",
                    let closeBrace = code[code.index(after: pos)...].firstIndex(of: "}")
                {
                    let arg = code[code.index(after: pos)..<closeBrace].trimmingCharacters(in: .whitespaces)
                    if !arg.isEmpty { found.append((match.lowerBound, arg)) }
                    search = code.index(after: closeBrace)
                } else {
                    search = match.upperBound
                }
            }
        }
        return found.sorted { $0.0 < $1.0 }.map(\.1)
    }

    private static func candidateReferenceTokens(in code: Substring) -> [String] {
        var tokens: [String] = []
        let delimiters: [(Character, Character)] = [("[", "]"), ("{", "}")]
        for (open, close) in delimiters {
            var idx = code.startIndex
            while let openIdx = code[idx...].firstIndex(of: open) {
                let afterOpen = code.index(after: openIdx)
                guard let closeIdx = code[afterOpen...].firstIndex(of: close) else { break }
                let token = code[afterOpen..<closeIdx].trimmingCharacters(in: .whitespaces)
                if !token.isEmpty && token.count <= 64
                    && !token.contains(where: { $0.isWhitespace || $0 == "\\" || $0 == "=" || $0 == "," || $0 == "{" || $0 == "[" })
                {
                    tokens.append(token)
                }
                idx = code.index(after: closeIdx)
            }
        }
        return tokens
    }
}
