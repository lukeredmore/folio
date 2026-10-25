import AppKit
import AVFoundation
import FolioEngineFFI
import SwiftUI

public final class HybridMarkdownTextView: NSTextView {

    public weak var workspaceViewModel: EditorWorkspaceViewModel?
    weak var editorCoordinator: HybridMarkdownEditorRepresentable.Coordinator?

    public var currentTheme: EditorTheme = .daylight {
        didSet {
            if currentTheme != oldValue { needsDisplay = true }
        }
    }

    public var typographySettings: EditorTypographySettings = .default {
        didSet {
            if typographySettings != oldValue { needsDisplay = true }
        }
    }

    public var lineDecorations: [LineDecoration] = [] {
        didSet {
            if lineDecorations != oldValue {
                refreshWideTableLayout()
                syncInlineVideoOverlayWithDecorations()
                needsDisplay = true
            }
        }
    }

    /// Optional horizontal column inset managed by `Coordinator.updateInsets` so centering the
    /// fixed-width prose column during split-view/window resize does not call `setTextContainerInset:`
    /// (which forces `NSLayoutManager.textContainerChangedGeometry` even when container width is unchanged).
    var horizontalColumnInset: CGFloat? {
        didSet {
            if horizontalColumnInset != oldValue {
                invalidateTextContainerOrigin()
                needsDisplay = true
            }
        }
    }

    /// The column always starts at the inset. NSTextView would otherwise move the container right
    /// so that wide table fragments starting left of the column fit in the view.
    public override var textContainerOrigin: NSPoint {
        NSPoint(x: horizontalColumnInset ?? textContainerInset.width, y: textContainerInset.height)
    }

    /// Horizontal scroll offset of each table wider than the canvas, by the table's first character.
    var tableScrollOffsets: [Int: CGFloat] = [:]
    var overflowingTables: [OverflowingTable] = []

    public var externalUpdateHighlightRanges: [NSRange] = [] {
        didSet {
            if externalUpdateHighlightRanges != oldValue { needsDisplay = true }
        }
    }

    public var proseColumnWidth: CGFloat = 0 {
        didSet {
            if abs(proseColumnWidth - oldValue) > 0.5 { needsDisplay = true }
        }
    }

    public var isTypewriterMode: Bool = false
    public var isSourceCodeMode: Bool = false
    var activeHoveredPillRange: NSRange?

    public var onToggleCheckboxAtCharacterIndex: ((Int) -> Void)?
    var mediaHoverTrackingArea: NSTrackingArea?
    var gifAnimationTimer: Timer?
    var activeInlineVideoContainer: NSView?
    public internal(set) var activeInlineVideoURL: String?
    var activeInlineVideoRange: NSRange?
    var activeInlineVideoPlayer: AVPlayer?

    public func applyProgrammaticDocumentText(_ newText: String, selectedRange: NSRange) {
        let coord = editorCoordinator
        coord?.isProgrammaticUpdate = true
        coord?.reflowAnchors.removeAll()
        if self.string != newText {
            self.string = newText
        }
        coord?.lastKnownTextHash = newText.hashValue
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

    public override func setSpellingState(_ value: Int, range charRange: NSRange) {
        if value != 0,
           let storage = textStorage,
           WideBlockLayoutManager.shouldSuppressSpellCheck(in: storage, range: charRange) {
            super.setSpellingState(0, range: charRange)
            return
        }
        super.setSpellingState(value, range: charRange)
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

    static let supportedCodeFenceLanguages: [(id: String, title: String, aliases: [String])] = [
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

    final class CodeFenceLanguageActionPayload: NSObject {
        let lineRange: NSRange
        let languageId: String

        init(lineRange: NSRange, languageId: String) {
            self.lineRange = lineRange
            self.languageId = languageId
        }
    }

    static func languageAccentColor(for rawLang: String, isDark: Bool) -> NSColor {
        let rgba = rawLang.withCString { cStr in
            ot_engine_language_accent_color(cStr, isDark)
        }
        return NSColor(srgbRed: rgba.r, green: rgba.g, blue: rgba.b, alpha: rgba.a)
    }

    static func languageMenuDotImage(for rawLang: String, isDark: Bool) -> NSImage {
        let size = NSSize(width: 8, height: 8)
        let img = NSImage(size: size)
        img.lockFocus()
        languageAccentColor(for: rawLang, isDark: isDark).setFill()
        NSBezierPath(ovalIn: NSRect(origin: .zero, size: size)).fill()
        img.unlockFocus()
        return img
    }

    struct CodeFenceBadgeGeometry {
        let pillRect: NSRect
        let dotRect: NSRect
        let textPoint: NSPoint
        let chevronCenter: NSPoint
        let badgeString: NSString
        let badgeAttributes: [NSAttributedString.Key: Any]
        let accent: NSColor
    }

    func computeCodeFenceBadgeGeometry(
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

    func presentCodeFenceLanguageMenu(for lineRange: NSRange, currentLanguage: String, badgeRect: NSRect) {
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

    @objc func handleSelectCodeFenceLanguage(_ sender: NSMenuItem) {
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
}
