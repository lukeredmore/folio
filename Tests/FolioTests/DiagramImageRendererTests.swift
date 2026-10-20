import AppKit
import XCTest
@testable import Folio

final class DiagramImageRendererTests: XCTestCase {

    /// Thread-safe log of render calls made by the injected render function.
    private final class RenderLog: @unchecked Sendable {
        private let lock = NSLock()
        private var sources: [String] = []
        func record(_ source: String) { lock.lock(); sources.append(source); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return sources }
    }

    private static func image() -> NSImage {
        NSImage(size: NSSize(width: 40, height: 20))
    }

    private func key(_ source: String) -> DiagramImageRenderer.Key {
        DiagramImageRenderer.Key(kind: .svg, source: source)
    }

    func testMissQueuesRenderAndLaterReturnsImage() {
        let log = RenderLog()
        let renderer = DiagramImageRenderer { key in
            log.record(key.source)
            return Self.image()
        }
        XCTAssertNil(renderer.image(for: key("a")), "A miss must not block on rendering")
        XCTAssertTrue(renderer.waitUntilIdle())
        XCTAssertNotNil(renderer.image(for: key("a")))
        XCTAssertEqual(log.all, ["a"], "A cached image is not rendered again")
    }

    func testFailedRenderIsCachedAndNotRetried() {
        let log = RenderLog()
        let renderer = DiagramImageRenderer { key in
            log.record(key.source)
            return nil
        }
        _ = renderer.image(for: key("bad"))
        XCTAssertTrue(renderer.waitUntilIdle())
        for _ in 0..<5 { XCTAssertNil(renderer.image(for: key("bad"))) }
        XCTAssertTrue(renderer.waitUntilIdle())
        XCTAssertEqual(log.all, ["bad"], "A failed render must not be retried on every restyle")
        XCTAssertFalse(renderer.isPending(key("bad")))
    }

    func testPrioritizedDiagramRendersFirst() {
        let log = RenderLog()
        let gate = DispatchSemaphore(value: 0)
        let renderer = DiagramImageRenderer { key in
            if key.source == "first" { gate.wait() }
            log.record(key.source)
            return Self.image()
        }
        _ = renderer.image(for: key("first"))
        Thread.sleep(forTimeInterval: 0.05)
        _ = renderer.image(for: key("b"))
        _ = renderer.image(for: key("c"))
        _ = renderer.image(for: key("c"), prioritize: true)
        gate.signal()
        XCTAssertTrue(renderer.waitUntilIdle())
        XCTAssertEqual(log.all, ["first", "c", "b"], "An on-screen diagram jumps ahead of queued ones")
    }

    func testCacheEvictsOldestFinishedEntries() {
        let log = RenderLog()
        let renderer = DiagramImageRenderer { key in
            log.record(key.source)
            return Self.image()
        }
        renderer.capacity = 2
        for source in ["a", "b", "c"] {
            _ = renderer.image(for: key(source))
            XCTAssertTrue(renderer.waitUntilIdle())
        }
        XCTAssertNotNil(renderer.image(for: key("c")))
        XCTAssertNil(renderer.image(for: key("a")), "The oldest entry is evicted and queued again")
        XCTAssertTrue(renderer.waitUntilIdle())
        XCTAssertEqual(log.all, ["a", "b", "c", "a"])
    }

    func testCompletionNotificationIsPostedOnMainThread() {
        let renderer = DiagramImageRenderer { _ in Self.image() }
        let posted = expectation(forNotification: FolioMediaImageCache.imageDidLoadNotification, object: nil) { _ in
            Thread.isMainThread
        }
        _ = renderer.image(for: key("n"))
        wait(for: [posted], timeout: 5)
    }

    @MainActor
    func testStylingQueuesDiagramsOnTheSharedRenderer() {
        let source = "flowchart LR\n    Unique\(UUID().uuidString.prefix(8))[A] --> B"
        let key = DiagramImageRenderer.Key(kind: .mermaid(isDark: false), source: source)
        let analysis = MarkdownLiveStyler.applyStyles(
            to: NSTextStorage(string: "# Doc\n\n```mermaid\n\(source)\n```\n\nText."),
            theme: .daylight,
            sourceCodeMode: false,
            focusMode: false,
            selectedRange: NSRange(location: 0, length: 0),
            containerWidth: 700
        )
        XCTAssertTrue(analysis.decorations.contains { if case .mermaidBlockRendered = $0.kind { return true }; return false })
        XCTAssertTrue(DiagramImageRenderer.shared.waitUntilIdle())
        XCTAssertNotNil(DiagramImageRenderer.shared.image(for: key), "Styling queues the diagram for background rendering")
    }
}
