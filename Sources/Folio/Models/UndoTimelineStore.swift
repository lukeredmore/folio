import Foundation

/// Per-file undo history shared by every open document window.
///
/// All windows persist the same `Folio.PerFileUndoTimelines.v1` dictionary, so they share one
/// in-memory copy. Separate copies would overwrite each other's history on every save.
@MainActor
public final class UndoTimelineStore {
    public var timelines: [String: DocumentUndoTimeline] = [:]
    /// True after the timelines are read from user defaults.
    public var hasLoaded: Bool = false

    public init() {}
}
