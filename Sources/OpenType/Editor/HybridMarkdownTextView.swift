import AppKit
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

    private static func languageAccentColor(for rawLang: String, isDark: Bool) -> NSColor {
        switch rawLang.lowercased().trimmingCharacters(in: .whitespaces) {
        case "swift":
            return NSColor(srgbRed: 0.94, green: 0.32, blue: 0.22, alpha: 1.0)
        case "python", "py":
            return NSColor(srgbRed: 0.22, green: 0.46, blue: 0.67, alpha: 1.0)
        case "javascript", "js", "jsx":
            return isDark
                ? NSColor(srgbRed: 0.95, green: 0.82, blue: 0.22, alpha: 1.0)
                : NSColor(srgbRed: 0.78, green: 0.58, blue: 0.04, alpha: 1.0)
        case "typescript", "ts", "tsx":
            return NSColor(srgbRed: 0.19, green: 0.47, blue: 0.78, alpha: 1.0)
        case "rust", "rs":
            return NSColor(srgbRed: 0.85, green: 0.45, blue: 0.24, alpha: 1.0)
        case "go", "golang":
            return NSColor(srgbRed: 0.0, green: 0.68, blue: 0.85, alpha: 1.0)
        case "json", "jsonc", "yaml", "yml", "toml":
            return NSColor(srgbRed: 0.20, green: 0.65, blue: 0.45, alpha: 1.0)
        case "bash", "sh", "zsh", "shell":
            return NSColor(srgbRed: 0.26, green: 0.68, blue: 0.34, alpha: 1.0)
        case "html", "xml", "css", "scss":
            return NSColor(srgbRed: 0.86, green: 0.30, blue: 0.42, alpha: 1.0)
        case "sql":
            return NSColor(srgbRed: 0.28, green: 0.52, blue: 0.88, alpha: 1.0)
        default:
            return isDark
                ? NSColor.white.withAlphaComponent(0.65)
                : NSColor.black.withAlphaComponent(0.55)
        }
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

        for dec in lineDecorations {
            let glyphRange = layoutManager.glyphRange(forCharacterRange: dec.lineRange, actualCharacterRange: nil)
            guard glyphRange.location != NSNotFound else { continue }
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

            case .codeFenceStart(let language):
                currentTheme.codeBackgroundNSColor.setFill()
                let boxRect = NSRect(x: origin.x, y: lineRect.minY, width: contentWidth, height: lineRect.height + 2)
                let path = NSBezierPath(roundedRect: boxRect, xRadius: 6, yRadius: 6)
                path.fill()

                if !language.isEmpty {
                    let accent = Self.languageAccentColor(for: language, isDark: currentTheme.isDark)
                    let badgeAttrs: [NSAttributedString.Key: Any] = [
                        .font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .semibold),
                        .foregroundColor: accent
                    ]
                    let badgeStr = language.uppercased() as NSString
                    let badgeSize = badgeStr.size(withAttributes: badgeAttrs)
                    let pillPadH: CGFloat = 7.0
                    let pillPadV: CGFloat = 2.0
                    let dotSpace: CGFloat = 10.0
                    let pillW = badgeSize.width + pillPadH * 2 + dotSpace
                    let pillH = badgeSize.height + pillPadV * 2
                    let pillRect = NSRect(
                        x: origin.x + contentWidth - pillW - 8.0,
                        y: lineRect.minY + (lineRect.height - pillH) * 0.5,
                        width: pillW,
                        height: pillH
                    )
                    accent.withAlphaComponent(currentTheme.isDark ? 0.16 : 0.10).setFill()
                    NSBezierPath(roundedRect: pillRect, xRadius: 4, yRadius: 4).fill()

                    // Small language accent dot
                    let dotRect = NSRect(
                        x: pillRect.minX + pillPadH,
                        y: pillRect.midY - 3.0,
                        width: 6.0,
                        height: 6.0
                    )
                    accent.setFill()
                    NSBezierPath(ovalIn: dotRect).fill()

                    let textPoint = NSPoint(
                        x: pillRect.minX + pillPadH + dotSpace,
                        y: pillRect.minY + pillPadV
                    )
                    badgeStr.draw(at: textPoint, withAttributes: badgeAttrs)
                }

            case .codeFenceBody:
                currentTheme.codeBackgroundNSColor.setFill()
                let boxRect = NSRect(x: origin.x, y: lineRect.minY - 1, width: contentWidth, height: lineRect.height + 2)
                boxRect.fill()

            case .codeFenceEnd:
                currentTheme.codeBackgroundNSColor.setFill()
                let boxRect = NSRect(x: origin.x, y: lineRect.minY - 2, width: contentWidth, height: lineRect.height + 2)
                let path = NSBezierPath(roundedRect: boxRect, xRadius: 6, yRadius: 6)
                path.fill()

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

                let node = LaTeXMathRenderer.parse(latex)
                let mathBox = LaTeXMathRenderer.layout(
                    node: node,
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
                let baselineY = origin.y + lineFrag.minY + glyphLoc.y

                let node = LaTeXMathRenderer.parse(latex)
                let mathBox = LaTeXMathRenderer.layout(
                    node: node,
                    baseFontSize: fontSize,
                    isDisplayStyle: false
                )
                let drawX = mathRect.minX + max(1.0, (mathRect.width - mathBox.width) * 0.5)
                let mathColor = currentTheme.headingNSColor.withAlphaComponent(dimFactor)
                mathBox.drawBox(drawX, baselineY, mathColor)

            case .horizontalRule:
                let hrColor = currentTheme.isDark
                    ? NSColor.white.withAlphaComponent(0.18)
                    : NSColor.black.withAlphaComponent(0.13)
                hrColor.setFill()
                let lineFrag = layoutManager.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
                let midY = origin.y + lineFrag.minY + lineFrag.height * 0.5 + 2.0
                let hrRect = NSRect(x: origin.x, y: midY - 0.75, width: contentWidth, height: 1.5)
                NSBezierPath(roundedRect: hrRect, xRadius: 0.75, yRadius: 0.75).fill()

            case let .tableRow(isHeader, isSeparator, isFirstRow, isLastRow, bodyRowIndex, tableWidth, columnDividers):
                let effectiveWidth = min(contentWidth, max(tableWidth, 240.0))
                let rowRect = NSRect(x: origin.x, y: lineRect.minY, width: effectiveWidth, height: lineRect.height)
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
                    NSRect(x: origin.x, y: rowRect.midY - 0.5, width: effectiveWidth, height: 1.0).fill()

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
                    let colLineRect = NSRect(x: origin.x + divX, y: rowRect.minY, width: 1.0, height: rowRect.height)
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

    public override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
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

        // Task list continuation: "- [ ] " or "- [x] "
        if let match = lineUpToCursor.range(of: #"^(\s*[-*+]\s+\[[ xX]\]\s+)(.*)$"#, options: .regularExpression) {
            let fullLine = String(lineUpToCursor[match])
            if let prefixMatch = fullLine.range(of: #"^\s*[-*+]\s+\[[ xX]\]\s+"#, options: .regularExpression) {
                let prefix = String(fullLine[prefixMatch])
                let remainder = String(fullLine[prefixMatch.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if remainder.isEmpty {
                    if shouldChangeText(in: lineRange, replacementString: "\n") {
                        replaceCharacters(in: lineRange, with: "\n")
                        didChangeText()
                    }
                    return
                } else {
                    let uncheckedPrefix = prefix.replacingOccurrences(of: "[x]", with: "[ ]").replacingOccurrences(of: "[X]", with: "[ ]")
                    super.insertNewline(sender)
                    insertText(uncheckedPrefix, replacementRange: self.selectedRange())
                    return
                }
            }
        }

        // Unordered list continuation: "- " or "* "
        if let prefixRange = lineUpToCursor.range(of: #"^\s*[-*+]\s+"#, options: .regularExpression) {
            let prefix = String(lineUpToCursor[prefixRange])
            let remainder = String(lineUpToCursor[prefixRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if remainder.isEmpty {
                if shouldChangeText(in: lineRange, replacementString: "\n") {
                    replaceCharacters(in: lineRange, with: "\n")
                    didChangeText()
                }
                return
            } else {
                super.insertNewline(sender)
                insertText(prefix, replacementRange: self.selectedRange())
                return
            }
        }

        // Ordered list continuation: "1. " -> "2. "
        if let prefixRange = lineUpToCursor.range(of: #"^\s*\d+\.\s+"#, options: .regularExpression) {
            let prefix = String(lineUpToCursor[prefixRange])
            let remainder = String(lineUpToCursor[prefixRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if remainder.isEmpty {
                if shouldChangeText(in: lineRange, replacementString: "\n") {
                    replaceCharacters(in: lineRange, with: "\n")
                    didChangeText()
                }
                return
            } else {
                let leadingSpace = prefix.prefix(while: { $0.isWhitespace })
                let digitsStr = prefix.dropFirst(leadingSpace.count).prefix(while: { $0.isNumber })
                let nextNum = (Int(digitsStr) ?? 1) + 1
                super.insertNewline(sender)
                insertText("\(leadingSpace)\(nextNum). ", replacementRange: self.selectedRange())
                return
            }
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

        init(viewModel: EditorWorkspaceViewModel) {
            self.viewModel = viewModel
        }

        @objc func scrollViewFrameDidChange(_ notification: Notification) {
            guard let scrollView = notification.object as? NSScrollView,
                  let tv = textView else { return }
            updateInsets(for: scrollView, textView: tv, theme: viewModel.theme)
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

            let analysis = MarkdownLiveStyler.applyStyles(
                to: storage,
                theme: viewModel.theme,
                typography: viewModel.typography,
                sourceCodeMode: viewModel.sourceCodeMode,
                focusMode: viewModel.focusMode,
                selectedRange: sel
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
