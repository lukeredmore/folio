import AppKit
import Foundation

extension EditorWorkspaceViewModel {

    public static let textAlignmentDefaultsKey = "Folio.TextAlignment.v1"
    public static let printPaperSizeDefaultsKey = "Folio.PrintPaperSize.v1"
    public static let printOrientationDefaultsKey = "Folio.PrintOrientation.v1"
    public static let printMarginsDefaultsKey = "Folio.PrintMargins.v1"

    func restorePageLayoutSettings(from defaults: UserDefaults) {
        textAlignment =
            defaults.string(forKey: Self.textAlignmentDefaultsKey)
            .flatMap(EditorTextAlignment.init(rawValue:)) ?? .left
        printPaperSize =
            defaults.string(forKey: Self.printPaperSizeDefaultsKey)
            .flatMap(PrintPaperSize.init(rawValue:)) ?? .letter
        printOrientation =
            defaults.string(forKey: Self.printOrientationDefaultsKey)
            .flatMap(PrintOrientation.init(rawValue:)) ?? .portrait
        if let data = defaults.data(forKey: Self.printMarginsDefaultsKey),
            let decoded = try? JSONDecoder().decode(PrintPageMargins.self, from: data)
        {
            printMargins = decoded
        } else {
            printMargins = .default
        }
    }

    /// Page layout directives parsed from the active document's LaTeX preamble or Markdown frontmatter.
    public var documentPageLayout: DocumentPageLayout {
        DocumentPageLayout.extract(from: markdownText, fileURL: currentFileURL)
    }

    /// Effective print/PDF page layout combining user settings with any in-document overrides.
    public func resolvedPrintPageLayout(overridePaper: PrintPaperSize? = nil) -> ResolvedPrintPageLayout {
        documentPageLayout.resolve(
            defaultPaper: overridePaper ?? printPaperSize,
            defaultOrientation: printOrientation,
            defaultMargins: printMargins
        )
    }

    /// Theme used for printing: the current theme, or the light preset with the current
    /// typography when the current theme is dark.
    var printTheme: EditorTheme {
        guard theme.isDark else { return theme }
        var light = EditorTheme.daylight
        light.typography = typography
        return light
    }

    /// Builds an `NSPrintInfo` configured with the resolved paper size, orientation, and margins.
    public func configuredPrintInfo(for layout: ResolvedPrintPageLayout? = nil) -> NSPrintInfo {
        let resolved = layout ?? resolvedPrintPageLayout()
        let printInfo = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        printInfo.orientation = resolved.orientation == .landscape ? .landscape : .portrait
        printInfo.paperSize = resolved.effectivePaperSize
        printInfo.topMargin = resolved.margins.top
        printInfo.bottomMargin = resolved.margins.bottom
        printInfo.leftMargin = resolved.margins.left
        printInfo.rightMargin = resolved.margins.right
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .automatic
        printInfo.isHorizontallyCentered = false
        printInfo.isVerticallyCentered = false
        return printInfo
    }

