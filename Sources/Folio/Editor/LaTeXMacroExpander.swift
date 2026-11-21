import CoreGraphics
import Foundation

public struct LaTeXFontDeclaration: Equatable, Hashable, Sendable {
    public var fontFamily: String?
    public var sizeScale: CGFloat?
    public var bold: Bool?
    public var italic: Bool?
    public var smallCaps: Bool?
    public var letterSpaceEm: CGFloat?

    public init(
        fontFamily: String? = nil,
        sizeScale: CGFloat? = nil,
        bold: Bool? = nil,
        italic: Bool? = nil,
        smallCaps: Bool? = nil,
        letterSpaceEm: CGFloat? = nil
    ) {
        self.fontFamily = fontFamily
        self.sizeScale = sizeScale
        self.bold = bold
        self.italic = italic
        self.smallCaps = smallCaps
        self.letterSpaceEm = letterSpaceEm
    }
}

public struct LaTeXMacroDefinition: Equatable, Hashable, Sendable {
    public let name: String
    public let argCount: Int
    public let defaultFirstArg: String?
    public let replacement: String
    public let operatorText: String?
    public let operatorHasLimits: Bool
    /// Delimited parameter text of a `\def`, or nil when every parameter is undelimited.
    public let parameterText: LaTeXParameterText?
    /// True for `\newenvironment`. `name` is then `environmentKey(_:)` of the environment,
    /// `replacement` is the begin code, and `environmentEnd` is the end code.
    public let isEnvironment: Bool
    public let environmentEnd: String?
    /// Font specification for `fontspec` `\newfontfamily` / `\newfontface` declarations.
    public let fontDeclaration: LaTeXFontDeclaration?

    public init(
        name: String,
        argCount: Int = 0,
        defaultFirstArg: String? = nil,
        replacement: String,
        operatorText: String? = nil,
        operatorHasLimits: Bool = false,
        parameterText: LaTeXParameterText? = nil,
        isEnvironment: Bool = false,
        environmentEnd: String? = nil,
        fontDeclaration: LaTeXFontDeclaration? = nil
    ) {
        self.name = name
        self.argCount = argCount
        self.defaultFirstArg = defaultFirstArg
        self.replacement = replacement
        self.operatorText = operatorText
        self.operatorHasLimits = operatorHasLimits
        self.parameterText = parameterText
        self.isEnvironment = isEnvironment
        self.environmentEnd = environmentEnd
        self.fontDeclaration = fontDeclaration
    }

    /// Dictionary key of a user-defined environment. It cannot collide with a control word.
    public static func environmentKey(_ environmentName: String) -> String {
        "\\begin{\(environmentName)}"
    }
}

public enum LaTeXMacroExpander {
    public static let maxExpandedUTF8Bytes = 32_768

    public static func extractDocumentMacros(from documentText: String) -> [String: LaTeXMacroDefinition] {
        var macros: [String: LaTeXMacroDefinition] = [:]
        _ = consumeDefinitions(in: documentText, into: &macros)
        return macros
    }

