import Foundation

/// Identifies one document window or tab, and what it opens with when it first appears.
///
/// SwiftUI persists this value for window restoration. Equality uses `id` only, so the
/// initial file and folder never make two windows look like the same window.
public struct DocumentWindowValue: Codable, Hashable, Sendable {
    public let id: UUID
    /// File to open when the window has no saved session of its own.
    public var initialFileURL: URL?
    /// Workspace folder to show when the window has no saved session of its own.
    public var initialWorkspaceURL: URL?

    public init(id: UUID = UUID(), initialFileURL: URL? = nil, initialWorkspaceURL: URL? = nil) {
        self.id = id
        self.initialFileURL = initialFileURL
        self.initialWorkspaceURL = initialWorkspaceURL
    }

    public static func == (lhs: DocumentWindowValue, rhs: DocumentWindowValue) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
