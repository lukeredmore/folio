import AppKit
import AVFoundation
import AVKit

/// Owns the 24 Hz animated GIF repaint timer and inline `AVPlayer` video overlay
/// for a `HybridMarkdownTextView`.
@MainActor
final class InlineMediaController {
    private weak var textView: HybridMarkdownTextView?
    private var gifAnimationTimer: Timer?
    private var activeVideoContainer: NSView?
    private(set) var activeVideoURL: String?
    private var activeVideoRange: NSRange?
    private var activeVideoPlayer: AVPlayer?

    var isVideoPlaying: Bool {
        activeVideoContainer != nil && activeVideoPlayer != nil
    }

    func attach(to textView: HybridMarkdownTextView) {
        self.textView = textView
    }

    func handleViewRemovedFromWindow() {
        stopGIFAnimationTimer()
        stopVideoPlayback()
    }

    func ensureGIFAnimationTimerRunning(in textView: HybridMarkdownTextView) {
        self.textView = textView
        guard gifAnimationTimer == nil, textView.window != nil, !textView.isSourceCodeMode else { return }
        let timer = Timer(timeInterval: 1.0 / 24.0, repeats: true) { [weak self] timer in
            if self == nil {
                timer.invalidate()
                return
            }
            MainActor.assumeIsolated {
                self?.tickGIFAnimationTimer()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        gifAnimationTimer = timer
    }

    func stopGIFAnimationTimer() {
        gifAnimationTimer?.invalidate()
        gifAnimationTimer = nil
    }

    private func tickGIFAnimationTimer() {
        guard let textView, textView.window != nil, !textView.isSourceCodeMode else {
            stopGIFAnimationTimer()
            return
        }
        let isDark = textView.currentTheme.isDark
        let hasAnyAnimated = textView.lineDecorations.contains { dec in
            guard case let .imageRendered(url, _, _, _, _, baseDir, _) = dec.kind else { return false }
            return FolioMediaImageCache.shared.isAnimatedMedia(for: url, baseDirectoryURL: baseDir, isDark: isDark)
        }
        guard hasAnyAnimated else {
            stopGIFAnimationTimer()
            return
        }
        guard let layoutManager = textView.layoutManager else { return }
        let origin = textView.textContainerOrigin
        let fullContentWidth = textView.bounds.width - origin.x * 2
        let contentWidth = textView.proseColumnWidth > 0 ? textView.proseColumnWidth : fullContentWidth
        let visibleChars = textView.visibleDecorationCharacterRange(for: textView.visibleRect, margin: 120.0)
        var imageXOffsetByLineLocation: [Int: CGFloat] = [:]

        for dec in textView.lineDecorations {
            if let visibleChars, !HybridMarkdownTextView.decorationSpan(dec.lineRange, touches: visibleChars) {
                continue
            }
            guard case let .imageRendered(url, _, _, _, _, baseDir, _) = dec.kind else { continue }
            guard
                let layout = textView.resolveMediaCardLayout(
                    for: dec,
                    advanceAnimation: false,
                    layoutManager: layoutManager,
                    origin: origin,
                    contentWidth: contentWidth,
                    imageXOffsetByLineLocation: &imageXOffsetByLineLocation
                )
            else {
                continue
            }
            if FolioMediaImageCache.shared.isAnimatedMedia(for: url, baseDirectoryURL: baseDir, isDark: isDark) {
                textView.setNeedsDisplay(layout.rect.insetBy(dx: -2.0, dy: -2.0))
            }
        }
    }

    func toggleOrStartVideo(
        url: String,
        fullRange: NSRange,
        baseDirectoryURL: URL?,
        frame: NSRect,
        in textView: HybridMarkdownTextView
    ) {
        self.textView = textView
        if activeVideoURL == url && activeVideoRange == fullRange {
            stopVideoPlayback()
        } else {
            startVideoPlayback(
                url: url,
                fullRange: fullRange,
                baseDirectoryURL: baseDirectoryURL,
                frame: frame,
                in: textView
            )
        }
    }

    func startVideoPlayback(
        url: String,
        fullRange: NSRange,
        baseDirectoryURL: URL?,
        frame: NSRect,
        in textView: HybridMarkdownTextView
    ) {
        self.textView = textView
        stopVideoPlayback()
        guard let playableURL = FolioMediaImageCache.shared.playableVideoURL(for: url, baseDirectoryURL: baseDirectoryURL) else {
            return
        }

        let container = NSView(frame: frame)
        container.wantsLayer = true
        container.layer?.cornerRadius = 6.0
        container.layer?.masksToBounds = true
        container.layer?.backgroundColor = NSColor.black.cgColor

        let player = AVPlayer(url: playableURL)
        let playerView = AVPlayerView(frame: container.bounds)
        playerView.autoresizingMask = [.width, .height]
        playerView.controlsStyle = .inline
        playerView.player = player
        container.addSubview(playerView)

        let closeButton = NSButton(
            frame: NSRect(
                x: max(4, container.bounds.width - 28),
                y: max(4, container.bounds.height - 28),
                width: 22,
                height: 22
            )
        )
        closeButton.autoresizingMask = [.minXMargin, .minYMargin]
        closeButton.bezelStyle = .circular
        closeButton.isBordered = false
        closeButton.wantsLayer = true
        closeButton.layer?.cornerRadius = 11.0
        closeButton.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.65).cgColor
        closeButton.title = "✕"
        closeButton.font = NSFont.systemFont(ofSize: 11, weight: .bold)
        closeButton.contentTintColor = .white
        closeButton.target = textView
        closeButton.action = #selector(HybridMarkdownTextView.closeActiveInlineVideo(_:))
        container.addSubview(closeButton)

        textView.addSubview(container)
        activeVideoContainer = container
        activeVideoPlayer = player
        activeVideoURL = url
        activeVideoRange = fullRange
        player.play()
        textView.needsDisplay = true
    }

    func stopVideoPlayback() {
        let hadVideo = activeVideoPlayer != nil || activeVideoContainer != nil
        activeVideoPlayer?.pause()
        activeVideoPlayer?.replaceCurrentItem(with: nil)
        activeVideoPlayer = nil
        activeVideoContainer?.removeFromSuperview()
        activeVideoContainer = nil
        activeVideoURL = nil
        activeVideoRange = nil
        if hadVideo {
            textView?.needsDisplay = true
        }
    }

    func updateVideoFrameIfActive(for url: String, fullRange: NSRange, drawRect: NSRect) {
        guard activeVideoURL == url,
            activeVideoRange == fullRange,
            let container = activeVideoContainer
        else {
            return
        }
        if container.frame != drawRect {
            container.frame = drawRect
        }
    }

    func syncVideoOverlayWithDecorations(in textView: HybridMarkdownTextView) {
        self.textView = textView
        guard let activeURL = activeVideoURL, let activeRange = activeVideoRange else { return }
        guard !textView.isSourceCodeMode else {
            stopVideoPlayback()
            return
        }
        let stillVisible = textView.lineDecorations.contains { dec in
            guard case let .imageRendered(url, _, fullRange, _, _, _, _) = dec.kind else {
                return false
            }
            return url == activeURL && fullRange == activeRange
        }
        if !stillVisible {
            stopVideoPlayback()
        }
    }
}
