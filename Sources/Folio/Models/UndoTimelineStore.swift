import Foundation

/// Per-file undo history shared by every open document window.
///
/// Production builds persist bounded timelines to `Application Support` (`undo_timelines.json`)
/// and automatically migrate any legacy `Folio.PerFileUndoTimelines.v1` blob out of `NSUserDefaults`
/// so large undo histories never exceed `CFPreferences`'s 4 MB domain ceiling.
@MainActor
public final class UndoTimelineStore {
    public nonisolated static let maxPersistedEntriesPerFile = 100
    public nonisolated static let maxPersistedFiles = 32
    public nonisolated static let maxFileStorageUTF8Bytes = 8_388_608
    public nonisolated static let maxUserDefaultsUTF8Bytes = 1_572_864
    private nonisolated static let hardUserDefaultsEncodedCeiling = 3_670_016

    public var timelines: [String: DocumentUndoTimeline] = [:]
    /// True after the timelines have been loaded from disk or user defaults.
    public var hasLoaded: Bool = false
    /// Explicit file backing URL. When `nil`, production `UserDefaults.standard` resolves to Application Support.
    public let storageFileURL: URL?

    public init(storageFileURL: URL? = nil) {
        self.storageFileURL = storageFileURL
    }

    public nonisolated static func defaultStorageFileURL(
        for defaults: UserDefaults,
        identity: FolioAppIdentity = .current
    ) -> URL? {
        guard defaults === UserDefaults.standard,
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else {
            return nil
        }
        return identity.undoTimelinesFileURL(in: appSupport)
    }

    public func loadIfNeeded(from defaults: UserDefaults, defaultsKey: String) {
        guard !hasLoaded else { return }
        hasLoaded = true

        if let fileURL = storageFileURL ?? Self.defaultStorageFileURL(for: defaults) {
            if let fileData = try? Data(contentsOf: fileURL),
                let decoded = try? JSONDecoder().decode([String: DocumentUndoTimeline].self, from: fileData)
            {
                timelines = decoded
                if defaults.object(forKey: defaultsKey) != nil {
                    defaults.removeObject(forKey: defaultsKey)
                }
                return
            }

            if let legacyData = defaults.data(forKey: defaultsKey),
                let decoded = try? JSONDecoder().decode([String: DocumentUndoTimeline].self, from: legacyData)
            {
                timelines = decoded
                defaults.removeObject(forKey: defaultsKey)
                persist(to: defaults, defaultsKey: defaultsKey)
                return
            }

            if defaults.object(forKey: defaultsKey) != nil {
                defaults.removeObject(forKey: defaultsKey)
            }
            timelines = [:]
            return
        }

        if let savedData = defaults.data(forKey: defaultsKey),
            let decoded = try? JSONDecoder().decode([String: DocumentUndoTimeline].self, from: savedData)
        {
            timelines = decoded
        } else {
            timelines = [:]
        }
    }

    public func persist(to defaults: UserDefaults, defaultsKey: String) {
        let resolvedFileURL = storageFileURL ?? Self.defaultStorageFileURL(for: defaults)
        var utf8Budget = resolvedFileURL != nil ? Self.maxFileStorageUTF8Bytes : Self.maxUserDefaultsUTF8Bytes
        var bounded = Self.boundedTimelines(
            timelines,
            maxEntriesPerFile: Self.maxPersistedEntriesPerFile,
            maxFiles: Self.maxPersistedFiles,
            maxEstimatedUTF8Bytes: utf8Budget
        )
        guard var encoded = try? JSONEncoder().encode(bounded) else { return }

        if let fileURL = resolvedFileURL {
            try? FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? encoded.write(to: fileURL, options: .atomic)
            if defaults.object(forKey: defaultsKey) != nil {
                defaults.removeObject(forKey: defaultsKey)
            }
        } else {
            while encoded.count >= Self.hardUserDefaultsEncodedCeiling && utf8Budget > 65_536 {
                utf8Budget /= 2
                bounded = Self.boundedTimelines(
                    timelines,
                    maxEntriesPerFile: Self.maxPersistedEntriesPerFile,
                    maxFiles: Self.maxPersistedFiles,
                    maxEstimatedUTF8Bytes: utf8Budget
                )
                guard let smaller = try? JSONEncoder().encode(bounded) else { return }
                encoded = smaller
            }
            if encoded.count < Self.hardUserDefaultsEncodedCeiling {
                defaults.set(encoded, forKey: defaultsKey)
            } else {
                defaults.removeObject(forKey: defaultsKey)
            }
        }
    }

