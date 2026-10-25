import Foundation
import FolioEngineFFI

public struct OutlineHeading: Identifiable, Equatable, Sendable {
    public let id: String
    public let level: Int
    public let title: String
    public let characterLocation: Int
    public let lineNumber: Int

    public init(level: Int, title: String, characterLocation: Int, lineNumber: Int) {
        self.id = "\(lineNumber)-\(characterLocation)-\(title)"
        self.level = level
        self.title = title
        self.characterLocation = characterLocation
        self.lineNumber = lineNumber
    }
}

public struct DocumentStats: Equatable, Sendable {
    public var words: Int = 0
    public var lines: Int = 0
    public var characters: Int = 0
    public var charactersWithoutSpaces: Int = 0
    public var selectedWords: Int = 0
    public var selectedCharacters: Int = 0

    public var readingTimeString: String {
        // Estimate reading time at ~225 words/minute
        let totalSeconds = max(0, Int((Double(words) / 225.0) * 60.0))
        if totalSeconds == 0 {
            return "0 sec"
        } else if totalSeconds < 60 {
            return "< 1 min"
        } else {
            let minutes = Int(ceil(Double(words) / 225.0))
            return "\(minutes) min"
        }
    }

    public static func compute(for text: String, selectedRange: NSRange? = nil) -> DocumentStats {
        let hasSel = (selectedRange != nil && (selectedRange?.length ?? 0) > 0)
        let selLoc = max(0, selectedRange?.location ?? 0)
        let selLen = max(0, selectedRange?.length ?? 0)

        let rawStats = text.withCString { cStr in
            ot_engine_compute_stats(cStr, hasSel, selLoc, selLen)
        }

        return DocumentStats(
            words: Int(rawStats.words),
            lines: Int(rawStats.lines),
            characters: Int(rawStats.characters),
            charactersWithoutSpaces: Int(rawStats.characters_without_spaces),
            selectedWords: Int(rawStats.selected_words),
            selectedCharacters: Int(rawStats.selected_characters)
        )
    }
}

public struct WorkspaceFileNode: Identifiable, Hashable, Sendable {
    public let url: URL
    public let name: String
    public let isDirectory: Bool
    public let modificationDate: Date
    public let creationDate: Date
    public var children: [WorkspaceFileNode]?
    public var remoteMountID: UUID?
    public var isRemoteRoot: Bool
    public var remoteConnectionString: String?
    public var syncStatus: RemoteFileSyncStatus?

    public init(
        url: URL,
        name: String,
        isDirectory: Bool,
        modificationDate: Date,
        creationDate: Date,
        children: [WorkspaceFileNode]?,
        remoteMountID: UUID? = nil,
        isRemoteRoot: Bool = false,
        remoteConnectionString: String? = nil,
        syncStatus: RemoteFileSyncStatus? = nil
    ) {
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.modificationDate = modificationDate
        self.creationDate = creationDate
        self.children = children
        self.remoteMountID = remoteMountID
        self.isRemoteRoot = isRemoteRoot
        self.remoteConnectionString = remoteConnectionString
        self.syncStatus = syncStatus
    }

    public var id: URL { url }

    public var isRemote: Bool { remoteMountID != nil }

    public static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "txt", "textbundle"]
    public static let latexExtensions: Set<String> = ["tex", "sty", "cls", "ltx"]
    public static let bibtexExtensions: Set<String> = ["bib"]

    public var isMarkdownFile: Bool {
        let lowerName = url.lastPathComponent.lowercased()
        if lowerName.hasSuffix(".comments.folio.md") {
            return false
        }
        return Self.markdownExtensions.contains(url.pathExtension.lowercased())
    }

    public var isLaTeXFile: Bool {
        Self.latexExtensions.contains(url.pathExtension.lowercased())
    }

    public var isBibTeXFile: Bool {
        Self.bibtexExtensions.contains(url.pathExtension.lowercased())
    }

    public var isSupportedDocumentFile: Bool {
        isMarkdownFile || isLaTeXFile || isBibTeXFile
    }

    public var iconSystemName: String {
        if isRemoteRoot { return "network" }
        if isLaTeXFile { return "function" }
        if isBibTeXFile { return "book.closed.fill" }
        return isMarkdownFile ? "doc.text.fill" : "doc"
    }
}

public enum FolioDocumentKind: String, Equatable, Sendable {
    case markdown
    case latex
    case bibtex
}

public enum FileSortOrder: String, CaseIterable, Identifiable, Sendable {
    case name = "Name"
    case modificationDate = "Modification Date"
    case creationDate = "Creation Date"

    public var id: String { rawValue }
}

public struct WorkspaceSearchMatch: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let fileURL: URL
    public let fileName: String
    public let lineNumber: Int
    public let lineSnippet: String
    public let matchRangeInFile: NSRange
}

