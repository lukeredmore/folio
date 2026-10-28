import Foundation

extension SelectionComment {

    public static let companionFileSuffix = ".comments.folio.md"

    /// Returns the primary companion comments file URL immediately next to `fileURL`.
    /// For `/path/to/Architecture.md`, this produces `/path/to/Architecture.comments.folio.md`.
    public static func companionCommentsURL(for fileURL: URL) -> URL {
        let directory = fileURL.deletingLastPathComponent()
        let filename = fileURL.lastPathComponent
        let lower = filename.lowercased()
        if lower.hasSuffix(companionFileSuffix) {
            return fileURL
        }
        let stem = fileURL.deletingPathExtension().lastPathComponent
        let baseName = stem.isEmpty ? filename : stem
        return directory.appendingPathComponent("\(baseName)\(companionFileSuffix)")
    }

    /// Returns all candidate companion file URLs next to `fileURL` (both `<stem>.comments.folio.md`
    /// and `<filename>.comments.folio.md`) so user-created or tool-created files with either naming work seamlessly.
    public static func candidateCompanionURLs(for fileURL: URL) -> [URL] {
        let primary = companionCommentsURL(for: fileURL)
        let directory = fileURL.deletingLastPathComponent()
        let fullNamed = directory.appendingPathComponent("\(fileURL.lastPathComponent)\(companionFileSuffix)")
        if primary.standardizedFileURL == fullNamed.standardizedFileURL {
            return [primary]
        }
        return [primary, fullNamed]
    }

    /// Serializes comments into the companion `.comments.folio.md` file format.
    public static func serializeCompanionMarkdown(
        _ comments: [SelectionComment],
        documentTitle: String,
        fileURL: URL? = nil,
        workspaceFolderURL: URL? = nil,
        documentText: String
    ) -> String {
        guard !comments.isEmpty else { return "" }
        let body = formatBatchForAgentPaste(
            comments,
            documentTitle: documentTitle,
            fileURL: fileURL,
            workspaceFolderURL: workspaceFolderURL,
            documentText: documentText
        )
        return body.isEmpty ? "" : body + "\n"
    }

    /// Parses a `.comments.folio.md` companion Markdown document and anchors each comment to its range in `documentText`.
    public static func parseCompanionMarkdown(
        _ companionMarkdown: String,
        inDocumentText documentText: String,
        theme: EditorTheme = .daylight,
        typography: EditorTypographySettings = .default
    ) -> [SelectionComment] {
        let normalized = companionMarkdown.replacingOccurrences(of: "\r\n", with: "\n")
        guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }

        let rawBlocks = normalized.components(separatedBy: "\n\n---\n\n")
        var parsedComments: [SelectionComment] = []
        let baseTime = Date()

        for (index, rawBlock) in rawBlocks.enumerated() {
            let trimmedBlock = rawBlock.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedBlock.isEmpty else { continue }
            if let comment = parseSingleCompanionBlock(
                trimmedBlock,
                inDocumentText: documentText,
                theme: theme,
                typography: typography,
                createdAt: baseTime.addingTimeInterval(TimeInterval(index) * 0.001)
            ) {
                parsedComments.append(comment)
            }
        }

