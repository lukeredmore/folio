import AppKit
import AVFoundation
import CryptoKit
import Foundation
import ImageIO

/// Decoded frames and timing metadata for an animated image (GIF, APNG, or WebP).
public struct FolioAnimatedMediaFrames: @unchecked Sendable {
    public let frames: [NSImage]
    public let frameDurations: [TimeInterval]
    public let cumulativeDurations: [TimeInterval]
    public let totalDuration: TimeInterval

    public init(frames: [NSImage], frameDurations: [TimeInterval]) {
        self.frames = frames
        self.frameDurations = frameDurations
        var cumulative: [TimeInterval] = []
        cumulative.reserveCapacity(frameDurations.count)
        var running: TimeInterval = 0
        for duration in frameDurations {
            let clamped = max(0.02, duration)
            running += clamped
            cumulative.append(running)
        }
        self.cumulativeDurations = cumulative
        self.totalDuration = running
    }

    public func frame(at time: TimeInterval) -> NSImage {
        guard !frames.isEmpty else { return NSImage() }
        guard frames.count > 1, totalDuration > 0 else { return frames[0] }
        let modTime = time.truncatingRemainder(dividingBy: totalDuration)
        let normalizedTime = modTime >= 0 ? modTime : (modTime + totalDuration)
        for (index, threshold) in cumulativeDurations.enumerated() where normalizedTime < threshold {
            return frames[index]
        }
        return frames[frames.count - 1]
    }
}

extension FolioMediaImageCache {

    /// Decodes multi-frame animated GIF/APNG/WebP data using ImageIO.
    /// Returns `nil` for single-frame static images.
    public static func decodeAnimatedFrames(from data: Data) -> FolioAnimatedMediaFrames? {
        guard !data.isEmpty,
            let source = CGImageSourceCreateWithData(data as CFData, nil)
        else {
            return nil
        }
        let frameCount = CGImageSourceGetCount(source)
        guard frameCount > 1 else { return nil }

        var frames: [NSImage] = []
        var durations: [TimeInterval] = []
        frames.reserveCapacity(frameCount)
        durations.reserveCapacity(frameCount)

        for index in 0..<frameCount {
            guard let cgImage = CGImageSourceCreateImageAtIndex(source, index, nil) else {
                continue
            }
            let size = NSSize(width: cgImage.width, height: cgImage.height)
            frames.append(NSImage(cgImage: cgImage, size: size))
            durations.append(frameDelay(at: index, in: source))
        }

        guard frames.count > 1 else { return nil }
        return FolioAnimatedMediaFrames(frames: frames, frameDurations: durations)
    }

