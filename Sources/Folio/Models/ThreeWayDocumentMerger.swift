import Foundation

// MARK: - 3-Way Document Merge & Conflict Resolution Engine

public enum ConflictResolutionStrategy: String, Codable, CaseIterable, Equatable, Sendable {
    case keepLocal = "Keep Local"
    case acceptExternal = "Accept External"
    case keepBoth = "Keep Both"

    public var title: String { rawValue }
}

public struct DocumentConflictHunk: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let index: Int
    public let baseStartLine: Int
    public let baseLines: [String]
    public let localLines: [String]
    public let externalLines: [String]
    public var selectedResolution: ConflictResolutionStrategy

    public var lineNumber: Int { baseStartLine }

    public var selectedStrategy: ConflictResolutionStrategy {
        get { selectedResolution }
        set { selectedResolution = newValue }
    }

    public init(
        id: UUID = UUID(),
        index: Int,
        baseStartLine: Int,
        baseLines: [String],
        localLines: [String],
        externalLines: [String],
        selectedResolution: ConflictResolutionStrategy = .keepLocal
    ) {
        self.id = id
        self.index = index
        self.baseStartLine = baseStartLine
        self.baseLines = baseLines
        self.localLines = localLines
        self.externalLines = externalLines
        self.selectedResolution = selectedResolution
    }

    public func resolvedLines(overrideStrategy: ConflictResolutionStrategy? = nil) -> [String] {
        let strategy = overrideStrategy ?? selectedResolution
        switch strategy {
        case .keepLocal:
            return localLines
        case .acceptExternal:
            return externalLines
        case .keepBoth:
            return localLines + externalLines
        }
    }
}

public enum DocumentMergeSegment: Equatable, Sendable {
    case clean([String])
    case conflict(DocumentConflictHunk)
}

public struct DocumentConflict: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let fileURL: URL
    public let baseText: String
    public let localText: String
    public let externalText: String
    public var segments: [DocumentMergeSegment]
    public let detectedAt: Date
    public let sourceDescription: String

    public init(
        id: UUID = UUID(),
        fileURL: URL,
        baseText: String,
        localText: String,
        externalText: String,
        segments: [DocumentMergeSegment],
        detectedAt: Date = Date(),
        sourceDescription: String = "Disk"
    ) {
        self.id = id
        self.fileURL = fileURL
        self.baseText = baseText
        self.localText = localText
        self.externalText = externalText
        self.segments = segments
        self.detectedAt = detectedAt
        self.sourceDescription = sourceDescription
    }

    public var hunks: [DocumentConflictHunk] {
        segments.compactMap { segment in
            if case let .conflict(hunk) = segment { return hunk }
            return nil
        }
    }

    public var conflictHunks: [DocumentConflictHunk] { hunks }

    public mutating func setResolution(_ strategy: ConflictResolutionStrategy, forHunkID hunkID: UUID) {
        for idx in segments.indices {
            if case var .conflict(hunk) = segments[idx], hunk.id == hunkID {
                hunk.selectedResolution = strategy
                segments[idx] = .conflict(hunk)
            }
        }
    }

    /// Reconstructs the full resolved document using `overrideStrategy` if provided, or each hunk's `selectedResolution` if `nil`.
    public func resolvedText(using overrideStrategy: ConflictResolutionStrategy? = nil) -> String {
        if let overrideStrategy {
            if segments.count == 1, case .conflict = segments[0] {
                switch overrideStrategy {
                case .keepLocal: return localText
                case .acceptExternal: return externalText
                case .keepBoth:
                    let sep = localText.hasSuffix("\n") || localText.isEmpty ? "" : "\n"
                    return localText + sep + externalText
                }
            }
        }

        var outputLines: [String] = []
        for segment in segments {
            switch segment {
            case .clean(let lines):
                outputLines.append(contentsOf: lines)
            case .conflict(let hunk):
                outputLines.append(contentsOf: hunk.resolvedLines(overrideStrategy: overrideStrategy))
            }
        }
        return outputLines.joined(separator: "\n")
    }

    /// Renders a standard Git-style conflict marker preview for inspection.
    public var conflictMarkersPreviewText: String {
        var outputLines: [String] = []
        for segment in segments {
            switch segment {
            case .clean(let lines):
                outputLines.append(contentsOf: lines)
            case .conflict(let hunk):
                outputLines.append("<<<<<<< Local (In Folio)")
                outputLines.append(contentsOf: hunk.localLines)
                outputLines.append("=======")
                outputLines.append(contentsOf: hunk.externalLines)
                outputLines.append(">>>>>>> External (\(sourceDescription))")
            }
        }
        return outputLines.joined(separator: "\n")
    }
}

public enum ThreeWayMergeResult: Equatable, Sendable {
    case clean(mergedText: String, wasAutoMerged: Bool)
    case conflict(DocumentConflict)
}

