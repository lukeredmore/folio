import AppKit
import Foundation

enum MarkdownRestyleOutcome {
    case restyled(MarkdownStyleResult)
    case needsFullRestyle(MarkdownFullRestyleReason)
}

extension MarkdownLiveStyler {
    /// Restyles only the line regions that `edit` and the selection change since `previous` can
    /// affect, and keeps the attributes, decorations, and headings of every other line. The
    /// result equals a full restyle; when that cannot be shown, nothing is kept and the caller
    /// must run `styleDocument`. A failed region check can leave regions restyled, which the full
    /// restyle replaces.
    static func restyleIncrementally(
        _ storage: NSTextStorage,
        parameters: MarkdownStyleParameters,
        selectedRange: NSRange,
        previous: MarkdownStyleRecord,
        edit: MarkdownTextEdit?
    ) -> MarkdownRestyleOutcome {
        let string = storage.string
        let text = string as NSString
        let plan: MarkdownRestylePlan
        switch MarkdownRestylePlan.make(
            previous: previous, text: text, parameters: parameters, selectedRange: selectedRange, edit: edit
        ) {
        case .success(let value): plan = value
        case .failure(let failure): return .needsFullRestyle(failure.reason)
        }
        // Without an edit the AST is the same, so only the selection moved.
        let ast = edit == nil ? previous.ast : parseStyleAST(string)
        if edit != nil {
            guard let oldOutside = MarkdownASTProjection(previous.ast).outsideRegions(plan, old: true),
                  let newOutside = MarkdownASTProjection(ast).outsideRegions(plan, old: false),
                  oldOutside == newOutside else {
                return .needsFullRestyle(.astChangedOutsideRegions)
            }
        }
        let documentMacros = edit == nil
            ? previous.documentMacros
            : documentMacros(in: string, sourceCodeMode: parameters.sourceCodeMode)
        guard documentMacros == previous.documentMacros else { return .needsFullRestyle(.documentMacrosChanged) }

        let span = EditorPerfPhase.applyStyles.begin()
        defer { span.end() }
        LaTeXBlockStyleCache.invalidate()
        LaTeXMathRenderer.setDocumentMacros(documentMacros)
        var passes: [MarkdownStylePass] = []
        for region in plan.regions {
            // One editing session per region, so layout and the edited range cover only the region.
            storage.beginEditing()
            let pass = MarkdownStylePass(storage: storage, parameters: parameters, selectedRange: selectedRange, ast: ast)
            storage.setAttributes(pass.baseAttributes, range: region.newRange)
            let stop = pass.styleLines(from: region.newRange.location, lineNumber: region.newStartLine, to: NSMaxRange(region.newRange))
            let endedAtCheckpoint = region.newEndLine.map { endLine in
                stop.index == NSMaxRange(region.newRange) && stop.lineNumber == endLine && !stop.inCodeFence
            } ?? true
            if endedAtCheckpoint {
                pass.finish()
            }
            storage.endEditing()
            guard endedAtCheckpoint else { return .needsFullRestyle(.regionDidNotEndAtCheckpoint) }
            passes.append(pass)
        }

        let decorations = MarkdownDecorationPhases(
            lines: splice(previous.decorations.lines, plan, passes.map(\.decorations.lines)),
            deferredInline: splice(previous.decorations.deferredInline, plan, passes.map(\.decorations.deferredInline)),
            links: splice(previous.decorations.links, plan, passes.map(\.decorations.links))
        )
        let headings = splice(previous.headings, plan, passes.map(\.headings))
        let checkpoints = (plan.keptCheckpoints + passes.flatMap(\.checkpoints))
            .sorted { $0.lineRange.location < $1.lineRange.location }
        let record = MarkdownStyleRecord(
            text: text,
            parameters: parameters,
            selectedRange: selectedRange,
            ast: ast,
            documentMacros: documentMacros,
            checkpoints: checkpoints,
            decorations: decorations,
            headings: headings
        )
        return .restyled(MarkdownStyleResult(
            analysis: MarkdownDocumentAnalysis(headings: headings, decorations: decorations.all),
            record: record,
            restyledRanges: plan.regions.map(\.newRange)
        ))
    }