    /// Builds a view of the whole document laid out at the resolved printable width, with every
    /// line inactive (rendered), soft line breaks joined, and every diagram rendered.
    func makePrintView(
        paper: PrintPaperSize? = nil,
        diagramTimeout: TimeInterval = 30
    ) -> HybridMarkdownTextView {
        let docLayout = documentPageLayout
        let resolved = docLayout.resolve(
            defaultPaper: paper ?? printPaperSize,
            defaultOrientation: printOrientation,
            defaultMargins: printMargins
        )
        let width = resolved.printableWidth
        var effectiveTypography = typography
        if let fontSizeOverride = resolved.baseFontSizePoints, printTheme.baseFontSize > 0 {
            effectiveTypography.fontSizeScale = fontSizeOverride / printTheme.baseFontSize
        }
        var effectiveTheme = printTheme
        effectiveTheme.typography = effectiveTypography
        let effectiveAlignment = resolved.textAlignmentOverride ?? textAlignment.nsAlignment

        let storage = NSTextStorage()
        let layoutManager = WideBlockLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = WideBlockTextContainer(
            containerSize: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        )
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        layoutManager.addTextContainer(container)

        let view = HybridMarkdownTextView(
            frame: NSRect(x: 0, y: 0, width: width, height: 100),
            textContainer: container
        )
        layoutManager.delegate = view.softLineBreakLayoutDelegate
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.textContainerInset = NSSize(width: 0, height: 0)
        view.drawsBackground = false
        view.proseColumnWidth = width
        view.currentTheme = effectiveTheme
        view.typographySettings = effectiveTypography
        // A trailing blank line holds the selection, so no document line is active.
        view.string = markdownText.hasSuffix("\n\n") ? markdownText : markdownText + "\n\n"
        let caret = NSRange(location: (view.string as NSString).length, length: 0)

        let style = { [self] in
            MarkdownLiveStyler.applyStyles(
                to: storage,
                theme: effectiveTheme,
                typography: effectiveTypography,
                sourceCodeMode: false,
                focusMode: false,
                selectedRange: caret,
                containerWidth: width,
                prettyMode: prettyModeEnabled,
                baseDirectoryURL: currentFileURL?.deletingLastPathComponent() ?? workspaceFolderURL,
                textAlignment: effectiveAlignment,
                fileURL: currentFileURL
            )
        }
        _ = style()
        // Diagrams render in the background; wait for them, then style again with real heights.
        _ = DiagramImageRenderer.shared.waitUntilIdle(timeout: diagramTimeout)
        var decorations = style().decorations
        Self.collapsePrintMetadataRegions(
            in: storage,
            decorations: &decorations,
            metadataRange: docLayout.metadataRange
        )
        view.lineDecorations = decorations
        let fullRange = NSRange(location: 0, length: storage.length)
        layoutManager.invalidateGlyphs(forCharacterRange: fullRange, changeInLength: 0, actualCharacterRange: nil)
        layoutManager.invalidateLayout(forCharacterRange: fullRange, actualCharacterRange: nil)
        layoutManager.ensureLayout(for: container)
        view.frame.size.height = max(1, ceil(layoutManager.usedRect(for: container).height) + 8)
        return view
    }

    private static func collapsePrintMetadataRegions(
        in storage: NSTextStorage,
        decorations: inout [LineDecoration],
        metadataRange: NSRange?
    ) {
        var rangesToCollapse: [NSRange] = []
        if let metadataRange {
            rangesToCollapse.append(metadataRange)
        }
        decorations.removeAll { dec in
            if case let .latexPreambleCard(_, _, preambleRange, _) = dec.kind {
                rangesToCollapse.append(preambleRange)
                return true
            }
            if let metadataRange, NSIntersectionRange(dec.lineRange, metadataRange).length > 0 {
                return true
            }
            return false
        }
        guard !rangesToCollapse.isEmpty else { return }
        let tinyFont = NSFont.systemFont(ofSize: 0.01)
        let collapsedPara = NSMutableParagraphStyle()
        collapsedPara.minimumLineHeight = 0.01
        collapsedPara.maximumLineHeight = 0.01
        collapsedPara.lineSpacing = 0
        collapsedPara.paragraphSpacing = 0
        collapsedPara.paragraphSpacingBefore = 0
        let attrs: [NSAttributedString.Key: Any] = [
            .font: tinyFont,
            .foregroundColor: NSColor.clear,
            .paragraphStyle: collapsedPara
        ]
        let nsString = storage.string as NSString
        storage.beginEditing()
        for rawRange in rangesToCollapse {
            let safeLoc = max(0, min(rawRange.location, storage.length))
            let safeLen = max(0, min(rawRange.length, storage.length - safeLoc))
            guard safeLen > 0 else { continue }
            let clamped = NSRange(location: safeLoc, length: safeLen)
            storage.addAttributes(attrs, range: clamped)
            LaTeXBlockStyleCache.collapseInternalNewlines(in: storage, nsString: nsString, range: clamped)
        }
        storage.endEditing()
    }

    /// Prints the document using the resolved page layout. The print panel also offers Save as PDF.
    public func printDocument() {
        let resolved = resolvedPrintPageLayout()
        let printInfo = configuredPrintInfo(for: resolved)
        let operation = NSPrintOperation(view: makePrintView(), printInfo: printInfo)
        operation.jobTitle = documentTitle
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.run()
    }
}
