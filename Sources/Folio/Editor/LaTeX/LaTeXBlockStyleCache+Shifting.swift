import AppKit
import Foundation

extension LaTeXBlockStyleCache {
    /// `dec` with a reference target after the edit moved to the new text.
    static func shiftReferenceTarget(_ dec: LineDecoration, diff: DiffWindow) -> LineDecoration {
        guard case let .latexInlinePill(label, tooltip, target?, targetURL, range, fontSize, false, dimFactor) = dec.kind,
            let moved = diff.newLocation(ofOld: target), moved != target
        else { return dec }
        let kind = BlockDecorationKind.latexInlinePill(
            label: label, tooltip: tooltip, targetLocation: moved, targetURL: targetURL, range: range, fontSize: fontSize, isCitation: false,
            dimFactor: dimFactor)
        return LineDecoration(lineRange: dec.lineRange, kind: kind)
    }

    static func shiftRange(_ r: NSRange, by delta: Int) -> NSRange {
        guard r.location != NSNotFound else { return r }
        return NSRange(location: r.location + delta, length: r.length)
    }

    static func shiftDecoration(_ dec: LineDecoration, by delta: Int, editLocation: Int) -> LineDecoration {
        guard delta != 0 else { return dec }
        let newLineRange = shiftRange(dec.lineRange, by: delta)
        let newKind: BlockDecorationKind
        switch dec.kind {
        case .headingUnderline, .blockquote, .codeFenceStart, .codeFenceBody, .codeFenceEnd,
            .mathBlockStart, .mathBlockBody, .mathBlockEnd, .horizontalRule, .tableRow:
            newKind = dec.kind
        case let .mathBlockRendered(latex, fullBlockRange, dimFactor):
            newKind = .mathBlockRendered(latex: latex, fullBlockRange: shiftRange(fullBlockRange, by: delta), dimFactor: dimFactor)
        case let .mermaidBlockRendered(source, fullBlockRange, dimFactor):
            newKind = .mermaidBlockRendered(mermaidSource: source, fullBlockRange: shiftRange(fullBlockRange, by: delta), dimFactor: dimFactor)
        case let .svgBlockRendered(source, fullBlockRange, dimFactor):
            newKind = .svgBlockRendered(svgSource: source, fullBlockRange: shiftRange(fullBlockRange, by: delta), dimFactor: dimFactor)
        case let .htmlBlockRendered(source, fullBlockRange, width, dimFactor):
            newKind = .htmlBlockRendered(
                htmlSource: source, fullBlockRange: shiftRange(fullBlockRange, by: delta), layoutWidth: width, dimFactor: dimFactor)
        case let .imageRendered(url, alt, fullRange, ew, eh, baseDir, dimFactor):
            newKind = .imageRendered(
                url: url, alt: alt, fullRange: shiftRange(fullRange, by: delta), explicitWidth: ew, explicitHeight: eh, baseDirectoryURL: baseDir,
                dimFactor: dimFactor)
        case let .inlineMathRendered(latex, range, fontSize, dimFactor):
            newKind = .inlineMathRendered(latex: latex, range: shiftRange(range, by: delta), fontSize: fontSize, dimFactor: dimFactor)
        case let .inlineCode(range, fontSize, dimFactor):
            newKind = .inlineCode(range: shiftRange(range, by: delta), fontSize: fontSize, dimFactor: dimFactor)
        case let .kbdPill(range, fontSize, dimFactor):
            newKind = .kbdPill(range: shiftRange(range, by: delta), fontSize: fontSize, dimFactor: dimFactor)
        case let .listBullet(range, dimFactor):
            newKind = .listBullet(range: shiftRange(range, by: delta), dimFactor: dimFactor)
        case let .latexPreambleCard(title, subtitle, fullBlockRange, dimFactor):
            newKind = .latexPreambleCard(title: title, subtitle: subtitle, fullBlockRange: shiftRange(fullBlockRange, by: delta), dimFactor: dimFactor)
        case let .latexTheoremCard(header, isProof, showHeader, fullBlockRange, dimFactor):
            newKind = .latexTheoremCard(
                header: header, isProof: isProof, showHeader: showHeader, fullBlockRange: shiftRange(fullBlockRange, by: delta), dimFactor: dimFactor)
        case let .latexAbstractCard(showHeader, fullBlockRange, dimFactor):
            newKind = .latexAbstractCard(showHeader: showHeader, fullBlockRange: shiftRange(fullBlockRange, by: delta), dimFactor: dimFactor)
        case let .latexInputCard(path, resolvedURL, lineRange, dimFactor):
            newKind = .latexInputCard(path: path, resolvedURL: resolvedURL, lineRange: shiftRange(lineRange, by: delta), dimFactor: dimFactor)
        case let .latexEquationNumber(number, fullBlockRange, dimFactor):
            newKind = .latexEquationNumber(number: number, fullBlockRange: shiftRange(fullBlockRange, by: delta), dimFactor: dimFactor)
        case let .latexSectionBadge(number, level, lineRange, dimFactor):
            newKind = .latexSectionBadge(number: number, level: level, lineRange: shiftRange(lineRange, by: delta), dimFactor: dimFactor)
        case let .latexInlinePill(label, tooltip, targetLoc, targetURL, range, fontSize, isCitation, dimFactor):
            // A citation target is a location in a bibliography file.
            let shiftedTarget = isCitation ? targetLoc : targetLoc.map { $0 >= editLocation ? $0 + delta : $0 }
            newKind = .latexInlinePill(
                label: label, tooltip: tooltip, targetLocation: shiftedTarget, targetURL: targetURL, range: shiftRange(range, by: delta), fontSize: fontSize,
                isCitation: isCitation, dimFactor: dimFactor)
        case let .latexInlineText(text, font, range, dimFactor):
            newKind = .latexInlineText(text: text, font: font, range: shiftRange(range, by: delta), dimFactor: dimFactor)
        case let .latexInlineRichText(lines, range, dimFactor):
            newKind = .latexInlineRichText(lines: lines, range: shiftRange(range, by: delta), dimFactor: dimFactor)
        }
        return LineDecoration(lineRange: newLineRange, kind: newKind)
    }
}