    /// Previous items outside the regions, moved past the edit, with each region's new items in
    /// its place. Items are in document order, so region order keeps document order.
    private static func splice<Item: MarkdownPositioned>(
        _ previous: [Item],
        _ plan: MarkdownRestylePlan,
        _ fresh: [[Item]]
    ) -> [Item] {
        var segments = Array(repeating: [Item](), count: plan.regions.count + 1)
        for item in previous {
            let location = item.location
            if plan.regions.contains(where: { NSLocationInRange(location, $0.oldRange) }) {
                continue
            }
            let segment = plan.regions.filter { $0.oldRange.location <= location }.count
            segments[segment].append(plan.shift.map { item.moved(by: $0) } ?? item)
        }
        var result: [Item] = []
        result.reserveCapacity(previous.count)
        for index in plan.regions.indices {
            result += segments[index]
            result += fresh[index]
        }
        return result + segments[plan.regions.count]
    }
}

/// An item whose place in the document is one character location.
protocol MarkdownPositioned {
    var location: Int { get }
    func moved(by shift: MarkdownRestyleShift) -> Self
}

extension LineDecoration: MarkdownPositioned {
    var location: Int { lineRange.location }

    func moved(by shift: MarkdownRestyleShift) -> LineDecoration {
        location >= shift.oldBoundary ? shifted(by: shift.delta) : self
    }
}

extension OutlineHeading: MarkdownPositioned {
    var location: Int { characterLocation }

    func moved(by shift: MarkdownRestyleShift) -> OutlineHeading {
        location >= shift.oldBoundary ? shifted(by: shift.delta, lines: shift.lineDelta) : self
    }
}

/// The parts of the cmark AST that the styler reads: indented code blocks, paragraphs that span
/// lines, and links and images. Two parses that agree on these outside the restyled regions
/// style those lines the same way.
struct MarkdownASTProjection {
    struct Block: Equatable {
        let kind: UInt32
        let startLine: Int
        let endLine: Int
    }

    let blocks: [Block]
    let links: [CmarkAstInline]

    init(_ ast: MarkdownStyleAST) {
        blocks = ast.blocks.compactMap { block in
            let isIndentedCode = block.kind == 2 && (block.flags & 1) == 0 && block.endLine >= block.startLine
            let isMultiLineParagraph = block.kind == 8 && block.endLine > block.startLine
            guard block.startLine > 0, isIndentedCode || isMultiLineParagraph else { return nil }
            return Block(kind: block.kind, startLine: block.startLine, endLine: block.endLine)
        }
        links = ast.inlines.filter { ($0.kind == 5 || $0.kind == 6) && $0.endLine >= $0.startLine && $0.startLine > 0 }
    }

    struct Outside: Equatable {
        var blocks: [Block] = []
        var links: [CmarkAstInline] = []
    }

    /// Elements outside the regions, in new line numbers. Nil when an element crosses a region
    /// boundary, because then the region does not hold all lines that depend on the element.
    func outsideRegions(_ plan: MarkdownRestylePlan, old: Bool) -> Outside? {
        var outside = Outside()
        let shift = old ? plan.shift : nil
        for block in blocks {
            guard let isOutside = isOutside(block.startLine, block.endLine, plan, old: old) else { return nil }
            guard isOutside else { continue }
            let move = shift.map { $0.line(block.startLine) - block.startLine } ?? 0
            outside.blocks.append(Block(kind: block.kind, startLine: block.startLine + move, endLine: block.endLine + move))
        }
        for link in links {
            guard let isOutside = isOutside(link.startLine, link.endLine, plan, old: old) else { return nil }
            guard isOutside else { continue }
            let move = shift.map { $0.line(link.startLine) - link.startLine } ?? 0
            outside.links.append(CmarkAstInline(
                kind: link.kind, startLine: link.startLine + move, startColumn: link.startColumn,
                endLine: link.endLine + move, endColumn: link.endColumn, url: link.url, literal: link.literal
            ))
        }
        return outside
    }

    /// True outside every region, false inside one, nil across a region boundary.
    private func isOutside(_ start: Int, _ end: Int, _ plan: MarkdownRestylePlan, old: Bool) -> Bool? {
        for region in plan.regions {
            let first = old ? region.oldStartLine : region.newStartLine
            let last = (old ? region.oldEndLine : region.newEndLine) ?? Int.max
            if start >= first && end < last { return false }
            if !(end < first || start >= last) { return nil }
        }
        return true
    }
}
