import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Folio

final class RemoteGIFAndVideoMediaTests: XCTestCase {

    override func tearDown() {
        FolioMediaImageCache.shared.curlCommandPrefix = FolioMediaImageCache.defaultCurlCommandPrefix
        FolioMediaImageCache.shared.sshAuthConfig = .disabled
        FolioMediaImageCache.shared.clearRemoteCache()
        super.tearDown()
    }

    private func makeTwoFrameGIFData() throws -> Data {
        let mutableData = NSMutableData()
        guard
            let dest = CGImageDestinationCreateWithData(
                mutableData as CFMutableData,
                UTType.gif.identifier as CFString,
                2,
                nil
            )
        else {
            XCTFail("Failed to create GIF destination")
            return Data()
        }

        let frameProps: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: 0.2,
                kCGImagePropertyGIFUnclampedDelayTime: 0.2
            ]
        ]
        for color in [NSColor.systemRed, NSColor.systemBlue] {
            let img = NSImage(size: NSSize(width: 32, height: 32))
            img.lockFocus()
            color.setFill()
            NSBezierPath(rect: NSRect(x: 0, y: 0, width: 32, height: 32)).fill()
            img.unlockFocus()
            var rect = NSRect(x: 0, y: 0, width: 32, height: 32)
            if let cgImg = img.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
                CGImageDestinationAddImage(dest, cgImg, frameProps as CFDictionary)
            }
        }
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return mutableData as Data
    }

    private func makeSyntheticMP4ContainerData() -> Data {
        // Minimal ISO Base Media File Format ftyp box header (24 bytes):
        // size=24 (0x00000018), type="ftyp", major_brand="isom", minor_version=0, compatible="isom","mp42"
        var bytes: [UInt8] = [
            0x00, 0x00, 0x00, 0x18,
            0x66, 0x74, 0x79, 0x70, // "ftyp"
            0x69, 0x73, 0x6F, 0x6D, // "isom"
            0x00, 0x00, 0x02, 0x00,
            0x69, 0x73, 0x6F, 0x6D, // "isom"
            0x6D, 0x70, 0x34, 0x32 // "mp42"
        ]
        bytes.append(contentsOf: Array(repeating: 0, count: 64))
        return Data(bytes)
    }

    private func centerColor(of image: NSImage?) throws -> NSColor {
        let cgImage = try XCTUnwrap(image?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let rep = NSBitmapImageRep(cgImage: cgImage)
        return try XCTUnwrap(rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.usingColorSpace(.sRGB))
    }

    func testAnimatedGIFDecodingAndRemoteFrameCycling() throws {
        let gifData = try makeTwoFrameGIFData()
        let decoded = try XCTUnwrap(FolioMediaImageCache.decodeAnimatedFrames(from: gifData))
        XCTAssertEqual(decoded.frames.count, 2)
        XCTAssertEqual(decoded.totalDuration, 0.4, accuracy: 0.02)

        let tempDir = try makeTemporaryDirectory("folio-gif-test")

        let gifFile = tempDir.appendingPathComponent("spinner.gif")
        try gifData.write(to: gifFile)

        let remoteURL = "https://cdn.example.test/assets/spinner.gif"
        FolioMediaImageCache.shared.curlCommandPrefix = "cat '\(gifFile.path)' #"

        _ = FolioMediaImageCache.shared.image(for: remoteURL)
        XCTAssertTrue(FolioMediaImageCache.shared.waitUntilRemoteFetchesIdle(timeout: 5.0))

        let loaded = FolioMediaImageCache.shared.image(for: remoteURL)
        XCTAssertNotNil(loaded)
        XCTAssertTrue(FolioMediaImageCache.shared.isAnimatedMedia(for: remoteURL))

        let frame0 = FolioMediaImageCache.shared.animatedFrame(for: remoteURL, at: 0.05)
        let frame1 = FolioMediaImageCache.shared.animatedFrame(for: remoteURL, at: 0.25)
        XCTAssertTrue(frame0.isAnimated)
        XCTAssertTrue(frame1.isAnimated)
        let firstColor = try centerColor(of: frame0.image)
        let secondColor = try centerColor(of: frame1.image)
        XCTAssertGreaterThan(firstColor.redComponent, firstColor.blueComponent + 0.3, "t=0.05s shows the red first frame")
        XCTAssertGreaterThan(secondColor.blueComponent, secondColor.redComponent + 0.3, "t=0.25s shows the blue second frame")
    }

    @MainActor
    func testVideoWithoutDecodableFramesGetsThePosterThumbnail() throws {
        let mp4File = try makeTemporaryDirectory("folio-video-poster").appendingPathComponent("empty.mp4")
        try makeSyntheticMP4ContainerData().write(to: mp4File)
        let poster = try XCTUnwrap(FolioMediaImageCache.extractVideoThumbnail(from: mp4File))
        XCTAssertEqual(poster.size, NSSize(width: 480, height: 270))
    }

    @MainActor
    func testRemoteVideoThumbnailExtractionAndInlinePlaybackOnClick() throws {
        XCTAssertTrue(FolioMediaImageCache.looksLikeVideoData(makeSyntheticMP4ContainerData()))

        let tempDir = try makeTemporaryDirectory("folio-video-test")

        let mp4File = tempDir.appendingPathComponent("demo.mp4")
        try writeSolidColorVideo(to: mp4File, width: 64, height: 36, red: 220, green: 30, blue: 30)
        XCTAssertTrue(FolioMediaImageCache.looksLikeVideoData(try Data(contentsOf: mp4File)))
        let localThumb = try XCTUnwrap(FolioMediaImageCache.extractVideoThumbnail(from: mp4File))
        XCTAssertEqual(localThumb.size, NSSize(width: 64, height: 36), "Decoding on the main thread returns the first frame")

        let remoteVideoURL = "https://cdn.example.test/videos/demo.mp4"
        FolioMediaImageCache.shared.curlCommandPrefix = "cat '\(mp4File.path)' #"

        _ = FolioMediaImageCache.shared.image(for: remoteVideoURL)
        XCTAssertTrue(FolioMediaImageCache.shared.waitUntilRemoteFetchesIdle(timeout: 5.0))

        let thumb = try XCTUnwrap(FolioMediaImageCache.shared.image(for: remoteVideoURL))
        XCTAssertEqual(thumb.size, NSSize(width: 64, height: 36), "The thumbnail is the decoded first frame, not the poster")
        let thumbColor = try centerColor(of: thumb)
        XCTAssertEqual(thumbColor.redComponent, 220.0 / 255.0, accuracy: 0.1)
        XCTAssertEqual(thumbColor.greenComponent, 30.0 / 255.0, accuracy: 0.1)
        XCTAssertEqual(thumbColor.blueComponent, 30.0 / 255.0, accuracy: 0.1)
        XCTAssertTrue(FolioMediaImageCache.shared.isKnownVideo(for: remoteVideoURL))

        let playableURL = try XCTUnwrap(FolioMediaImageCache.shared.playableVideoURL(for: remoteVideoURL))
        XCTAssertTrue(playableURL.isFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: playableURL.path))

        // Render in HybridMarkdownTextView and click the video card to start inline playback
        let doc = """
            # Demo Recording

            ![Demo Video](\(remoteVideoURL))

            Cursor sits on this bottom line.
            """
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(containerSize: NSSize(width: 680, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)

        let textView = HybridMarkdownTextView(frame: NSRect(x: 0, y: 0, width: 760, height: 500), textContainer: container)
        textView.textContainerInset = NSSize(width: 40, height: 24)
        textView.string = doc
        let bottomLoc = (doc as NSString).range(of: "Cursor sits").location
        textView.setSelectedRange(NSRange(location: bottomLoc, length: 0))

        let analysis = MarkdownLiveStyler.applyStyles(
            to: storage,
            theme: .daylight,
            typography: .default,
            sourceCodeMode: false,
            focusMode: false,
            selectedRange: NSRange(location: bottomLoc, length: 0),
            containerWidth: 680,
            prettyMode: true
        )
        textView.lineDecorations = analysis.decorations
        layoutManager.ensureLayout(for: container)

        // Find the video decoration hit rect and simulate clicking it
        var offsets: [Int: CGFloat] = [:]
        let videoDec = try XCTUnwrap(
            analysis.decorations.first {
                if case .imageRendered = $0.kind { return true }
                return false
            })
        let hitRect = try XCTUnwrap(
            textView.mediaDecorationHitRect(
                for: videoDec,
                layoutManager: layoutManager,
                origin: textView.textContainerOrigin,
                contentWidth: 680,
                imageXOffsetByLineLocation: &offsets
            ))
        let clickPoint = NSPoint(x: hitRect.midX, y: hitRect.midY)

        XCTAssertFalse(textView.isInlineVideoPlaying)
        XCTAssertTrue(textView.handleVideoClickIfNeeded(at: clickPoint))
        XCTAssertTrue(textView.isInlineVideoPlaying)
        XCTAssertEqual(textView.activeInlineVideoURL, remoteVideoURL)
        XCTAssertEqual(textView.selectedRange().location, bottomLoc, "Clicking video play overlay should not move cursor onto the video line")

        // Clicking again toggles inline video off
        XCTAssertTrue(textView.handleVideoClickIfNeeded(at: clickPoint))
        XCTAssertFalse(textView.isInlineVideoPlaying)
        XCTAssertNil(textView.activeInlineVideoURL)
    }
}
