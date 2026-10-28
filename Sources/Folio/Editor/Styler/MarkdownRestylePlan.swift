import AppKit
import Foundation

/// Why a restyle styled the whole document instead of some line regions.
enum MarkdownFullRestyleReason: String, Sendable {
    case notRequested
    case noRecord
    case settingsChanged
    case sourceCodeMode
    case latexDocument
    case inconsistentEdit
    case blockContextSyntax
    case wholeDocument
    case astChangedOutsideRegions
    case documentMacrosChanged
    case regionDidNotEndAtCheckpoint
}

/// Lines that an incremental restyle redoes, in the text of the last restyle (old) and in the
/// current text (new). A region starts on the first line or after a checkpoint, and ends at a
/// checkpoint or at the end of the text.
struct MarkdownRestyleRegion {
    var oldRange: NSRange
    var newRange: NSRange
    /// One-based number of the first line.
    var oldStartLine: Int
    var newStartLine: Int
    /// One-based number of the checkpoint line after the region; nil at the end of the text.
    var oldEndLine: Int?
    var newEndLine: Int?

    func containsOld(line: Int) -> Bool {
        line >= oldStartLine && line < (oldEndLine ?? Int.max)
    }
}

/// How positions after the edited region moved.
struct MarkdownRestyleShift {
    /// Old positions at or after this one move by `delta`.
    let oldBoundary: Int
    /// Old lines at or after this one, outside the regions, move by `lineDelta`.
    let oldBoundaryLine: Int
    let delta: Int
    let lineDelta: Int

    func position(_ oldPosition: Int) -> Int {
        oldPosition >= oldBoundary ? oldPosition + delta : oldPosition
    }

    func line(_ oldLine: Int) -> Int {
        oldLine >= oldBoundaryLine ? oldLine + lineDelta : oldLine
    }
}

/// The line regions that an edit and a selection change can affect, and how the rest of the
/// document moved. Lines outside the regions keep their styling: they start after a checkpoint,
/// their text did not change, and they are not active in the old or the new selection.
struct MarkdownRestylePlan {
    let regions: [MarkdownRestyleRegion]
    let shift: MarkdownRestyleShift?
    /// Checkpoints outside the regions, in new coordinates.
    let keptCheckpoints: [MarkdownStyleCheckpoint]

    /// The edited lines: the same start in both texts, and the identical text after them.
    private struct LineEdit {
        let start: Int
        let oldEnd: Int
        let newEnd: Int
        let delta: Int
        let lineDelta: Int
    }

    private struct MappedCheckpoint {
        let old: MarkdownStyleCheckpoint
        let new: MarkdownStyleCheckpoint
    }

    static func make(
        previous: MarkdownStyleRecord,
        text: NSString,
        parameters: MarkdownStyleParameters,
        selectedRange: NSRange,
        edit: MarkdownTextEdit?
    ) -> Result<MarkdownRestylePlan, PlanFailure> {
        guard previous.parameters == parameters else { return .failure(PlanFailure(.settingsChanged)) }
        guard !parameters.sourceCodeMode else { return .failure(PlanFailure(.sourceCodeMode)) }
        if LaTeXLiveStyler.isLaTeXOrBibTeXDocument(text as String, fileURL: parameters.fileURL) {
            return .failure(PlanFailure(.latexDocument))
        }
        let lineEdit: LineEdit?
        switch edit.map({ makeLineEdit($0, old: previous.text, new: text) }) {
        case .none:
            guard previous.text.length == text.length else { return .failure(PlanFailure(.inconsistentEdit)) }
            lineEdit = nil
        case .some(.success(let value)):
            lineEdit = value
        case .some(.failure(let failure)):
            return .failure(failure)
        }

        let mapped = previous.checkpoints.compactMap { mapCheckpoint($0, through: lineEdit) }
        var interests = [selectionLines(selectedRange, in: text)]
        interests.append(selectionLines(mapOldRange(previous.selectedRange, through: edit), in: text))
        if let lineEdit {
            interests.append(NSRange(location: lineEdit.start, length: lineEdit.newEnd - lineEdit.start))
        }
        let regions = merged(interests.map { region(around: $0, checkpoints: mapped, old: previous.text, new: text) })
        if regions.count == 1, regions[0].newRange == NSRange(location: 0, length: text.length) {
            return .failure(PlanFailure(.wholeDocument))
        }

        var shift: MarkdownRestyleShift?
        if let lineEdit {
            guard
                let dirty = regions.first(where: {
                    $0.newRange.location <= lineEdit.start && lineEdit.newEnd <= NSMaxRange($0.newRange)
                }), dirty.newRange.length - dirty.oldRange.length == lineEdit.delta
            else {
                return .failure(PlanFailure(.inconsistentEdit))
            }
            shift = MarkdownRestyleShift(
                oldBoundary: NSMaxRange(dirty.oldRange),
                oldBoundaryLine: dirty.oldStartLine,
                delta: lineEdit.delta,
                lineDelta: lineEdit.lineDelta
            )
        }
        let kept = mapped.filter { checkpoint in
            !regions.contains { NSIntersectionRange($0.newRange, checkpoint.new.lineRange).length > 0 }
        }
        return .success(MarkdownRestylePlan(regions: regions, shift: shift, keptCheckpoints: kept.map(\.new)))
    }

