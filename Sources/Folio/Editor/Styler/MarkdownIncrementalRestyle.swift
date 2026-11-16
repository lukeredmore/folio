import AppKit
import Foundation

package enum MarkdownRestyleOutcome {
    case restyled(MarkdownStyleResult)
    case needsFullRestyle(MarkdownFullRestyleReason)
}

extension MarkdownLiveStyler {
    /// Restyles only the line regions that `edit` and the selection change since `previous` can
    /// affect, and keeps the attributes, decorations, and headings of every other line. The
    /// result equals a full restyle — when that cannot be shown, nothing is kept and the caller
    /// must run `styleDocument`. A failed region check can leave regions restyled, which the full
    /// restyle replaces.
    package static func restyleIncrementally(
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

        let ast = edit == nil ? previous.ast : parseStyleAST(string)
        if edit != nil {
            guard astMatchesOutsideRegions(old: previous.ast, new: ast, plan: plan) else {
                return .needsFullRestyle(.astChangedOutsideRegions)
            }
        }

        let macroState = resolveIncrementalMacros(
            string: string,
            text: text,
            parameters: parameters,
            previous: previous,
            plan: plan,
            edit: edit
        )
        guard macroState.macros == previous.documentMacros else {
            return .needsFullRestyle(.documentMacrosChanged)
        }

        let span = EditorPerfPhase.applyStyles.begin()
        defer { span.end() }
        if edit != nil {
            LaTeXBlockStyleCache.invalidate(for: storage)
        }
        LaTeXMathRenderer.setDocumentMacros(macroState.macros)

        var passes: [MarkdownStylePass] = []
        passes.reserveCapacity(plan.regions.count)
        for region in plan.regions {
            storage.beginEditing()
            let windowUpper = region.newEndLine ?? Int.max
            let pass = MarkdownStylePass(
                storage: storage,
                string: string,
                nsString: text,
                parameters: parameters,
                selectedRange: selectedRange,
                ast: ast,
                lineWindow: region.newStartLine...max(region.newStartLine, windowUpper)
            )
            storage.setAttributes(pass.baseAttributes, range: region.newRange)
            let stop = pass.styleLines(
                from: region.newRange.location,
                lineNumber: region.newStartLine,
                to: NSMaxRange(region.newRange)
            )
            let endedAtCheckpoint =
                region.newEndLine.map { endLine in
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
        let checkpoints = mergeCheckpoints(kept: plan.keptCheckpoints, passes: passes)
        let balancedCheckpoints =
            macroState.recomputeBalance
            ? areBracesBalancedAtCheckpoints(
                in: text,
                checkpoints: checkpoints,
                hasMacroKeywords: macroState.hasMacroKeywords
            )
            : macroState.macrosBalancedAtCheckpoints

        let record = MarkdownStyleRecord(
            text: text,
            parameters: parameters,
            selectedRange: selectedRange,
            ast: ast,
            documentMacros: macroState.macros,
            hasMacroKeywords: macroState.hasMacroKeywords,
            macrosBalancedAtCheckpoints: balancedCheckpoints,
            checkpoints: checkpoints,
            decorations: decorations,
            headings: headings
        )
        return .restyled(
            MarkdownStyleResult(
                analysis: MarkdownDocumentAnalysis(headings: headings, decorations: decorations.all),
                record: record,
                restyledRanges: plan.regions.map(\.newRange)
            ))
    }

    private static func resolveIncrementalMacros(
        string: String,
        text: NSString,
        parameters: MarkdownStyleParameters,
        previous: MarkdownStyleRecord,
        plan: MarkdownRestylePlan,
        edit: MarkdownTextEdit?
    ) -> (
        macros: [String: LaTeXMacroDefinition],
        hasMacroKeywords: Bool,
        macrosBalancedAtCheckpoints: Bool,
        recomputeBalance: Bool
    ) {
        guard edit != nil, !parameters.sourceCodeMode else {
            return (
                previous.documentMacros,
                previous.hasMacroKeywords,
                previous.macrosBalancedAtCheckpoints,
                false
            )
        }

        if !previous.hasMacroKeywords {
            let introducedMacroKeyword = plan.regions.contains { region in
                containsMacroKeywords(in: text, range: region.newRange)
            }
            if !introducedMacroKeyword {
                return ([:], false, true, false)
            }
        } else if previous.macrosBalancedAtCheckpoints {
            let touchedBackslash = plan.regions.contains { region in
                (region.oldRange.length > 0
                    && previous.text.range(of: "\\", options: .literal, range: region.oldRange).location != NSNotFound)
                    || (region.newRange.length > 0
                        && text.range(of: "\\", options: .literal, range: region.newRange).location != NSNotFound)
            }
            if !touchedBackslash {
                return (previous.documentMacros, true, true, false)
            }
        }

        let fullRange = NSRange(location: 0, length: text.length)
        let hasKeywords = containsMacroKeywords(in: text, range: fullRange)
        let macros = hasKeywords ? LaTeXMacroExpander.extractDocumentMacros(from: string) : [:]
        return (macros, hasKeywords, true, hasKeywords)
    }

    /// Previous items outside the regions, moved past the edit, with each region's new items in
    /// its place. Advances a single region cursor in $O(D + R)$ time without heap-filtering per item.
    private static func splice<Item: MarkdownPositioned>(
        _ previous: [Item],
        _ plan: MarkdownRestylePlan,
        _ fresh: [[Item]]
    ) -> [Item] {
        let regions = plan.regions
        let regionCount = regions.count
        let shift = plan.shift
        let freshCount = fresh.reduce(0) { $0 + $1.count }
        var result: [Item] = []
        result.reserveCapacity(previous.count + freshCount)

        var regionCursor = 0
        var emittedFreshUpTo = 0

        for item in previous {
            let location = item.location
            while regionCursor < regionCount && location >= NSMaxRange(regions[regionCursor].oldRange) {
                if emittedFreshUpTo <= regionCursor {
                    result.append(contentsOf: fresh[regionCursor])
                    emittedFreshUpTo = regionCursor + 1
                }
                regionCursor += 1
            }
            if regionCursor < regionCount && NSLocationInRange(location, regions[regionCursor].oldRange) {
                if emittedFreshUpTo <= regionCursor {
                    result.append(contentsOf: fresh[regionCursor])
                    emittedFreshUpTo = regionCursor + 1
                }
                continue
            }
            result.append(shift.map { item.moved(by: $0) } ?? item)
        }

        while emittedFreshUpTo < regionCount {
            result.append(contentsOf: fresh[emittedFreshUpTo])
            emittedFreshUpTo += 1
        }
        return result
    }

    /// Merges sorted `kept` checkpoints and sorted per-region pass checkpoints in $O(C)$ linear order.
    private static func mergeCheckpoints(
        kept: [MarkdownStyleCheckpoint],
        passes: [MarkdownStylePass]
    ) -> [MarkdownStyleCheckpoint] {
        let freshCount = passes.reduce(0) { $0 + $1.checkpoints.count }
        guard freshCount > 0 else { return kept }
        guard !kept.isEmpty else {
            var out: [MarkdownStyleCheckpoint] = []
            out.reserveCapacity(freshCount)
            for pass in passes {
                out.append(contentsOf: pass.checkpoints)
            }
            return out
        }

        var merged: [MarkdownStyleCheckpoint] = []
        merged.reserveCapacity(kept.count + freshCount)
        var keptIdx = 0
        for pass in passes {
            for cp in pass.checkpoints {
                while keptIdx < kept.count && kept[keptIdx].lineRange.location < cp.lineRange.location {
                    merged.append(kept[keptIdx])
                    keptIdx += 1
                }
                merged.append(cp)
            }
        }
        if keptIdx < kept.count {
            merged.append(contentsOf: kept[keptIdx...])
        }
        return merged
    }

    /// Compares the styler-relevant AST projection (`relevantBlocks` and `links`) outside `plan.regions`
    /// in two linear cursors without allocating intermediate arrays or copying AST nodes.
    private static func astMatchesOutsideRegions(
        old oldAST: MarkdownStyleAST,
        new newAST: MarkdownStyleAST,
        plan: MarkdownRestylePlan
    ) -> Bool {
        let shift = plan.shift

        func isOutside(_ start: Int, _ end: Int, old: Bool) -> Bool? {
            for region in plan.regions {
                let first = old ? region.oldStartLine : region.newStartLine
                let last = (old ? region.oldEndLine : region.newEndLine) ?? Int.max
                if start >= first && end < last { return false }
                if !(end < first || start >= last) { return nil }
            }
            return true
        }

        var oldBlockIdx = 0
        var newBlockIdx = 0
        let oldBlocks = oldAST.relevantBlocks
        let newBlocks = newAST.relevantBlocks

        while true {
            while oldBlockIdx < oldBlocks.count {
                let b = oldBlocks[oldBlockIdx]
                guard let outside = isOutside(b.startLine, b.endLine, old: true) else { return false }
                if outside { break }
                oldBlockIdx += 1
            }
            while newBlockIdx < newBlocks.count {
                let b = newBlocks[newBlockIdx]
                guard let outside = isOutside(b.startLine, b.endLine, old: false) else { return false }
                if outside { break }
                newBlockIdx += 1
            }
            if oldBlockIdx == oldBlocks.count && newBlockIdx == newBlocks.count {
                break
            }
            guard oldBlockIdx < oldBlocks.count && newBlockIdx < newBlocks.count else {
                return false
            }
            let ob = oldBlocks[oldBlockIdx]
            let nb = newBlocks[newBlockIdx]
            let move = shift.map { $0.line(ob.startLine) - ob.startLine } ?? 0
            if ob.kind != nb.kind || ob.startLine + move != nb.startLine || ob.endLine + move != nb.endLine {
                return false
            }
            oldBlockIdx += 1
            newBlockIdx += 1
        }

        var oldLinkIdx = 0
        var newLinkIdx = 0
        let oldLinks = oldAST.links
        let newLinks = newAST.links

        while true {
            while oldLinkIdx < oldLinks.count {
                let l = oldLinks[oldLinkIdx]
                guard let outside = isOutside(l.startLine, l.endLine, old: true) else { return false }
                if outside { break }
                oldLinkIdx += 1
            }
            while newLinkIdx < newLinks.count {
                let l = newLinks[newLinkIdx]
                guard let outside = isOutside(l.startLine, l.endLine, old: false) else { return false }
                if outside { break }
                newLinkIdx += 1
            }
            if oldLinkIdx == oldLinks.count && newLinkIdx == newLinks.count {
                break
            }
            guard oldLinkIdx < oldLinks.count && newLinkIdx < newLinks.count else {
                return false
            }
            let ol = oldLinks[oldLinkIdx]
            let nl = newLinks[newLinkIdx]
            let move = shift.map { $0.line(ol.startLine) - ol.startLine } ?? 0
            if ol.kind != nl.kind
                || ol.startLine + move != nl.startLine
                || ol.startColumn != nl.startColumn
                || ol.endLine + move != nl.endLine
                || ol.endColumn != nl.endColumn
                || ol.url != nl.url
                || ol.literal != nl.literal
            {
                return false
            }
            oldLinkIdx += 1
            newLinkIdx += 1
        }

        return true
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
