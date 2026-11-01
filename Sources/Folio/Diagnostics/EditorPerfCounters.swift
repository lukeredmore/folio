import Foundation

/// Work done by one editor. Tests assert on deltas of these counts, which do not depend on
/// machine speed.
package struct EditorPerfCounters: Equatable, Sendable {
    /// Restyle passes that ran. Re-entrant calls that return early are not counted.
    package var restyleCount = 0
    /// Restyle passes whose attribute edits covered the whole document.
    package var fullRangeRestyleCount = 0
    /// Sum over restyle passes of the characters whose attributes the pass edited, as reported
    /// by `NSTextStorage.editedRange` when the pass ends its editing session.
    package var charactersRestyled = 0
    /// Markdown AST parses (`ot_engine_parse_markdown_ast`) while this editor was in scope.
    package var parseCount = 0
    /// Calls to `HybridMarkdownTextView.draw(_:)`.
    package var drawCount = 0
    /// File-system operations (stat, read, directory listing) for LaTeX project files while this
    /// editor was in scope. Typing must not do any.
    package var latexFileOperationCount = 0
    /// LaTeX blocks that a restyle kept from the previous pass instead of styling them again.
    package var latexBlocksReusedCount = 0
    /// Total time of each signposted phase that ran while this editor was in scope.
    package var phaseNanoseconds: [EditorPerfPhase: UInt64] = [:]

    package init() {}
}

/// Persistence work done by one `EditorWorkspaceViewModel`.
package struct WorkspacePerfCounters: Equatable, Sendable {
    /// Calls to `persistUndoTimelines()` that encoded and stored the undo history.
    package var undoPersistCount = 0
    /// Document writes to disk, from autosave or an explicit save.
    package var autosaveWriteCount = 0

    package init() {}
}
