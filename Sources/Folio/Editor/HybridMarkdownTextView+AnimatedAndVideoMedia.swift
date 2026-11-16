import AppKit

extension HybridMarkdownTextView {

    struct ResolvedMediaCardLayout {
        let rect: NSRect
        let image: NSImage?
    }

    func animatedMediaFrame(for rawSource: String, baseDirectoryURL: URL?, isDark: Bool) -> NSImage? {
        let result = FolioMediaImageCache.shared.animatedFrame(
            for: rawSource,
            baseDirectoryURL: baseDirectoryURL,
            isDark: isDark
        )
        if result.isAnimated {
            inlineMediaController.ensureGIFAnimationTimerRunning(in: self)
        }
        return result.image
    }

    func ensureGIFAnimationTimerRunning() {
        inlineMediaController.ensureGIFAnimationTimerRunning(in: self)
    }

    func stopGIFAnimationTimer() {
        inlineMediaController.stopGIFAnimationTimer()
    }

    // MARK: - Inline Video Playback

    public var isInlineVideoPlaying: Bool {
        inlineMediaController.isVideoPlaying
    }

    func handleVideoClickIfNeeded(at point: NSPoint) -> Bool {
        guard !isSourceCodeMode, let layoutManager = self.layoutManager else { return false }
        let origin = self.textContainerOrigin
        let fullContentWidth = self.bounds.width - origin.x * 2
        let contentWidth = proseColumnWidth > 0 ? proseColumnWidth : fullContentWidth
        let probeRect = NSRect(x: point.x - 16.0, y: point.y - 16.0, width: 32.0, height: 32.0)
        let visibleChars = visibleDecorationCharacterRange(for: probeRect, margin: 64.0)
        var imageXOffsetByLineLocation: [Int: CGFloat] = [:]

        for dec in lineDecorations {
            if let visibleChars, !Self.decorationSpan(dec.lineRange, touches: visibleChars) {
                continue
            }
            guard case let .imageRendered(url, _, fullRange, _, _, baseDirectoryURL, _) = dec.kind,
                let layout = resolveMediaCardLayout(
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
            guard layout.rect.contains(point),
                FolioMediaImageCache.shared.isKnownVideo(for: url, baseDirectoryURL: baseDirectoryURL)
            else {
                continue
            }
            inlineMediaController.toggleOrStartVideo(
                url: url,
                fullRange: fullRange,
                baseDirectoryURL: baseDirectoryURL,
                frame: layout.rect,
                in: self
            )
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
        inlineMediaController.startVideoPlayback(
            url: url,
            fullRange: fullRange,
            baseDirectoryURL: baseDirectoryURL,
            frame: frame,
            in: self
        )
    }

    @objc public func closeActiveInlineVideo(_ sender: Any?) {
        inlineMediaController.stopVideoPlayback()
    }

    public func stopInlineVideoPlayback() {
        inlineMediaController.stopVideoPlayback()
    }

    func updateInlineVideoFrameIfActive(for url: String, fullRange: NSRange, drawRect: NSRect) {
        inlineMediaController.updateVideoFrameIfActive(for: url, fullRange: fullRange, drawRect: drawRect)
    }

    func syncInlineVideoOverlayWithDecorations() {
        inlineMediaController.syncVideoOverlayWithDecorations(in: self)
    }

    func resolveMediaCardLayout(
        for dec: LineDecoration,
        glyphRange explicitGlyphRange: NSRange? = nil,
        advanceAnimation: Bool,
        layoutManager: NSLayoutManager,
        origin: NSPoint,
        contentWidth: CGFloat,
        imageXOffsetByLineLocation: inout [Int: CGFloat]
    ) -> ResolvedMediaCardLayout? {
        guard case let .imageRendered(url, _, fullRange, explicitWidth, explicitHeight, baseDirectoryURL, _) = dec.kind else {
            return nil
        }
        let glyphRange = explicitGlyphRange ?? layoutManager.glyphRange(forCharacterRange: dec.lineRange, actualCharacterRange: nil)
        guard glyphRange.location != NSNotFound else { return nil }
        let lineFrag = layoutManager.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
        let imgGlyphIdx = layoutManager.glyphIndexForCharacter(at: fullRange.location)
        let glyphX =
            (imgGlyphIdx != NSNotFound && imgGlyphIdx < layoutManager.numberOfGlyphs)
            ? layoutManager.location(forGlyphAt: imgGlyphIdx).x
            : 0.0
        let lineKey = dec.lineRange.location
        let currentOffset = imageXOffsetByLineLocation[lineKey] ?? 0.0
        let startX = origin.x + max(glyphX, currentOffset)
        let remainingWidth = max(80.0, (origin.x + contentWidth) - startX)

        let loadedImg =
            advanceAnimation
            ? animatedMediaFrame(for: url, baseDirectoryURL: baseDirectoryURL, isDark: currentTheme.isDark)
            : FolioMediaImageCache.shared.image(for: url, baseDirectoryURL: baseDirectoryURL, isDark: currentTheme.isDark)

        if let img = loadedImg, img.size.width > 0, img.size.height > 0 {
            let intrinsicSize = img.size
            let aspect = intrinsicSize.height / max(1.0, intrinsicSize.width)
            let targetW: CGFloat
            let targetH: CGFloat
            if let ew = explicitWidth, let eh = explicitHeight {
                targetW = ew
                targetH = eh
            } else if let ew = explicitWidth {
                targetW = ew
                targetH = round(ew * aspect)
            } else if let eh = explicitHeight {
                targetH = eh
                targetW = round(eh / max(0.01, aspect))
            } else {
                targetW = intrinsicSize.width
                targetH = intrinsicSize.height
            }
            let maxDrawH = max(18.0, lineFrag.height - 6.0)
            let scale = min(1.0, min(remainingWidth / max(1.0, targetW), maxDrawH / max(1.0, targetH)))
            let drawW = targetW * scale
            let drawH = targetH * scale
            imageXOffsetByLineLocation[lineKey] = (startX - origin.x) + drawW + 8.0
            let rect = NSRect(
                x: startX,
                y: origin.y + lineFrag.minY + (lineFrag.height - drawH) * 0.5,
                width: drawW,
                height: drawH
            )
            return ResolvedMediaCardLayout(rect: rect, image: img)
        }

        let cardWidth = min(remainingWidth, max(220.0, min(440.0, explicitWidth ?? 400.0)))
        let cardHeight = min(50.0, max(38.0, lineFrag.height - 6.0))
        imageXOffsetByLineLocation[lineKey] = (startX - origin.x) + cardWidth + 8.0
        let rect = NSRect(
            x: startX,
            y: origin.y + lineFrag.minY + (lineFrag.height - cardHeight) * 0.5,
            width: cardWidth,
            height: cardHeight
        )
        return ResolvedMediaCardLayout(rect: rect, image: nil)
    }

    func mediaDecorationHitRect(
        for dec: LineDecoration,
        layoutManager: NSLayoutManager,
        origin: NSPoint,
        contentWidth: CGFloat,
        imageXOffsetByLineLocation: inout [Int: CGFloat]
    ) -> NSRect? {
        resolveMediaCardLayout(
            for: dec,
            advanceAnimation: false,
            layoutManager: layoutManager,
            origin: origin,
            contentWidth: contentWidth,
            imageXOffsetByLineLocation: &imageXOffsetByLineLocation
        )?.rect
    }
}