    public static func isStandaloneMacroDefinitionBlock(_ text: String) -> Bool {
        var stripped = LaTeXLexer.stripComments(from: text).trimmingCharacters(in: .whitespacesAndNewlines)
        if stripped.hasPrefix("$$") && stripped.hasSuffix("$$") && stripped.count >= 4 {
            stripped = String(stripped.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !stripped.isEmpty else { return false }
        var macros: [String: LaTeXMacroDefinition] = [:]
        let remainder = consumeDefinitions(in: stripped, into: &macros)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return !macros.isEmpty && remainder.isEmpty
    }

    public static func expandAndNormalize(
        _ latex: String,
        macros: [String: LaTeXMacroDefinition] = [:]
    ) -> (expandedLatex: String, tag: String?) {
        var localMacros = macros
        let prevCount = localMacros.count
        var working = LaTeXLexer.stripComments(from: latex)
        working = consumeDefinitions(in: working, into: &localMacros)
        if localMacros.count != prevCount {
            registerCustomOperators(from: localMacros)
        }

        if !localMacros.isEmpty && working.contains("\\") && working.utf8.count <= maxExpandedUTF8Bytes {
            for _ in 0..<16 {
                let (next, didHitLimit) = expandMacrosOnce(
                    in: working,
                    macros: localMacros,
                    maxUTF8Bytes: maxExpandedUTF8Bytes
                )
                let unchanged = (next == working)
                working = next
                if didHitLimit || unchanged { break }
            }
        }

        let (withoutTag, extractedTag) = extractTag(from: working)
        let normalized = normalizeEnvironmentsAndCommands(withoutTag)
        return (normalized.trimmingCharacters(in: .whitespacesAndNewlines), extractedTag)
    }

    static func registerCustomOperators(from macros: [String: LaTeXMacroDefinition]) {
        LaTeXMathRenderer.registerCustomOperators(from: macros)
    }

    private static func consumeDefinitions(
        in text: String,
        into macros: inout [String: LaTeXMacroDefinition]
    ) -> String {
        guard
            text.contains("\\newcommand")
                || text.contains("\\renewcommand")
                || text.contains("\\providecommand")
                || text.contains("\\DeclareMathOperator")
                || text.contains("\\def")
                || text.contains("environment{")
                || text.contains("fontfamily")
                || text.contains("fontface")
                || text.contains("\\let")
        else {
            return text
        }
        let chars = Array(text)
        var out = ""
        var endAliases: Set<String> = []
        var i = 0
        while i < chars.count {
            if chars[i] == "\\", let (def, nextIdx) = parseDefinition(chars, at: i) {
                macros[def.name] = def
                i = nextIdx
                while i < chars.count && (chars[i] == " " || chars[i] == "\t") { i += 1 }
                if i < chars.count && chars[i] == "\n" { i += 1 }
            } else if chars[i] == "\\", let (endName, nextIdx) = parseEndEnvironmentAlias(chars, at: i) {
                endAliases.insert(endName)
                i = nextIdx
                while i < chars.count && (chars[i] == " " || chars[i] == "\t") { i += 1 }
                if i < chars.count && chars[i] == "\n" { i += 1 }
            } else {
                out.append(chars[i])
                i += 1
            }
        }
        for (key, def) in macros where key.hasPrefix("\\") {
            let envName = String(key.dropFirst())
            guard !envName.isEmpty,
                !envName.hasPrefix("end"),
                !def.isEnvironment,
                def.operatorText == nil,
                def.fontDeclaration == nil,
                endAliases.contains(envName) || macros["\\end\(envName)"] != nil,
                macros[LaTeXMacroDefinition.environmentKey(envName)] == nil
            else {
                continue
            }
            macros[LaTeXMacroDefinition.environmentKey(envName)] = LaTeXMacroDefinition(
                name: LaTeXMacroDefinition.environmentKey(envName),
                argCount: def.argCount,
                defaultFirstArg: def.defaultFirstArg,
                replacement: def.replacement,
                parameterText: def.parameterText,
                isEnvironment: true,
                environmentEnd: macros["\\end\(envName)"]?.replacement
            )
        }
        return out
    }

    private static func parseDefinition(
        _ chars: [Character],
        at start: Int
    ) -> (LaTeXMacroDefinition, Int)? {
        let (cmd, afterCmd) = readControlWord(chars, at: start)
        switch cmd {
        case "\\newcommand", "\\renewcommand", "\\providecommand":
            var idx = skipSpaces(chars, from: afterCmd)
            if idx < chars.count && chars[idx] == "*" { idx = skipSpaces(chars, from: idx + 1) }
            guard let (rawName, afterName) = readMacroNameArg(chars, at: idx) else { return nil }
            idx = skipSpaces(chars, from: afterName)
            var argCount = 0
            if let (countStr, afterCount) = readBracketGroup(chars, at: idx),
                let parsed = Int(countStr.trimmingCharacters(in: .whitespaces))
            {
                argCount = max(0, min(9, parsed))
                idx = skipSpaces(chars, from: afterCount)
            }
            var defaultFirstArg: String?
            if let (optDefault, afterOpt) = readBracketGroup(chars, at: idx) {
                defaultFirstArg = optDefault
                idx = skipSpaces(chars, from: afterOpt)
            }
            guard let (body, afterBody) = readBracedGroup(chars, at: idx) else { return nil }
            return (
                LaTeXMacroDefinition(
                    name: rawName,
                    argCount: argCount,
                    defaultFirstArg: defaultFirstArg,
                    replacement: body
                ), afterBody
            )

        case "\\DeclareMathOperator":
            var idx = skipSpaces(chars, from: afterCmd)
            var isStarred = false
            if idx < chars.count && chars[idx] == "*" {
                isStarred = true
                idx = skipSpaces(chars, from: idx + 1)
            }
            guard let (rawName, afterName) = readMacroNameArg(chars, at: idx) else { return nil }
            idx = skipSpaces(chars, from: afterName)
            guard let (opBody, afterBody) = readBracedGroup(chars, at: idx) else { return nil }
            let cleanOp = sanitizeOperatorText(opBody)
            return (
                LaTeXMacroDefinition(
                    name: rawName,
                    argCount: 0,
                    replacement: "\\mathrm{\(cleanOp)}",
                    operatorText: cleanOp,
                    operatorHasLimits: isStarred
                ), afterBody
            )

        case "\\def":
            let (rawName, afterName) = readControlWord(chars, at: skipSpaces(chars, from: afterCmd))
            guard rawName.count > 1,
                let (argCount, parameterText, bodyStart) = parseDefParameterText(chars, from: afterName),
                let (body, afterBody) = readBracedGroup(chars, at: bodyStart)
            else { return nil }
            return (
                LaTeXMacroDefinition(name: rawName, argCount: argCount, replacement: body, parameterText: parameterText),
                afterBody
            )

        case "\\newenvironment", "\\renewenvironment":
            return parseEnvironmentDefinition(chars, after: afterCmd)

        case "\\newfontfamily", "\\renewfontfamily", "\\providefontfamily",
            "\\newfontface", "\\renewfontface", "\\providefontface":
            return parseFontspecDefinition(cmd: cmd, chars, after: afterCmd)

        default:
            return nil
        }
    }
}