    public nonisolated static func boundedTimelines(
        _ timelines: [String: DocumentUndoTimeline],
        maxEntriesPerFile: Int = maxPersistedEntriesPerFile,
        maxFiles: Int = maxPersistedFiles,
        maxEstimatedUTF8Bytes: Int = maxFileStorageUTF8Bytes
    ) -> [String: DocumentUndoTimeline] {
        guard maxEntriesPerFile > 0, maxFiles > 0, maxEstimatedUTF8Bytes > 0 else {
            return [:]
        }

        struct Candidate {
            let key: String
            var undoSlice: [DocumentUndoEntry]
            var redoSlice: [DocumentUndoEntry]
            let latestTimestamp: Date
        }

        var candidates: [Candidate] = []
        candidates.reserveCapacity(timelines.count)
        for (key, timeline) in timelines {
            let undoSlice = Array(timeline.undoStack.suffix(maxEntriesPerFile))
            let redoSlice = Array(timeline.redoStack.suffix(maxEntriesPerFile))
            guard !undoSlice.isEmpty || !redoSlice.isEmpty else { continue }
            let latestUndo = undoSlice.last?.timestamp ?? .distantPast
            let latestRedo = redoSlice.last?.timestamp ?? .distantPast
            candidates.append(
                Candidate(
                    key: key,
                    undoSlice: undoSlice,
                    redoSlice: redoSlice,
                    latestTimestamp: max(latestUndo, latestRedo)
                ))
        }

        candidates.sort { lhs, rhs in
            if lhs.latestTimestamp != rhs.latestTimestamp {
                return lhs.latestTimestamp > rhs.latestTimestamp
            }
            return lhs.key < rhs.key
        }

        var result: [String: DocumentUndoTimeline] = [:]
        var remainingBytes = maxEstimatedUTF8Bytes
        for var candidate in candidates.prefix(maxFiles) {
            let keyOverhead = candidate.key.utf8.count + 64
            guard remainingBytes > keyOverhead else { break }
            var sliceBytes =
                keyOverhead
                + candidate.undoSlice.reduce(0) { $0 + estimatedEntryBytes($1) }
                + candidate.redoSlice.reduce(0) { $0 + estimatedEntryBytes($1) }

            while sliceBytes > remainingBytes && (!candidate.undoSlice.isEmpty || !candidate.redoSlice.isEmpty) {
                if candidate.redoSlice.count > candidate.undoSlice.count, let dropped = candidate.redoSlice.first {
                    candidate.redoSlice.removeFirst()
                    sliceBytes -= estimatedEntryBytes(dropped)
                } else if let dropped = candidate.undoSlice.first {
                    candidate.undoSlice.removeFirst()
                    sliceBytes -= estimatedEntryBytes(dropped)
                } else if let dropped = candidate.redoSlice.first {
                    candidate.redoSlice.removeFirst()
                    sliceBytes -= estimatedEntryBytes(dropped)
                }
            }

            guard !candidate.undoSlice.isEmpty || !candidate.redoSlice.isEmpty, sliceBytes <= remainingBytes else {
                continue
            }
            result[candidate.key] = DocumentUndoTimeline(
                undoStack: candidate.undoSlice,
                redoStack: candidate.redoSlice
            )
            remainingBytes -= sliceBytes
        }
        return result
    }

    private nonisolated static func estimatedEntryBytes(_ entry: DocumentUndoEntry) -> Int {
        entry.previousText.utf8.count + entry.newText.utf8.count + entry.summary.utf8.count + 160
    }
}
