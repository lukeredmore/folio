import AppKit
import SwiftUI
import XCTest
@testable import Folio

@MainActor
final class FolioUILagProfileTests: XCTestCase {

    private func findSubview<T: NSView>(of type: T.Type, in root: NSView) -> T? {
        if let match = root as? T { return match }
        for child in root.subviews {
            if let found = findSubview(of: type, in: child) {
                return found
            }
        }
        return nil
    }

    @MainActor
    func testProfileUILagScenarios() throws {
        let suiteName = "com.folio.tests.uiprofile.\(UUID().uuidString)"
        guard let testDefaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create UserDefaults")
            return
        }
        defer { testDefaults.removePersistentDomain(forName: suiteName) }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FolioUIProfile-\(UUID().uuidString)", isDirectory: true)
        let assetsDir = tempDir.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assetsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let archSVG = """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 640 160" width="640" height="160">
          <defs>
            <linearGradient id="bg" x1="0%" y1="0%" x2="100%" y2="100%">
              <stop offset="0%" stop-color="#0f172a"/>
              <stop offset="100%" stop-color="#1e293b"/>
            </linearGradient>
            <linearGradient id="accent" x1="0%" y1="0%" x2="100%" y2="0%">
              <stop offset="0%" stop-color="#3b82f6"/>
              <stop offset="100%" stop-color="#8b5cf6"/>
            </linearGradient>
          </defs>
          <rect width="640" height="160" rx="14" fill="url(#bg)"/>
          <rect x="24" y="28" width="168" height="104" rx="10" fill="#1e293b" stroke="#3b82f6" stroke-width="2"/>
          <text x="108" y="72" text-anchor="middle" fill="#f8fafc" font-family="-apple-system, sans-serif" font-size="15" font-weight="700">folio_engine</text>
          <rect x="240" y="28" width="168" height="104" rx="10" fill="#1e293b" stroke="#6366f1" stroke-width="2"/>
          <text x="324" y="72" text-anchor="middle" fill="#f8fafc" font-family="-apple-system, sans-serif" font-size="15" font-weight="700">FolioApp (macOS)</text>
          <rect x="456" y="28" width="160" height="104" rx="10" fill="#1e293b" stroke="#8b5cf6" stroke-width="2"/>
          <text x="536" y="72" text-anchor="middle" fill="#f8fafc" font-family="-apple-system, sans-serif" font-size="15" font-weight="700">folio_zed_mod</text>
        </svg>
        """
        try archSVG.write(to: assetsDir.appendingPathComponent("folio_architecture.svg"), atomically: true, encoding: .utf8)

        let showcaseDoc = """
        # Folio Rich Media & Math Showcase

        Welcome to the **Rich Media & Pretty Mode** test document with inline math $\\int_0^\\infty e^{-x^2} dx = \\frac{\\sqrt{\\pi}}{2}$ and $\\sum_{n=1}^{\\infty} \\frac{1}{n^2} = \\frac{\\pi^2}{6}$.

        ![Folio Architecture Overview](assets/folio_architecture.svg "Folio Native + Zed Architecture")

        <img src="assets/folio_architecture.svg" alt="HTML Image Banner (480×120)" width="480" height="120" />

        $$
        \\mathcal{L}_{\\text{Folio}}(x) = \\int_{-\\infty}^{\\infty} \\frac{\\hat{f}(\\xi) e^{2\\pi i x \\xi}}{\\sqrt{1 + \\xi^2}} \\, d\\xi
        $$

        ```mermaid
        flowchart LR
            Markdown["Markdown + HTML Buffer"] --> Parser["pulldown-cmark + AST"]
            Parser --> Styler["Live Buffer Folds & Inlays"]
            Parser --> Mermaid["Native Mermaid SVG Engine"]
            Styler --> Render["120Hz Native Canvas"]
            Mermaid --> Render
        ```

        ```mermaid
        sequenceDiagram
            participant User
            participant Editor
            participant FolioEngine
            User->>Editor: Move cursor off ```mermaid block
            Editor->>FolioEngine: ot_engine_render_mermaid_svg(code, is_dark)
            FolioEngine-->>Editor: Normalized SVG vector diagram
            Editor-->>User: Render interactive diagram card
        ```

        ```svg
        <svg viewBox="0 0 520 110" width="520" height="110" xmlns="http://www.w3.org/2000/svg">
          <rect x="8" y="8" width="504" height="94" rx="12" fill="#eff6ff" stroke="#3b82f6" stroke-width="2"/>
          <circle cx="58" cy="55" r="26" fill="#2563eb"/>
          <text x="104" y="48" fill="#1e3a8a" font-family="-apple-system, sans-serif" font-size="16" font-weight="bold">Inline SVG Block Rendering</text>
        </svg>
        ```

        | Subsystem | Latency | Frame Budget | Status |
        | :--- | :---: | :---: | :--- |
        | Sidebar Toggle | < 2 ms | 8.33 ms (120Hz) | Active |
        | SVG & Mermaid Blit | < 1 ms | 8.33 ms (120Hz) | Active |
        """
        let mainFile = tempDir.appendingPathComponent("rich_media_showcase.md")
        try showcaseDoc.write(to: mainFile, atomically: true, encoding: .utf8)
        for i in 1...12 {
            try "# Document \(i)\n\nBody text for workspace node \(i).\n"
                .write(to: tempDir.appendingPathComponent("doc_\(i).md"), atomically: true, encoding: .utf8)
        }

