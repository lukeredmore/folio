import AppKit
import Foundation

/// What a Markdown restyle produced. The editor keeps the latest record, so the next restyle can
/// redo only the lines that an edit or a selection change can affect.
struct MarkdownStyleRecord {
    /// The text that was styled.
    let text: NSString
    let parameters: MarkdownStyleParameters
    let selectedRange: NSRange
    let ast: MarkdownStyleAST
    let documentMacros: [String: LaTeXMacroDefinition]
    /// Sorted by location.
    let checkpoints: [MarkdownStyleCheckpoint]
    let decorations: MarkdownDecorationPhases
    let headings: [OutlineHeading]
}

struct MarkdownStyleResult {
    let analysis: MarkdownDocumentAnalysis
    /// Nil when the next restyle must be a full one: LaTeX documents, source mode, empty text.
    let record: MarkdownStyleRecord?
    /// Character ranges whose attributes the restyle replaced.
    let restyledRanges: [NSRange]
}

/// The characters replaced since the last restyle, as one range.
struct MarkdownTextEdit: Equatable {
    /// The changed characters in the current text.
    private(set) var range: NSRange
    /// Current text length minus the text length at the last restyle.
    private(set) var changeInLength: Int

    init(range: NSRange, changeInLength: Int) {
        self.range = range
        self.changeInLength = changeInLength
    }

    /// The range of the text at the last restyle that `range` replaced.
    var replacedRange: NSRange {
        NSRange(location: range.location, length: range.length - changeInLength)
    }

    /// Adds a later edit that replaced `editedRange.length - delta` characters at
    /// `editedRange.location` with the `editedRange.length` characters now there.
    mutating func merge(editedRange: NSRange, changeInLength delta: Int) {
        let replacedEnd = NSMaxRange(editedRange) - delta
        let start = min(range.location, editedRange.location)
        var end = NSMaxRange(range)
        if end > editedRange.location {
            end = end >= replacedEnd ? end + delta : NSMaxRange(editedRange)
        }
        end = max(end, NSMaxRange(editedRange))
        range = NSRange(location: start, length: end - start)
        changeInLength += delta
    }
}

extension LineDecoration {
    /// The same decoration `delta` characters later in the text.
    func shifted(by delta: Int) -> LineDecoration {
        guard delta != 0 else { return self }
        return LineDecoration(lineRange: lineRange.shifted(by: delta), kind: kind.shifted(by: delta))
    }
}

extension BlockDecorationKind {
    /// The same decoration with every range it stores moved `delta` characters later.
    func shifted(by delta: Int) -> BlockDecorationKind {
        switch self {
        case .headingUnderline, .blockquote, .codeFenceStart, .codeFenceBody, .codeFenceEnd,
            .mathBlockStart, .mathBlockBody, .mathBlockEnd, .horizontalRule, .tableRow:
            return self
        case let .mathBlockRendered(latex, range, dim):
            return .mathBlockRendered(latex: latex, fullBlockRange: range.shifted(by: delta), dimFactor: dim)
        case let .mermaidBlockRendered(source, range, dim):
            return .mermaidBlockRendered(mermaidSource: source, fullBlockRange: range.shifted(by: delta), dimFactor: dim)
        case let .svgBlockRendered(source, range, dim):
            return .svgBlockRendered(svgSource: source, fullBlockRange: range.shifted(by: delta), dimFactor: dim)
        case let .imageRendered(url, alt, range, width, height, baseURL, dim):
            return .imageRendered(
                url: url, alt: alt, fullRange: range.shifted(by: delta), explicitWidth: width,
                explicitHeight: height, baseDirectoryURL: baseURL, dimFactor: dim
            )
        case let .inlineMathRendered(latex, range, size, dim):
            return .inlineMathRendered(latex: latex, range: range.shifted(by: delta), fontSize: size, dimFactor: dim)
        case let .inlineCode(range, size, dim):
            return .inlineCode(range: range.shifted(by: delta), fontSize: size, dimFactor: dim)
        case let .kbdPill(range, size, dim):
            return .kbdPill(range: range.shifted(by: delta), fontSize: size, dimFactor: dim)
        case let .listBullet(range, dim):
            return .listBullet(range: range.shifted(by: delta), dimFactor: dim)
        case .latexPreambleCard, .latexTheoremCard, .latexAbstractCard, .latexInputCard,
            .latexEquationNumber, .latexSectionBadge, .latexInlinePill, .latexInlineText, .latexInlineRichText:
            return shiftedLaTeXDecoration(by: delta)
        }
    }

    /// LaTeX documents always restyle fully, so these cases only keep `shifted(by:)` total.
    private func shiftedLaTeXDecoration(by delta: Int) -> BlockDecorationKind {
        switch self {
        case let .latexPreambleCard(title, subtitle, range, dim):
            return .latexPreambleCard(title: title, subtitle: subtitle, fullBlockRange: range.shifted(by: delta), dimFactor: dim)
        case let .latexTheoremCard(header, isProof, showHeader, range, dim):
            return .latexTheoremCard(
                header: header, isProof: isProof, showHeader: showHeader,
                fullBlockRange: range.shifted(by: delta), dimFactor: dim
            )
        case let .latexAbstractCard(showHeader, range, dim):
            return .latexAbstractCard(showHeader: showHeader, fullBlockRange: range.shifted(by: delta), dimFactor: dim)
        case let .latexInputCard(path, url, range, dim):
            return .latexInputCard(path: path, resolvedURL: url, lineRange: range.shifted(by: delta), dimFactor: dim)
        case let .latexEquationNumber(number, range, dim):
            return .latexEquationNumber(number: number, fullBlockRange: range.shifted(by: delta), dimFactor: dim)
        case let .latexSectionBadge(number, level, range, dim):
            return .latexSectionBadge(number: number, level: level, lineRange: range.shifted(by: delta), dimFactor: dim)
        case let .latexInlinePill(label, tooltip, target, url, range, size, isCitation, dim):
            return .latexInlinePill(
                label: label, tooltip: tooltip, targetLocation: target, targetURL: url,
                range: range.shifted(by: delta), fontSize: size, isCitation: isCitation, dimFactor: dim
            )
        case let .latexInlineText(text, font, range, dim):
            return .latexInlineText(text: text, font: font, range: range.shifted(by: delta), dimFactor: dim)
        case let .latexInlineRichText(lines, range, dim):
            return .latexInlineRichText(lines: lines, range: range.shifted(by: delta), dimFactor: dim)
        default:
            return self
        }
    }
}

extension OutlineHeading {
    func shifted(by delta: Int, lines lineDelta: Int) -> OutlineHeading {
        guard delta != 0 || lineDelta != 0 else { return self }
        return OutlineHeading(
            level: level,
            title: title,
            characterLocation: characterLocation + delta,
            lineNumber: lineNumber + lineDelta
        )
    }
}

extension MarkdownStyleCheckpoint {
    func shifted(by delta: Int, lines lineDelta: Int) -> MarkdownStyleCheckpoint {
        MarkdownStyleCheckpoint(lineRange: lineRange.shifted(by: delta), lineNumber: lineNumber + lineDelta)
    }
}

extension NSRange {
    func shifted(by delta: Int) -> NSRange {
        NSRange(location: location + delta, length: length)
    }
}
