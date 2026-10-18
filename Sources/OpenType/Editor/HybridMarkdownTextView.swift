import AppKit
import OpenTypeEngineFFI
import SwiftUI

public final class HybridMarkdownTextView: NSTextView {

    public var currentTheme: EditorTheme = .daylight {
        didSet { needsDisplay = true }
    }

    public var typographySettings: EditorTypographySettings = .default {
        didSet { needsDisplay = true }
    }

    public var lineDecorations: [LineDecoration] = [] {
        didSet { needsDisplay = true }
    }

    public var isTypewriterMode: Bool = false
    public var isSourceCodeMode: Bool = false

    public var onToggleCheckboxAtCharacterIndex: ((Int) -> Void)?

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
        ("html", "HTML / XML", ["html", "xml", "svg"]),
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

        guard !isSourceCodeMode,
              let layoutManager = self.layoutManager,
              let textContainer = self.textContainer else {
            return
        }

        let origin = self.textContainerOrigin
        let contentWidth = self.bounds.width - origin.x * 2

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
                let lastFrag = layoutManager.lineFragmentRect(forGlyphAt: lastGlyphIdx, effectiveRange: nil)

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
                let offset = typographySettings.headingUnderlineOffset * (level == 1 ? 1.0 : 0.85)
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
                guard codeGlyphs.location != NSNotFound else { continue }
                var codeRect = layoutManager.boundingRect(forGlyphRange: codeGlyphs, in: textContainer)
                codeRect.origin.x += origin.x
                codeRect.origin.y += origin.y

                let lineFrag = layoutManager.lineFragmentRect(forGlyphAt: codeGlyphs.location, effectiveRange: nil)
                let glyphLoc = layoutManager.location(forGlyphAt: codeGlyphs.location)
                let baselineOffset = (self.textStorage?.attribute(.baselineOffset, at: codeRange.location, effectiveRange: nil) as? CGFloat) ?? 0.0
                let baselineY = origin.y + lineFrag.minY + glyphLoc.y - baselineOffset
                let codeFont = currentTheme.codeFont(size: codeFontSize)
                let pillTop = baselineY - codeFont.ascender - 2.0
                let pillHeight = codeFont.ascender + abs(codeFont.descender) + 4.0
                let pillRect = NSRect(
                    x: codeRect.minX - 3.0,
                    y: pillTop,
                    width: codeRect.width + 6.0,
                    height: pillHeight
                )
                currentTheme.codeBackgroundNSColor.withAlphaComponent(dimFactor).setFill()
                NSBezierPath(roundedRect: pillRect, xRadius: 4.0, yRadius: 4.0).fill()

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
                let effectiveWidth = min(contentWidth, max(tableWidth, 240.0))
                let startX = origin.x + (tableOffsetX > 0 ? tableOffsetX : max(0.0, floor((contentWidth - effectiveWidth) * 0.5)))
                let rowRect = NSRect(x: startX, y: lineRect.minY, width: effectiveWidth, height: lineRect.height)
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