    private static func frameDelay(at index: Int, in source: CGImageSource) -> TimeInterval {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] else {
            return 0.1
        }
        let dictKeys: [(CFString, CFString, CFString)] = [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime)
        ]
        for (dictKey, unclampedKey, delayKey) in dictKeys {
            if let dict = properties[dictKey] as? [CFString: Any] {
                if let unclamped = dict[unclampedKey] as? Double, unclamped > 0.01 {
                    return unclamped
                }
                if let delay = dict[delayKey] as? Double, delay > 0.01 {
                    return delay
                }
            }
        }
        return 0.1
    }

    func canonicalCacheKey(for rawSource: String, baseDirectoryURL: URL?, isDark: Bool) -> String {
        let trimmed = rawSource.trimmingCharacters(in: .whitespacesAndNewlines)
        if let remoteURL = Self.resolveRemoteURL(from: trimmed) {
            return Self.remoteCacheKey(for: remoteURL)
        }
        return "\(baseDirectoryURL?.path ?? "")|\(isDark ? "1" : "0")|\(trimmed)"
    }

    /// Returns the appropriate animation frame at `time` (if the image is a multi-frame GIF/APNG/WebP),
    /// or the static image with `isAnimated == false`.
    public func animatedFrame(
        for rawSource: String,
        baseDirectoryURL: URL? = nil,
        isDark: Bool = false,
        at time: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> (image: NSImage?, isAnimated: Bool) {
        let baseImage = image(for: rawSource, baseDirectoryURL: baseDirectoryURL, isDark: isDark)
        let key = canonicalCacheKey(for: rawSource, baseDirectoryURL: baseDirectoryURL, isDark: isDark)
        lock.lock()
        let animated = animatedFramesCache[key]
        lock.unlock()
        if let animated = animated, animated.frames.count > 1 {
            return (animated.frame(at: time), true)
        }
        return (baseImage, false)
    }

    public func isAnimatedMedia(
        for rawSource: String,
        baseDirectoryURL: URL? = nil,
        isDark: Bool = false
    ) -> Bool {
        let key = canonicalCacheKey(for: rawSource, baseDirectoryURL: baseDirectoryURL, isDark: isDark)
        lock.lock()
        let hasAnimated = (animatedFramesCache[key]?.frames.count ?? 0) > 1
        lock.unlock()
        return hasAnimated
    }

    /// Returns `true` if `rawSource` has a video URL extension/scheme OR was detected as a video container when fetched.
    public func isKnownVideo(for rawSource: String, baseDirectoryURL: URL? = nil) -> Bool {
        if Self.isVideoURL(rawSource) {
            return true
        }
        let trimmed = rawSource.trimmingCharacters(in: .whitespacesAndNewlines)
        if let remoteURL = Self.resolveRemoteURL(from: trimmed) {
            let key = Self.remoteCacheKey(for: remoteURL)
            lock.lock()
            let hasRemoteVideo = remoteVideoFileURLs[key] != nil
            lock.unlock()
            return hasRemoteVideo
        }
        return false
    }

    /// Detects MP4/MOV/M4V ISO base media (`ftyp`/`moov`) or WebM/Matroska EBML headers from raw bytes.
    public static func looksLikeVideoData(_ data: Data) -> Bool {
        guard data.count >= 12 else { return false }
        let bytes = [UInt8](data.prefix(12))
        // ISO Base Media File Format (MP4, MOV, M4V): box type at bytes 4..7
        let boxType = String(bytes: bytes[4..<8], encoding: .ascii) ?? ""
        if ["ftyp", "moov", "wide", "mdat", "free"].contains(boxType) {
            return true
        }
        // WebM / Matroska EBML magic: 0x1A 0x45 0xDF 0xA3
        if bytes[0] == 0x1A && bytes[1] == 0x45 && bytes[2] == 0xDF && bytes[3] == 0xA3 {
            return true
        }
        return false
    }

    /// Waits for `generator` to decode the frame at `time`. Returns nil when it cannot.
    private static func decodedFrame(from generator: AVAssetImageGenerator, at time: CMTime) -> CGImage? {
        final class DecodedFrame: @unchecked Sendable {
            var image: CGImage?
        }
        let frame = DecodedFrame()
        let decoded = DispatchSemaphore(value: 0)
        generator.generateCGImageAsynchronously(for: time) { image, _, _ in
            frame.image = image
            decoded.signal()
        }
        decoded.wait()
        return frame.image
    }

    /// Extracts a thumbnail frame from a local video file URL using `AVAssetImageGenerator`,
    /// falling back to a synthesized 16:9 poster frame if the container has no decodable frame in the current environment.
    public static func extractVideoThumbnail(from fileURL: URL) -> NSImage? {
        let asset = AVURLAsset(url: fileURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 960, height: 540)
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity

        let candidateTimes = [
            CMTime(seconds: 0.1, preferredTimescale: 600),
            CMTime.zero
        ]
        for time in candidateTimes {
            if let cgImg = decodedFrame(from: generator, at: time) {
                return NSImage(cgImage: cgImg, size: NSSize(width: cgImg.width, height: cgImg.height))
            }
        }

        // Fallback poster frame so valid video URLs/containers still render a playable card
        let fallbackSize = NSSize(width: 480, height: 270)
        let poster = NSImage(size: fallbackSize)
        poster.lockFocus()
        let rect = NSRect(origin: .zero, size: fallbackSize)
        NSGradient(
            starting: NSColor(calibratedRed: 0.13, green: 0.16, blue: 0.24, alpha: 1.0),
            ending: NSColor(calibratedRed: 0.07, green: 0.09, blue: 0.14, alpha: 1.0)
        )?.draw(in: rect, angle: -35)
        poster.unlockFocus()
        return poster
    }

    func cacheAndDecodeRemoteVideo(_ data: Data, url: URL, cacheKey: String) -> NSImage? {
        let rawExt = url.pathExtension.lowercased()
        let ext = ["mp4", "mov", "m4v", "webm"].contains(rawExt) ? rawExt : "mp4"
        let digest = SHA256.hash(data: Data(cacheKey.utf8))
            .compactMap { String(format: "%02x", $0) }
            .joined()
            .prefix(24)
        let mediaDir = FolioAppIdentity.current.remoteMediaDirectory(in: FileManager.default.temporaryDirectory)
        try? FileManager.default.createDirectory(at: mediaDir, withIntermediateDirectories: true)
        let tempFileURL = mediaDir.appendingPathComponent("video-\(digest).\(ext)")
        do {
            try data.write(to: tempFileURL, options: .atomic)
        } catch {
            return nil
        }
        lock.lock()
        remoteVideoFileURLs[cacheKey] = tempFileURL
        lock.unlock()
        return Self.extractVideoThumbnail(from: tempFileURL)
    }

    /// Resolves a local or cached `URL` suitable for `AVPlayer` inline playback.
    public func playableVideoURL(for rawSource: String, baseDirectoryURL: URL? = nil) -> URL? {
        let trimmed = rawSource.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let remoteURL = Self.resolveRemoteURL(from: trimmed) {
            let key = Self.remoteCacheKey(for: remoteURL)
            lock.lock()
            let cachedFile = remoteVideoFileURLs[key]
            lock.unlock()
            if let cachedFile = cachedFile, FileManager.default.fileExists(atPath: cachedFile.path) {
                return cachedFile
            }
            triggerRemoteFetchIfNeeded(url: remoteURL, cacheKey: key)
            let scheme = remoteURL.scheme?.lowercased() ?? ""
            if scheme == "http" || scheme == "https" {
                return remoteURL
            }
            return nil
        }

        if let localURL = resolveLocalFileURL(from: trimmed, baseDirectoryURL: baseDirectoryURL),
            FileManager.default.fileExists(atPath: localURL.path)
        {
            return localURL
        }
        return nil
    }
}
