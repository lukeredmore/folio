import AppKit
import SwiftUI
import XCTest
@testable import Folio

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
}
