import Foundation

enum LaTeXLexer {
    /// Returns `line` up to its first unescaped `%` comment character.
    static func stripLineComment(_ line: Substring) -> Substring {
        var idx = line.startIndex
        var backslashes = 0
        while idx < line.endIndex {
            let ch = line[idx]
            if ch == "%" && backslashes % 2 == 0 {
                return line[..<idx]
            }
            backslashes = ch == "\\" ? backslashes + 1 : 0
            idx = line.index(after: idx)
        }
        return line
    }

    static func stripLineComment(_ line: String) -> String {
        guard line.contains("%") else { return line }
        return String(stripLineComment(Substring(line)))
    }

    /// Strips unescaped `%` comments from every line of `text`, preserving line breaks.
    static func stripComments(from text: String) -> String {
        guard text.contains("%") else { return text }
        return
            text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String(stripLineComment($0)) }
            .joined(separator: "\n")
    }

    /// UTF-16 offset of the first unescaped `%` inside `range`, or `nil`.
    static func findUnescapedPercent(in nsString: NSString, range: NSRange) -> Int? {
        let end = NSMaxRange(range)
        var idx = range.location
        while idx < end {
            if nsString.character(at: idx) == 0x25 {
                var backslashes = 0
                var prev = idx - 1
                while prev >= range.location && nsString.character(at: prev) == 0x5C {
                    backslashes += 1
                    prev -= 1
                }
                if backslashes % 2 == 0 {
                    return idx
                }
            }
            idx += 1
        }
        return nil
    }

    /// Replaces each unescaped `%` comment up to `\n` with spaces so UTF-16 offsets stay identical.
    static func maskedComments(_ text: String) -> String {
        guard text.contains("%") else { return text }
        var units = Array(text.utf16)
        var idx = 0
        var inComment = false
        while idx < units.count {
            let unit = units[idx]
            if unit == 0x0A {
                inComment = false
            } else if inComment {
                units[idx] = 0x20
            } else if unit == 0x5C {
                idx += 2
                continue
            } else if unit == 0x25 {
                inComment = true
                units[idx] = 0x20
            }
            idx += 1
        }
        return String(utf16CodeUnits: units, count: units.count)
    }

    /// Finds the UTF-16 location of the `}` matching the `{` at `openBraceLocation`, skipping
    /// escaped characters and `%...\n` comments.
    static func findMatchingCloseBrace(
        in nsString: NSString,
        openBraceLocation: Int,
        fullLength: Int,
        skipComments: Bool = true
    ) -> Int? {
        guard openBraceLocation >= 0,
            openBraceLocation < fullLength,
            nsString.character(at: openBraceLocation) == 0x7B
        else {
            return nil
        }
        var depth = 1
        var idx = openBraceLocation + 1
        while idx < fullLength {
            let ch = nsString.character(at: idx)
            if ch == 0x5C {
                idx += 2
                continue
            }
            if skipComments && ch == 0x25 {
                while idx < fullLength && nsString.character(at: idx) != 0x0A {
                    idx += 1
                }
                continue
            }
            if ch == 0x7B {
                depth += 1
            } else if ch == 0x7D {
                depth -= 1
                if depth == 0 {
                    return idx
                }
            }
            idx += 1
        }
        return nil
    }

    /// Offset in `text` of the `}` that closes the group containing `start`, or `text.length`.
    static func groupEnd(in text: NSString, from start: Int) -> Int {
        var depth = 0
        var idx = start
        while idx < text.length {
            let ch = text.character(at: idx)
            if ch == 0x5C {
                idx += 2
                continue
            }
            if ch == 0x7B {
                depth += 1
            } else if ch == 0x7D {
                if depth == 0 { return idx }
                depth -= 1
            }
            idx += 1
        }
        return text.length
    }

    /// True when every unescaped `{` outside `%` comments has a matching `}` in `text`.
    static func hasBalancedBraces(_ text: String) -> Bool {
        let units = Array(text.utf16)
        var depth = 0
        var idx = 0
        while idx < units.count {
            let ch = units[idx]
            if ch == 0x5C {
                idx += 2
                continue
            }
            if ch == 0x25 {
                while idx < units.count && units[idx] != 0x0A {
                    idx += 1
                }
                continue
            }
            if ch == 0x7B {
                depth += 1
            } else if ch == 0x7D {
                depth -= 1
                if depth < 0 { return false }
            }
            idx += 1
        }
        return depth == 0
    }

    /// Unwraps `\cmd{...}` wrappers in `raw` by stripping each wrapper prefix and its balanced
    /// closing `}` (never an unrelated trailing `}` elsewhere in the string).
    static func unwrapCommandBraces(_ raw: String, commands: [String]) -> String {
        guard raw.contains("\\") else { return raw }
        let chars = Array(raw)
        let commandArrays = commands.map { Array($0) }
        return String(unwrapChars(chars, commandArrays: commandArrays))
    }

    private static func unwrapChars(_ chars: [Character], commandArrays: [[Character]]) -> [Character] {
        var out: [Character] = []
        out.reserveCapacity(chars.count)
        var idx = 0
        while idx < chars.count {
            if chars[idx] == "\\" {
                var matchedPrefixLen: Int?
                for cmd in commandArrays where idx + cmd.count <= chars.count {
                    var matches = true
                    for offset in 0..<cmd.count where chars[idx + offset] != cmd[offset] {
                        matches = false
                        break
                    }
                    if matches {
                        matchedPrefixLen = cmd.count
                        break
                    }
                }
                if let prefixLen = matchedPrefixLen {
                    let openBraceIdx = idx + prefixLen - 1
                    if let closeIdx = matchingCloseBrace(in: chars, openBraceIdx: openBraceIdx) {
                        let inner = Array(chars[(openBraceIdx + 1)..<closeIdx])
                        out.append(contentsOf: unwrapChars(inner, commandArrays: commandArrays))
                        idx = closeIdx + 1
                        continue
                    } else {
                        idx = openBraceIdx + 1
                        continue
                    }
                }
                if idx + 1 < chars.count {
                    out.append(chars[idx])
                    out.append(chars[idx + 1])
                    idx += 2
                    continue
                }
            }
            out.append(chars[idx])
            idx += 1
        }
        return out
    }

    private static func matchingCloseBrace(in chars: [Character], openBraceIdx: Int) -> Int? {
        guard openBraceIdx < chars.count, chars[openBraceIdx] == "{" else { return nil }
        var depth = 1
        var idx = openBraceIdx + 1
        while idx < chars.count {
            if chars[idx] == "\\" {
                idx += 2
                continue
            }
            if chars[idx] == "{" {
                depth += 1
            } else if chars[idx] == "}" {
                depth -= 1
                if depth == 0 {
                    return idx
                }
            }
            idx += 1
        }
        return nil
    }
}
