import AppKit
import Foundation

/// Measured heights and snapshots of HTML blocks, shared by the styler (which reserves the
/// block's height in the text) and the web views (which measure it).
final class HTMLBlockLayoutCache: @unchecked Sendable {
    static let shared = HTMLBlockLayoutCache()

    struct Key: Hashable {
        let source: String
        let width: Int
        let style: HTMLBlockPageStyle
    }

    /// Maximum cached heights and snapshots. Oldest entries are evicted first.
    var capacity = 512

    private let lock = NSLock()
    private var heights: [Key: CGFloat] = [:]
    private var heightOrder: [Key] = []
    private var snapshots: [String: NSImage] = [:]
    private var snapshotOrder: [String] = []

    static func key(source: String, width: CGFloat, style: HTMLBlockPageStyle) -> Key {
        Key(source: source, width: Int(width.rounded()), style: style)
    }

    func height(for key: Key) -> CGFloat? {
        lock.lock()
        defer { lock.unlock() }
        return heights[key]
    }

    /// Stores a measured height. Returns true when it differs from the stored height.
    @discardableResult
    func setHeight(_ height: CGFloat, for key: Key) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let old = heights[key] {
            guard abs(old - height) >= 1.0 else { return false }
        } else {
            heightOrder.append(key)
            if heightOrder.count > capacity {
                heights.removeValue(forKey: heightOrder.removeFirst())
            }
        }
        heights[key] = height
        return true
    }

    func snapshot(for source: String) -> NSImage? {
        lock.lock()
        defer { lock.unlock() }
        return snapshots[source]
    }

    func setSnapshot(_ image: NSImage, for source: String) {
        lock.lock()
        defer { lock.unlock() }
        if snapshots[source] == nil {
            snapshotOrder.append(source)
            if snapshotOrder.count > capacity {
                snapshots.removeValue(forKey: snapshotOrder.removeFirst())
            }
        }
        snapshots[source] = image
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        heights.removeAll()
        heightOrder.removeAll()
        snapshots.removeAll()
        snapshotOrder.removeAll()
    }

    /// Height to reserve before the block is measured: one body line per source line, capped.
    static func estimatedHeight(lineCount: Int, fontSize: CGFloat, lineHeight: Double) -> CGFloat {
        let line = ceil(fontSize * CGFloat(lineHeight))
        return min(480.0, max(line, line * CGFloat(max(1, lineCount)) * 0.5))
    }
}