    public override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        // 1. Hit-test code fence language selector badge on the right
        if !isSourceCodeMode, let layoutManager = self.layoutManager {
            let origin = self.textContainerOrigin
            let contentWidth = self.bounds.width - origin.x * 2
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
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: targetY))
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
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = viewModel.theme.editorBackgroundNSColor

        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)

        let textContainer = NSTextContainer(containerSize: NSSize(width: 800, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        layoutManager.addTextContainer(textContainer)

        let textView = HybridMarkdownTextView(frame: .zero, textContainer: textContainer)
        textView.minSize = NSSize(width: 0, height: 400)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.allowsUndo = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isContinuousSpellCheckingEnabled = viewModel.spellCheckEnabled
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true

        textView.delegate = context.coordinator
        context.coordinator.textView = textView
        viewModel.activeTextView = textView

        textView.onToggleCheckboxAtCharacterIndex = { [weak viewModel] boxLocation in
            viewModel?.toggleTaskCheckbox(at: boxLocation)
        }

        scrollView.documentView = textView

        // Set initial text and apply styling
        textView.string = viewModel.markdownText
        textView.typographySettings = viewModel.typography
        context.coordinator.updateInsets(for: scrollView, textView: textView, theme: viewModel.theme)
        context.coordinator.restyle(textView: textView)

        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.scrollViewFrameDidChange(_:)),
            name: NSView.frameDidChangeNotification,
            object: scrollView
        )
        scrollView.postsFrameChangedNotifications = true

        return scrollView
    }

    public func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? HybridMarkdownTextView else { return }
        context.coordinator.viewModel = viewModel
        viewModel.activeTextView = textView

        scrollView.backgroundColor = viewModel.theme.editorBackgroundNSColor
        textView.backgroundColor = viewModel.theme.editorBackgroundNSColor
        textView.insertionPointColor = viewModel.theme.linkNSColor
        textView.currentTheme = viewModel.theme
        textView.typographySettings = viewModel.typography
        textView.isTypewriterMode = viewModel.typewriterMode
        textView.isSourceCodeMode = viewModel.sourceCodeMode
        textView.isContinuousSpellCheckingEnabled = viewModel.spellCheckEnabled

        context.coordinator.updateInsets(for: scrollView, textView: textView, theme: viewModel.theme)

        if !context.coordinator.isUpdatingFromTextView && textView.string != viewModel.markdownText {
            let savedSelection = textView.selectedRange()
            context.coordinator.isProgrammaticUpdate = true
            textView.string = viewModel.markdownText
            let safeLocation = min(savedSelection.location, (textView.string as NSString).length)
            textView.setSelectedRange(NSRange(location: safeLocation, length: 0))
            context.coordinator.isProgrammaticUpdate = false
            context.coordinator.restyle(textView: textView)
        } else if context.coordinator.lastTheme != viewModel.theme ||
                  context.coordinator.lastTypography != viewModel.typography ||
                  context.coordinator.lastSourceMode != viewModel.sourceCodeMode ||
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

    public final class Coordinator: NSObject, NSTextViewDelegate {
        var viewModel: EditorWorkspaceViewModel
        weak var textView: HybridMarkdownTextView?
        var isUpdatingFromTextView = false
        var isProgrammaticUpdate = false
        var isRestyling = false

        var lastTheme: EditorTheme?
        var lastTypography: EditorTypographySettings?
        var lastSourceMode: Bool?
        var lastFocusMode: Bool?
        var lastActiveLineRange: NSRange?
        var lastContentWidth: CGFloat = 0

        init(viewModel: EditorWorkspaceViewModel) {
            self.viewModel = viewModel
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
            let totalWidth = textView.enclosingScrollView?.bounds.width ?? textView.bounds.width
            let maxWrite = viewModel.typography.maxColumnWidth
            let horizontalPad = max(44.0, floor((totalWidth - maxWrite) / 2.0))
            let computed = totalWidth - horizontalPad * 2.0
            return computed > 200 ? computed : maxWrite
        }

        func updateInsets(for scrollView: NSScrollView, textView: HybridMarkdownTextView, theme: EditorTheme) {
            let totalWidth = scrollView.bounds.width
            let maxWrite = viewModel.typography.maxColumnWidth
            let horizontalPad = max(44.0, floor((totalWidth - maxWrite) / 2.0))
            let newInset = NSSize(width: horizontalPad, height: 42.0)
            if textView.textContainerInset != newInset {
                textView.textContainerInset = newInset
            }
        }

        public func textDidChange(_ notification: Notification) {
            guard !isProgrammaticUpdate, !isRestyling, let tv = textView else { return }
            isUpdatingFromTextView = true
            let currentText = tv.string
            let sel = tv.selectedRange()
            viewModel.handleEditorTextEdited(currentText, selectedRange: sel)
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
        }

        func restyle(textView: HybridMarkdownTextView) {
            guard !isRestyling, let storage = textView.textStorage else { return }
            isRestyling = true
            let sel = textView.selectedRange()
            let contentWidth = currentContentWidth(for: textView)

            let analysis = MarkdownLiveStyler.applyStyles(
                to: storage,
                theme: viewModel.theme,
                typography: viewModel.typography,
                sourceCodeMode: viewModel.sourceCodeMode,
                focusMode: viewModel.focusMode,
                selectedRange: sel,
                containerWidth: contentWidth
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

            textView.lineDecorations = analysis.decorations
            textView.needsDisplay = true
            lastTheme = viewModel.theme
            lastTypography = viewModel.typography
            lastSourceMode = viewModel.sourceCodeMode
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
