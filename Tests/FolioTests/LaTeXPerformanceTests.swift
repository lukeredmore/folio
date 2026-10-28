import AppKit
import XCTest
@testable import Folio

final class LaTeXPerformanceTests: XCTestCase {

    @MainActor
    func testProfileShowcaseOperations() throws {
        let showcaseURL = try copyOfExample("latex_paper_showcase.tex", companions: ["references.bib"])
        let tex = try String(contentsOf: showcaseURL, encoding: .utf8)
        let baseDir = showcaseURL.deletingLastPathComponent()

        let vm = makeIsolatedViewModel()
        vm.currentFileURL = showcaseURL
        vm.workspaceFolderURL = baseDir
        vm.markdownText = tex

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 960, height: 800))
        let textStorage = NSTextStorage(string: tex)
        let layoutManager = WideBlockLayoutManager()
        let softDelegate = SoftLineBreakLayoutDelegate()
        layoutManager.delegate = softDelegate
        textStorage.addLayoutManager(layoutManager)
        let textContainer = WideBlockTextContainer(containerSize: NSSize(width: 760, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = false
        textContainer.lineFragmentPadding = 0
        layoutManager.addTextContainer(textContainer)

        let tv = HybridMarkdownTextView(frame: NSRect(x: 0, y: 0, width: 960, height: 2400), textContainer: textContainer)
        tv.workspaceViewModel = vm
        vm.activeTextView = tv
        scrollView.documentView = tv

        let ns = tex as NSString
        var lineStarts: [Int] = []
        var idx = 0
        while idx < ns.length {
            lineStarts.append(idx)
            let lr = ns.lineRange(for: NSRange(location: idx, length: 0))
            idx = NSMaxRange(lr)
        }

        // Warmup initial restyle + layout
        print("[STEP 0] warmup")
        let initialAnalysis = MarkdownLiveStyler.applyStyles(
            to: textStorage,
            theme: .daylight,
            typography: .default,
            sourceCodeMode: false,
            focusMode: false,
            selectedRange: NSRange(location: 0, length: 0),
            containerWidth: 760,
            prettyMode: true,
            baseDirectoryURL: baseDir,
            fileURL: showcaseURL
        )
        tv.lineDecorations = initialAnalysis.decorations
        layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0, length: textStorage.length))

        // 1. Breakdown of LaTeXLiveStyler phases on cursor move
        print("[STEP 1] macro & index")
        let tMacro0 = CFAbsoluteTimeGetCurrent()
        for _ in 0..<20 {
            _ = LaTeXMacroExpander.extractDocumentMacros(from: tex)
        }
        let macroExtractMs = (CFAbsoluteTimeGetCurrent() - tMacro0) * 1000.0 / 20.0

        let tIndex0 = CFAbsoluteTimeGetCurrent()
        for _ in 0..<20 {
            _ = LaTeXDocumentIndexer.buildIndex(string: tex, nsString: ns, baseDirectoryURL: baseDir)
        }
        let indexBuildMs = (CFAbsoluteTimeGetCurrent() - tIndex0) * 1000.0 / 20.0

        // 2. Measure 20 cursor line moves (applyStyles + layout)
        print("[STEP 2] cursor moves")
        let cursorIterations = 20
        var styleOnlyTotal = 0.0
        var layoutOnlyTotal = 0.0
        let t0 = CFAbsoluteTimeGetCurrent()
        for i in 0..<cursorIterations {
            let loc = lineStarts[(i * 7) % lineStarts.count]
            let sel = NSRange(location: loc, length: 0)
            vm.updateSelectionStats(selectedRange: sel)
            let ts0 = CFAbsoluteTimeGetCurrent()
            let analysis = MarkdownLiveStyler.applyStyles(
                to: textStorage,
                theme: .daylight,
                typography: .default,
                sourceCodeMode: false,
                focusMode: false,
                selectedRange: sel,
                containerWidth: 760,
                prettyMode: true,
                baseDirectoryURL: baseDir,
                fileURL: showcaseURL
            )
            styleOnlyTotal += (CFAbsoluteTimeGetCurrent() - ts0)
            let tl0 = CFAbsoluteTimeGetCurrent()
            tv.lineDecorations = analysis.decorations
            layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0, length: textStorage.length))
            layoutOnlyTotal += (CFAbsoluteTimeGetCurrent() - tl0)
        }
        let cursorMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0 / Double(cursorIterations)
        let styleMs = styleOnlyTotal * 1000.0 / Double(cursorIterations)
        let layoutMs = layoutOnlyTotal * 1000.0 / Double(cursorIterations)

        // 3. Measure 20 keystrokes in body prose
        let proseLoc = ns.range(of: "We present").location
        XCTAssertNotEqual(proseLoc, NSNotFound)
        let keystrokeIterations = 20
        let t1 = CFAbsoluteTimeGetCurrent()
        for i in 0..<keystrokeIterations {
            let ch = String(UnicodeScalar(97 + (i % 26))!)
            textStorage.replaceCharacters(in: NSRange(location: proseLoc, length: 0), with: ch)
            let sel = NSRange(location: proseLoc + 1, length: 0)
            vm.isLiveKeystrokeInProgress = true
            vm.handleEditorTextEdited(textStorage.string, selectedRange: sel)
            vm.isLiveKeystrokeInProgress = false
            let analysis = MarkdownLiveStyler.applyStyles(
                to: textStorage,
                theme: .daylight,
                typography: .default,
                sourceCodeMode: false,
                focusMode: false,
                selectedRange: sel,
                containerWidth: 760,
                prettyMode: true,
                baseDirectoryURL: baseDir,
                fileURL: showcaseURL
            )
            tv.lineDecorations = analysis.decorations
            layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0, length: textStorage.length))
            textStorage.replaceCharacters(in: NSRange(location: proseLoc, length: 1), with: "")
            let restored = MarkdownLiveStyler.applyStyles(
                to: textStorage,
                theme: .daylight,
                typography: .default,
                sourceCodeMode: false,
                focusMode: false,
                selectedRange: NSRange(location: proseLoc, length: 0),
                containerWidth: 760,
                prettyMode: true,
                baseDirectoryURL: baseDir,
                fileURL: showcaseURL
            )
            tv.lineDecorations = restored.decorations
        }
        let keystrokeMs = (CFAbsoluteTimeGetCurrent() - t1) * 1000.0 / Double(keystrokeIterations * 2)

        // 4. Measure 20 drawBackground frames
        let bitmapRep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 960,
            pixelsHigh: 800,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        let drawIterations = 20
        let t2 = CFAbsoluteTimeGetCurrent()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmapRep)
        for i in 0..<drawIterations {
            let yOffset = CGFloat((i * 60) % 1200)
            tv.drawBackground(in: NSRect(x: 0, y: yOffset, width: 960, height: 800))
        }
        NSGraphicsContext.restoreGraphicsState()
        let drawMs = (CFAbsoluteTimeGetCurrent() - t2) * 1000.0 / Double(drawIterations)

        print(
            String(
                format:
                    "[PROFILE] macroExtract=%.2fms indexBuild=%.2fms styleOnly=%.2fms layoutOnly=%.2fms cursorMove=%.2fms keystroke=%.2fms drawBackground=%.2fms",
                macroExtractMs, indexBuildMs, styleMs, layoutMs, cursorMs, keystrokeMs, drawMs
            ))
        XCTAssertLessThan(cursorMs, 15.0, "Cursor move latency on showcase document should stay well under 16ms frame budget")
        XCTAssertLessThan(keystrokeMs, 20.0, "Keystroke latency on showcase document should stay responsive")
    }
}
