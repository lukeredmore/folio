import AppKit
import FolioEngineFFI
import SwiftUI

public final class HybridMarkdownTextView: NSTextView {

    public weak var workspaceViewModel: EditorWorkspaceViewModel?
    weak var editorCoordinator: HybridMarkdownEditorRepresentable.Coordinator?

    public var currentTheme: EditorTheme = .daylight {
        didSet { needsDisplay = true }
    }

    public var typographySettings: EditorTypographySettings = .default {
        didSet { needsDisplay = true }
    }

    public var lineDecorations: [LineDecoration] = [] {
        didSet { needsDisplay = true }
    }

    public var externalUpdateHighlightRanges: [NSRange] = [] {
        didSet { needsDisplay = true }
    }

    public var proseColumnWidth: CGFloat = 0 {
        didSet { needsDisplay = true }
    }

    public var isTypewriterMode: Bool = false
    public var isSourceCodeMode: Bool = false

    public var onToggleCheckboxAtCharacterIndex: ((Int) -> Void)?

    public func applyProgrammaticDocumentText(_ newText: String, selectedRange: NSRange) {
        let coord = editorCoordinator
        coord?.isProgrammaticUpdate = true
        coord?.reflowAnchors.removeAll()
        if self.string != newText {
            self.string = newText
        }
        let nsLen = (self.string as NSString).length
        let safeLoc = max(0, min(selectedRange.location, nsLen))
        let safeLen = max(0, min(selectedRange.length, nsLen - safeLoc))
        let clampedRange = NSRange(location: safeLoc, length: safeLen)
        if self.selectedRange() != clampedRange {
            self.setSelectedRange(clampedRange)
        }
        coord?.isProgrammaticUpdate = false
        coord?.restyle(textView: self)
    }

    public override func breakUndoCoalescing() {
        super.breakUndoCoalescing()
        workspaceViewModel?.breakUndoCoalescing()
    }

    @objc public func undo(_ sender: Any?) {
        workspaceViewModel?.undo()
    }

    @objc public func redo(_ sender: Any?) {
        workspaceViewModel?.redo()
    }

