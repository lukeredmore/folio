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
        guard let dest = CGImageDestinationCreateWithData(
            mutableData as CFMutableData,
            UTType.gif.identifier as CFString,
            2,
            nil
        ) else {
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
            0x6D, 0x70, 0x34, 0x32  // "mp42"
        ]
        bytes.append(contentsOf: Array(repeating: 0, count: 64))
        return Data(bytes)
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
        XCTAssertNotNil(frame0.image)
        XCTAssertNotNil(frame1.image)
        XCTAssertFalse(frame0.image === frame1.image, "Expected distinct NSImage frames at t=0.05s vs t=0.25s")
    }

    @MainActor
    func testRemoteVideoThumbnailExtractionAndInlinePlaybackOnClick() throws {
        let mp4Data = makeSyntheticMP4ContainerData()
        XCTAssertTrue(FolioMediaImageCache.looksLikeVideoData(mp4Data))

        let tempDir = try makeTemporaryDirectory("folio-video-test")

        let mp4File = tempDir.appendingPathComponent("demo.mp4")
        try mp4Data.write(to: mp4File)

        let remoteVideoURL = "https://cdn.example.test/videos/demo.mp4"
        FolioMediaImageCache.shared.curlCommandPrefix = "cat '\(mp4File.path)' #"

        _ = FolioMediaImageCache.shared.image(for: remoteVideoURL)
        XCTAssertTrue(FolioMediaImageCache.shared.waitUntilRemoteFetchesIdle(timeout: 5.0))

        let thumb = FolioMediaImageCache.shared.image(for: remoteVideoURL)
        XCTAssertNotNil(thumb, "Remote video should produce a valid thumbnail NSImage")
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
        let videoDec = try XCTUnwrap(analysis.decorations.first {
            if case .imageRendered = $0.kind { return true }
            return false
        })
        let hitRect = try XCTUnwrap(textView.mediaDecorationHitRect(
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
