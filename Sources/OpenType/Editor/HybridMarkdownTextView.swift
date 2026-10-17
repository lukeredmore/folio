import AppKit
import SwiftUI

public final class HybridMarkdownTextView: NSTextView {

    public var currentTheme: EditorTheme = .daylight {
        didSet { needsDisplay = true }
    }

    public var lineDecorations: [LineDecoration] = [] {
        didSet { needsDisplay = true }
    }

    public var isTypewriterMode: Bool = false
    public var isSourceCodeMode: Bool = false

    public var onToggleCheckboxAtCharacterIndex: ((Int) -> Void)?

    private static let autoPairs: [Character: Character] = [
        "(": ")",
        "[": "]",
        "{": "}",
        "\"": "\"",
        "`": "`"
    ]

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

            guard lineRect.intersects(rect) else { continue }

            switch dec.kind {
            case .headingUnderline(let level):
                let borderColor = currentTheme.isDark
                    ? NSColor.white.withAlphaComponent(level == 1 ? 0.16 : 0.10)
                    : NSColor.black.withAlphaComponent(level == 1 ? 0.12 : 0.08)
                borderColor.setFill()
                let underlineY = lineRect.maxY - (level == 1 ? 4.0 : 3.0)
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
                    let badgeAttrs: [NSAttributedString.Key: Any] = [
                        .font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .semibold),
                        .foregroundColor: currentTheme.secondaryTextNSColor.withAlphaComponent(0.85)
                    ]
                    let badgeStr = language.uppercased() as NSString
                    let badgeSize = badgeStr.size(withAttributes: badgeAttrs)
                    let badgePoint = NSPoint(
                        x: origin.x + contentWidth - badgeSize.width - 10,
                        y: lineRect.minY + (lineRect.height - badgeSize.height) / 2.0
                    )
                    badgeStr.draw(at: badgePoint, withAttributes: badgeAttrs)
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

            case .mathBlockStart, .mathBlockBody, .mathBlockEnd:
                let mathBg = currentTheme.codeBackgroundNSColor.withAlphaComponent(0.65)
                mathBg.setFill()
                let boxRect = NSRect(x: origin.x, y: lineRect.minY - 1, width: contentWidth, height: lineRect.height + 2)
                boxRect.fill()

            case .horizontalRule:
                let hrColor = currentTheme.isDark
                    ? NSColor.white.withAlphaComponent(0.18)
                    : NSColor.black.withAlphaComponent(0.14)
                hrColor.setFill()
                let midY = lineRect.midY
                let hrRect = NSRect(x: origin.x, y: midY - 1.0, width: contentWidth, height: 2.0)
                NSBezierPath(roundedRect: hrRect, xRadius: 1.0, yRadius: 1.0).fill()

            case .tableHeaderRow:
                let headerBg = currentTheme.isDark
                    ? NSColor.white.withAlphaComponent(0.08)
                    : NSColor.black.withAlphaComponent(0.05)
                headerBg.setFill()
                let rowRect = NSRect(x: origin.x, y: lineRect.minY, width: contentWidth, height: lineRect.height)
                rowRect.fill()

                let borderColor = currentTheme.isDark
                    ? NSColor.white.withAlphaComponent(0.18)
                    : NSColor.black.withAlphaComponent(0.15)
                borderColor.setStroke()
                let borderPath = NSBezierPath(rect: rowRect)
                borderPath.lineWidth = 1.0
                borderPath.stroke()

            case .tableSeparatorRow:
                let sepColor = currentTheme.linkNSColor.withAlphaComponent(0.45)
                sepColor.setFill()
                let sepRect = NSRect(x: origin.x, y: lineRect.midY - 0.75, width: contentWidth, height: 1.5)
                sepRect.fill()

            case .tableBodyRow(let rowIndex):
                if rowIndex % 2 == 1 {
                    let stripeBg = currentTheme.isDark
                        ? NSColor.white.withAlphaComponent(0.035)
                        : NSColor.black.withAlphaComponent(0.022)
                    stripeBg.setFill()
                    let rowRect = NSRect(x: origin.x, y: lineRect.minY, width: contentWidth, height: lineRect.height)
                    rowRect.fill()
                }
                let borderColor = currentTheme.isDark
                    ? NSColor.white.withAlphaComponent(0.12)
                    : NSColor.black.withAlphaComponent(0.10)
                borderColor.setStroke()
                let rowRect = NSRect(x: origin.x, y: lineRect.minY, width: contentWidth, height: lineRect.height)
                let borderPath = NSBezierPath(rect: rowRect)
                borderPath.lineWidth = 0.75
                borderPath.stroke()
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
                    // Empty task item -> clear prefix and exit list
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
            let maxWrite = theme.maxWriteWidth
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
                sourceCodeMode: viewModel.sourceCodeMode,
                focusMode: viewModel.focusMode,
                selectedRange: sel
            )

            textView.lineDecorations = analysis.decorations
            lastTheme = viewModel.theme
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
