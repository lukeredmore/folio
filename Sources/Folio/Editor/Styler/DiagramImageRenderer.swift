import AppKit
import Foundation

/// Renders Mermaid and SVG fence blocks on a background worker so styling and drawing never
/// block the main thread on diagram layout. Results, including failures, are cached by source.
///
/// Callers ask for an image with `image(for:)`. A cache miss returns `nil` and queues a render;
/// when renders finish, `FolioMediaImageCache.imageDidLoadNotification` is posted on the main
/// thread (at most once per `notificationInterval`), and callers restyle and redraw.
public final class DiagramImageRenderer: @unchecked Sendable {
    public static let shared = DiagramImageRenderer()

    public enum Kind: Hashable, Sendable {
        case mermaid(isDark: Bool)
        case svg
    }

    public struct Key: Hashable, Sendable {
        public let kind: Kind
        public let source: String
    }

    private enum Entry {
        case ready(NSImage)
        case failed
        case pending
    }

    /// Maximum cached diagrams. Oldest entries are evicted first.
    public var capacity = 256
    /// Minimum time between completion notifications while renders are still queued.
    public var notificationInterval: TimeInterval = 1.0

    private let lock = NSLock()
    private var entries: [Key: Entry] = [:]
    private var insertionOrder: [Key] = []
    private var queue: [Key] = []
    private var workerRunning = false
    private var lastNotification = Date.distantPast
    private let worker = DispatchQueue(label: "folio.diagram-renderer", qos: .userInitiated)
    private let renderFunction: @Sendable (Key) -> NSImage?

    public init(render: (@Sendable (Key) -> NSImage?)? = nil) {
        renderFunction = render ?? DiagramImageRenderer.defaultRender
    }

    /// The rendered image for `key`, or `nil` while it is rendering or when rendering failed.
    /// A miss queues a render. `prioritize` moves a queued render to the front, for diagrams that
    /// are on screen.
    public func image(for key: Key, prioritize: Bool = false) -> NSImage? {
        lock.lock()
        defer { lock.unlock() }
        switch entries[key] {
        case .ready(let image)?:
            return image
        case .failed?:
            return nil
        case .pending?:
            if prioritize, let index = queue.firstIndex(of: key), index > 0 {
                queue.remove(at: index)
                queue.insert(key, at: 0)
            }
            return nil
        case nil:
            entries[key] = .pending
            insertionOrder.append(key)
            if prioritize { queue.insert(key, at: 0) } else { queue.append(key) }
            startWorkerIfNeeded()
            return nil
        }
    }

    /// True while `key` is queued or rendering.
    public func isPending(_ key: Key) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if case .pending? = entries[key] { return true }
        return false
    }

    /// Blocks until every queued render is finished. For tests.
    public func waitUntilIdle(timeout: TimeInterval = 30) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            lock.lock()
            let idle = queue.isEmpty && !workerRunning
            lock.unlock()
            if idle { return true }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return false
    }

    /// Must be called with `lock` held.
    private func startWorkerIfNeeded() {
        guard !workerRunning, !queue.isEmpty else { return }
        workerRunning = true
        worker.async { [weak self] in self?.drainQueue() }
    }

    private func drainQueue() {
        while true {
            lock.lock()
            guard !queue.isEmpty else {
                workerRunning = false
                lock.unlock()
                postNotification(force: true)
                return
            }
            let key = queue.removeFirst()
            lock.unlock()

            let image = renderFunction(key)

            lock.lock()
            if entries[key] != nil {
                entries[key] = image.map { .ready($0) } ?? .failed
            }
            evictIfNeeded()
            lock.unlock()
            postNotification(force: false)
        }
    }

    /// Evicts the oldest finished entries until at most `capacity` remain. Queued entries stay.
    /// Must be called with `lock` held.
    private func evictIfNeeded() {
        var index = 0
        while insertionOrder.count > capacity && index < insertionOrder.count {
            let key = insertionOrder[index]
            if case .pending? = entries[key] {
                index += 1
                continue
            }
            insertionOrder.remove(at: index)
            entries.removeValue(forKey: key)
        }
    }

    private func postNotification(force: Bool) {
        lock.lock()
        let now = Date()
        let due = force || now.timeIntervalSince(lastNotification) >= notificationInterval
        if due { lastNotification = now }
        lock.unlock()
        guard due else { return }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: FolioMediaImageCache.imageDidLoadNotification, object: nil)
        }
    }

    private static func defaultRender(_ key: Key) -> NSImage? {
        let svg: String
        switch key.kind {
        case .mermaid(let isDark):
            svg = MarkdownLiveStyler.renderMermaidSVG(key.source, isDark: isDark)
        case .svg:
            svg = MarkdownLiveStyler.normalizeSVG(key.source)
        }
        guard !svg.isEmpty, let data = svg.data(using: .utf8), let image = NSImage(data: data),
              image.size.width > 0, image.size.height > 0 else {
            return nil
        }
        return image
    }
}
