import Foundation

public struct OutlineHeading: Identifiable, Equatable {
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

public struct DocumentStats: Equatable {
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
        var stats = DocumentStats()
        if text.isEmpty {
            stats.lines = 1
            return stats
        }

        let nsString = text as NSString
        stats.characters = nsString.length
        stats.charactersWithoutSpaces = text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.count

        var lineCount = 0
        nsString.enumerateSubstrings(in: NSRange(location: 0, length: nsString.length), options: [.byLines, .substringNotRequired]) { _, _, _, _ in
            lineCount += 1
        }
        if text.hasSuffix("\n") {
            lineCount += 1
        }
        stats.lines = max(1, lineCount)

        var wordCount = 0
        nsString.enumerateSubstrings(in: NSRange(location: 0, length: nsString.length), options: [.byWords, .substringNotRequired]) { _, _, _, _ in
            wordCount += 1
        }
        stats.words = wordCount

        if let sel = selectedRange, sel.length > 0, sel.location + sel.length <= nsString.length {
            stats.selectedCharacters = sel.length
            var selWords = 0
            nsString.enumerateSubstrings(in: sel, options: [.byWords, .substringNotRequired]) { _, _, _, _ in
                selWords += 1
            }
            stats.selectedWords = selWords
        }

        return stats
    }
}

public struct WorkspaceFileNode: Identifiable, Hashable {
    public let url: URL
    public let name: String
    public let isDirectory: Bool
    public let modificationDate: Date
    public let creationDate: Date
    public var children: [WorkspaceFileNode]?

    public var id: URL { url }

    public var isMarkdownFile: Bool {
        let ext = url.pathExtension.lowercased()
        return ["md", "markdown", "mdown", "mkd", "txt", "textbundle"].contains(ext)
    }
}

public enum FileSortOrder: String, CaseIterable, Identifiable {
    case name = "Name"
    case modificationDate = "Modification Date"
    case creationDate = "Creation Date"

    public var id: String { rawValue }
}

public struct WorkspaceSearchMatch: Identifiable, Equatable {
    public let id = UUID()
    public let fileURL: URL
    public let fileName: String
    public let lineNumber: Int
    public let lineSnippet: String
    public let matchRangeInFile: NSRange
}