    struct PlanFailure: Error {
        let reason: MarkdownFullRestyleReason

        init(_ reason: MarkdownFullRestyleReason) {
            self.reason = reason
        }
    }

    private static func makeLineEdit(_ edit: MarkdownTextEdit, old: NSString, new: NSString) -> Result<LineEdit, PlanFailure> {
        let replaced = edit.replacedRange
        guard old.length + edit.changeInLength == new.length, replaced.length >= 0,
            NSMaxRange(edit.range) <= new.length, NSMaxRange(replaced) <= old.length
        else {
            return .failure(PlanFailure(.inconsistentEdit))
        }
        let oldLines = wholeLines(replaced, in: old)
        let newLines = wholeLines(edit.range, in: new)
        guard oldLines.location == newLines.location,
            old.length - NSMaxRange(oldLines) == new.length - NSMaxRange(newLines)
        else {
            return .failure(PlanFailure(.inconsistentEdit))
        }
        let startsDocument = oldLines.location == 0
        if hasBlockContextSyntax(old.substring(with: oldLines), startsDocument: startsDocument)
            || hasBlockContextSyntax(new.substring(with: newLines), startsDocument: startsDocument)
        {
            return .failure(PlanFailure(.blockContextSyntax))
        }
        return .success(
            LineEdit(
                start: newLines.location,
                oldEnd: NSMaxRange(oldLines),
                newEnd: NSMaxRange(newLines),
                delta: edit.changeInLength,
                lineDelta: lineCount(in: newLines, of: new) - lineCount(in: oldLines, of: old)
            ))
    }

    /// Lines whose effect can reach past a blank line, so an edit that adds, removes, or changes
    /// them can change lines outside the edited block: fence and display math delimiters, raw
    /// SVG, HTML block starts, table delimiter rows, and a front matter delimiter on the first
    /// line. The styler only treats these at the start of a line (raw SVG closes anywhere).
    static func hasBlockContextSyntax(_ text: String, startsDocument: Bool) -> Bool {
        let lower = text.lowercased()
        if lower.contains("<svg") || lower.contains("</svg") {
            return true
        }
        let nsText = text as NSString
        var index = 0
        while index < nsText.length {
            let lineRange = nsText.lineRange(for: NSRange(location: index, length: 0))
            let content = MarkdownLiveStyler.strippedLineContentRange(nsString: nsText, lineRange: lineRange)
            let trimmed = nsText.substring(with: content).trimmingCharacters(in: .whitespaces)
            if ["```", "~~~", "$$", "<"].contains(where: { trimmed.hasPrefix($0) })
                || MarkdownLiveStyler.isTableSeparatorRow(nsString: nsText, contentRange: content)
            {
                return true
            }
            if startsDocument && index == 0 && trimmed.hasPrefix("---") {
                return true
            }
            index = NSMaxRange(lineRange)
        }
        return false
    }

