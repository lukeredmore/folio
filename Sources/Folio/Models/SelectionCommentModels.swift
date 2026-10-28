import Foundation

public struct SelectionComment: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var range: NSRange
    public var selectedRawText: String
    public var selectedFormattedText: String
    public var commentText: String
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        range: NSRange,
        selectedRawText: String,
        selectedFormattedText: String,
        commentText: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.range = range
        self.selectedRawText = selectedRawText
        self.selectedFormattedText = selectedFormattedText
        self.commentText = commentText
        self.createdAt = createdAt
    }

    public func lineSpan(in documentText: String) -> ClosedRange<Int> {
        SelectionComment.lineSpan(for: range, in: documentText)
    }

    public func lineRangeLabel(in documentText: String) -> String {
        SelectionComment.lineRangeLabel(for: range, in: documentText)
    }

    public static func lineSpan(for range: NSRange, in documentText: String) -> ClosedRange<Int> {
        let nsStr = documentText as NSString
        let length = nsStr.length
        guard length > 0 else { return 1...1 }

        let clampedStart = max(0, min(range.location, length))
        let clampedEnd = max(clampedStart, min(NSMaxRange(range), length))
        let startLine = lineNumber(atUTF16Index: clampedStart, in: nsStr)

        let effectiveEndIndex: Int
        if clampedEnd > clampedStart {
            let lastCharIndex = clampedEnd - 1
            if lastCharIndex < length && nsStr.character(at: lastCharIndex) == 10 && lastCharIndex > clampedStart {
                effectiveEndIndex = lastCharIndex - 1
            } else {
                effectiveEndIndex = lastCharIndex
            }
        } else {
            effectiveEndIndex = clampedStart
        }

        let endLine = max(startLine, lineNumber(atUTF16Index: effectiveEndIndex, in: nsStr))
        return startLine...endLine
    }

    public static func lineRangeLabel(for range: NSRange, in documentText: String) -> String {
        let span = lineSpan(for: range, in: documentText)
        if span.lowerBound == span.upperBound {
            return "L\(span.lowerBound)"
        }
        return "L\(span.lowerBound)–L\(span.upperBound)"
    }

    private static func lineNumber(atUTF16Index target: Int, in nsString: NSString) -> Int {
        let clamped = max(0, min(target, nsString.length))
        var line = 1
        var index = 0
        while index < clamped {
            let lineRange = nsString.lineRange(for: NSRange(location: index, length: 0))
            if NSMaxRange(lineRange) <= clamped {
                line += 1
                index = NSMaxRange(lineRange)
            } else {
                break
            }
        }
        return line
    }

    public static func displayFilePath(
        documentTitle: String,
        fileURL: URL?,
        workspaceFolderURL: URL? = nil
    ) -> String {
        guard let fileURL else { return documentTitle }
        let stdFile = fileURL.standardizedFileURL.path
        if let workspaceFolderURL {
            let stdWorkspace = workspaceFolderURL.standardizedFileURL.path
            let prefix = stdWorkspace.hasSuffix("/") ? stdWorkspace : stdWorkspace + "/"
            if stdFile.hasPrefix(prefix) {
                return String(stdFile.dropFirst(prefix.count))
            }
        }
        return fileURL.lastPathComponent
    }

    public func formatForAgentPaste(
        documentTitle: String,
        fileURL: URL? = nil,
        workspaceFolderURL: URL? = nil,
        documentText: String
    ) -> String {
        let fileLabel = Self.displayFilePath(
            documentTitle: documentTitle,
            fileURL: fileURL,
            workspaceFolderURL: workspaceFolderURL
        )
        let lineLabel = lineRangeLabel(in: documentText)
        let nsStr = documentText as NSString
        let currentQuote: String
        if range.location >= 0 && NSMaxRange(range) <= nsStr.length && range.length > 0 {
            currentQuote = nsStr.substring(with: range)
        } else {
            currentQuote = selectedRawText
        }

        let trimmedQuote = currentQuote.trimmingCharacters(in: .newlines)
        let quotedLines =
            trimmedQuote
            .components(separatedBy: .newlines)
            .map { $0.isEmpty ? ">" : "> \($0)" }
            .joined(separator: "\n")

        let trimmedComment = commentText.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
            **`\(fileLabel)` (\(lineLabel))**
            \(quotedLines)

            \(trimmedComment)
            """
    }

    public static func formatBatchForAgentPaste(
        _ comments: [SelectionComment],
        documentTitle: String,
        fileURL: URL? = nil,
        workspaceFolderURL: URL? = nil,
        documentText: String
    ) -> String {
        let sorted = comments.sorted { lhs, rhs in
            if lhs.range.location != rhs.range.location {
                return lhs.range.location < rhs.range.location
            }
            return lhs.createdAt < rhs.createdAt
        }
        return
            sorted
            .map {
                $0.formatForAgentPaste(
                    documentTitle: documentTitle,
                    fileURL: fileURL,
                    workspaceFolderURL: workspaceFolderURL,
                    documentText: documentText
                )
            }
            .joined(separator: "\n\n---\n\n")
    }

    /// Reconciles this comment's range after an edit from `oldText` to `newText`.
    /// Returns `nil` if the commented text was completely deleted.
    public func reconciled(from oldText: String, to newText: String) -> SelectionComment? {
        guard oldText != newText else { return self }
        let oldNS = oldText as NSString
        let newNS = newText as NSString
        guard newNS.length > 0 else { return nil }

        // 1. If the exact substring still exists at the same range, keep it.
        if NSMaxRange(range) <= newNS.length,
            newNS.substring(with: range) == selectedRawText
        {
            return self
        }

        // 2. Compute common prefix and suffix between oldText and newText to shift ranges cleanly.
        let oldLen = oldNS.length
        let newLen = newNS.length
        let minLen = min(oldLen, newLen)

        var commonPrefix = 0
        while commonPrefix < minLen && oldNS.character(at: commonPrefix) == newNS.character(at: commonPrefix) {
            commonPrefix += 1
        }

        var oldSuffix = oldLen
        var newSuffix = newLen
        while oldSuffix > commonPrefix && newSuffix > commonPrefix && oldNS.character(at: oldSuffix - 1) == newNS.character(at: newSuffix - 1) {
            oldSuffix -= 1
            newSuffix -= 1
        }

        let delta = newLen - oldLen
        var updated = self
        if NSMaxRange(range) <= commonPrefix {
            return updated
        } else if range.location >= oldSuffix {
            let shifted = NSRange(location: max(0, range.location + delta), length: range.length)
            if NSMaxRange(shifted) <= newLen {
                updated.range = shifted
                return updated
            }
        }

        // 3. Fallback: search for the nearest occurrence of `selectedRawText` in `newText`.
        guard !selectedRawText.isEmpty else { return nil }
        var bestRange: NSRange?
        var searchRange = NSRange(location: 0, length: newLen)
        while searchRange.location < newLen {
            let found = newNS.range(of: selectedRawText, options: [], range: searchRange)
            guard found.location != NSNotFound else { break }
            if let currentBest = bestRange {
                if abs(found.location - range.location) < abs(currentBest.location - range.location) {
                    bestRange = found
                }
            } else {
                bestRange = found
            }
            let nextLoc = found.location + max(1, found.length)
            guard nextLoc <= newLen else { break }
            searchRange = NSRange(location: nextLoc, length: newLen - nextLoc)
        }

        if let bestRange {
            updated.range = bestRange
            return updated
        }
        return nil
    }
}

public enum SelectionDirection: String, Equatable, Sendable {
    case forward
    case backward
}

public struct SelectionTooltipAnchor: Equatable, Sendable {
    public let range: NSRange
    public let selectionRectInViewport: CGRect
    public let headRectInViewport: CGRect
    public let direction: SelectionDirection
    public let viewportSize: CGSize

    public init(
        range: NSRange,
        selectionRectInViewport: CGRect,
        headRectInViewport: CGRect? = nil,
        direction: SelectionDirection = .forward,
        viewportSize: CGSize
    ) {
        self.range = range
        self.selectionRectInViewport = selectionRectInViewport
        self.headRectInViewport = headRectInViewport ?? selectionRectInViewport
        self.direction = direction
        self.viewportSize = viewportSize
    }
}