        return parsedComments.sorted { lhs, rhs in
            if lhs.range.location != rhs.range.location {
                return lhs.range.location < rhs.range.location
            }
            return lhs.createdAt < rhs.createdAt
        }
    }

    private static func parseSingleCompanionBlock(
        _ block: String,
        inDocumentText documentText: String,
        theme: EditorTheme,
        typography: EditorTypographySettings,
        createdAt: Date
    ) -> SelectionComment? {
        let lines = block.components(separatedBy: "\n")
        guard !lines.isEmpty else { return nil }

        var idx = 0
        var hintedStartLine: Int?
        var hintedEndLine: Int?

        // 1. Optional header line: **`path/to/file.md` (L12–L14)** or **`file.md` (L12)**
        let firstTrimmed = lines[0].trimmingCharacters(in: .whitespaces)
        if firstTrimmed.hasPrefix("**`") {
            let parsedHint = parseHeaderLineHint(firstTrimmed)
            hintedStartLine = parsedHint.startLine
            hintedEndLine = parsedHint.endLine
            idx = 1
        }

        // Skip blank lines between header and blockquote
        while idx < lines.count && lines[idx].trimmingCharacters(in: .whitespaces).isEmpty {
            idx += 1
        }

        // 2. Collect blockquoted lines (`> ...` or `>`)
        var quoteLines: [String] = []
        while idx < lines.count {
            let line = lines[idx]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == ">" {
                quoteLines.append("")
                idx += 1
            } else if trimmed.hasPrefix("> ") {
                quoteLines.append(String(trimmed.dropFirst(2)))
                idx += 1
            } else if trimmed.hasPrefix(">") {
                quoteLines.append(String(trimmed.dropFirst(1)))
                idx += 1
            } else {
                break
            }
        }

        // 3. Remaining lines form the comment body
        let commentBody = lines[idx...]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !commentBody.isEmpty else { return nil }

        let quotedText = quoteLines.joined(separator: "\n")
        guard
            let resolvedRange = resolveRange(
                forQuotedText: quotedText,
                hintedStartLine: hintedStartLine,
                hintedEndLine: hintedEndLine,
                inDocumentText: documentText
            ), resolvedRange.length > 0
        else {
            return nil
        }

        let nsDoc = documentText as NSString
        let rawSelected = nsDoc.substring(with: resolvedRange)
        let formattedSelected = MarkdownCopyFormatter.strippedPlainText(
            in: documentText,
            range: resolvedRange,
            theme: theme,
            typography: typography
        )

        return SelectionComment(
            range: resolvedRange,
            selectedRawText: rawSelected,
            selectedFormattedText: formattedSelected,
            commentText: commentBody,
            createdAt: createdAt
        )
    }

    private static func parseHeaderLineHint(_ headerLine: String) -> (startLine: Int?, endLine: Int?) {
        let pattern = #"\(L(\d+)(?:[–-]L?(\d+))?\)\*\*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(
                in: headerLine,
                range: NSRange(location: 0, length: (headerLine as NSString).length)
            )
        else {
            return (nil, nil)
        }
        let nsHeader = headerLine as NSString
        var startLine: Int?
        var endLine: Int?
        if match.range(at: 1).location != NSNotFound {
            startLine = Int(nsHeader.substring(with: match.range(at: 1)))
        }
        if match.range(at: 2).location != NSNotFound {
            endLine = Int(nsHeader.substring(with: match.range(at: 2)))
        }
        return (startLine, endLine ?? startLine)
    }

    private static func resolveRange(
        forQuotedText quotedText: String,
        hintedStartLine: Int?,
        hintedEndLine: Int?,
        inDocumentText documentText: String
    ) -> NSRange? {
        let nsDoc = documentText as NSString
        guard nsDoc.length > 0 else { return nil }

        let hintedCharRange = characterRangeForLines(
            startLine: hintedStartLine,
            endLine: hintedEndLine,
            in: nsDoc
        )
        let targetOffset = hintedCharRange?.location ?? 0

        let trimmedQuote = quotedText.trimmingCharacters(in: .newlines)
        if !trimmedQuote.isEmpty {
            // Find the occurrence of `trimmedQuote` closest to `targetOffset`
            var bestRange: NSRange?
            var searchRange = NSRange(location: 0, length: nsDoc.length)
            while searchRange.location < nsDoc.length {
                let found = nsDoc.range(of: trimmedQuote, options: [], range: searchRange)
                guard found.location != NSNotFound else { break }
                if let currentBest = bestRange {
                    if abs(found.location - targetOffset) < abs(currentBest.location - targetOffset) {
                        bestRange = found
                    }
                } else {
                    bestRange = found
                }
                let nextLoc = found.location + max(1, found.length)
                guard nextLoc <= nsDoc.length else { break }
                searchRange = NSRange(location: nextLoc, length: nsDoc.length - nextLoc)
            }
            if let bestRange {
                return bestRange
            }
        }

        return hintedCharRange
    }

    private static func characterRangeForLines(
        startLine: Int?,
        endLine: Int?,
        in nsDoc: NSString
    ) -> NSRange? {
        guard let startLine, startLine >= 1, nsDoc.length > 0 else { return nil }
        let effectiveEndLine = max(startLine, endLine ?? startLine)

        var currentLine = 1
        var index = 0
        var startLocation: Int?
        var endLocation: Int?

        while index < nsDoc.length {
            let lineRange = nsDoc.lineRange(for: NSRange(location: index, length: 0))
            if currentLine == startLine {
                startLocation = lineRange.location
            }
            if currentLine == effectiveEndLine {
                var trimmedEnd = NSMaxRange(lineRange)
                while trimmedEnd > lineRange.location {
                    let ch = nsDoc.character(at: trimmedEnd - 1)
                    if ch == 10 || ch == 13 {
                        trimmedEnd -= 1
                    } else {
                        break
                    }
                }
                endLocation = trimmedEnd
                break
            }
            index = NSMaxRange(lineRange)
            currentLine += 1
        }

        if let start = startLocation {
            let end = endLocation ?? nsDoc.length
            if end > start {
                return NSRange(location: start, length: end - start)
            }
        }
        return nil
    }
}