    /// The lines that contain `range` and the line that starts where it ends.
    private static func wholeLines(_ range: NSRange, in text: NSString) -> NSRange {
        let lines = text.lineRange(for: range)
        let end = NSMaxRange(range)
        guard end <= text.length else { return lines }
        return NSUnionRange(lines, text.lineRange(for: NSRange(location: end, length: 0)))
    }

    /// The lines that the selection touches, including the active line.
    private static func selectionLines(_ selection: NSRange, in text: NSString) -> NSRange {
        let start = min(selection.location, text.length)
        let end = min(max(start, NSMaxRange(selection)), text.length)
        return wholeLines(NSRange(location: start, length: end - start), in: text)
    }

    private static func mapOldRange(_ range: NSRange, through edit: MarkdownTextEdit?) -> NSRange {
        guard let edit else { return range }
        let replacedEnd = NSMaxRange(edit.replacedRange)
        func map(_ position: Int, inside: Int) -> Int {
            if position < edit.range.location { return position }
            if position >= replacedEnd { return position + edit.changeInLength }
            return inside
        }
        let start = map(range.location, inside: edit.range.location)
        let end = max(start, map(NSMaxRange(range), inside: NSMaxRange(edit.range)))
        return NSRange(location: start, length: end - start)
    }

    private static func mapCheckpoint(_ checkpoint: MarkdownStyleCheckpoint, through edit: LineEdit?) -> MappedCheckpoint? {
        guard let edit else { return MappedCheckpoint(old: checkpoint, new: checkpoint) }
        if NSMaxRange(checkpoint.lineRange) <= edit.start {
            return MappedCheckpoint(old: checkpoint, new: checkpoint)
        }
        if checkpoint.lineRange.location >= edit.oldEnd {
            return MappedCheckpoint(old: checkpoint, new: checkpoint.shifted(by: edit.delta, lines: edit.lineDelta))
        }
        return nil
    }

    /// From the last checkpoint that ends at or before `lines` to the first one that starts at or
    /// after its end.
    private static func region(
        around lines: NSRange,
        checkpoints: [MappedCheckpoint],
        old: NSString,
        new: NSString
    ) -> MarkdownRestyleRegion {
        let before = checkpoints.last { NSMaxRange($0.new.lineRange) <= lines.location }
        let after = checkpoints.first { $0.new.lineRange.location >= NSMaxRange(lines) }
        let oldStart = before.map { NSMaxRange($0.old.lineRange) } ?? 0
        let newStart = before.map { NSMaxRange($0.new.lineRange) } ?? 0
        let oldEnd = after?.old.lineRange.location ?? old.length
        let newEnd = after?.new.lineRange.location ?? new.length
        return MarkdownRestyleRegion(
            oldRange: NSRange(location: oldStart, length: oldEnd - oldStart),
            newRange: NSRange(location: newStart, length: newEnd - newStart),
            oldStartLine: before.map { $0.old.lineNumber + 1 } ?? 1,
            newStartLine: before.map { $0.new.lineNumber + 1 } ?? 1,
            oldEndLine: after?.old.lineNumber,
            newEndLine: after?.new.lineNumber
        )
    }

    private static func merged(_ regions: [MarkdownRestyleRegion]) -> [MarkdownRestyleRegion] {
        var result: [MarkdownRestyleRegion] = []
        for region in regions.sorted(by: { $0.newRange.location < $1.newRange.location }) {
            guard var last = result.last,
                region.newRange.location < NSMaxRange(last.newRange)
                    || region.newRange == last.newRange
            else {
                result.append(region)
                continue
            }
            if NSMaxRange(region.newRange) > NSMaxRange(last.newRange) {
                last.newRange = NSUnionRange(last.newRange, region.newRange)
                last.oldRange = NSUnionRange(last.oldRange, region.oldRange)
                last.newEndLine = region.newEndLine
                last.oldEndLine = region.oldEndLine
            }
            result[result.count - 1] = last
        }
        return result
    }

    /// Number of lines in `range`, which starts at a line start, as the styler's line loop counts them.
    static func lineCount(in range: NSRange, of text: NSString) -> Int {
        var count = 0
        var index = range.location
        while index < NSMaxRange(range) {
            index = NSMaxRange(text.lineRange(for: NSRange(location: index, length: 0)))
            count += 1
        }
        return count
    }
}
