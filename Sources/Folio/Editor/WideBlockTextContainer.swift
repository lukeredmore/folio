import AppKit

/// Text container whose line fragments for wide blocks (tables) can be wider than the column
/// and start left of it. The column itself stays at the container's bounds, so prose layout is
/// unchanged; a wide table is centered on the column, or pinned to the canvas margin and
/// scrolled horizontally when it is wider than the canvas.
final class WideBlockTextContainer: NSTextContainer {

    struct Region: Equatable {
        /// Characters laid out with the wide fragment.
        let range: NSRange
        /// Fragment origin relative to the column's leading edge (negative is left of the column).
        let x: CGFloat
        /// Fragment width.
        let width: CGFloat
    }

    /// Sorted by location and non-overlapping.
    private(set) var regions: [Region] = []

    override var isSimpleRectangularTextContainer: Bool { regions.isEmpty }

    /// Replaces the wide regions and returns the character ranges whose layout must be redone.
    func setRegions(_ newRegions: [Region]) -> [NSRange] {
        let sorted = newRegions.sorted { $0.range.location < $1.range.location }
        guard sorted != regions else { return [] }
        let changed = Set(regions.map(\.range.location)).symmetricDifference(sorted.map(\.range.location))
        var ranges = regions.filter { changed.contains($0.range.location) }.map(\.range)
        ranges += sorted.filter { changed.contains($0.range.location) }.map(\.range)
        for new in sorted {
            if let old = regions.first(where: { $0.range.location == new.range.location }), old != new {
                ranges.append(NSUnionRange(old.range, new.range))
            }
        }
        regions = sorted
        return ranges
    }

    func region(containing characterIndex: Int) -> Region? {
        var low = 0
        var high = regions.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let candidate = regions[mid]
            if characterIndex < candidate.range.location {
                high = mid - 1
            } else if characterIndex >= NSMaxRange(candidate.range) {
                low = mid + 1
            } else {
                return candidate
            }
        }
        return nil
    }

    override func lineFragmentRect(
        forProposedRect proposedRect: NSRect,
        at characterIndex: Int,
        writingDirection baseWritingDirection: NSWritingDirection,
        remaining remainingRect: UnsafeMutablePointer<NSRect>?
    ) -> NSRect {
        if let region = region(containing: characterIndex) {
            remainingRect?.pointee = .zero
            return NSRect(x: region.x, y: proposedRect.minY, width: region.width, height: proposedRect.height)
        }
        return super.lineFragmentRect(
            forProposedRect: proposedRect,
            at: characterIndex,
            writingDirection: baseWritingDirection,
            remaining: remainingRect
        )
    }
}
