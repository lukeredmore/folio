import AppKit

/// Editor-wide alignment for prose (paragraphs, list items, blockquotes).
public enum EditorTextAlignment: String, CaseIterable, Identifiable, Sendable {
    case left
    case justified

    public var id: String { rawValue }
    public var title: String { self == .left ? "Left" : "Justify" }
    public var nsAlignment: NSTextAlignment { self == .left ? .natural : .justified }
}

/// Paper size used when printing.
public enum PrintPaperSize: String, CaseIterable, Identifiable, Sendable {
    case letter
    case a4
    case legal
    case a5

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .letter: return "US Letter (8.5 × 11 in)"
        case .a4: return "A4 (210 × 297 mm)"
        case .legal: return "US Legal (8.5 × 14 in)"
        case .a5: return "A5 (148 × 210 mm)"
        }
    }

    /// Size in points (1/72 in).
    public var size: NSSize {
        switch self {
        case .letter: return NSSize(width: 612, height: 792)
        case .a4: return NSSize(width: 595.28, height: 841.89)
        case .legal: return NSSize(width: 612, height: 1008)
        case .a5: return NSSize(width: 419.53, height: 595.28)
        }
    }

    /// Margin on every side, in points.
    public static let margin: CGFloat = 54

    /// Width available for text on the page.
    public var printableWidth: CGFloat { size.width - Self.margin * 2 }
}
