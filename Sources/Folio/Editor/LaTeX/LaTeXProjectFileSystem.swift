import Foundation

/// Modification date and size of a file, used to decide whether cached facts are still valid.
struct LaTeXFileStamp: Hashable, Sendable {
    let modificationDate: Date?
    let size: Int
}

/// The file-system operations that LaTeX project resolution uses. All LaTeX project I/O goes
/// through one of these, so tests can count it and the restyle path can be shown to do none.
struct LaTeXProjectFileSystem: Sendable {
    /// Stamp of a regular file, or nil when the path is missing or a directory.
    var stamp: @Sendable (URL) -> LaTeXFileStamp?
    var readText: @Sendable (URL) -> String?
    /// Files directly inside a directory, sorted by name.
    var listDirectory: @Sendable (URL) -> [URL]

    /// The real file system. Each operation counts toward the current editor's
    /// `latexFileOperationCount` and toward `LaTeXProjectFileSystem.liveOperationCount`.
    static let live = LaTeXProjectFileSystem(
        stamp: { url in
            recordOperation()
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue,
                let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            else { return nil }
            return LaTeXFileStamp(
                modificationDate: attributes[.modificationDate] as? Date,
                size: (attributes[.size] as? NSNumber)?.intValue ?? 0
            )
        },
        readText: { url in
            recordOperation()
            return try? String(contentsOf: url, encoding: .utf8)
        },
        listDirectory: { url in
            recordOperation()
            let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
            return items.map(\.standardizedFileURL).sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
    )

    private static let operationLock = NSLock()
    nonisolated(unsafe) private static var operations = 0

    /// Live file-system operations since launch, on any thread.
    static var liveOperationCount: Int {
        operationLock.lock()
        defer { operationLock.unlock() }
        return operations
    }

    private static func recordOperation() {
        operationLock.lock()
        operations += 1
        operationLock.unlock()
        EditorPerfScope.recorder?.increment(.latexFileOperation)
    }
}
