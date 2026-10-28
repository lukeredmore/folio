import Foundation
import XCTest
@testable import Folio

/// Per-test defaults, directories, and view models, removed when the test ends.
extension XCTestCase {
    /// A new, empty `UserDefaults` suite.
    func isolatedDefaults() -> UserDefaults {
        let suiteName = "app.folio.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("Could not create the UserDefaults suite \(suiteName)")
        }
        addTeardownBlock {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }

    /// A new, empty directory under the temporary directory.
    func makeTemporaryDirectory(_ prefix: String = "FolioTests") throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    /// A temporary copy of `examples/<name>` with `examples/assets` and the `companions`.
    func copyOfExample(_ name: String, companions: [String] = []) throws -> URL {
        let workspace = try PerfFixtures.makeWorkspace(copyingExample: name)
        addTeardownBlock {
            workspace.remove()
        }
        let directory = workspace.fileURL.deletingLastPathComponent()
        for companion in companions {
            let source = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("examples/\(companion)")
            try FileManager.default.copyItem(at: source, to: directory.appendingPathComponent(companion))
        }
        return workspace.fileURL
    }

    /// A view model with isolated defaults and a temporary remote mirror.
    @MainActor
    func makeIsolatedViewModel(defaults: UserDefaults? = nil) -> EditorWorkspaceViewModel {
        let resolvedDefaults = defaults ?? isolatedDefaults()
        let mirror: URL
        do {
            mirror = try makeTemporaryDirectory("FolioMirror")
        } catch {
            preconditionFailure("Could not create a remote mirror directory: \(error)")
        }
        let manager = RemoteWorkspaceManager(mirrorBaseDirectory: mirror, userDefaults: resolvedDefaults)
        return EditorWorkspaceViewModel(remoteWorkspaceManager: manager, userDefaults: resolvedDefaults)
    }
}
