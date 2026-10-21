import AppKit
import Foundation

extension EditorWorkspaceViewModel {

    public static let textAlignmentDefaultsKey = "Folio.TextAlignment.v1"
    public static let printPaperSizeDefaultsKey = "Folio.PrintPaperSize.v1"

    func restorePageLayoutSettings(from defaults: UserDefaults) {
        textAlignment = defaults.string(forKey: Self.textAlignmentDefaultsKey).flatMap(EditorTextAlignment.init(rawValue:)) ?? .left
        printPaperSize = defaults.string(forKey: Self.printPaperSizeDefaultsKey).flatMap(PrintPaperSize.init(rawValue:)) ?? .letter
    }

    /// Theme used for printing: the current theme, or the light preset with the current
    /// typography when the current theme is dark.
    var printTheme: EditorTheme {
        guard theme.isDark else { return theme }
        var light = EditorTheme.daylight
        light.typography = typography
        return light
    }

    /// Builds a view of the whole document laid out at the paper's printable width, with every
    /// line inactive (rendered) and every diagram rendered.
    func makePrintView(paper: PrintPaperSize, diagramTimeout: TimeInterval = 30) -> HybridMarkdownTextView {
        let width = paper.printableWidth
        let storage = NSTextStorage()
        let layoutManager = WideBlockLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = WideBlockTextContainer(containerSize: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        layoutManager.addTextContainer(container)

        let view = HybridMarkdownTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100), textContainer: container)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.textContainerInset = .zero
        view.drawsBackground = false
        view.currentTheme = printTheme
        view.typographySettings = typography
        // A trailing blank line holds the selection, so no document line is active.
        view.string = markdownText.hasSuffix("\n\n") ? markdownText : markdownText + "\n\n"
        let caret = NSRange(location: (view.string as NSString).length, length: 0)

        let style = { [self] in
            MarkdownLiveStyler.applyStyles(
                to: storage,
                theme: printTheme,
                typography: typography,
                sourceCodeMode: false,
                focusMode: false,
                selectedRange: caret,
                containerWidth: width,
                prettyMode: prettyModeEnabled,
                baseDirectoryURL: currentFileURL?.deletingLastPathComponent() ?? workspaceFolderURL,
                textAlignment: textAlignment.nsAlignment
            )
        }
        _ = style()
        // Diagrams render in the background; wait for them, then style again with real heights.
        _ = DiagramImageRenderer.shared.waitUntilIdle(timeout: diagramTimeout)
        view.lineDecorations = style().decorations
        layoutManager.ensureLayout(for: container)
        view.frame.size.height = ceil(layoutManager.usedRect(for: container).height) + 8
        return view
    }

    /// Prints the document on `printPaperSize` paper. The print panel also offers Save as PDF.
    public func printDocument() {
        let printInfo = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        printInfo.paperSize = printPaperSize.size
        printInfo.topMargin = PrintPaperSize.margin
        printInfo.bottomMargin = PrintPaperSize.margin
        printInfo.leftMargin = PrintPaperSize.margin
        printInfo.rightMargin = PrintPaperSize.margin
        printInfo.horizontalPagination = .clip
        printInfo.verticalPagination = .automatic
        printInfo.isHorizontallyCentered = false
        printInfo.isVerticallyCentered = false

        let operation = NSPrintOperation(view: makePrintView(paper: printPaperSize), printInfo: printInfo)
        operation.jobTitle = documentTitle
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.run()
    }
}
