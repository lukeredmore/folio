import Foundation
@testable import Folio

final class MockRemoteTransport: RemoteFileTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [UUID: [String: String]] = [:]
    var simulatedError: Error?

    func setRemoteFiles(for mountID: UUID, files: [String: String]) {
        lock.withLock {
            storage[mountID] = files
        }
    }

    func getRemoteFile(for mountID: UUID, relativePath: String) -> String? {
        lock.withLock {
            storage[mountID]?[relativePath]
        }
    }

    func fetchSnapshot(for mount: RemoteMountSpec) async throws -> [RemoteFileEntry] {
        let (err, files) = lock.withLock {
            (simulatedError, storage[mount.id] ?? [:])
        }

        if let err {
            throw err
        }

        let now = Date().timeIntervalSince1970
        return files.keys.sorted().compactMap { relPath in
            guard let text = files[relPath] else { return nil }
            return RemoteFileEntry(relativePath: relPath, modificationTimestamp: now, content: text)
        }
    }

    func pushFile(content: String, relativePath: String, for mount: RemoteMountSpec) async throws -> TimeInterval {
        let err: Error? = lock.withLock {
            if simulatedError == nil {
                var map = storage[mount.id] ?? [:]
                map[relativePath] = content
                storage[mount.id] = map
            }
            return simulatedError
        }

        if let err {
            throw err
        }
        return Date().timeIntervalSince1970
    }

    func deleteFile(relativePath: String, for mount: RemoteMountSpec) async throws {
        let err: Error? = lock.withLock {
            if simulatedError == nil {
                storage[mount.id]?.removeValue(forKey: relativePath)
            }
            return simulatedError
        }

        if let err {
            throw err
        }
    }
}