    public override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(undo(_:)) {
            return workspaceViewModel?.canUndo ?? false
        }
        if item.action == #selector(redo(_:)) {
            return workspaceViewModel?.canRedo ?? false
        }
        return super.validateUserInterfaceItem(item)
    }

    private static let supportedCodeFenceLanguages: [(id: String, title: String, aliases: [String])] = [
        ("swift", "Swift", ["swift"]),
        ("python", "Python", ["python", "py"]),
        ("javascript", "JavaScript", ["javascript", "js", "jsx"]),
        ("typescript", "TypeScript", ["typescript", "ts", "tsx"]),
        ("rust", "Rust", ["rust", "rs"]),
        ("go", "Go", ["go", "golang"]),
        ("c", "C", ["c", "h"]),
        ("cpp", "C++", ["cpp", "c++", "hpp"]),
        ("objc", "Objective-C", ["objc", "objective-c"]),
        ("bash", "Shell / Bash", ["bash", "sh", "zsh", "shell"]),
        ("json", "JSON", ["json", "jsonc"]),
        ("yaml", "YAML", ["yaml", "yml"]),
        ("toml", "TOML", ["toml"]),
        ("html", "HTML / XML", ["html", "xml"]),
        ("svg", "SVG Vector", ["svg"]),
        ("mermaid", "Mermaid Diagram", ["mermaid", "mmd"]),
        ("css", "CSS / SCSS", ["css", "scss"]),
        ("sql", "SQL", ["sql"])
    ]

    private final class CodeFenceLanguageActionPayload: NSObject {
        let lineRange: NSRange
        let languageId: String

        init(lineRange: NSRange, languageId: String) {
            self.lineRange = lineRange
            self.languageId = languageId
        }
    }

    private static func languageAccentColor(for rawLang: String, isDark: Bool) -> NSColor {
        let rgba = rawLang.withCString { cStr in
            ot_engine_language_accent_color(cStr, isDark)
        }
        return NSColor(srgbRed: rgba.r, green: rgba.g, blue: rgba.b, alpha: rgba.a)
    }

    private static func languageMenuDotImage(for rawLang: String, isDark: Bool) -> NSImage {
        let size = NSSize(width: 8, height: 8)
        let img = NSImage(size: size)
        img.lockFocus()
        languageAccentColor(for: rawLang, isDark: isDark).setFill()
        NSBezierPath(ovalIn: NSRect(origin: .zero, size: size)).fill()
        img.unlockFocus()
        return img
    }

    private struct CodeFenceBadgeGeometry {
        let pillRect: NSRect
        let dotRect: NSRect
        let textPoint: NSPoint
        let chevronCenter: NSPoint
        let badgeString: NSString
        let badgeAttributes: [NSAttributedString.Key: Any]
        let accent: NSColor
    }

    private func computeCodeFenceBadgeGeometry(
        for lineRange: NSRange,
        language: String,
        layoutManager: NSLayoutManager,
        origin: NSPoint,
        contentWidth: CGFloat
    ) -> CodeFenceBadgeGeometry? {
        let glyphRange = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
        guard glyphRange.location != NSNotFound else { return nil }

        let firstFrag = layoutManager.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
        let glyphLoc = layoutManager.location(forGlyphAt: glyphRange.location)
        let baselineY = origin.y + firstFrag.minY + glyphLoc.y
        let codeMono = currentTheme.codeFont(size: currentTheme.baseFontSize * typographySettings.fontSizeScale * 0.88)
        let textVisualMidY = baselineY - (codeMono.ascender + codeMono.descender) * 0.5

        let trimmedLang = language.trimmingCharacters(in: .whitespaces)
        let labelText = trimmedLang.isEmpty ? "PLAIN TEXT" : trimmedLang.uppercased()
        let accent = Self.languageAccentColor(for: trimmedLang, isDark: currentTheme.isDark)
        let badgeAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .semibold),
            .foregroundColor: accent
        ]
        let badgeStr = labelText as NSString
        let badgeSize = badgeStr.size(withAttributes: badgeAttrs)

        let pillPadH: CGFloat = 7.5
        let pillPadV: CGFloat = 2.5
        let dotSpace: CGFloat = 10.0
        let chevronSpace: CGFloat = 12.0
        let pillW = badgeSize.width + pillPadH * 2 + dotSpace + chevronSpace
        let pillH = badgeSize.height + pillPadV * 2
        let pillRect = NSRect(
            x: origin.x + contentWidth - pillW - 8.0,
            y: floor(textVisualMidY - pillH * 0.5),
            width: pillW,
            height: pillH
        )
        let dotRect = NSRect(
            x: pillRect.minX + pillPadH,
            y: pillRect.midY - 3.0,
            width: 6.0,
            height: 6.0
        )
        let textPoint = NSPoint(
            x: pillRect.minX + pillPadH + dotSpace,
            y: pillRect.minY + pillPadV
        )
        let chevronCenter = NSPoint(
            x: pillRect.maxX - pillPadH - 3.0,
            y: pillRect.midY + 0.5
        )
        return CodeFenceBadgeGeometry(
            pillRect: pillRect,
            dotRect: dotRect,
            textPoint: textPoint,
            chevronCenter: chevronCenter,
            badgeString: badgeStr,
            badgeAttributes: badgeAttrs,
            accent: accent
        )
    }

    public override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)

        guard let layoutManager = self.layoutManager,
              let textContainer = self.textContainer else {
            return
        }

        let origin = self.textContainerOrigin
        let fullContentWidth = self.bounds.width - origin.x * 2
        let contentWidth = proseColumnWidth > 0 ? proseColumnWidth : fullContentWidth
        var imageXOffsetByLineLocation: [Int: CGFloat] = [:]

        // Draw visual highlights for lines recently updated externally on disk / remote sync
        if !externalUpdateHighlightRanges.isEmpty {
            let nsLen = (self.string as NSString).length
            let highlightFill = currentTheme.isDark
                ? NSColor.systemGreen.withAlphaComponent(0.14)
                : NSColor.systemGreen.withAlphaComponent(0.10)
            let highlightBar = currentTheme.isDark
                ? NSColor.systemGreen.withAlphaComponent(0.85)
                : NSColor.systemGreen.withAlphaComponent(0.75)

            for rawRange in externalUpdateHighlightRanges {
                let clampedLoc = max(0, min(rawRange.location, nsLen))
                let clampedLen = max(0, min(rawRange.length, nsLen - clampedLoc))
                let safeRange = NSRange(location: clampedLoc, length: clampedLen)
                let glyphRange = layoutManager.glyphRange(forCharacterRange: safeRange, actualCharacterRange: nil)
                guard glyphRange.location != NSNotFound else { continue }
                var boxRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
                boxRect.origin.x = origin.x - 10.0
                boxRect.origin.y += origin.y
                boxRect.size.width = contentWidth + 20.0
                boxRect.size.height = max(20.0, boxRect.size.height)
                guard boxRect.insetBy(dx: -20, dy: -30).intersects(rect) else { continue }

                highlightFill.setFill()
                NSBezierPath(roundedRect: boxRect, xRadius: 5.0, yRadius: 5.0).fill()

                let barRect = NSRect(x: origin.x - 10.0, y: boxRect.minY + 1.0, width: 3.5, height: max(4.0, boxRect.height - 2.0))
                highlightBar.setFill()
                NSBezierPath(roundedRect: barRect, xRadius: 1.75, yRadius: 1.75).fill()
            }
        }

        guard !isSourceCodeMode else {
            return
        }

        for (decIdx, dec) in lineDecorations.enumerated() {
            if case .codeFenceBody = dec.kind { continue }
            if case .codeFenceEnd = dec.kind { continue }

            let glyphRange = layoutManager.glyphRange(forCharacterRange: dec.lineRange, actualCharacterRange: nil)
            guard glyphRange.location != NSNotFound else { continue }

            if case .codeFenceStart(let language) = dec.kind {
                var endDecIdx = decIdx
                var scanIdx = decIdx + 1
                while scanIdx < lineDecorations.count {
                    switch lineDecorations[scanIdx].kind {
                    case .codeFenceBody:
                        endDecIdx = scanIdx
                        scanIdx += 1
                    case .codeFenceEnd:
                        endDecIdx = scanIdx
                        scanIdx = lineDecorations.count
                    default:
                        scanIdx = lineDecorations.count
                    }
                }

                let firstFrag = layoutManager.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
                let endRange = lineDecorations[endDecIdx].lineRange
                let endGlyphs = layoutManager.glyphRange(forCharacterRange: endRange, actualCharacterRange: nil)
                let lastGlyphIdx = endGlyphs.location != NSNotFound
                    ? max(endGlyphs.location, NSMaxRange(endGlyphs) - 1)
                    : max(glyphRange.location, NSMaxRange(glyphRange) - 1)
                let lastFrag = layoutManager.lineFragmentUsedRect(forGlyphAt: lastGlyphIdx, effectiveRange: nil)

                let fenceTop = origin.y + firstFrag.minY - 2.0
                let fenceBottom = origin.y + lastFrag.maxY + 2.0
                let unifiedFenceRect = NSRect(
                    x: origin.x,
                    y: fenceTop,
                    width: contentWidth,
                    height: max(24.0, fenceBottom - fenceTop)
                )

                guard unifiedFenceRect.insetBy(dx: -20, dy: -50).intersects(rect) else { continue }

                currentTheme.codeBackgroundNSColor.setFill()
                let cardPath = NSBezierPath(roundedRect: unifiedFenceRect, xRadius: 7.0, yRadius: 7.0)
                cardPath.fill()

                let cardBorderColor = currentTheme.isDark
                    ? NSColor.white.withAlphaComponent(0.08)
                    : NSColor.black.withAlphaComponent(0.06)
                cardBorderColor.setStroke()
                let strokePath = NSBezierPath(roundedRect: unifiedFenceRect.insetBy(dx: 0.5, dy: 0.5), xRadius: 7.0, yRadius: 7.0)
                strokePath.lineWidth = 1.0
                strokePath.stroke()

                if let badge = computeCodeFenceBadgeGeometry(
                    for: dec.lineRange,
                    language: language,
                    layoutManager: layoutManager,
                    origin: origin,
                    contentWidth: contentWidth
                ) {
                    badge.accent.withAlphaComponent(currentTheme.isDark ? 0.16 : 0.10).setFill()
                    let pillPath = NSBezierPath(roundedRect: badge.pillRect, xRadius: 4.5, yRadius: 4.5)
                    pillPath.fill()

                    badge.accent.withAlphaComponent(currentTheme.isDark ? 0.30 : 0.22).setStroke()
                    let pillBorder = NSBezierPath(roundedRect: badge.pillRect.insetBy(dx: 0.5, dy: 0.5), xRadius: 4.5, yRadius: 4.5)
                    pillBorder.lineWidth = 1.0
                    pillBorder.stroke()

                    badge.accent.setFill()
                    NSBezierPath(ovalIn: badge.dotRect).fill()

                    badge.badgeString.draw(at: badge.textPoint, withAttributes: badge.badgeAttributes)

                    // Draw crisp downward dropdown chevron (▾)
                    let chevron = NSBezierPath()
                    chevron.move(to: NSPoint(x: badge.chevronCenter.x - 2.8, y: badge.chevronCenter.y - 1.4))
                    chevron.line(to: NSPoint(x: badge.chevronCenter.x, y: badge.chevronCenter.y + 1.6))
                    chevron.line(to: NSPoint(x: badge.chevronCenter.x + 2.8, y: badge.chevronCenter.y - 1.4))
                    chevron.lineWidth = 1.35
                    chevron.lineCapStyle = .round
                    chevron.lineJoinStyle = .round
                    badge.accent.withAlphaComponent(0.85).setStroke()
                    chevron.stroke()
                }
                continue
            }

            var lineRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            lineRect.origin.x += origin.x
            lineRect.origin.y += origin.y
            lineRect.size.width = max(lineRect.size.width, contentWidth)

            if case let .tableRow(_, _, _, _, _, _, tableWidth, _) = dec.kind {
                lineRect.size.width = max(lineRect.size.width, tableWidth)
            }

            guard lineRect.insetBy(dx: -20, dy: -50).intersects(rect) else { continue }

            switch dec.kind {
            case .headingUnderline(let level):
                let borderColor = currentTheme.isDark
                    ? NSColor.white.withAlphaComponent(level == 1 ? 0.16 : 0.10)
                    : NSColor.black.withAlphaComponent(level == 1 ? 0.11 : 0.075)
                borderColor.setFill()

                let lastGlyphIndex = max(glyphRange.location, NSMaxRange(glyphRange) - 1)
                let lineFrag = layoutManager.lineFragmentRect(forGlyphAt: lastGlyphIndex, effectiveRange: nil)
                let glyphLoc = layoutManager.location(forGlyphAt: lastGlyphIndex)
                let baselineY = origin.y + lineFrag.minY + glyphLoc.y
                let hFont = currentTheme.headingFont(level: level, scale: typographySettings.fontSizeScale)
                let descenderDepth = abs(hFont.descender)
                let offset = max(3.0, min(6.0, typographySettings.headingUnderlineOffset * (level == 1 ? 0.75 : 0.65)))
                let underlineY = baselineY + descenderDepth + offset

                let underlineRect = NSRect(x: origin.x, y: underlineY, width: contentWidth, height: level == 1 ? 1.5 : 1.0)
                underlineRect.fill()

            case .blockquote(let nestLevel):
                let bgAlpha: CGFloat = currentTheme.isDark ? 0.14 : 0.035
                currentTheme.linkNSColor.withAlphaComponent(bgAlpha).setFill()
                let bgRect = NSRect(x: origin.x, y: lineRect.minY, width: contentWidth, height: lineRect.height)
                bgRect.fill()

                for i in 0..<nestLevel {
                    let barX = origin.x + CGFloat(i) * 14.0
                    let barRect = NSRect(x: barX, y: lineRect.minY, width: 3.5, height: lineRect.height)
                    currentTheme.linkNSColor.withAlphaComponent(0.65).setFill()
                    NSBezierPath(roundedRect: barRect, xRadius: 1.5, yRadius: 1.5).fill()
                }

            case .codeFenceStart, .codeFenceBody, .codeFenceEnd:
                break

            case .mathBlockStart(let isActive), .mathBlockBody(let isActive), .mathBlockEnd(let isActive):
                if isActive {
                    let mathBg = currentTheme.codeBackgroundNSColor.withAlphaComponent(0.70)
                    mathBg.setFill()
                    let boxRect = NSRect(x: origin.x, y: lineRect.minY - 1, width: contentWidth, height: lineRect.height + 2)
                    boxRect.fill()
                }

            case .mathBlockRendered(let latex, let fullBlockRange, let dimFactor):
                let blockGlyphs = layoutManager.glyphRange(forCharacterRange: fullBlockRange, actualCharacterRange: nil)
                guard blockGlyphs.location != NSNotFound else { continue }
                var blockRect = layoutManager.boundingRect(forGlyphRange: blockGlyphs, in: textContainer)
                blockRect.origin.x = origin.x
                blockRect.origin.y += origin.y
                blockRect.size.width = contentWidth

                // Subtle card background for display math block
                let cardBg = currentTheme.codeBackgroundNSColor.withAlphaComponent(currentTheme.isDark ? 0.45 : 0.50)
                cardBg.setFill()
                let cardPath = NSBezierPath(roundedRect: blockRect.insetBy(dx: 0, dy: 2), xRadius: 8, yRadius: 8)
                cardPath.fill()

                let mathBox = LaTeXMathRenderer.layoutLatex(
                    latex,
                    baseFontSize: currentTheme.baseFontSize * typographySettings.fontSizeScale,
                    isDisplayStyle: true
                )
                let startX = origin.x + max(12.0, (contentWidth - mathBox.width) * 0.5)
                let baselineY = blockRect.midY + (mathBox.ascent - mathBox.descent) * 0.5
                let mathColor = currentTheme.headingNSColor.withAlphaComponent(dimFactor)
                mathBox.drawBox(startX, baselineY, mathColor)

            case .inlineMathRendered(let latex, let mathRange, let fontSize, let dimFactor):
                let mathGlyphs = layoutManager.glyphRange(forCharacterRange: mathRange, actualCharacterRange: nil)
                guard mathGlyphs.location != NSNotFound else { continue }
                var mathRect = layoutManager.boundingRect(forGlyphRange: mathGlyphs, in: textContainer)
                mathRect.origin.x += origin.x
                mathRect.origin.y += origin.y

                let lineFrag = layoutManager.lineFragmentRect(forGlyphAt: mathGlyphs.location, effectiveRange: nil)
                let glyphLoc = layoutManager.location(forGlyphAt: mathGlyphs.location)
                let baselineOffset = (self.textStorage?.attribute(.baselineOffset, at: mathRange.location, effectiveRange: nil) as? CGFloat) ?? 0.0
                let baselineY = origin.y + lineFrag.minY + glyphLoc.y - baselineOffset

                let mathBox = LaTeXMathRenderer.layoutLatex(
                    latex,
                    baseFontSize: fontSize,
                    isDisplayStyle: false
                )
                let drawX = mathRect.minX + max(1.0, (mathRect.width - mathBox.width) * 0.5)
                let mathColor = currentTheme.headingNSColor.withAlphaComponent(dimFactor)
                mathBox.drawBox(drawX, baselineY, mathColor)

            case let .inlineCode(codeRange, codeFontSize, dimFactor):
                let codeGlyphs = layoutManager.glyphRange(forCharacterRange: codeRange, actualCharacterRange: nil)
                guard codeGlyphs.location != NSNotFound, codeGlyphs.length > 0 else { continue }
                let baselineOffset = (self.textStorage?.attribute(.baselineOffset, at: codeRange.location, effectiveRange: nil) as? CGFloat) ?? 0.0
                let codeFont = currentTheme.codeFont(size: codeFontSize)
                currentTheme.codeBackgroundNSColor.withAlphaComponent(dimFactor).setFill()

                // Draw one pill per line fragment so a code span that wraps does not cover both lines.
                var glyphIndex = codeGlyphs.location
                while glyphIndex < NSMaxRange(codeGlyphs) {
                    var fragmentGlyphs = NSRange()
                    let lineFrag = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: &fragmentGlyphs)
                    let pieceGlyphs = NSIntersectionRange(fragmentGlyphs, codeGlyphs)
                    guard pieceGlyphs.length > 0 else { break }
                    var pieceRect = layoutManager.boundingRect(forGlyphRange: pieceGlyphs, in: textContainer)
                    pieceRect.origin.x += origin.x
                    let glyphLoc = layoutManager.location(forGlyphAt: pieceGlyphs.location)
                    let baselineY = origin.y + lineFrag.minY + glyphLoc.y - baselineOffset
                    let pillRect = NSRect(
                        x: pieceRect.minX - 3.0,
                        y: baselineY - codeFont.ascender - 2.0,
                        width: pieceRect.width + 6.0,
                        height: codeFont.ascender + abs(codeFont.descender) + 4.0
                    )
                    NSBezierPath(roundedRect: pillRect, xRadius: 4.0, yRadius: 4.0).fill()
                    glyphIndex = NSMaxRange(pieceGlyphs)
                }

            case let .kbdPill(kbdRange, kbdFontSize, dimFactor):
                let kbdGlyphs = layoutManager.glyphRange(forCharacterRange: kbdRange, actualCharacterRange: nil)
                guard kbdGlyphs.location != NSNotFound else { continue }
                var kbdRect = layoutManager.boundingRect(forGlyphRange: kbdGlyphs, in: textContainer)
                kbdRect.origin.x += origin.x
                kbdRect.origin.y += origin.y

                let lineFrag = layoutManager.lineFragmentRect(forGlyphAt: kbdGlyphs.location, effectiveRange: nil)
                let glyphLoc = layoutManager.location(forGlyphAt: kbdGlyphs.location)
                let baselineOffset = (self.textStorage?.attribute(.baselineOffset, at: kbdRange.location, effectiveRange: nil) as? CGFloat) ?? 0.0
                let baselineY = origin.y + lineFrag.minY + glyphLoc.y - baselineOffset
                let kbdFont = currentTheme.codeFont(size: kbdFontSize)
                let pillTop = baselineY - kbdFont.ascender - 2.5
                let pillHeight = kbdFont.ascender + abs(kbdFont.descender) + 5.0
                let pillRect = NSRect(
                    x: kbdRect.minX - 4.0,
                    y: pillTop,
                    width: kbdRect.width + 8.0,
                    height: pillHeight
                )
                let shadowRect = pillRect.offsetBy(dx: 0, dy: 1.5)
                let shadowColor = NSColor.black.withAlphaComponent((currentTheme.isDark ? 0.45 : 0.08) * dimFactor)
                shadowColor.setFill()
                NSBezierPath(roundedRect: shadowRect, xRadius: 4.5, yRadius: 4.5).fill()

                currentTheme.codeBackgroundNSColor.withAlphaComponent(dimFactor).setFill()
                NSBezierPath(roundedRect: pillRect, xRadius: 4.5, yRadius: 4.5).fill()

                let borderColor = currentTheme.isDark
                    ? NSColor.white.withAlphaComponent(0.22 * dimFactor)
                    : NSColor.black.withAlphaComponent(0.16 * dimFactor)
                borderColor.setStroke()
                let borderPath = NSBezierPath(roundedRect: pillRect.insetBy(dx: 0.5, dy: 0.5), xRadius: 4.5, yRadius: 4.5)
                borderPath.lineWidth = 1.0
                borderPath.stroke()

            case let .mermaidBlockRendered(mermaidSource, fullBlockRange, dimFactor):
                let blockGlyphs = layoutManager.glyphRange(forCharacterRange: fullBlockRange, actualCharacterRange: nil)
                guard blockGlyphs.location != NSNotFound else { continue }
                var blockRect = layoutManager.boundingRect(forGlyphRange: blockGlyphs, in: textContainer)
                blockRect.origin.x = origin.x
                blockRect.origin.y += origin.y
                blockRect.size.width = contentWidth

                let cardRect = blockRect.insetBy(dx: 0, dy: 3)
                currentTheme.codeBackgroundNSColor.withAlphaComponent(dimFactor).setFill()
                NSBezierPath(roundedRect: cardRect, xRadius: 8.0, yRadius: 8.0).fill()

                let (img, _) = FolioMediaImageCache.shared.mermaidImage(for: mermaidSource, isDark: currentTheme.isDark)
                let innerRect = cardRect.insetBy(dx: 16.0, dy: 12.0)
                if let img = img, img.size.width > 0, img.size.height > 0, innerRect.width > 10, innerRect.height > 10 {
                    let intrinsicSize = img.size
                    let scale = min(1.0, min(innerRect.width / intrinsicSize.width, innerRect.height / intrinsicSize.height))
                    let drawW = intrinsicSize.width * scale
                    let drawH = intrinsicSize.height * scale
                    let drawRect = NSRect(
                        x: innerRect.midX - drawW * 0.5,
                        y: innerRect.midY - drawH * 0.5,
                        width: drawW,
                        height: drawH
                    )
                    img.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: dimFactor, respectFlipped: true, hints: nil)
                }

                // Draw subtle "MERMAID" badge in top-right corner
                let badgeAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedSystemFont(ofSize: 9.5, weight: .semibold),
                    .foregroundColor: currentTheme.secondaryTextNSColor.withAlphaComponent(dimFactor * 0.85)
                ]
                let badgeStr = "MERMAID" as NSString
                let badgeSize = badgeStr.size(withAttributes: badgeAttrs)
                badgeStr.draw(
                    at: NSPoint(x: cardRect.maxX - badgeSize.width - 10.0, y: cardRect.minY + 6.0),
                    withAttributes: badgeAttrs
                )

            case let .svgBlockRendered(svgSource, fullBlockRange, dimFactor):
                let blockGlyphs = layoutManager.glyphRange(forCharacterRange: fullBlockRange, actualCharacterRange: nil)
                guard blockGlyphs.location != NSNotFound else { continue }
                var blockRect = layoutManager.boundingRect(forGlyphRange: blockGlyphs, in: textContainer)
                blockRect.origin.x = origin.x
                blockRect.origin.y += origin.y
                blockRect.size.width = contentWidth

                let cardRect = blockRect.insetBy(dx: 0, dy: 3)
                currentTheme.codeBackgroundNSColor.withAlphaComponent(dimFactor).setFill()
                NSBezierPath(roundedRect: cardRect, xRadius: 8.0, yRadius: 8.0).fill()

                let (img, _) = FolioMediaImageCache.shared.svgImage(for: svgSource)
                let innerRect = cardRect.insetBy(dx: 16.0, dy: 12.0)
                if let img = img, img.size.width > 0, img.size.height > 0, innerRect.width > 10, innerRect.height > 10 {
                    let intrinsicSize = img.size
                    let scale = min(1.0, min(innerRect.width / intrinsicSize.width, innerRect.height / intrinsicSize.height))
                    let drawW = intrinsicSize.width * scale
                    let drawH = intrinsicSize.height * scale
                    let drawRect = NSRect(
                        x: innerRect.midX - drawW * 0.5,
                        y: innerRect.midY - drawH * 0.5,
                        width: drawW,
                        height: drawH
                    )
                    img.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: dimFactor, respectFlipped: true, hints: nil)
                }

                let badgeAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedSystemFont(ofSize: 9.5, weight: .semibold),
                    .foregroundColor: currentTheme.secondaryTextNSColor.withAlphaComponent(dimFactor * 0.85)
                ]
                let badgeStr = "SVG" as NSString
                let badgeSize = badgeStr.size(withAttributes: badgeAttrs)
                badgeStr.draw(
                    at: NSPoint(x: cardRect.maxX - badgeSize.width - 10.0, y: cardRect.minY + 6.0),
                    withAttributes: badgeAttrs
                )

            case let .imageRendered(url, alt, fullRange, explicitWidth, explicitHeight, baseDirectoryURL, dimFactor):
                let lineFrag = layoutManager.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
                let imgGlyphIdx = layoutManager.glyphIndexForCharacter(at: fullRange.location)
                let glyphX = (imgGlyphIdx != NSNotFound && imgGlyphIdx < layoutManager.numberOfGlyphs)
                    ? layoutManager.location(forGlyphAt: imgGlyphIdx).x
                    : 0.0
                let lineKey = dec.lineRange.location
                let currentOffset = imageXOffsetByLineLocation[lineKey] ?? 0.0
                let startX = origin.x + max(glyphX, currentOffset)
                let remainingWidth = max(80.0, (origin.x + contentWidth) - startX)

                let isVideo = FolioMediaImageCache.isVideoURL(url)
                let loadedImg = FolioMediaImageCache.shared.image(
                    for: url,
                    baseDirectoryURL: baseDirectoryURL,
                    isDark: currentTheme.isDark
                )

                if let img = loadedImg, img.size.width > 0, img.size.height > 0 {
                    let intrinsicSize = img.size
                    let aspect = intrinsicSize.height / max(1.0, intrinsicSize.width)
                    let targetW: CGFloat
                    let targetH: CGFloat
                    if let ew = explicitWidth, let eh = explicitHeight {
                        targetW = ew
                        targetH = eh
                    } else if let ew = explicitWidth {
                        targetW = ew
                        targetH = round(ew * aspect)
                    } else if let eh = explicitHeight {
                        targetH = eh
                        targetW = round(eh / max(0.01, aspect))
                    } else {
                        targetW = intrinsicSize.width
                        targetH = intrinsicSize.height
                    }
                    let maxDrawH = max(18.0, lineFrag.height - 6.0)
                    let scale = min(1.0, min(remainingWidth / max(1.0, targetW), maxDrawH / max(1.0, targetH)))
                    let drawW = targetW * scale
                    let drawH = targetH * scale
                    let drawRect = NSRect(
                        x: startX,
                        y: origin.y + lineFrag.minY + (lineFrag.height - drawH) * 0.5,
                        width: drawW,
                        height: drawH
                    )
                    img.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: dimFactor, respectFlipped: true, hints: nil)

                    if isVideo {
                        let circleRadius: CGFloat = 20.0
                        let circleRect = NSRect(
                            x: drawRect.midX - circleRadius,
                            y: drawRect.midY - circleRadius,
                            width: circleRadius * 2.0,
                            height: circleRadius * 2.0
                        )
                        NSColor.black.withAlphaComponent(0.62 * dimFactor).setFill()
                        NSBezierPath(ovalIn: circleRect).fill()

                        let playTriangle = NSBezierPath()
                        playTriangle.move(to: NSPoint(x: drawRect.midX - 5.0, y: drawRect.midY - 7.5))
                        playTriangle.line(to: NSPoint(x: drawRect.midX - 5.0, y: drawRect.midY + 7.5))
                        playTriangle.line(to: NSPoint(x: drawRect.midX + 8.0, y: drawRect.midY))
                        playTriangle.close()
                        NSColor.white.withAlphaComponent(0.95 * dimFactor).setFill()
                        playTriangle.fill()
                    }
                    imageXOffsetByLineLocation[lineKey] = (startX - origin.x) + drawW + 8.0
                } else {
                    // Compact placeholder card for pending/missing image or video
                    let cardWidth = min(remainingWidth, max(200.0, min(380.0, explicitWidth ?? 360.0)))
                    let cardHeight = min(50.0, max(38.0, lineFrag.height - 6.0))
                    let cardRect = NSRect(
                        x: startX,
                        y: origin.y + lineFrag.minY + (lineFrag.height - cardHeight) * 0.5,
                        width: cardWidth,
                        height: cardHeight
                    )
                    imageXOffsetByLineLocation[lineKey] = (startX - origin.x) + cardWidth + 8.0

                    currentTheme.codeBackgroundNSColor.withAlphaComponent(dimFactor).setFill()
                    NSBezierPath(roundedRect: cardRect, xRadius: 7.0, yRadius: 7.0).fill()

                    let cardBorder = currentTheme.isDark
                        ? NSColor.white.withAlphaComponent(0.10 * dimFactor)
                        : NSColor.black.withAlphaComponent(0.08 * dimFactor)
                    cardBorder.setStroke()
                    let strokePath = NSBezierPath(roundedRect: cardRect.insetBy(dx: 0.5, dy: 0.5), xRadius: 7.0, yRadius: 7.0)
                    strokePath.lineWidth = 1.0
                    strokePath.stroke()

                    let badgeLabel = isVideo ? "▶ VIDEO" : "IMAGE"
                    let badgeAttrs: [NSAttributedString.Key: Any] = [
                        .font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .semibold),
                        .foregroundColor: currentTheme.linkNSColor.withAlphaComponent(dimFactor)
                    ]
                    let badgeStr = badgeLabel as NSString
                    let badgeSize = badgeStr.size(withAttributes: badgeAttrs)
                    let pillRect = NSRect(
                        x: cardRect.minX + 12.0,
                        y: cardRect.midY - badgeSize.height * 0.5 - 3.0,
                        width: badgeSize.width + 12.0,
                        height: badgeSize.height + 6.0
                    )
                    currentTheme.linkNSColor.withAlphaComponent(0.14 * dimFactor).setFill()
                    NSBezierPath(roundedRect: pillRect, xRadius: 4.5, yRadius: 4.5).fill()
                    badgeStr.draw(
                        at: NSPoint(x: pillRect.minX + 6.0, y: pillRect.minY + 3.0),
                        withAttributes: badgeAttrs
                    )

                    let titleText = alt.isEmpty ? (url as NSString).lastPathComponent : alt
                    let titleAttrs: [NSAttributedString.Key: Any] = [
                        .font: currentTheme.bodyFont(size: 12.0, bold: true),
                        .foregroundColor: currentTheme.textNSColor.withAlphaComponent(dimFactor)
                    ]
                    let subAttrs: [NSAttributedString.Key: Any] = [
                        .font: currentTheme.codeFont(size: 10.5),
                        .foregroundColor: currentTheme.secondaryTextNSColor.withAlphaComponent(dimFactor * 0.85)
                    ]
                    let textX = pillRect.maxX + 10.0
                    NSGraphicsContext.saveGraphicsState()
                    NSBezierPath(rect: cardRect.insetBy(dx: 8.0, dy: 2.0)).addClip()
                    (titleText as NSString).draw(
                        at: NSPoint(x: textX, y: cardRect.midY - 14.0),
                        withAttributes: titleAttrs
                    )
                    (url as NSString).draw(
                        at: NSPoint(x: textX, y: cardRect.midY + 1.0),
                        withAttributes: subAttrs
                    )
                    NSGraphicsContext.restoreGraphicsState()
                }

            case let .listBullet(bulletRange, dimFactor):
                let bulletGlyphs = layoutManager.glyphRange(forCharacterRange: bulletRange, actualCharacterRange: nil)
                guard bulletGlyphs.location != NSNotFound else { continue }
                var bulletRect = layoutManager.boundingRect(forGlyphRange: bulletGlyphs, in: textContainer)
                bulletRect.origin.x += origin.x
                bulletRect.origin.y += origin.y

                let lineFrag = layoutManager.lineFragmentRect(forGlyphAt: bulletGlyphs.location, effectiveRange: nil)
                let glyphLoc = layoutManager.location(forGlyphAt: bulletGlyphs.location)
                let baselineY = origin.y + lineFrag.minY + glyphLoc.y
                let baseFont = currentTheme.bodyFont(size: currentTheme.baseFontSize * typographySettings.fontSizeScale)
                let midY = baselineY - (baseFont.ascender + baseFont.descender) * 0.5
                let dotDiameter: CGFloat = 5.5
                let dotRect = NSRect(
                    x: bulletRect.midX - dotDiameter * 0.5,
                    y: midY - dotDiameter * 0.5,
                    width: dotDiameter,
                    height: dotDiameter
                )
                currentTheme.linkNSColor.withAlphaComponent(dimFactor).setFill()
                NSBezierPath(ovalIn: dotRect).fill()

            case .horizontalRule:
                let hrColor = currentTheme.isDark
                    ? NSColor.white.withAlphaComponent(0.18)
                    : NSColor.black.withAlphaComponent(0.13)
                hrColor.setFill()
                let lineFrag = layoutManager.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
                let midY = origin.y + lineFrag.minY + lineFrag.height * 0.5 + 2.0
                let hrRect = NSRect(x: origin.x, y: midY - 0.75, width: contentWidth, height: 1.5)
                NSBezierPath(roundedRect: hrRect, xRadius: 0.75, yRadius: 0.75).fill()

            case let .tableRow(isHeader, isSeparator, isFirstRow, isLastRow, bodyRowIndex, tableOffsetX, tableWidth, columnDividers):
                // Allow wide tables to exceed `contentWidth` without clamping!
                let effectiveWidth = max(tableWidth, 240.0)
                let startX = origin.x + (tableOffsetX > 0 ? tableOffsetX : max(0.0, floor((contentWidth - effectiveWidth) * 0.5)))
                let usedFrag = layoutManager.lineFragmentUsedRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
                let rowY = origin.y + usedFrag.minY
                let rowH = max(isSeparator ? 2.0 : 32.0, usedFrag.height)
                let rowRect = NSRect(x: startX, y: rowY, width: effectiveWidth, height: rowH)
                let outerBorderColor = currentTheme.isDark
                    ? NSColor.white.withAlphaComponent(0.14)
                    : NSColor.black.withAlphaComponent(0.11)
                let innerGridColor = currentTheme.isDark
                    ? NSColor.white.withAlphaComponent(0.08)
                    : NSColor.black.withAlphaComponent(0.065)

                if isSeparator {
                    // Draw crisp horizontal separator line between header and body
                    let headerDividerColor = currentTheme.isDark
                        ? NSColor.white.withAlphaComponent(0.18)
                        : NSColor.black.withAlphaComponent(0.15)
                    headerDividerColor.setFill()
                    NSRect(x: rowRect.minX, y: rowRect.midY - 0.5, width: effectiveWidth, height: 1.0).fill()

                    // Left and right outer borders across separator
                    outerBorderColor.setFill()
                    NSRect(x: rowRect.minX, y: rowRect.minY, width: 1.0, height: rowRect.height).fill()
                    NSRect(x: rowRect.maxX - 1.0, y: rowRect.minY, width: 1.0, height: rowRect.height).fill()
                    continue
                }

                // Background tint for header or alternating body rows
                if isHeader {
                    let headerBg = currentTheme.isDark
                        ? NSColor.white.withAlphaComponent(0.06)
                        : NSColor.black.withAlphaComponent(0.038)
                    headerBg.setFill()
                    rowRect.fill()
                } else if bodyRowIndex % 2 == 1 {
                    let stripeBg = currentTheme.isDark
                        ? NSColor.white.withAlphaComponent(0.025)
                        : NSColor.black.withAlphaComponent(0.016)
                    stripeBg.setFill()
                    rowRect.fill()
                }

                // Subtle vertical column dividers
                innerGridColor.setFill()
                for divX in columnDividers where divX < effectiveWidth - 4.0 {
                    let colLineRect = NSRect(x: startX + divX, y: rowRect.minY, width: 1.0, height: rowRect.height)
                    colLineRect.fill()
                }

                // Subtle horizontal divider at the bottom of each non-last body row
                if !isHeader && !isLastRow {
                    innerGridColor.setFill()
                    NSRect(x: rowRect.minX, y: rowRect.maxY - 0.5, width: effectiveWidth, height: 0.75).fill()
                }

                // Outer table frame edges (top on first row, bottom on last row, left & right on all rows)
                outerBorderColor.setFill()
                NSRect(x: rowRect.minX, y: rowRect.minY, width: 1.0, height: rowRect.height).fill()
                NSRect(x: rowRect.maxX - 1.0, y: rowRect.minY, width: 1.0, height: rowRect.height).fill()
                if isFirstRow {
                    NSRect(x: rowRect.minX, y: rowRect.minY, width: effectiveWidth, height: 1.0).fill()
                }
                if isLastRow {
                    NSRect(x: rowRect.minX, y: rowRect.maxY - 1.0, width: effectiveWidth, height: 1.0).fill()
                }
            }
        }
    }

    private func presentCodeFenceLanguageMenu(for lineRange: NSRange, currentLanguage: String, badgeRect: NSRect) {
        let menu = NSMenu(title: "Select Language")
        let normalizedCurrent = currentLanguage.lowercased().trimmingCharacters(in: .whitespaces)
        var matchedAny = false

        for lang in Self.supportedCodeFenceLanguages {
            let item = NSMenuItem(
                title: lang.title,
                action: #selector(handleSelectCodeFenceLanguage(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = CodeFenceLanguageActionPayload(lineRange: lineRange, languageId: lang.id)
            item.image = Self.languageMenuDotImage(for: lang.id, isDark: currentTheme.isDark)
            if lang.aliases.contains(normalizedCurrent) {
                item.state = .on
                matchedAny = true
            }
            menu.addItem(item)
        }

        if !normalizedCurrent.isEmpty && !matchedAny {
            menu.insertItem(.separator(), at: 0)
            let customItem = NSMenuItem(
                title: normalizedCurrent.uppercased(),
                action: #selector(handleSelectCodeFenceLanguage(_:)),
                keyEquivalent: ""
            )
            customItem.target = self
            customItem.representedObject = CodeFenceLanguageActionPayload(lineRange: lineRange, languageId: normalizedCurrent)
            customItem.image = Self.languageMenuDotImage(for: normalizedCurrent, isDark: currentTheme.isDark)
            customItem.state = .on
            menu.insertItem(customItem, at: 0)
        }

        menu.addItem(.separator())
        let plainItem = NSMenuItem(
            title: "Plain Text",
            action: #selector(handleSelectCodeFenceLanguage(_:)),
            keyEquivalent: ""
        )
        plainItem.target = self
        plainItem.representedObject = CodeFenceLanguageActionPayload(lineRange: lineRange, languageId: "")
        plainItem.image = Self.languageMenuDotImage(for: "", isDark: currentTheme.isDark)
        if normalizedCurrent.isEmpty {
            plainItem.state = .on
        }
        menu.addItem(plainItem)

        menu.popUp(
            positioning: nil,
            at: NSPoint(x: badgeRect.minX, y: badgeRect.maxY + 4.0),
            in: self
        )
    }

    @objc private func handleSelectCodeFenceLanguage(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? CodeFenceLanguageActionPayload else { return }
        let nsStr = self.string as NSString
        guard payload.lineRange.location < nsStr.length else { return }

        let safeLineRange = nsStr.lineRange(for: NSRange(location: payload.lineRange.location, length: 0))
        var contentEnd = NSMaxRange(safeLineRange)
        while contentEnd > safeLineRange.location {
            let ch = nsStr.character(at: contentEnd - 1)
            if ch == 10 || ch == 13 {
                contentEnd -= 1
            } else {
                break
            }
        }
        let contentRange = NSRange(location: safeLineRange.location, length: contentEnd - safeLineRange.location)
        let currentLineContent = nsStr.substring(with: contentRange)
        let leadingWhitespace = currentLineContent.prefix(while: { $0 == " " || $0 == "\t" })
        let newLineContent = "\(leadingWhitespace)```\(payload.languageId)"

        if shouldChangeText(in: contentRange, replacementString: newLineContent) {
            replaceCharacters(in: contentRange, with: newLineContent)
            didChangeText()
        }
    }

    private var mediaHoverTrackingArea: NSTrackingArea?

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = mediaHoverTrackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        mediaHoverTrackingArea = area
    }

    public func imageAltTooltip(at point: NSPoint) -> String? {
        guard !isSourceCodeMode, let layoutManager = self.layoutManager else { return nil }
        let origin = self.textContainerOrigin
        let fullContentWidth = self.bounds.width - origin.x * 2
        let contentWidth = proseColumnWidth > 0 ? proseColumnWidth : fullContentWidth
        var imageXOffsetByLineLocation: [Int: CGFloat] = [:]

        for dec in lineDecorations {
            guard case let .imageRendered(url, alt, fullRange, explicitWidth, explicitHeight, baseDirectoryURL, _) = dec.kind else {
                continue
            }
            let glyphRange = layoutManager.glyphRange(forCharacterRange: dec.lineRange, actualCharacterRange: nil)
            guard glyphRange.location != NSNotFound else { continue }
            let lineFrag = layoutManager.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
            let imgGlyphIdx = layoutManager.glyphIndexForCharacter(at: fullRange.location)
            let glyphX = (imgGlyphIdx != NSNotFound && imgGlyphIdx < layoutManager.numberOfGlyphs)
                ? layoutManager.location(forGlyphAt: imgGlyphIdx).x
                : 0.0
            let lineKey = dec.lineRange.location
            let currentOffset = imageXOffsetByLineLocation[lineKey] ?? 0.0
            let startX = origin.x + max(glyphX, currentOffset)
            let remainingWidth = max(80.0, (origin.x + contentWidth) - startX)

            let loadedImg = FolioMediaImageCache.shared.image(
                for: url,
                baseDirectoryURL: baseDirectoryURL,
                isDark: currentTheme.isDark
            )

            let hitRect: NSRect
            if let img = loadedImg, img.size.width > 0, img.size.height > 0 {
                let intrinsicSize = img.size
                let aspect = intrinsicSize.height / max(1.0, intrinsicSize.width)
                let targetW: CGFloat
                let targetH: CGFloat
                if let ew = explicitWidth, let eh = explicitHeight {
                    targetW = ew
                    targetH = eh
                } else if let ew = explicitWidth {
                    targetW = ew
                    targetH = round(ew * aspect)
                } else if let eh = explicitHeight {
                    targetH = eh
                    targetW = round(eh / max(0.01, aspect))
                } else {
                    targetW = intrinsicSize.width
                    targetH = intrinsicSize.height
                }
                let maxDrawH = max(18.0, lineFrag.height - 6.0)
                let scale = min(1.0, min(remainingWidth / max(1.0, targetW), maxDrawH / max(1.0, targetH)))
                let drawW = targetW * scale
                let drawH = targetH * scale
                hitRect = NSRect(
                    x: startX,
                    y: origin.y + lineFrag.minY + (lineFrag.height - drawH) * 0.5,
                    width: drawW,
                    height: drawH
                )
                imageXOffsetByLineLocation[lineKey] = (startX - origin.x) + drawW + 8.0
            } else {
                let cardWidth = min(remainingWidth, max(200.0, min(380.0, explicitWidth ?? 360.0)))
                let cardHeight = min(50.0, max(38.0, lineFrag.height - 6.0))
                hitRect = NSRect(
                    x: startX,
                    y: origin.y + lineFrag.minY + (lineFrag.height - cardHeight) * 0.5,
                    width: cardWidth,
                    height: cardHeight
                )
                imageXOffsetByLineLocation[lineKey] = (startX - origin.x) + cardWidth + 8.0
            }

            if hitRect.contains(point) {
                return alt.isEmpty ? nil : alt
            }
        }
        return nil
    }

    public override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let tip = imageAltTooltip(at: point)
        if self.toolTip != tip {
            self.toolTip = tip
        }
        super.mouseMoved(with: event)
    }

    public override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        // 1. Hit-test code fence language selector badge on the right
        if !isSourceCodeMode, let layoutManager = self.layoutManager {
            let origin = self.textContainerOrigin
            let fullContentWidth = self.bounds.width - origin.x * 2
            let contentWidth = proseColumnWidth > 0 ? proseColumnWidth : fullContentWidth
            for dec in lineDecorations {
                if case .codeFenceStart(let language) = dec.kind,
                   let badge = computeCodeFenceBadgeGeometry(
                       for: dec.lineRange,
                       language: language,
                       layoutManager: layoutManager,
                       origin: origin,
                       contentWidth: contentWidth
                   ) {
                    if badge.pillRect.insetBy(dx: -4.0, dy: -4.0).contains(point) {
                        presentCodeFenceLanguageMenu(
                            for: dec.lineRange,
                            currentLanguage: language,
                            badgeRect: badge.pillRect
                        )
                        return
                    }
                }
            }
        }

        // 2. Hit-test task list checkboxes
        let charIndex = characterIndexForInsertion(at: point)
        let nsStr = self.string as NSString

        if charIndex < nsStr.length {
            let lineRange = nsStr.lineRange(for: NSRange(location: charIndex, length: 0))
            let lineStr = nsStr.substring(with: lineRange)
            if let rangeOfBox = lineStr.range(of: #"\[[ xX]\]"#, options: .regularExpression) {
                let nsBoxRange = NSRange(rangeOfBox, in: lineStr)
                let absBoxRange = NSRange(location: lineRange.location + nsBoxRange.location, length: nsBoxRange.length)
                let expandedHitRange = NSRange(
                    location: max(0, absBoxRange.location - 2),
                    length: min(nsStr.length - max(0, absBoxRange.location - 2), absBoxRange.length + 3)
                )
                if NSLocationInRange(charIndex, expandedHitRange) {
                    onToggleCheckboxAtCharacterIndex?(absBoxRange.location)
                    return
                }
            }
        }

        super.mouseDown(with: event)
    }

    public override func insertNewline(_ sender: Any?) {
        let sel = self.selectedRange()
        let nsStr = self.string as NSString
        guard sel.location <= nsStr.length else {
            super.insertNewline(sender)
            return
        }

        let lineRange = nsStr.lineRange(for: NSRange(location: sel.location, length: 0))
        let lineUpToCursor = nsStr.substring(with: NSRange(location: lineRange.location, length: sel.location - lineRange.location))

        let action = lineUpToCursor.withCString { cStr in
            ot_engine_newline_continuation(cStr)
        }
        defer {
            ot_engine_free_newline_action(action)
        }

        switch action.kind {
        case 1:
            if shouldChangeText(in: lineRange, replacementString: "\n") {
                replaceCharacters(in: lineRange, with: "\n")
                didChangeText()
            }
            return
        case 2:
            if let prefixPtr = action.prefix {
                let prefix = String(cString: prefixPtr)
                super.insertNewline(sender)
                insertText(prefix, replacementRange: self.selectedRange())
                return
            }
        default:
            break
        }

        super.insertNewline(sender)
        startNewParagraphIfSoftBreak()
    }

    /// In live mode a single newline inside a paragraph is a soft break and renders as a space,
    /// so Return would look like it did nothing. Insert a second newline to start a new paragraph.
    private func startNewParagraphIfSoftBreak() {
        guard !isSourceCodeMode, let storage = textStorage else { return }
        let location = selectedRange().location
        guard location > 0, location <= storage.length,
              (storage.string as NSString).character(at: location - 1) == 10,
              storage.attribute(MarkdownLiveStyler.softLineBreakAttributeKey, at: location - 1, effectiveRange: nil) != nil else {
            return
        }
        insertText("\n", replacementRange: selectedRange())
    }

    public func centerSelectionIfTypewriter() {
        guard isTypewriterMode,
              let layoutManager = self.layoutManager,
              let textContainer = self.textContainer,
              let scrollView = self.enclosingScrollView else {
            return
        }
        let sel = self.selectedRange()
        let glyphRange = layoutManager.glyphRange(forCharacterRange: sel, actualCharacterRange: nil)
        let caretRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        let visibleHeight = scrollView.contentView.bounds.height
        let targetY = max(0, caretRect.midY + textContainerOrigin.y - visibleHeight * 0.45)
        let currentX = scrollView.contentView.bounds.origin.x
        scrollView.contentView.scroll(to: NSPoint(x: currentX, y: targetY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}

public struct HybridMarkdownEditorRepresentable: NSViewRepresentable {
    @ObservedObject var viewModel: EditorWorkspaceViewModel

    public init(viewModel: EditorWorkspaceViewModel) {
        self.viewModel = viewModel
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }

    public func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = viewModel.theme.editorBackgroundNSColor

        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        layoutManager.delegate = context.coordinator.softLineBreakLayoutDelegate
        textStorage.addLayoutManager(layoutManager)

        let textContainer = NSTextContainer(containerSize: NSSize(width: 800, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = false
        textContainer.lineFragmentPadding = 0.0
        layoutManager.addTextContainer(textContainer)

        let textView = HybridMarkdownTextView(frame: .zero, textContainer: textContainer)
        textView.minSize = NSSize(width: 0, height: 400)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width]
        textView.allowsUndo = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isContinuousSpellCheckingEnabled = viewModel.spellCheckEnabled
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true

        textView.delegate = context.coordinator
        textView.workspaceViewModel = viewModel
        textView.editorCoordinator = context.coordinator
        textView.externalUpdateHighlightRanges = viewModel.externalUpdateHighlightRanges
        context.coordinator.textView = textView
        viewModel.activeTextView = textView

        textView.onToggleCheckboxAtCharacterIndex = { [weak viewModel] boxLocation in
            viewModel?.toggleTaskCheckbox(at: boxLocation)
        }

        scrollView.documentView = textView

        // Set initial text and apply styling
        context.coordinator.isProgrammaticUpdate = true
        textView.string = viewModel.markdownText
        context.coordinator.isProgrammaticUpdate = false
        textView.typographySettings = viewModel.typography
        context.coordinator.updateInsets(for: scrollView, textView: textView, theme: viewModel.theme)
        context.coordinator.restyle(textView: textView)

        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.scrollViewFrameDidChange(_:)),
            name: NSView.frameDidChangeNotification,
            object: scrollView
        )
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.mediaImageDidLoad(_:)),
            name: FolioMediaImageCache.imageDidLoadNotification,
            object: nil
        )
        scrollView.postsFrameChangedNotifications = true

        return scrollView
    }

    public func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? HybridMarkdownTextView else { return }
        context.coordinator.viewModel = viewModel
        textView.workspaceViewModel = viewModel
        textView.editorCoordinator = context.coordinator
        viewModel.activeTextView = textView

        scrollView.backgroundColor = viewModel.theme.editorBackgroundNSColor
        textView.backgroundColor = viewModel.theme.editorBackgroundNSColor
        textView.insertionPointColor = viewModel.theme.linkNSColor
        textView.currentTheme = viewModel.theme
        textView.typographySettings = viewModel.typography
        textView.isTypewriterMode = viewModel.typewriterMode
        textView.isSourceCodeMode = viewModel.sourceCodeMode
        textView.isContinuousSpellCheckingEnabled = viewModel.spellCheckEnabled
        if textView.externalUpdateHighlightRanges != viewModel.externalUpdateHighlightRanges {
            textView.externalUpdateHighlightRanges = viewModel.externalUpdateHighlightRanges
        }

        context.coordinator.updateInsets(for: scrollView, textView: textView, theme: viewModel.theme)

        if !context.coordinator.isUpdatingFromTextView && textView.string != viewModel.markdownText {
            let savedSelection = textView.selectedRange()
            textView.applyProgrammaticDocumentText(viewModel.markdownText, selectedRange: savedSelection)
        } else if context.coordinator.lastTheme != viewModel.theme ||
                  context.coordinator.lastTypography != viewModel.typography ||
                  context.coordinator.lastSourceMode != viewModel.sourceCodeMode ||
                  context.coordinator.lastPrettyMode != viewModel.prettyModeEnabled ||
                  context.coordinator.lastFileURL != viewModel.currentFileURL ||
                  context.coordinator.lastFocusMode != viewModel.focusMode {
            context.coordinator.restyle(textView: textView)
        }

        if let scrollTarget = viewModel.pendingScrollToCharacterLocation {
            DispatchQueue.main.async {
                viewModel.pendingScrollToCharacterLocation = nil
                let nsLen = (textView.string as NSString).length
                let safeLoc = max(0, min(scrollTarget, nsLen))
                let targetRange = NSRange(location: safeLoc, length: 0)
                textView.window?.makeFirstResponder(textView)
                textView.setSelectedRange(targetRange)
                textView.scrollRangeToVisible(targetRange)
                context.coordinator.restyle(textView: textView)
            }
        }
    }

    @MainActor
    public final class Coordinator: NSObject, NSTextViewDelegate {
        var viewModel: EditorWorkspaceViewModel
        weak var textView: HybridMarkdownTextView?
        var isUpdatingFromTextView = false
        var isProgrammaticUpdate = false
        var isRestyling = false

        var lastTheme: EditorTheme?
        var lastTypography: EditorTypographySettings?
        var lastSourceMode: Bool?
        var lastPrettyMode: Bool?
        var lastFileURL: URL?
        var lastFocusMode: Bool?
        var lastActiveLineRange: NSRange?
        var lastContentWidth: CGFloat = 0
        var maxTableWidth: CGFloat = 0

        /// Strong owner of the layout manager delegate (the layout manager holds it weakly).
        let softLineBreakLayoutDelegate = SoftLineBreakLayoutDelegate()
        /// Locations inside paragraphs the user edited. Each paragraph is rewrapped to the
        /// source line width when the selection leaves it.
        var reflowAnchors: [Int] = []
        var isApplyingReflow = false

        init(viewModel: EditorWorkspaceViewModel) {
            self.viewModel = viewModel
        }

        @objc func mediaImageDidLoad(_ notification: Notification) {
            guard let tv = textView else { return }
            restyle(textView: tv)
            tv.needsDisplay = true
        }

        @objc func scrollViewFrameDidChange(_ notification: Notification) {
            guard let scrollView = notification.object as? NSScrollView,
                  let tv = textView else { return }
            updateInsets(for: scrollView, textView: tv, theme: viewModel.theme)
            let newContentWidth = currentContentWidth(for: tv)
            if abs(newContentWidth - lastContentWidth) > 0.5 {
                restyle(textView: tv)
            }
        }

        func currentContentWidth(for textView: HybridMarkdownTextView) -> CGFloat {
            let totalWidth = textView.enclosingScrollView?.contentView.bounds.width
                ?? textView.enclosingScrollView?.bounds.width
                ?? textView.bounds.width
            let maxWrite = viewModel.typography.maxColumnWidth
            let horizontalPad = max(44.0, floor((totalWidth - maxWrite) / 2.0))
            let computed = totalWidth - horizontalPad * 2.0
            return computed > 200 ? computed : maxWrite
        }

        func updateInsets(for scrollView: NSScrollView, textView: HybridMarkdownTextView, theme: EditorTheme) {
            let viewportWidth = max(320.0, scrollView.contentView.bounds.width > 0 ? scrollView.contentView.bounds.width : scrollView.bounds.width)
            let maxWrite = viewModel.typography.maxColumnWidth
            let horizontalPad = max(44.0, floor((viewportWidth - maxWrite) / 2.0))
            let proseWidth = max(200.0, viewportWidth - horizontalPad * 2.0)
            let newInset = NSSize(width: horizontalPad, height: 42.0)
            if textView.textContainerInset != newInset {
                textView.textContainerInset = newInset
            }
            if abs(textView.proseColumnWidth - proseWidth) > 0.5 {
                textView.proseColumnWidth = proseWidth
            }

            let effectiveInnerWidth = max(proseWidth, ceil(maxTableWidth + 16.0))
            let targetDocWidth = max(viewportWidth, ceil(effectiveInnerWidth + horizontalPad * 2.0))
            textView.minSize = NSSize(width: targetDocWidth, height: 400)
            if abs(textView.frame.size.width - targetDocWidth) > 0.5 {
                textView.frame.size.width = targetDocWidth
            }
            if let tc = textView.textContainer {
                let targetContainerSize = NSSize(width: effectiveInnerWidth, height: CGFloat.greatestFiniteMagnitude)
                if abs(tc.containerSize.width - targetContainerSize.width) > 0.5 {
                    tc.containerSize = targetContainerSize
                }
            }
        }

        public func textView(
            _ textView: NSTextView,
            shouldChangeTextIn affectedCharRange: NSRange,
            replacementString: String?
        ) -> Bool {
            if !reflowAnchors.isEmpty, let replacement = replacementString {
                let delta = (replacement as NSString).length - affectedCharRange.length
                reflowAnchors = reflowAnchors.map { anchor in
                    anchor > affectedCharRange.location ? max(affectedCharRange.location, anchor + delta) : anchor
                }
            }
            return true
        }

        public func textDidChange(_ notification: Notification) {
            guard !isProgrammaticUpdate, !isRestyling, let tv = textView else { return }
            isUpdatingFromTextView = true
            let currentText = tv.string
            let sel = tv.selectedRange()
            if !isApplyingReflow {
                reflowAnchors.append(sel.location)
                if reflowAnchors.count > 32 {
                    reflowAnchors.removeFirst(reflowAnchors.count - 32)
                }
                viewModel.isLiveKeystrokeInProgress = true
                viewModel.handleEditorTextEdited(currentText, selectedRange: sel)
                viewModel.isLiveKeystrokeInProgress = false
            } else {
                viewModel.withUndoMetadata(origin: .formattingAction, summary: "Reflow Paragraph") {
                    viewModel.handleEditorTextEdited(currentText, selectedRange: sel)
                }
            }
            restyle(textView: tv)
            tv.centerSelectionIfTypewriter()
            isUpdatingFromTextView = false
        }

        public func textViewDidChangeSelection(_ notification: Notification) {
            guard !isProgrammaticUpdate, !isRestyling, let tv = textView else { return }
            let sel = tv.selectedRange()
            let nsStr = tv.string as NSString
            let safeLoc = min(sel.location, nsStr.length)
            let activeLine = nsStr.lineRange(for: NSRange(location: safeLoc, length: 0))

            viewModel.updateSelectionStats(selectedRange: sel)

            if lastActiveLineRange != activeLine || viewModel.focusMode {
                lastActiveLineRange = activeLine
                restyle(textView: tv)
            }
            tv.centerSelectionIfTypewriter()

            if !reflowAnchors.isEmpty && viewModel.sourceLineWidth > 0 {
                DispatchQueue.main.async { [weak self] in
                    self?.reflowEditedParagraphsOutsideSelection()
                }
            }
        }

        /// Rewraps edited paragraphs to the source line width once the selection is outside
        /// them. Runs after the current edit and selection change complete.
        func reflowEditedParagraphsOutsideSelection() {
            guard let tv = textView, !reflowAnchors.isEmpty, !isApplyingReflow else { return }
            let width = viewModel.sourceLineWidth
            guard width > 0 else {
                reflowAnchors.removeAll()
                return
            }
            let text = tv.string
            let nsStr = text as NSString
            let sel = tv.selectedRange()
            let selLines = MarkdownSourceReflow.lineNumber(at: sel.location, in: nsStr)...MarkdownSourceReflow.lineNumber(at: NSMaxRange(sel), in: nsStr)
            let anchorLines = reflowAnchors.map { (anchor: $0, line: MarkdownSourceReflow.lineNumber(at: $0, in: nsStr)) }
            guard anchorLines.contains(where: { !selLines.contains($0.line) }) else { return }

            let spans = MarkdownSourceReflow.paragraphLineSpans(in: text)
            var keep: [Int] = []
            var targets: [ClosedRange<Int>] = []
            for entry in anchorLines {
                guard let span = spans.first(where: { $0.contains(entry.line) }) else { continue }
                if span.overlaps(selLines) {
                    keep.append(entry.anchor)
                } else if !targets.contains(span) {
                    targets.append(span)
                }
            }
            reflowAnchors = keep
            guard !targets.isEmpty else { return }

            isApplyingReflow = true
            tv.breakUndoCoalescing()
            // Bottom-up, so line numbers of the remaining paragraphs stay valid.
            for span in targets.sorted(by: { $0.lowerBound > $1.lowerBound }) {
                let current = tv.string
                guard let edit = MarkdownSourceReflow.reflowParagraph(in: current, line: span.lowerBound, width: width),
                      (current as NSString).substring(with: edit.range) != edit.replacement else { continue }
                var newSel = tv.selectedRange()
                if newSel.location >= NSMaxRange(edit.range) {
                    newSel.location += (edit.replacement as NSString).length - edit.range.length
                }
                if tv.shouldChangeText(in: edit.range, replacementString: edit.replacement) {
                    tv.replaceCharacters(in: edit.range, with: edit.replacement)
                    tv.didChangeText()
                    tv.undoManager?.setActionName("Reflow Paragraph")
                    tv.setSelectedRange(newSel)
                }
            }
            tv.breakUndoCoalescing()
            isApplyingReflow = false
        }

        func restyle(textView: HybridMarkdownTextView) {
            guard !isRestyling, let storage = textView.textStorage else { return }
            isRestyling = true
            let sel = textView.selectedRange()
            let contentWidth = currentContentWidth(for: textView)
            let baseDir = viewModel.currentFileURL?.deletingLastPathComponent() ?? viewModel.workspaceFolderURL

            let analysis = MarkdownLiveStyler.applyStyles(
                to: storage,
                theme: viewModel.theme,
                typography: viewModel.typography,
                sourceCodeMode: viewModel.sourceCodeMode,
                focusMode: viewModel.focusMode,
                selectedRange: sel,
                containerWidth: contentWidth,
                prettyMode: viewModel.prettyModeEnabled,
                baseDirectoryURL: baseDir
            )

            // Clear any spellchecker squiggles on code/math/table decorations
            if let lm = textView.layoutManager {
                let fullRange = NSRange(location: 0, length: (storage.string as NSString).length)
                if !viewModel.spellCheckEnabled {
                    lm.removeTemporaryAttribute(.spellingState, forCharacterRange: fullRange)
                } else {
                    for dec in analysis.decorations {
                        lm.removeTemporaryAttribute(.spellingState, forCharacterRange: dec.lineRange)
                    }
                }
            }

            maxTableWidth = analysis.decorations.reduce(CGFloat(0)) { acc, dec in
                if case let .tableRow(_, _, _, _, _, _, tableW, _) = dec.kind {
                    return max(acc, tableW)
                }
                return acc
            }
            if let scrollView = textView.enclosingScrollView {
                updateInsets(for: scrollView, textView: textView, theme: viewModel.theme)
            }

            textView.lineDecorations = analysis.decorations
            textView.needsDisplay = true
            lastTheme = viewModel.theme
            lastTypography = viewModel.typography
            lastSourceMode = viewModel.sourceCodeMode
            lastPrettyMode = viewModel.prettyModeEnabled
            lastFileURL = viewModel.currentFileURL
            lastFocusMode = viewModel.focusMode
            lastContentWidth = contentWidth

            let currentHeadings = analysis.headings
            if viewModel.headings != currentHeadings {
                DispatchQueue.main.async { [weak self] in
                    self?.viewModel.headings = currentHeadings
                }
            }

            // Update active heading in outline based on cursor position
            let cursorLoc = sel.location
            let activeHeading = currentHeadings.last(where: { $0.characterLocation <= cursorLoc })
            if viewModel.activeHeadingID != activeHeading?.id {
                DispatchQueue.main.async { [weak self] in
                    self?.viewModel.activeHeadingID = activeHeading?.id
                }
            }

            isRestyling = false
        }
    }
}