        // Seed ~440 KB of undo timeline data across background files (matching real user defaults)
        var seededTimelines: [String: DocumentUndoTimeline] = [:]
        let fillerChunk = String(repeating: "Markdown paragraph content for undo history persistence benchmark.\n", count: 80)
        for fileIdx in 1...3 {
            var entries: [DocumentUndoEntry] = []
            for step in 1...30 {
                entries.append(DocumentUndoEntry(
                    previousText: fillerChunk + "Step \(step - 1)",
                    newText: fillerChunk + "Step \(step)",
                    previousSelectedRange: NSRange(location: 0, length: 0),
                    newSelectedRange: NSRange(location: 10, length: 0),
                    timestamp: Date(),
                    origin: .userTyping,
                    summary: "Typing"
                ))
            }
            seededTimelines["/tmp/history_file_\(fileIdx).md"] = DocumentUndoTimeline(undoStack: entries, redoStack: [])
        }
        let encodedSeed = try JSONEncoder().encode(seededTimelines)
        testDefaults.set(encodedSeed, forKey: EditorWorkspaceViewModel.undoTimelinesDefaultsKey)

        let vm = EditorWorkspaceViewModel(userDefaults: testDefaults)
        var typo = vm.typography
        typo.maxColumnWidth = 860
        vm.typography = typo
        vm.activeSidebarTab = .files
        vm.openFolder(at: tempDir)
        vm.openFile(at: mainFile)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1509, height: 1020),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSHostingView(rootView: MainWindowView(viewModel: vm))
        window.layoutIfNeeded()
        window.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        guard let textView = vm.activeTextView,
              let scrollView = textView.enclosingScrollView else {
            XCTFail("Expected active HybridMarkdownTextView")
            return
        }

        // Wait for background diagram renderer to finish and restyle
        XCTAssertTrue(DiagramImageRenderer.shared.waitUntilIdle(timeout: 10))
        textView.editorCoordinator?.restyle(textView: textView)
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))

        let visibleRect = NSRect(x: 0, y: 0, width: 1236, height: 960)
        guard let bitmapRep = textView.bitmapImageRepForCachingDisplay(in: visibleRect),
              let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmapRep) else {
            XCTFail("Failed to create bitmapImageRep / graphicsContext")
            return
        }

        let renderFrame = { (rect: NSRect) in
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphicsContext
            textView.draw(rect)
            NSGraphicsContext.restoreGraphicsState()
        }

        // Warm up 1 draw pass
        renderFrame(visibleRect)

        // 1. Measure 30 frames of Sidebar Resize + Canvas Redraw
        let resizeStart = CFAbsoluteTimeGetCurrent()
        for frame in 0..<30 {
            let progress = CGFloat(frame) / 29.0
            let width = 1236.0 + progress * 273.0
            scrollView.frame = NSRect(x: 0, y: 0, width: width, height: 960)
            NotificationCenter.default.post(name: NSView.frameDidChangeNotification, object: scrollView)
            renderFrame(NSRect(x: 0, y: 0, width: width, height: 960))
        }
        let resizeTotalMs = (CFAbsoluteTimeGetCurrent() - resizeStart) * 1000.0

        // 2. Measure 30 frames of Canvas Redraw during Scroll
        let scrollStart = CFAbsoluteTimeGetCurrent()
        for frame in 0..<30 {
            let yOffset = CGFloat(frame % 10) * 15.0
            let rect = NSRect(x: 0, y: yOffset, width: 1236, height: 960)
            renderFrame(rect)
        }
        let scrollTotalMs = (CFAbsoluteTimeGetCurrent() - scrollStart) * 1000.0

        // 3. Measure 20 Keystrokes with 440 KB Undo History
        var insertLoc = (textView.string as NSString).range(of: "Welcome to").location
        textView.setSelectedRange(NSRange(location: insertLoc, length: 0))
        var typingEditOnlyMs = 0.0
        let typingStart = CFAbsoluteTimeGetCurrent()
        for i in 0..<20 {
            let ch = (i % 5 == 0) ? " " : "a"
            let t0 = CFAbsoluteTimeGetCurrent()
            textView.replaceCharacters(in: NSRange(location: insertLoc, length: 0), with: ch)
            insertLoc += 1
            textView.setSelectedRange(NSRange(location: insertLoc, length: 0))
            textView.didChangeText()
            typingEditOnlyMs += (CFAbsoluteTimeGetCurrent() - t0) * 1000.0
            renderFrame(visibleRect)
        }
        let typingTotalMs = (CFAbsoluteTimeGetCurrent() - typingStart) * 1000.0

        // 4. Measure 20 Cursor Line Transitions
        let nsStr = textView.string as NSString
        var lineStarts: [Int] = []
        var idx = 0
        while idx < nsStr.length && lineStarts.count < 20 {
            lineStarts.append(idx)
            let r = nsStr.lineRange(for: NSRange(location: idx, length: 0))
            idx = NSMaxRange(r)
        }
        var cursorRestyleOnlyMs = 0.0
        let cursorStart = CFAbsoluteTimeGetCurrent()
        for loc in lineStarts {
            let t0 = CFAbsoluteTimeGetCurrent()
            textView.setSelectedRange(NSRange(location: loc, length: 0))
            NotificationCenter.default.post(name: NSTextView.didChangeSelectionNotification, object: textView)
            cursorRestyleOnlyMs += (CFAbsoluteTimeGetCurrent() - t0) * 1000.0
            renderFrame(visibleRect)
        }
        let cursorTotalMs = (CFAbsoluteTimeGetCurrent() - cursorStart) * 1000.0

        print("""
        === FOLIO UI LAG PROFILE ===
        Seeded Undo History Payload: \(encodedSeed.count) bytes
        1. Sidebar Resize + Redraw (30 frames): \(String(format: "%.2f", resizeTotalMs)) ms total (\(String(format: "%.2f", resizeTotalMs / 30.0)) ms/frame)
        2. Scroll + Redraw (30 frames):         \(String(format: "%.2f", scrollTotalMs)) ms total (\(String(format: "%.2f", scrollTotalMs / 30.0)) ms/frame)
        3. Live Typing (20 keystrokes):         \(String(format: "%.2f", typingTotalMs)) ms total (\(String(format: "%.2f", typingTotalMs / 20.0)) ms/keystroke, edit+restyle=\(String(format: "%.2f", typingEditOnlyMs / 20.0)) ms)
        4. Cursor Line Moves (20 lines):        \(String(format: "%.2f", cursorTotalMs)) ms total (\(String(format: "%.2f", cursorTotalMs / 20.0)) ms/move, restyle=\(String(format: "%.2f", cursorRestyleOnlyMs / 20.0)) ms)
        ============================
        """)

        XCTAssertLessThan(resizeTotalMs / 30.0, 15.0, "Sidebar resize + redraw should stay responsive")
        XCTAssertLessThan(scrollTotalMs / 30.0, 12.0, "Scroll + redraw should stay responsive")
        XCTAssertLessThan(typingEditOnlyMs / 20.0, 22.0, "Live typing edit+restyle with 440KB undo history should stay responsive")
        XCTAssertLessThan(typingTotalMs / 20.0, 30.0, "Live typing + software bitmap redraw should stay responsive")
        XCTAssertLessThan(cursorTotalMs / 20.0, 28.0, "Cursor line transitions should stay responsive")
    }

    @MainActor
    func testNativeSidebarAndBottomBarHeightAlignment() throws {
        let vm = EditorWorkspaceViewModel()
        vm.showSidebar = true
        let hostingView = NSHostingView(rootView: MainWindowView(viewModel: vm))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        hostingView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        hostingView.layoutSubtreeIfNeeded()

        let footerHosting = NSHostingView(rootView: SidebarView(viewModel: vm).sidebarFooterBar)
        let statusHosting = NSHostingView(rootView: StatusBarView(viewModel: vm))
        let footerHeight = footerHosting.fittingSize.height
        let statusHeight = statusHosting.fittingSize.height

        let scrollView = try XCTUnwrap(vm.activeTextView?.enclosingScrollView)
        let scrollWindowRect = scrollView.convert(scrollView.bounds, to: nil)
        let editorScrollMinY = scrollWindowRect.minY
        XCTAssertEqual(footerHeight, 30.0, accuracy: 0.5, "Sidebar footer bar height must be 30pt")
        XCTAssertEqual(statusHeight, 30.0, accuracy: 0.5, "StatusBarView height must be 30pt")
        XCTAssertEqual(footerHeight, editorScrollMinY, accuracy: 0.5, "Sidebar footer top edge must align with StatusBarView top edge")
        XCTAssertEqual(scrollWindowRect.maxY, hostingView.bounds.height, accuracy: 1.0, "Editor scroll view canvas must extend all the way to the top edge of the window")

        for tab in SidebarTab.allCases {
            vm.activeSidebarTab = tab
            hostingView.layoutSubtreeIfNeeded()
        }
    }
}