public enum ThreeWayDocumentMerger {
    /// Performs a line-level 3-way merge between `base` (last synced ancestor), `local` (current editor buffer),
    /// and `external` (newly changed file on disk or remote).
    public static func merge(
        base: String,
        local: String,
        external: String,
        fileURL: URL,
        sourceDescription: String = "Disk"
    ) -> ThreeWayMergeResult {
        if local == external {
            return .clean(mergedText: local, wasAutoMerged: false)
        }
        if local == base {
            return .clean(mergedText: external, wasAutoMerged: false)
        }
        if external == base {
            return .clean(mergedText: local, wasAutoMerged: false)
        }

        let baseLines = DocumentLineDiff.splitLines(base)
        let localLines = DocumentLineDiff.splitLines(local)
        let externalLines = DocumentLineDiff.splitLines(external)

        let localEdits = DocumentLineDiff.extractEdits(from: baseLines, to: localLines)
        let externalEdits = DocumentLineDiff.extractEdits(from: baseLines, to: externalLines)

        func editsOverlap(_ a: Range<Int>, _ b: Range<Int>) -> Bool {
            if a.isEmpty && b.isEmpty {
                return a.lowerBound == b.lowerBound
            }
            if a.isEmpty {
                return a.lowerBound >= b.lowerBound && a.lowerBound <= b.upperBound
            }
            if b.isEmpty {
                return b.lowerBound >= a.lowerBound && b.lowerBound <= a.upperBound
            }
            return a.overlaps(b)
        }

        func applyEdits(_ edits: [DocumentLineDiff.LineEdit], over span: Range<Int>) -> [String] {
            var result: [String] = []
            var cursor = span.lowerBound
            for edit in edits {
                if edit.baseRange.lowerBound > cursor {
                    result.append(contentsOf: baseLines[cursor..<edit.baseRange.lowerBound])
                }
                result.append(contentsOf: edit.replacement)
                cursor = edit.baseRange.upperBound
            }
            if cursor < span.upperBound {
                result.append(contentsOf: baseLines[cursor..<span.upperBound])
            }
            return result
        }

        var segments: [DocumentMergeSegment] = []
        var cleanBuffer: [String] = []
        var hunkCount = 0

        func flushCleanBuffer() {
            if !cleanBuffer.isEmpty {
                segments.append(.clean(cleanBuffer))
                cleanBuffer.removeAll(keepingCapacity: true)
            }
        }

        var baseCursor = 0
        var i = 0
        var j = 0

        while i < localEdits.count || j < externalEdits.count {
            if i < localEdits.count && (j >= externalEdits.count || (!editsOverlap(localEdits[i].baseRange, externalEdits[j].baseRange) && localEdits[i].baseRange.lowerBound < externalEdits[j].baseRange.lowerBound)) {
                let edit = localEdits[i]
                if edit.baseRange.lowerBound > baseCursor {
                    cleanBuffer.append(contentsOf: baseLines[baseCursor..<edit.baseRange.lowerBound])
                }
                cleanBuffer.append(contentsOf: edit.replacement)
                baseCursor = edit.baseRange.upperBound
                i += 1
            } else if j < externalEdits.count && (i >= localEdits.count || (!editsOverlap(localEdits[i].baseRange, externalEdits[j].baseRange) && externalEdits[j].baseRange.lowerBound < localEdits[i].baseRange.lowerBound)) {
                let edit = externalEdits[j]
                if edit.baseRange.lowerBound > baseCursor {
                    cleanBuffer.append(contentsOf: baseLines[baseCursor..<edit.baseRange.lowerBound])
                }
                cleanBuffer.append(contentsOf: edit.replacement)
                baseCursor = edit.baseRange.upperBound
                j += 1
            } else {
                // Overlapping local and external edits: expand cluster to include all transitively overlapping edits
                var groupLocal: [DocumentLineDiff.LineEdit] = [localEdits[i]]
                var groupExternal: [DocumentLineDiff.LineEdit] = [externalEdits[j]]
                var spanStart = min(localEdits[i].baseRange.lowerBound, externalEdits[j].baseRange.lowerBound)
                var spanEnd = max(localEdits[i].baseRange.upperBound, externalEdits[j].baseRange.upperBound)
                i += 1
                j += 1

                var expanded = true
                while expanded {
                    expanded = false
                    while i < localEdits.count && editsOverlap(spanStart..<spanEnd, localEdits[i].baseRange) {
                        spanStart = min(spanStart, localEdits[i].baseRange.lowerBound)
                        spanEnd = max(spanEnd, localEdits[i].baseRange.upperBound)
                        groupLocal.append(localEdits[i])
                        i += 1
                        expanded = true
                    }
                    while j < externalEdits.count && editsOverlap(spanStart..<spanEnd, externalEdits[j].baseRange) {
                        spanStart = min(spanStart, externalEdits[j].baseRange.lowerBound)
                        spanEnd = max(spanEnd, externalEdits[j].baseRange.upperBound)
                        groupExternal.append(externalEdits[j])
                        j += 1
                        expanded = true
                    }
                }

                if spanStart > baseCursor {
                    cleanBuffer.append(contentsOf: baseLines[baseCursor..<spanStart])
                }

                let spanRange = spanStart..<spanEnd
                let localChunk = applyEdits(groupLocal, over: spanRange)
                let externalChunk = applyEdits(groupExternal, over: spanRange)

                if localChunk == externalChunk {
                    // Both sides made the exact same edit
                    cleanBuffer.append(contentsOf: localChunk)
                } else {
                    flushCleanBuffer()
                    hunkCount += 1
                    segments.append(.conflict(DocumentConflictHunk(
                        index: hunkCount,
                        baseStartLine: max(1, spanStart + 1),
                        baseLines: Array(baseLines[spanRange]),
                        localLines: localChunk,
                        externalLines: externalChunk,
                        selectedResolution: .keepLocal
                    )))
                }

                baseCursor = spanEnd
            }
        }

        if baseCursor < baseLines.count {
            cleanBuffer.append(contentsOf: baseLines[baseCursor..<baseLines.count])
        }
        flushCleanBuffer()

        if hunkCount == 0 {
            let mergedLines = segments.flatMap { segment -> [String] in
                if case let .clean(lines) = segment { return lines }
                return []
            }
            return .clean(mergedText: mergedLines.joined(separator: "\n"), wasAutoMerged: true)
        } else {
            return .conflict(DocumentConflict(
                fileURL: fileURL,
                baseText: base,
                localText: local,
                externalText: external,
                segments: segments,
                sourceDescription: sourceDescription
            ))
        }
    }
}
