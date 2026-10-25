import Foundation
import SwiftMath

public struct LaTeXMacroDefinition: Equatable, Hashable, Sendable {
    public let name: String
    public let argCount: Int
    public let defaultFirstArg: String?
    public let replacement: String
    public let operatorText: String?
    public let operatorHasLimits: Bool

    public init(
        name: String,
        argCount: Int = 0,
        defaultFirstArg: String? = nil,
        replacement: String,
        operatorText: String? = nil,
        operatorHasLimits: Bool = false
    ) {
        self.name = name
        self.argCount = argCount
        self.defaultFirstArg = defaultFirstArg
        self.replacement = replacement
        self.operatorText = operatorText
        self.operatorHasLimits = operatorHasLimits
    }
}

public enum LaTeXMacroExpander {
    public static func extractDocumentMacros(from documentText: String) -> [String: LaTeXMacroDefinition] {
        var macros: [String: LaTeXMacroDefinition] = [:]
        _ = consumeDefinitions(in: documentText, into: &macros)
        return macros
    }

    public static func isStandaloneMacroDefinitionBlock(_ text: String) -> Bool {
        var stripped = stripComments(from: text).trimmingCharacters(in: .whitespacesAndNewlines)
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
        var working = stripComments(from: latex)
        working = consumeDefinitions(in: working, into: &localMacros)
        if localMacros.count != prevCount {
            registerCustomOperators(from: localMacros)
        }

        if !localMacros.isEmpty && working.contains("\\") {
            for _ in 0..<16 {
                let next = expandMacrosOnce(in: working, macros: localMacros)
                if next == working { break }
                working = next
            }
        }

        let (withoutTag, extractedTag) = extractTag(from: working)
        let normalized = normalizeEnvironmentsAndCommands(withoutTag)
        return (normalized.trimmingCharacters(in: .whitespacesAndNewlines), extractedTag)
    }

    static func registerCustomOperators(from macros: [String: LaTeXMacroDefinition]) {
        for definition in macros.values {
            guard let opText = definition.operatorText else { continue }
            let symbolName = definition.name.hasPrefix("\\")
                ? String(definition.name.dropFirst())
                : definition.name
            guard !symbolName.isEmpty else { continue }
            MTMathAtomFactory.add(
                latexSymbol: symbolName,
                value: MTMathAtomFactory.operatorWithName(opText, limits: definition.operatorHasLimits)
            )
        }
    }

    private static func stripComments(from text: String) -> String {
        guard text.contains("%") else { return text }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.map { line -> String in
            let chars = Array(line)
            var idx = 0
            while idx < chars.count {
                if chars[idx] == "%" {
                    var backslashes = 0
                    var prev = idx - 1
                    while prev >= 0 && chars[prev] == "\\" {
                        backslashes += 1
                        prev -= 1
                    }
                    if backslashes % 2 == 0 {
                        return String(chars[0..<idx])
                    }
                }
                idx += 1
            }
            return String(line)
        }.joined(separator: "\n")
    }

    private static func consumeDefinitions(
        in text: String,
        into macros: inout [String: LaTeXMacroDefinition]
    ) -> String {
        guard text.contains("\\newcommand")
            || text.contains("\\renewcommand")
            || text.contains("\\providecommand")
            || text.contains("\\DeclareMathOperator")
            || text.contains("\\def") else {
            return text
        }
        let chars = Array(text)
        var out = ""
        var i = 0
        while i < chars.count {
            if chars[i] == "\\", let (def, nextIdx) = parseDefinition(chars, at: i) {
                macros[def.name] = def
                i = nextIdx
                while i < chars.count && (chars[i] == " " || chars[i] == "\t") { i += 1 }
                if i < chars.count && chars[i] == "\n" { i += 1 }
            } else {
                out.append(chars[i])
                i += 1
            }
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
               let parsed = Int(countStr.trimmingCharacters(in: .whitespaces)) {
                argCount = max(0, min(9, parsed))
                idx = skipSpaces(chars, from: afterCount)
            }
            var defaultFirstArg: String?
            if let (optDefault, afterOpt) = readBracketGroup(chars, at: idx) {
                defaultFirstArg = optDefault
                idx = skipSpaces(chars, from: afterOpt)
            }
            guard let (body, afterBody) = readBracedGroup(chars, at: idx) else { return nil }
            return (LaTeXMacroDefinition(
                name: rawName,
                argCount: argCount,
                defaultFirstArg: defaultFirstArg,
                replacement: body
            ), afterBody)

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
            return (LaTeXMacroDefinition(
                name: rawName,
                argCount: 0,
                replacement: "\\mathrm{\(cleanOp)}",
                operatorText: cleanOp,
                operatorHasLimits: isStarred
            ), afterBody)

        case "\\def":
            var idx = skipSpaces(chars, from: afterCmd)
            let (rawName, afterName) = readControlWord(chars, at: idx)
            guard rawName.count > 1 else { return nil }
            idx = afterName
            var argCount = 0
            while idx + 1 < chars.count && chars[idx] == "#" {
                if let digit = chars[idx + 1].wholeNumberValue, digit == argCount + 1 {
                    argCount = digit
                    idx += 2
                } else {
                    break
                }
            }
            idx = skipSpaces(chars, from: idx)
            guard let (body, afterBody) = readBracedGroup(chars, at: idx) else { return nil }
            return (LaTeXMacroDefinition(name: rawName, argCount: argCount, replacement: body), afterBody)

        default:
            return nil
        }
    }
}
