import AppKit
import AVFoundation
import AVKit

extension HybridMarkdownTextView {

    func animatedMediaFrame(for rawSource: String, baseDirectoryURL: URL?, isDark: Bool) -> NSImage? {
        let result = FolioMediaImageCache.shared.animatedFrame(
            for: rawSource,
            baseDirectoryURL: baseDirectoryURL,
            isDark: isDark
        )
        if result.isAnimated {
            ensureGIFAnimationTimerRunning()
        }
        return result.image
    }

    func ensureGIFAnimationTimerRunning() {
        guard gifAnimationTimer == nil, !isSourceCodeMode else { return }
        let timer = Timer(timeInterval: 1.0 / 24.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickGIFAnimationTimer() }
        }
        RunLoop.main.add(timer, forMode: .common)
        gifAnimationTimer = timer
    }

    func stopGIFAnimationTimer() {
        gifAnimationTimer?.invalidate()
        gifAnimationTimer = nil
    }

    private func tickGIFAnimationTimer() {
        guard !isSourceCodeMode else {
            stopGIFAnimationTimer()
            return
        }
        let hasAnimatedDecoration = lineDecorations.contains { dec in
            guard case let .imageRendered(url, _, _, _, _, baseDir, _) = dec.kind else { return false }
            return FolioMediaImageCache.shared.isAnimatedMedia(for: url, baseDirectoryURL: baseDir, isDark: currentTheme.isDark)
        }
        if hasAnimatedDecoration {
            needsDisplay = true
        } else {
            stopGIFAnimationTimer()
        }
    }

    // MARK: - Inline Video Playback

    public var isInlineVideoPlaying: Bool {
        activeInlineVideoContainer != nil && activeInlineVideoPlayer != nil
    }

    func handleVideoClickIfNeeded(at point: NSPoint) -> Bool {
        guard !isSourceCodeMode, let layoutManager = self.layoutManager else { return false }
        let origin = self.textContainerOrigin
        let fullContentWidth = self.bounds.width - origin.x * 2
        let contentWidth = proseColumnWidth > 0 ? proseColumnWidth : fullContentWidth
        var imageXOffsetByLineLocation: [Int: CGFloat] = [:]

        for dec in lineDecorations {
            guard case let .imageRendered(url, _, fullRange, _, _, baseDirectoryURL, _) = dec.kind,
                  let hitRect = mediaDecorationHitRect(
                      for: dec,
                      layoutManager: layoutManager,
                      origin: origin,
                      contentWidth: contentWidth,
                      imageXOffsetByLineLocation: &imageXOffsetByLineLocation
                  ) else {
                continue
            }
            guard hitRect.contains(point),
                  FolioMediaImageCache.shared.isKnownVideo(for: url, baseDirectoryURL: baseDirectoryURL) else {
                continue
            }
            if activeInlineVideoURL == url && activeInlineVideoRange == fullRange {
                stopInlineVideoPlayback()
            } else {
                startInlineVideoPlayback(
                    url: url,
                    fullRange: fullRange,
                    baseDirectoryURL: baseDirectoryURL,
                    frame: hitRect
                )
            }
            return true
        }
        return false
    }

    public func startInlineVideoPlayback(
        url: String,
        fullRange: NSRange,
        baseDirectoryURL: URL?,
        frame: NSRect
    ) {
        stopInlineVideoPlayback()
        guard let playableURL = FolioMediaImageCache.shared.playableVideoURL(
            for: url,
            baseDirectoryURL: baseDirectoryURL
        ) else {
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
        closeButton.target = self
        closeButton.action = #selector(closeActiveInlineVideo(_:))
        container.addSubview(closeButton)

        addSubview(container)
        activeInlineVideoContainer = container
        activeInlineVideoPlayer = player
        activeInlineVideoURL = url
        activeInlineVideoRange = fullRange
        player.play()
        needsDisplay = true
    }

    @objc public func closeActiveInlineVideo(_ sender: Any?) {
        stopInlineVideoPlayback()
    }

    public func stopInlineVideoPlayback() {
        activeInlineVideoPlayer?.pause()
        activeInlineVideoPlayer = nil
        activeInlineVideoContainer?.removeFromSuperview()
        activeInlineVideoContainer = nil
        activeInlineVideoURL = nil
        activeInlineVideoRange = nil
        needsDisplay = true
    }

    func updateInlineVideoFrameIfActive(for url: String, fullRange: NSRange, drawRect: NSRect) {
        guard activeInlineVideoURL == url,
              activeInlineVideoRange == fullRange,
              let container = activeInlineVideoContainer else {
            return
        }
        if container.frame != drawRect {
            container.frame = drawRect
        }
    }

    func syncInlineVideoOverlayWithDecorations() {
        guard let activeURL = activeInlineVideoURL,
              let activeRange = activeInlineVideoRange else {
            return
        }
        guard !isSourceCodeMode else {
            stopInlineVideoPlayback()
            return
        }
        let stillVisible = lineDecorations.contains { dec in
            guard case let .imageRendered(url, _, fullRange, _, _, _, _) = dec.kind else {
                return false
            }
            return url == activeURL && fullRange == activeRange
        }
        if !stillVisible {
            stopInlineVideoPlayback()
        }
    }

    func mediaDecorationHitRect(
        for dec: LineDecoration,
        layoutManager: NSLayoutManager,
        origin: NSPoint,
        contentWidth: CGFloat,
        imageXOffsetByLineLocation: inout [Int: CGFloat]
    ) -> NSRect? {
        guard case let .imageRendered(url, _, fullRange, explicitWidth, explicitHeight, baseDirectoryURL, _) = dec.kind else {
            return nil
        }
        let glyphRange = layoutManager.glyphRange(forCharacterRange: dec.lineRange, actualCharacterRange: nil)
        guard glyphRange.location != NSNotFound else { return nil }
        let lineFrag = layoutManager.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
        let imgGlyphIdx = layoutManager.glyphIndexForCharacter(at: fullRange.location)
        let glyphX = (imgGlyphIdx != NSNotFound && imgGlyphIdx < layoutManager.numberOfGlyphs)
            ? layoutManager.location(forGlyphAt: imgGlyphIdx).x
            : 0.0
        let lineKey = dec.lineRange.location
        let currentOffset = imageXOffsetByLineLocation[lineKey] ?? 0.0
        let startX = origin.x + max(glyphX, currentOffset)
        let remainingWidth = max(80.0, (origin.x + contentWidth) - startX)

        let loadedImg = FolioMediaImageCache.shared.image(
            for: url,
            baseDirectoryURL: baseDirectoryURL,
            isDark: currentTheme.isDark
        )
        if let img = loadedImg, img.size.width > 0, img.size.height > 0 {
            let intrinsicSize = img.size
            let aspect = intrinsicSize.height / max(1.0, intrinsicSize.width)
            let targetW = explicitWidth ?? (explicitHeight.map { round($0 / max(0.01, aspect)) } ?? intrinsicSize.width)
            let targetH = explicitHeight ?? (explicitWidth.map { round($0 * aspect) } ?? intrinsicSize.height)
            let maxDrawH = max(18.0, lineFrag.height - 6.0)
            let scale = min(1.0, min(remainingWidth / max(1.0, targetW), maxDrawH / max(1.0, targetH)))
            let drawW = targetW * scale
            let drawH = targetH * scale
            imageXOffsetByLineLocation[lineKey] = (startX - origin.x) + drawW + 8.0
            return NSRect(
                x: startX,
                y: origin.y + lineFrag.minY + (lineFrag.height - drawH) * 0.5,
                width: drawW,
                height: drawH
            )
        }
        let cardWidth = min(remainingWidth, max(200.0, min(380.0, explicitWidth ?? 360.0)))
        let cardHeight = min(50.0, max(38.0, lineFrag.height - 6.0))
        imageXOffsetByLineLocation[lineKey] = (startX - origin.x) + cardWidth + 8.0
        return NSRect(
            x: startX,
            y: origin.y + lineFrag.minY + (lineFrag.height - cardHeight) * 0.5,
            width: cardWidth,
            height: cardHeight
        )
    }
}