public struct EditorTypographySettings: Equatable, Hashable, Codable, Sendable {
    /// Multiplier applied to the theme's base font size (0.80 ... 1.50)
    public var fontSizeScale: CGFloat = 1.0
    /// Line height multiple applied to body and list paragraphs (1.0 ... 2.0)
    public var lineHeightMultiple: CGFloat = 1.24
    /// Extra line spacing (leading) in points between lines in a paragraph (0 ... 18)
    public var lineSpacing: CGFloat = 6.0
    /// Spacing in points after each body paragraph (2 ... 28)
    public var paragraphSpacing: CGFloat = 12.0
    /// Character spacing (kerning/tracking) in points for body text (-0.5 ... 2.5)
    public var characterSpacing: CGFloat = 0.15
    /// Character spacing (kerning/tracking) in points for headings (-0.5 ... 3.0)
    public var headingCharacterSpacing: CGFloat = 0.55
    /// Multiplier for spacing above and below headings (0.6 ... 2.0)
    public var headingSpacingScale: CGFloat = 1.15
    /// Vertical offset in points below heading descenders for H1/H2 underlines (2 ... 16)
    public var headingUnderlineOffset: CGFloat = 8.0
    /// Whether to draw horizontal underlines beneath H1 and H2 headings
    public var showHeadingUnderlines: Bool = true
    /// Maximum readable column width in points (560 ... 1280)
    public var maxColumnWidth: CGFloat = 860.0

    public init(
        fontSizeScale: CGFloat = 1.0,
        lineHeightMultiple: CGFloat = 1.24,
        lineSpacing: CGFloat = 6.0,
        paragraphSpacing: CGFloat = 12.0,
        characterSpacing: CGFloat = 0.15,
        headingCharacterSpacing: CGFloat = 0.55,
        headingSpacingScale: CGFloat = 1.15,
        headingUnderlineOffset: CGFloat = 8.0,
        showHeadingUnderlines: Bool = true,
        maxColumnWidth: CGFloat = 860.0
    ) {
        self.fontSizeScale = fontSizeScale
        self.lineHeightMultiple = lineHeightMultiple
        self.lineSpacing = lineSpacing
        self.paragraphSpacing = paragraphSpacing
        self.characterSpacing = characterSpacing
        self.headingCharacterSpacing = headingCharacterSpacing
        self.headingSpacingScale = headingSpacingScale
        self.headingUnderlineOffset = headingUnderlineOffset
        self.showHeadingUnderlines = showHeadingUnderlines
        self.maxColumnWidth = maxColumnWidth
    }

    public static let `default` = EditorTypographySettings()
}

// MARK: - Infinite Undo & Revision History Models

public enum UndoEntryOrigin: String, Codable, Equatable, Sendable {
    case userTyping = "Typing"
    case formattingAction = "Formatting"
    case findReplace = "Find & Replace"
    case externalUpdate = "External Update"
    case conflictResolution = "Conflict Resolution"
    case programmatic = "Edit"
}

public struct DocumentUndoEntry: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var previousText: String
    public var newText: String
    public var previousSelectedLocation: Int
    public var previousSelectedLength: Int
    public var newSelectedLocation: Int
    public var newSelectedLength: Int
    public var timestamp: Date
    public var origin: UndoEntryOrigin
    public var summary: String

    public init(
        id: UUID = UUID(),
        previousText: String,
        newText: String,
        previousSelectedRange: NSRange = NSRange(location: 0, length: 0),
        newSelectedRange: NSRange = NSRange(location: 0, length: 0),
        timestamp: Date = Date(),
        origin: UndoEntryOrigin = .userTyping,
        summary: String? = nil
    ) {
        self.id = id
        self.previousText = previousText
        self.newText = newText
        self.previousSelectedLocation = max(0, previousSelectedRange.location)
        self.previousSelectedLength = max(0, previousSelectedRange.length)
        self.newSelectedLocation = max(0, newSelectedRange.location)
        self.newSelectedLength = max(0, newSelectedRange.length)
        self.timestamp = timestamp
        self.origin = origin
        self.summary = summary ?? origin.rawValue
    }

    public var previousSelectedRange: NSRange {
        NSRange(location: previousSelectedLocation, length: previousSelectedLength)
    }

    public var newSelectedRange: NSRange {
        NSRange(location: newSelectedLocation, length: newSelectedLength)
    }
}

public struct DocumentUndoTimeline: Codable, Equatable, Sendable {
    public var undoStack: [DocumentUndoEntry] = []
    public var redoStack: [DocumentUndoEntry] = []

    public init(undoStack: [DocumentUndoEntry] = [], redoStack: [DocumentUndoEntry] = []) {
        self.undoStack = undoStack
        self.redoStack = redoStack
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
}
