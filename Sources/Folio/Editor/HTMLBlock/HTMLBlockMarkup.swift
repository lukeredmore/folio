import Foundation

/// Classifies CommonMark HTML blocks and prepares their markup for an `HTMLBlockWebView`.
///
/// Offsets are UTF-16 code unit offsets into the block source, the same units as `NSString`
/// and JavaScript strings.
enum HTMLBlockMarkup {

    struct Token: Equatable {
        enum Kind: Equatable {
            case text
            case startTag(name: String, selfClosing: Bool)
            case endTag(name: String)
            case comment
            case rawText
            case declaration
        }

        let kind: Kind
        let range: Range<Int>
    }

    /// First tags of blocks that keep their native rendering: media cards, SVG, folded
    /// `<details>`, and elements that render nothing or need scripts or frames.
    static let nativeFirstTags: Set<String> = [
        "img", "video", "svg", "details", "summary", "br", "script", "style", "link", "meta",
        "base", "title", "template", "noscript", "iframe", "object", "embed", "head", "html", "body"
    ]

    static let voidElements: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param",
        "source", "track", "wbr", "keygen"
    ]

    /// Elements whose end tag the HTML parser can infer.
    static let optionalEndElements: Set<String> = [
        "p", "li", "dt", "dd", "tr", "td", "th", "thead", "tbody", "tfoot", "option", "optgroup",
        "colgroup", "caption", "rt", "rp", "rb", "rtc"
    ]

    /// Elements whose content the parser reads as text up to the matching end tag.
    static let rawTextElements: Set<String> = [
        "script", "style", "textarea", "title", "xmp", "iframe", "noembed", "noframes"
    ]

    /// Elements whose text must not be wrapped in a `<span>`: the parser drops or moves the
    /// span, or the span is not valid in the content model (SVG, MathML, `<select>`).
    static let noWrapElements: Set<String> = [
        "svg", "math", "select", "option", "optgroup", "datalist", "template", "noscript",
        "textarea", "title", "script", "style"
    ]

    /// Elements that drop one newline right after their start tag.
    static let leadingNewlineElements: Set<String> = ["pre", "listing", "textarea"]

    /// True when the block should render in a web view: it starts with a start tag that has no
    /// native rendering, and every element it opens is closed inside the block.
    static func rendersInWebView(_ source: String) -> Bool {
        let units = Array(source.utf16)
        let tokens = tokenize(units)
        guard let first = tokens.first(where: { !($0.kind == .text && isWhitespace(units[$0.range])) }),
            case let .startTag(name, _) = first.kind,
            !nativeFirstTags.contains(name)
        else {
            return false
        }
        return isSelfContained(tokens)
    }

    /// True when no end tag closes an element opened before the block, and every element left
    /// open at the end has an optional end tag.
    static func isSelfContained(_ tokens: [Token]) -> Bool {
        var stack: [String] = []
        for token in tokens {
            switch token.kind {
            case let .startTag(name, selfClosing):
                guard !selfClosing, !voidElements.contains(name) else { continue }
                stack.append(name)
            case let .endTag(name):
                if let index = stack.lastIndex(of: name) {
                    stack.removeSubrange(index...)
                } else if name != "p" && name != "br" {
                    return false
                }
            case .text, .comment, .rawText, .declaration:
                continue
            }
        }
        return stack.allSatisfy { optionalEndElements.contains($0) }
    }

    /// The block markup with each non-blank text run wrapped in
    /// `<span data-fs="start" data-fe="end">`, where the offsets locate the run in `source`.
    static func annotatedMarkup(_ source: String) -> String {
        let units = Array(source.utf16)
        let nsSource = source as NSString
        var out = ""
        out.reserveCapacity(source.utf16.count + source.utf16.count / 2)
        var noWrapStack: [String] = []
        var previousStartTag: String?

        for token in tokenize(units) {
            var range = token.range
            switch token.kind {
            case .text:
                let dropsNewline = previousStartTag.map { leadingNewlineElements.contains($0) } ?? false
                if dropsNewline, let newlineEnd = leadingNewlineEnd(units, range) {
                    out += nsSource.substring(with: NSRange(location: range.lowerBound, length: newlineEnd - range.lowerBound))
                    range = newlineEnd..<range.upperBound
                }
                let piece = nsSource.substring(with: NSRange(location: range.lowerBound, length: range.count))
                if noWrapStack.isEmpty && !range.isEmpty && !isWhitespace(units[range]) {
                    out += "<span data-fs=\"\(range.lowerBound)\" data-fe=\"\(range.upperBound)\">\(piece)</span>"
                } else {
                    out += piece
                }
            case let .startTag(name, selfClosing):
                out += nsSource.substring(with: NSRange(location: range.lowerBound, length: range.count))
                if !selfClosing && noWrapElements.contains(name) {
                    noWrapStack.append(name)
                }
            case let .endTag(name):
                out += nsSource.substring(with: NSRange(location: range.lowerBound, length: range.count))
                if let index = noWrapStack.lastIndex(of: name) {
                    noWrapStack.removeSubrange(index...)
                }
            case .comment, .rawText, .declaration:
                out += nsSource.substring(with: NSRange(location: range.lowerBound, length: range.count))
            }
            if case let .startTag(name, _) = token.kind {
                previousStartTag = name
            } else {
                previousStartTag = nil
            }
        }
        return out
    }

    // MARK: - Tokenizer

    static func tokenize(_ units: [UInt16]) -> [Token] {
        var tokens: [Token] = []
        var index = 0
        var textStart = 0
        let count = units.count

        func flushText(upTo end: Int) {
            if end > textStart {
                tokens.append(Token(kind: .text, range: textStart..<end))
            }
        }

        while index < count {
            guard units[index] == lessThan, let markup = scanMarkup(units, at: index) else {
                index += 1
                continue
            }
            flushText(upTo: index)
            tokens.append(markup)
            index = markup.range.upperBound
            if case let .startTag(name, selfClosing) = markup.kind, !selfClosing, rawTextElements.contains(name) {
                let close = findEndTag(units, name: name, from: index) ?? count
                if close > index {
                    tokens.append(Token(kind: .rawText, range: index..<close))
                }
                index = close
            }
            textStart = index
        }
        flushText(upTo: count)
        return tokens
    }

    private static let lessThan: UInt16 = 0x3C
    private static let greaterThan: UInt16 = 0x3E
    private static let slash: UInt16 = 0x2F
    private static let bang: UInt16 = 0x21
    private static let question: UInt16 = 0x3F
    private static let dash: UInt16 = 0x2D
    private static let doubleQuote: UInt16 = 0x22
    private static let singleQuote: UInt16 = 0x27
    private static let newline: UInt16 = 0x0A
    private static let carriageReturn: UInt16 = 0x0D

    private static func isASCIILetter(_ unit: UInt16) -> Bool {
        (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A)
    }

    private static func isTagNameUnit(_ unit: UInt16) -> Bool {
        isASCIILetter(unit) || (unit >= 0x30 && unit <= 0x39) || unit == dash || unit == 0x3A || unit == 0x5F
    }

    static func isWhitespace(_ units: ArraySlice<UInt16>) -> Bool {
        units.allSatisfy { $0 == 0x20 || $0 == 0x09 || $0 == newline || $0 == carriageReturn || $0 == 0x0C }
    }

    private static func leadingNewlineEnd(_ units: [UInt16], _ range: Range<Int>) -> Int? {
        guard let first = range.first else { return nil }
        if units[first] == newline { return first + 1 }
        if units[first] == carriageReturn {
            return first + 1 < range.upperBound && units[first + 1] == newline ? first + 2 : first + 1
        }
        return nil
    }

    private static func indexOf(_ units: [UInt16], _ unit: UInt16, from start: Int) -> Int? {
        var index = start
        while index < units.count {
            if units[index] == unit { return index }
            index += 1
        }
        return nil
    }

    private static func lowercasedName(_ units: [UInt16], _ range: Range<Int>) -> String {
        String(decoding: units[range], as: UTF16.self).lowercased()
    }

    /// The comment, declaration, start tag, or end tag at `start`, or nil when the `<` is text.
    private static func scanMarkup(_ units: [UInt16], at start: Int) -> Token? {
        let count = units.count
        guard start + 1 < count else { return nil }
        let next = units[start + 1]

        if next == bang, start + 3 < count, units[start + 2] == dash, units[start + 3] == dash {
            var index = start + 4
            while index + 2 < count {
                if units[index] == dash && units[index + 1] == dash && units[index + 2] == greaterThan {
                    return Token(kind: .comment, range: start..<(index + 3))
                }
                index += 1
            }
            return Token(kind: .comment, range: start..<count)
        }
        if next == bang || next == question {
            let end = indexOf(units, greaterThan, from: start + 2).map { $0 + 1 } ?? count
            return Token(kind: .declaration, range: start..<end)
        }
        if next == slash {
            guard start + 2 < count, isASCIILetter(units[start + 2]) else { return nil }
            var nameEnd = start + 2
            while nameEnd < count && isTagNameUnit(units[nameEnd]) { nameEnd += 1 }
            guard let close = indexOf(units, greaterThan, from: nameEnd) else { return nil }
            return Token(kind: .endTag(name: lowercasedName(units, (start + 2)..<nameEnd)), range: start..<(close + 1))
        }
        guard isASCIILetter(next) else { return nil }
        var nameEnd = start + 1
        while nameEnd < count && isTagNameUnit(units[nameEnd]) { nameEnd += 1 }
        var index = nameEnd
        var quote: UInt16?
        while index < count {
            let unit = units[index]
            if let open = quote {
                if unit == open { quote = nil }
            } else if unit == doubleQuote || unit == singleQuote {
                quote = unit
            } else if unit == greaterThan {
                let selfClosing = index > nameEnd && units[index - 1] == slash
                let name = lowercasedName(units, (start + 1)..<nameEnd)
                return Token(kind: .startTag(name: name, selfClosing: selfClosing), range: start..<(index + 1))
            }
            index += 1
        }
        return nil
    }

    /// Index of the `<` of `</name` at or after `start`, matched without case.
    private static func findEndTag(_ units: [UInt16], name: String, from start: Int) -> Int? {
        let nameUnits = Array(name.utf16)
        var index = start
        while index + 2 + nameUnits.count <= units.count {
            if units[index] == lessThan, units[index + 1] == slash {
                var matches = true
                var offset = 0
                while matches && offset < nameUnits.count {
                    let unit = units[index + 2 + offset]
                    let lower = (unit >= 0x41 && unit <= 0x5A) ? unit + 0x20 : unit
                    matches = lower == nameUnits[offset]
                    offset += 1
                }
                let after = index + 2 + nameUnits.count
                if matches && (after >= units.count || !isTagNameUnit(units[after])) {
                    return index
                }
            }
            index += 1
        }
        return nil
    }
}
