import AppKit

/// Editor-wide alignment for prose (paragraphs, list items, blockquotes).
public enum EditorTextAlignment: String, CaseIterable, Identifiable, Sendable {
    case left
    case justified

    public var id: String { rawValue }
    public var title: String { self == .left ? "Left" : "Justify" }
    public var nsAlignment: NSTextAlignment { self == .left ? .natural : .justified }
}

/// Paper orientation used when printing or saving as PDF.
public enum PrintOrientation: String, CaseIterable, Identifiable, Codable, Sendable {
    case portrait
    case landscape

    public var id: String { rawValue }
    public var title: String { self == .portrait ? "Portrait" : "Landscape" }
}

/// Paper size used when printing.
public enum PrintPaperSize: String, CaseIterable, Identifiable, Codable, Sendable {
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

    public var shortTitle: String {
        switch self {
        case .letter: return "US Letter"
        case .a4: return "A4"
        case .legal: return "US Legal"
        case .a5: return "A5"
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

    /// Default margin on every side, in points (0.75 in).
    public static let margin: CGFloat = 54

    /// Width available for text on the page with default margins.
    public var printableWidth: CGFloat { size.width - Self.margin * 2 }

    /// Width available for text on the page with custom margins and orientation.
    public func printableWidth(margins: PrintPageMargins, orientation: PrintOrientation = .portrait) -> CGFloat {
        let effectiveWidth = orientation == .landscape ? max(size.width, size.height) : min(size.width, size.height)
        return max(144.0, effectiveWidth - margins.left - margins.right)
    }
}

/// Preset margin configurations for quick selection in Settings.
public enum PrintMarginPreset: String, CaseIterable, Identifiable, Sendable {
    case narrow
    case compact
    case normal
    case wide
    case custom

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .narrow: return "Narrow (0.5 in)"
        case .compact: return "Compact (0.75 in)"
        case .normal: return "Normal (1.0 in)"
        case .wide: return "Wide (1.25 in)"
        case .custom: return "Custom"
        }
    }

    public var margins: PrintPageMargins? {
        switch self {
        case .narrow: return .narrow
        case .compact: return .default
        case .normal: return .normal
        case .wide: return .wide
        case .custom: return nil
        }
    }
}

/// Per-side page margins in points (1/72 in) for Print and Save as PDF.
public struct PrintPageMargins: Equatable, Codable, Sendable {
    public var top: CGFloat
    public var bottom: CGFloat
    public var left: CGFloat
    public var right: CGFloat

    public init(
        top: CGFloat = PrintPaperSize.margin,
        bottom: CGFloat = PrintPaperSize.margin,
        left: CGFloat = PrintPaperSize.margin,
        right: CGFloat = PrintPaperSize.margin
    ) {
        self.top = top
        self.bottom = bottom
        self.left = left
        self.right = right
    }

    public init(uniform: CGFloat) {
        self.init(top: uniform, bottom: uniform, left: uniform, right: uniform)
    }

    public static let narrow = PrintPageMargins(uniform: 36) // 0.50 in
    public static let `default` = PrintPageMargins(uniform: PrintPaperSize.margin) // 0.75 in
    public static let normal = PrintPageMargins(uniform: 72) // 1.00 in
    public static let wide = PrintPageMargins(uniform: 90) // 1.25 in

    public var isUniform: Bool {
        abs(top - bottom) < 0.5 && abs(top - left) < 0.5 && abs(top - right) < 0.5
    }

    public var preset: PrintMarginPreset {
        guard isUniform else { return .custom }
        if abs(top - 36) < 0.5 { return .narrow }
        if abs(top - 54) < 0.5 { return .compact }
        if abs(top - 72) < 0.5 { return .normal }
        if abs(top - 90) < 0.5 { return .wide }
        return .custom
    }

    public var summaryText: String {
        let fmt: (CGFloat) -> String = { pt in
            let inches = pt / 72.0
            return String(format: "%.2g in", inches)
        }
        if isUniform {
            return "\(fmt(top)) margins"
        }
        return "T:\(fmt(top)) B:\(fmt(bottom)) L:\(fmt(left)) R:\(fmt(right))"
    }
}

/// Resolved print page layout combining user defaults with in-document overrides (`geometry`, frontmatter, etc.).
public struct ResolvedPrintPageLayout: Equatable, Sendable {
    public let paperSize: PrintPaperSize
    public let customPaperDimensions: NSSize?
    public let orientation: PrintOrientation
    public let margins: PrintPageMargins
    public let baseFontSizePoints: CGFloat?
    public let textAlignmentOverride: NSTextAlignment?
    public let hasDocumentOverrides: Bool
    public let overrideSummary: String?

    public var effectivePaperSize: NSSize {
        let raw = customPaperDimensions ?? paperSize.size
        switch orientation {
        case .portrait:
            return raw.width <= raw.height ? raw : NSSize(width: raw.height, height: raw.width)
        case .landscape:
            return raw.width >= raw.height ? raw : NSSize(width: raw.height, height: raw.width)
        }
    }

    public var printableWidth: CGFloat {
        max(144.0, effectivePaperSize.width - margins.left - margins.right)
    }

    public var printableHeight: CGFloat {
        max(144.0, effectivePaperSize.height - margins.top - margins.bottom)
    }
}
