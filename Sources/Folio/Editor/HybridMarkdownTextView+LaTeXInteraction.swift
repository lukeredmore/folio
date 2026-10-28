import AppKit
import Foundation

extension HybridMarkdownTextView {

    func latexDecorationTooltip(at point: NSPoint) -> String? {
        guard !isSourceCodeMode,
            let layoutManager = self.layoutManager,
            let textContainer = self.textContainer
        else { return nil }
        let origin = self.textContainerOrigin
        let fullContentWidth = self.bounds.width - origin.x * 2
        let contentWidth = proseColumnWidth > 0 ? proseColumnWidth : fullContentWidth
        let probeRect = NSRect(x: point.x - 16, y: point.y - 16, width: 32, height: 32)
        let visibleCharRange = visibleDecorationCharacterRange(for: probeRect, margin: 64)

        for (decIdx, dec) in lineDecorations.enumerated() {
            if let visible = visibleCharRange, !Self.decorationSpan(decorationSpan(at: decIdx), touches: visible) {
                continue
            }
            switch dec.kind {
            case let .latexInlinePill(label, tooltip, _, _, pillRange, fontSize, _, _):
                if let rect = computeLaTeXInlinePillRect(
                    pillRange: pillRange,
                    label: label,
                    fontSize: fontSize,
                    layoutManager: layoutManager,
                    origin: origin
                ), rect.insetBy(dx: -2, dy: -2).contains(point) {
                    return tooltip
                }
            case let .latexPreambleCard(title, subtitle, fullBlockRange, _):
                let bg = layoutManager.glyphRange(forCharacterRange: fullBlockRange, actualCharacterRange: nil)
                guard bg.location != NSNotFound else { continue }
                var rect = layoutManager.boundingRect(forGlyphRange: bg, in: textContainer)
                rect.origin.x = origin.x
                rect.origin.y += origin.y
                rect.size.width = contentWidth
                if rect.contains(point) {
                    return subtitle.isEmpty ? title : "\(title)\n\(subtitle)\nClick to edit preamble"
                }
            case let .latexInputCard(path, resolvedURL, lineRange, _):
                let bg = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
                guard bg.location != NSNotFound else { continue }
                let frag = layoutManager.lineFragmentRect(forGlyphAt: bg.location, effectiveRange: nil)
                let rect = NSRect(x: origin.x, y: origin.y + frag.minY, width: contentWidth, height: frag.height)
                if rect.contains(point) {
                    return resolvedURL?.path ?? "Unresolved TeX input: \(path)"
                }
            default:
                break
            }
        }
        return nil
    }

    func handleLaTeXDecorationClick(at point: NSPoint, event: NSEvent) -> Bool {
        guard !isSourceCodeMode,
            let layoutManager = self.layoutManager,
            let textContainer = self.textContainer
        else { return false }
        let origin = self.textContainerOrigin
        let fullContentWidth = self.bounds.width - origin.x * 2
        let contentWidth = proseColumnWidth > 0 ? proseColumnWidth : fullContentWidth
        let probeRect = NSRect(x: point.x - 16, y: point.y - 16, width: 32, height: 32)
        let visibleCharRange = visibleDecorationCharacterRange(for: probeRect, margin: 64)

        for (decIdx, dec) in lineDecorations.enumerated() {
            if let visible = visibleCharRange, !Self.decorationSpan(decorationSpan(at: decIdx), touches: visible) {
                continue
            }
            switch dec.kind {
            case let .latexPreambleCard(_, _, fullBlockRange, _):
                let bg = layoutManager.glyphRange(forCharacterRange: fullBlockRange, actualCharacterRange: nil)
                guard bg.location != NSNotFound else { continue }
                var rect = layoutManager.boundingRect(forGlyphRange: bg, in: textContainer)
                rect.origin.x = origin.x
                rect.origin.y += origin.y
                rect.size.width = contentWidth
                if rect.contains(point) {
                    setSelectedRange(NSRange(location: fullBlockRange.location, length: 0))
                    return true
                }

            case let .latexInputCard(_, resolvedURL, lineRange, _):
                let bg = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
                guard bg.location != NSNotFound else { continue }
                let frag = layoutManager.lineFragmentRect(forGlyphAt: bg.location, effectiveRange: nil)
                let rect = NSRect(x: origin.x, y: origin.y + frag.minY, width: contentWidth, height: frag.height)
                if rect.contains(point) {
                    if let url = resolvedURL, !event.modifierFlags.contains(.option) {
                        workspaceViewModel?.openFile(at: url)
                    } else {
                        setSelectedRange(NSRange(location: lineRange.location, length: 0))
                    }
                    return true
                }

            case let .latexInlinePill(label, _, targetLocation, targetURL, pillRange, fontSize, _, _):
                guard
                    let rect = computeLaTeXInlinePillRect(
                        pillRange: pillRange,
                        label: label,
                        fontSize: fontSize,
                        layoutManager: layoutManager,
                        origin: origin
                    ), rect.insetBy(dx: -2, dy: -2).contains(point)
                else { continue }

                if event.modifierFlags.contains(.command) {
                    if let url = targetURL, url != workspaceViewModel?.currentFileURL {
                        workspaceViewModel?.openFile(at: url)
                        return true
                    }
                    if let loc = targetLocation, loc < (self.string as NSString).length {
                        let targetRange = NSRange(location: loc, length: 0)
                        setSelectedRange(targetRange)
                        scrollRangeToVisible(targetRange)
                        return true
                    }
                }
                setSelectedRange(NSRange(location: pillRange.location, length: 0))
                return true

            default:
                break
            }
        }
        return false
    }

    func tryContinueLaTeXItemOnNewline() -> Bool {
        let sel = self.selectedRange()
        let nsStr = self.string as NSString
        guard sel.location <= nsStr.length else { return false }
        let lineRange = nsStr.lineRange(for: NSRange(location: sel.location, length: 0))
        let lineUpToCursor = nsStr.substring(with: NSRange(location: lineRange.location, length: sel.location - lineRange.location))
        let trimmed = lineUpToCursor.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("\\item") else { return false }

        let leadingSpaces = String(lineUpToCursor.prefix(while: { $0 == " " || $0 == "\t" }))
        let afterItem = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        if afterItem.isEmpty {
            if shouldChangeText(in: lineRange, replacementString: "\n") {
                replaceCharacters(in: lineRange, with: "\n")
                didChangeText()
            }
            return true
        } else {
            super.insertNewline(nil)
            insertText("\(leadingSpaces)\\item ", replacementRange: self.selectedRange())
            return true
        }
    }
}
