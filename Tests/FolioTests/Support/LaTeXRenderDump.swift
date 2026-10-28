import AppKit
@testable import Folio

/// Text form of what a styled LaTeX document shows, for golden tests. Each line lists the
/// visible characters, skipping collapsed or clear syntax. Runs with font traits are written
/// `‹traits:text›` (b bold, i italic, tt monospace, u underline, sub, sup). Inline decorations
/// that replace hidden source are written `⟦...⟧`, with `$...$` for math and `⏎` between lines.
/// A line that joins the next one, because its line break is drawn as a space or not at all,
/// ends in ` ↩`.
enum LaTeXRenderDump {
    static func dump(_ storage: NSTextStorage, decorations: [LineDecoration]) -> String {
        let ns = storage.string as NSString
        var inline: [Int: (range: NSRange, text: String)] = [:]
        var blocks: [String] = []
        for decoration in decorations {
            if let described = describeInline(decoration.kind) {
                inline[described.range.location] = described
            } else if let name = blockName(decoration.kind) {
                let line = ns.substring(to: min(decoration.lineRange.location, ns.length)).components(separatedBy: "\n").count
                blocks.append("line \(line): \(name)")
            }
        }
        var out = ""
        var lineNumber = 1
        var idx = 0
        while idx < ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: idx, length: 0))
            let newline = NSMaxRange(lineRange) - 1
            let joinsNext =
                newline < ns.length && ns.character(at: newline) == 0x0A
                && storage.attribute(MarkdownLiveStyler.softLineBreakAttributeKey, at: newline, effectiveRange: nil) != nil
            out += String(format: "%03d| ", lineNumber) + visibleText(storage, ns: ns, lineRange: lineRange, inline: inline) + (joinsNext ? " ↩" : "") + "\n"
            idx = NSMaxRange(lineRange)
            lineNumber += 1
        }
        out += blocks.isEmpty ? "" : "blocks:\n" + blocks.map { "  \($0)\n" }.joined()
        return out
    }

    private static func visibleText(
        _ storage: NSTextStorage,
        ns: NSString,
        lineRange: NSRange,
        inline: [Int: (range: NSRange, text: String)]
    ) -> String {
        var pieces: [String] = []
        var run = ""
        var runTags = ""
        func flush() {
            guard !run.isEmpty else { return }
            pieces.append(runTags.isEmpty ? run : "‹\(runTags):\(run)›")
            run = ""
        }
        var i = lineRange.location
        let end = NSMaxRange(lineRange) - (ns.substring(with: lineRange).hasSuffix("\n") ? 1 : 0)
        while i < end {
            if let decoration = inline[i] {
                flush()
                pieces.append("⟦\(decoration.text)⟧")
                i = max(i + 1, NSMaxRange(decoration.range))
                continue
            }
            let attrs = storage.attributes(at: i, effectiveRange: nil)
            if isHidden(attrs) {
                i += 1
                continue
            }
            let tags = fontTags(attrs[.font] as? NSFont, underline: (attrs[.underlineStyle] as? Int ?? 0) != 0)
            if tags != runTags {
                flush()
                runTags = tags
            }
            run += ns.substring(with: NSRange(location: i, length: 1))
            i += 1
        }
        flush()
        return pieces.joined()
    }

    private static func isHidden(_ attrs: [NSAttributedString.Key: Any]) -> Bool {
        if attrs[MarkdownLiveStyler.collapsedTokenAttributeKey] as? Bool == true { return true }
        if let color = attrs[.foregroundColor] as? NSColor, color.alphaComponent == 0 { return true }
        if let font = attrs[.font] as? NSFont, font.pointSize < 3 { return true }
        return false
    }

    private static func fontTags(_ font: NSFont?, underline: Bool, offset: CGFloat = 0) -> String {
        var tags: [String] = []
        if let font {
            let traits = NSFontManager.shared.traits(of: font)
            if traits.contains(.boldFontMask) { tags.append("b") }
            if traits.contains(.italicFontMask) { tags.append("i") }
            if font.isFixedPitch { tags.append("tt") }
        }
        if underline { tags.append("u") }
        if offset < 0 { tags.append("sub") }
        if offset > 0 { tags.append("sup") }
        return tags.joined(separator: "+")
    }

    private static func describeInline(_ kind: BlockDecorationKind) -> (range: NSRange, text: String)? {
        switch kind {
        case let .latexInlineRichText(lines, range, _):
            let text = lines.map { runs in
                runs.map { run -> String in
                    switch run {
                    case let .text(text, font, underline, offset):
                        let tags = fontTags(font, underline: underline, offset: offset)
                        return tags.isEmpty ? text : "‹\(tags):\(text)›"
                    case let .math(latex, _, offset):
                        return offset == 0 ? "$\(latex)$" : "‹\(offset < 0 ? "sub" : "sup"):$\(latex)$›"
                    }
                }.joined()
            }.joined(separator: "⏎")
            return (range, text)
        case let .latexInlineText(text, _, range, _):
            return (range, text)
        case let .inlineMathRendered(latex, range, _, _):
            return (range, "$\(latex)$")
        case let .latexInlinePill(label, _, _, _, range, _, _, _):
            return (range, "[\(label)]")
        default:
            return nil
        }
    }

    private static func blockName(_ kind: BlockDecorationKind) -> String? {
        switch kind {
        case let .latexSectionBadge(number, level, _, _): return "section badge \(number) level \(level)"
        case let .headingUnderline(level): return "heading underline level \(level)"
        case let .latexPreambleCard(title, _, _, _): return "preamble card \(title)"
        case let .latexInputCard(path, _, _, _): return "input card \(path)"
        case .horizontalRule: return "horizontal rule"
        default: return nil
        }
    }
}
