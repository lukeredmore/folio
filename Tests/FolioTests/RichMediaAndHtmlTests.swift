import AppKit
import SwiftUI
import XCTest
@testable import FolioEditor
@testable import FolioEditorTestSupport
@testable import FolioModels

final class RichMediaAndHtmlTests: XCTestCase {

    @MainActor
    func testRichMediaImagesVideosMermaidSvgAndInlineHTMLWithPrettyMode() throws {
        // 1. Verify Mermaid SVG FFI and SVG normalization FFI
        let mermaidSvg = MarkdownLiveStyler.renderMermaidSVG("flowchart LR\n    A[Start] --> B[End]", isDark: false)
        XCTAssertTrue(mermaidSvg.contains("<svg"), "Mermaid FFI should produce valid SVG")
        XCTAssertTrue(mermaidSvg.contains("Start") && mermaidSvg.contains("End"))
        XCTAssertFalse(
            mermaidSvg.contains("fill=\"transparent\""),
            "Mermaid SVG must use SVG 1.1 fill=\"none\" rather than CSS fill=\"transparent\" so CoreSVG does not render a black canvas")

        let (mermaidNSImage, _) = FolioMediaImageCache.shared.mermaidImage(for: "flowchart LR\n    A[Start] --> B[End]", isDark: false)
        let renderedImg = try XCTUnwrap(mermaidNSImage, "CoreSVG should rasterize Mermaid SVG into NSImage")
        let rep = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: 64,
                pixelsHigh: 64,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
        )
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 64, height: 64).fill()
        renderedImg.draw(in: NSRect(x: 0, y: 0, width: 64, height: 64))
        NSGraphicsContext.restoreGraphicsState()
        let cornerColor = try XCTUnwrap(rep.colorAt(x: 2, y: 2)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(cornerColor.redComponent, 0.9, "Mermaid canvas background must be transparent over white card, not solid black")
        XCTAssertGreaterThan(cornerColor.greenComponent, 0.9)
        XCTAssertGreaterThan(cornerColor.blueComponent, 0.9)

        let normalizedSvg = MarkdownLiveStyler.normalizeSVG("<svg viewBox=\"0 0 120 60\"><rect width=\"120\" height=\"60\"/></svg>")
        XCTAssertTrue(normalizedSvg.contains("xmlns=\"http://www.w3.org/2000/svg\""))

        // 2. Verify live buffer decorations for Markdown images, HTML <img>/<video>, Mermaid/SVG fences, and inline HTML tags
        let markdown = """
            # Rich Media Test

            ![Hero Diagram](assets/hero.png)

            <img src="assets/banner.svg" alt="Banner" width="320" height="120" />

            <video src="demos/walkthrough.mp4" title="Walkthrough Video" width="480" height="270"></video>

            Press <kbd>Cmd+Shift+P</kbd> to toggle <mark>Pretty Mode</mark> with <u>underlined</u>, H<sub>2</sub>O, and E=mc<sup>2</sup>.

            ```mermaid
            flowchart TD
                Client --> Server
            ```

            ```svg
            <svg viewBox="0 0 100 50"><circle cx="50" cy="25" r="20" fill="#2563eb"/></svg>
            ```
            """

        let storage = NSTextStorage(string: markdown)
        // Cursor at line 0 ("# Rich Media Test") so all media lines and blocks are inactive and rendered
        let prettyAnalysis = MarkdownLiveStyler.applyStyles(
            to: storage,
            theme: .daylight,
            sourceCodeMode: false,
            focusMode: false,
            selectedRange: NSRange(location: 0, length: 0),
            prettyMode: true
        )

        let imageDecs = prettyAnalysis.decorations.compactMap { dec -> (url: String, alt: String)? in
            if case let .imageRendered(url, alt, _, _, _, _, _) = dec.kind {
                return (url, alt)
            }
            return nil
        }
        XCTAssertEqual(imageDecs.count, 3, "Expected 3 image/video rendered decorations (Markdown image, HTML <img>, HTML <video>)")
        XCTAssertTrue(imageDecs.contains(where: { $0.url == "assets/hero.png" && $0.alt == "Hero Diagram" }))
        XCTAssertTrue(imageDecs.contains(where: { $0.url == "assets/banner.svg" && $0.alt == "Banner" }))
        XCTAssertTrue(imageDecs.contains(where: { $0.url == "demos/walkthrough.mp4" && $0.alt == "Walkthrough Video" }))
        XCTAssertTrue(FolioMediaImageCache.isVideoURL("demos/walkthrough.mp4"))

        let hasMermaidBlock = prettyAnalysis.decorations.contains {
            if case .mermaidBlockRendered = $0.kind { return true }
            return false
        }
        XCTAssertTrue(hasMermaidBlock, "Inactive ```mermaid fence should emit .mermaidBlockRendered in Pretty Mode")

        let hasSvgBlock = prettyAnalysis.decorations.contains {
            if case .svgBlockRendered = $0.kind { return true }
            return false
        }
        XCTAssertTrue(hasSvgBlock, "Inactive ```svg fence should emit .svgBlockRendered in Pretty Mode")

        let hasKbdPill = prettyAnalysis.decorations.contains {
            if case .kbdPill = $0.kind { return true }
            return false
        }
        XCTAssertTrue(hasKbdPill, "<kbd> tag should emit .kbdPill decoration in Pretty Mode")

        // 3. Verify toggling Pretty Mode off disables rich block/media rendering while preserving syntax highlighting
        let rawPrettyDisabledAnalysis = MarkdownLiveStyler.applyStyles(
            to: storage,
            theme: .daylight,
            sourceCodeMode: false,
            focusMode: false,
            selectedRange: NSRange(location: 0, length: 0),
            prettyMode: false
        )
        let hasRenderedMediaWhenPrettyOff = rawPrettyDisabledAnalysis.decorations.contains {
            switch $0.kind {
            case .imageRendered, .mermaidBlockRendered, .svgBlockRendered, .kbdPill:
                return true
            default:
                return false
            }
        }
        XCTAssertFalse(hasRenderedMediaWhenPrettyOff, "Disabling Pretty Mode should suppress rendered media/diagram cards and show syntax-highlighted source")
        XCTAssertTrue(rawPrettyDisabledAnalysis.decorations.contains(where: { $0.kind == .codeFenceStart(language: "mermaid") }))
        XCTAssertTrue(rawPrettyDisabledAnalysis.decorations.contains(where: { $0.kind == .codeFenceStart(language: "svg") }))

        // 4. Verify anchor images `[![alt](img_url)](link_url)` fold the outer link syntax and emit a single `.imageRendered`
        let anchorMarkdown = """
            # Anchor Test

            [![Download Latest Folio.dmg](https://img.shields.io/badge/Download-Folio.dmg-blue)](https://github.com/lukeredmore/folio/releases/latest/download/Folio.dmg)
            """
        let anchorStorage = NSTextStorage(string: anchorMarkdown)
        let anchorAnalysis = MarkdownLiveStyler.applyStyles(
            to: anchorStorage,
            theme: .daylight,
            sourceCodeMode: false,
            focusMode: false,
            selectedRange: NSRange(location: 0, length: 0),
            prettyMode: true
        )
        let anchorImages = anchorAnalysis.decorations.compactMap { dec -> (url: String, alt: String)? in
            if case let .imageRendered(url, alt, _, _, _, _, _) = dec.kind {
                return (url, alt)
            }
            return nil
        }
        XCTAssertEqual(anchorImages.count, 1, "Anchor image should emit exactly 1 .imageRendered decoration")
        XCTAssertEqual(anchorImages.first?.url, "https://img.shields.io/badge/Download-Folio.dmg-blue")
        XCTAssertEqual(anchorImages.first?.alt, "Download Latest Folio.dmg")

        let nsAnchor = anchorMarkdown as NSString
        let outerTrailingLinkSyntax = nsAnchor.range(of: ")](https://github.com/lukeredmore/folio/releases/latest/download/Folio.dmg)")
        let outerTrailingColor = anchorStorage.attribute(.foregroundColor, at: outerTrailingLinkSyntax.location + 3, effectiveRange: nil) as? NSColor
        XCTAssertEqual(outerTrailingColor, .clear, "Outer link destination of anchor image must be hidden (.clear) when line is inactive")

        // 5. Verify Mermaid quoted '&' in node label and cyclic state diagram don't split on '&'
        let stateMermaid = MarkdownLiveStyler.renderMermaidSVG(
            """
            flowchart LR
                Styler["Live Buffer Folds & Inlays"] --> View["HybridMarkdownTextView"]
            """,
            isDark: false
        )
        XCTAssertTrue(stateMermaid.contains("Live Buffer Folds &amp; Inlays"))
        XCTAssertFalse(stateMermaid.contains(">Inlays\"</text>"))
    }

    @MainActor
    func testMissingLocalMediaPlaceholderAndExtensionlessResolution() throws {
        let rootTempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("folio-media-tests-\(UUID().uuidString)", isDirectory: true)
        let spacedDir =
            rootTempDir
            .appendingPathComponent("trying stuff out", isDirectory: true)
            .appendingPathComponent("May 2022", isDirectory: true)
        try FileManager.default.createDirectory(at: spacedDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootTempDir) }

        // Write a real local PNG ("Globe_High.png") inside a directory with spaces in its path
        let sampleImg = NSImage(size: NSSize(width: 96, height: 48))
        sampleImg.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 96, height: 48).fill()
        sampleImg.unlockFocus()
        let tiff = try XCTUnwrap(sampleImg.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        let pngData = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let existingImageURL = spacedDir.appendingPathComponent("Globe_High.png")
        try pngData.write(to: existingImageURL)

        // 1. Existing local image loads both by exact filename and extensionless stem (LaTeX \includegraphics)
        XCTAssertEqual(
            FolioMediaImageCache.shared.loadState(for: "Globe_High.png", baseDirectoryURL: spacedDir),
            .loaded
        )
        XCTAssertEqual(
            FolioMediaImageCache.shared.loadState(for: "Globe_High", baseDirectoryURL: spacedDir),
            .loaded
        )
        let loadedByStem = try XCTUnwrap(
            FolioMediaImageCache.shared.image(for: "Globe_High", baseDirectoryURL: spacedDir)
        )
        XCTAssertEqual(loadedByStem.size, NSSize(width: 96, height: 48))

        // 2. Missing local image and video report .missingLocalFile with diagnostic subtitle and resolved path tooltip
        let expectedMissingPath = spacedDir.appendingPathComponent("mmayer.png").standardizedFileURL.path
        let missingImgInfo = FolioMediaImageCache.shared.placeholderInfo(
            for: "mmayer.png",
            alt: "Marissa Mayer's résumé, re-created with AltaCV",
            baseDirectoryURL: spacedDir
        )
        XCTAssertEqual(missingImgInfo.state, .missingLocalFile(resolvedPath: expectedMissingPath))
        XCTAssertEqual(missingImgInfo.titleText, "Marissa Mayer's résumé, re-created with AltaCV")
        XCTAssertEqual(missingImgInfo.subtitleText, "File not found · mmayer.png")
        XCTAssertTrue(missingImgInfo.isError)
        XCTAssertEqual(
            missingImgInfo.tooltipText,
            "Marissa Mayer's résumé, re-created with AltaCV — File not found: \(expectedMissingPath)"
        )

        let missingVideoInfo = FolioMediaImageCache.shared.placeholderInfo(
            for: "sample.mp4",
            alt: "",
            baseDirectoryURL: spacedDir
        )
        XCTAssertEqual(missingVideoInfo.titleText, "sample.mp4")
        XCTAssertEqual(missingVideoInfo.subtitleText, "File not found · sample.mp4")
        XCTAssertTrue(missingVideoInfo.isError)

        // 3. Invalid data URI reports .invalidMedia with diagnostic subtitle
        let invalidDataInfo = FolioMediaImageCache.shared.placeholderInfo(
            for: "data:image/png;base64,!!!invalid!!!",
            alt: "Broken Inline",
            baseDirectoryURL: spacedDir
        )
        XCTAssertEqual(invalidDataInfo.state, .invalidMedia)
        XCTAssertEqual(invalidDataInfo.subtitleText, "Cannot decode · data:image/png;base64,!!!invalid!!!")
        XCTAssertTrue(invalidDataInfo.isError)

        // 4. Verify HybridMarkdownTextView hover tooltip over a missing local image card
        let textStorage = NSTextStorage()
        let layoutManager = WideBlockLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let textContainer = WideBlockTextContainer(containerSize: NSSize(width: 680, height: 1000))
        textContainer.lineFragmentPadding = 0
        layoutManager.addTextContainer(textContainer)
        let textView = HybridMarkdownTextView(frame: NSRect(x: 0, y: 0, width: 760, height: 400), textContainer: textContainer)
        textView.textContainerInset = NSSize(width: 40, height: 20)
        textView.proseColumnWidth = 680

        let doc = """
            # Samples

            <img src="mmayer.png" alt="Marissa Mayer's résumé, re-created with AltaCV" width="600px">
            """
        textView.string = doc
        let analysis = MarkdownLiveStyler.applyStyles(
            to: textStorage,
            theme: .daylight,
            sourceCodeMode: false,
            focusMode: false,
            selectedRange: NSRange(location: 0, length: 0),
            containerWidth: 680,
            prettyMode: true,
            baseDirectoryURL: spacedDir
        )
        textView.lineDecorations = analysis.decorations
        layoutManager.ensureLayout(for: textContainer)

        let imgDec = try XCTUnwrap(
            analysis.decorations.first {
                if case .imageRendered = $0.kind { return true }
                return false
            }
        )
        var xOffsets: [Int: CGFloat] = [:]
        let cardRect = try XCTUnwrap(
            textView.mediaDecorationHitRect(
                for: imgDec,
                layoutManager: layoutManager,
                origin: textView.textContainerOrigin,
                contentWidth: 680,
                imageXOffsetByLineLocation: &xOffsets
            )
        )
        let hoverTip = textView.imageAltTooltip(at: NSPoint(x: cardRect.midX, y: cardRect.midY))
        XCTAssertEqual(
            hoverTip,
            "Marissa Mayer's résumé, re-created with AltaCV — File not found: \(expectedMissingPath)"
        )
    }

    @MainActor
    func testTaskCheckboxHitTestingGatesOnRealCheckboxRectAndRejectsCodeMathAndMargins() throws {
        let storage = NSTextStorage()
        let layoutManager = WideBlockLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = WideBlockTextContainer(containerSize: NSSize(width: 680, height: 1200))
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        let textView = HybridMarkdownTextView(frame: NSRect(x: 0, y: 0, width: 760, height: 600), textContainer: container)
        textView.textContainerInset = NSSize(width: 40, height: 20)
        textView.proseColumnWidth = 680

        let doc = #"""
            - [ ] Buy milk

            Plain note [x] inline

            ```swift
            let flag = arr[x]
            ```

            Math $\mathbb{E}[x]$ inline

            Cursor line
            """#
        textView.string = doc
        let nsDoc = doc as NSString
        let cursorLoc = nsDoc.range(of: "Cursor line").location
        let analysis = MarkdownLiveStyler.applyStyles(
            to: storage,
            theme: .daylight,
            sourceCodeMode: false,
            focusMode: false,
            selectedRange: NSRange(location: cursorLoc, length: 0),
            containerWidth: 680,
            prettyMode: true
        )
        textView.lineDecorations = analysis.decorations
        layoutManager.ensureLayout(for: container)

        var toggledLocations: [Int] = []
        textView.onToggleCheckboxAtCharacterIndex = { loc in
            toggledLocations.append(loc)
        }

        let origin = textView.textContainerOrigin
        func centerPoint(for substring: String) -> (point: NSPoint, location: Int) {
            let range = nsDoc.range(of: substring)
            let boxSubrange = (substring as NSString).range(of: "[")
            let bracketRange = NSRange(location: range.location + boxSubrange.location, length: 3)
            let glyphRange = layoutManager.glyphRange(forCharacterRange: bracketRange, actualCharacterRange: nil)
            let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
            return (NSPoint(x: origin.x + rect.midX, y: origin.y + rect.midY), bracketRange.location)
        }

        let taskHit = centerPoint(for: "- [ ] Buy milk")
        XCTAssertTrue(textView.toggleTaskCheckboxIfHit(at: taskHit.point))
        XCTAssertEqual(toggledLocations, [taskHit.location])

        // Left margin outside the checkbox glyph rect on the same line
        XCTAssertFalse(textView.toggleTaskCheckboxIfHit(at: NSPoint(x: 6.0, y: taskHit.point.y)))
        // Plain prose [x] without a list marker
        XCTAssertFalse(textView.toggleTaskCheckboxIfHit(at: centerPoint(for: "note [x]").point))
        // Fenced code block arr[x]
        XCTAssertFalse(textView.toggleTaskCheckboxIfHit(at: centerPoint(for: "arr[x]").point))
        // Inline math \mathbb{E}[x]
        XCTAssertFalse(textView.toggleTaskCheckboxIfHit(at: centerPoint(for: #"E}[x]"#).point))
        XCTAssertEqual(toggledLocations, [taskHit.location])
    }

    @MainActor
    func testCodeFenceLanguagePickerPreservesBlockquotesTildesAndFenceLengths() {
        XCTAssertEqual(
            HybridMarkdownTextView.updatedCodeFenceLine("> ~~~python", languageId: "rust"),
            "> ~~~rust"
        )
        XCTAssertEqual(
            HybridMarkdownTextView.updatedCodeFenceLine("  > > ````markdown", languageId: "html"),
            "  > > ````html"
        )
        XCTAssertEqual(
            HybridMarkdownTextView.updatedCodeFenceLine("~~~~javascript", languageId: ""),
            "~~~~"
        )

        let textView = HybridMarkdownTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        textView.string = "> ~~~python\nprint(1)\n> ~~~\n"
        textView.applyCodeFenceLanguage("swift", toLineAt: 0)
        XCTAssertEqual(textView.string, "> ~~~swift\nprint(1)\n> ~~~\n")
    }

    @MainActor
    func testInsertNewlineContinuesLaTeXItemOnlyInLaTeXDocuments() {
        let mdView = HybridMarkdownTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        mdView.string = "\\item Markdown prose"
        mdView.setSelectedRange(NSRange(location: (mdView.string as NSString).length, length: 0))
        mdView.insertNewline(nil)
        XCTAssertEqual(mdView.string, "\\item Markdown prose\n", "Markdown documents must not auto-insert \\item on Return")

        let texView = HybridMarkdownTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        let tex = "\\documentclass{article}\n\\begin{document}\n\\begin{itemize}\n  \\item First\n\\end{itemize}\n\\end{document}"
        texView.string = tex
        let endOfFirst = NSMaxRange((tex as NSString).range(of: "\\item First"))
        texView.setSelectedRange(NSRange(location: endOfFirst, length: 0))
        texView.insertNewline(nil)
        XCTAssertTrue(texView.string.contains("  \\item First\n  \\item \n"), "LaTeX documents must continue \\item on Return")
    }
}
