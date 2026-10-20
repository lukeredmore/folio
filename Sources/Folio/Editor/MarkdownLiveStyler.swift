import AppKit
import AVFoundation
import Foundation
import FolioEngineFFI

public struct CmarkAstBlock: Equatable {
    public let kind: UInt32
    public let startLine: Int
    public let startColumn: Int
    public let endLine: Int
    public let endColumn: Int
    public let level: Int
    public let flags: UInt32
    public let info: String
}

public struct CmarkAstInline: Equatable {
    public let kind: UInt32
    public let startLine: Int
    public let startColumn: Int
    public let endLine: Int
    public let endColumn: Int
    public let url: String
    public let literal: String
}

public enum TableColumnAlignment: Equatable {
    case left
    case center
    case right
}

public enum BlockDecorationKind: Equatable {
    case headingUnderline(level: Int)
    case blockquote(nestLevel: Int)
    case codeFenceStart(language: String)
    case codeFenceBody
    case codeFenceEnd
    case mathBlockStart(isActive: Bool)
    case mathBlockBody(isActive: Bool)
    case mathBlockEnd(isActive: Bool)
    case mathBlockRendered(latex: String, fullBlockRange: NSRange, dimFactor: CGFloat)
    case mermaidBlockRendered(mermaidSource: String, fullBlockRange: NSRange, dimFactor: CGFloat)
    case svgBlockRendered(svgSource: String, fullBlockRange: NSRange, dimFactor: CGFloat)
    case imageRendered(
        url: String,
        alt: String,
        fullRange: NSRange,
        explicitWidth: CGFloat?,
        explicitHeight: CGFloat?,
        baseDirectoryURL: URL?,
        dimFactor: CGFloat
    )
    case inlineMathRendered(latex: String, range: NSRange, fontSize: CGFloat, dimFactor: CGFloat)
    case inlineCode(range: NSRange, fontSize: CGFloat, dimFactor: CGFloat)
    case kbdPill(range: NSRange, fontSize: CGFloat, dimFactor: CGFloat)
    case listBullet(range: NSRange, dimFactor: CGFloat)
    case horizontalRule
    case tableRow(
        isHeader: Bool,
        isSeparator: Bool,
        isFirstRow: Bool,
        isLastRow: Bool,
        bodyRowIndex: Int,
        tableOffsetX: CGFloat,
        tableWidth: CGFloat,
        columnDividers: [CGFloat]
    )
}

public struct LineDecoration {
    public let lineRange: NSRange
    public let kind: BlockDecorationKind
}

public struct MarkdownDocumentAnalysis {
    public let headings: [OutlineHeading]
    public let decorations: [LineDecoration]
}

/// Shared cache and loader for local, data-URI, remote, SVG, and Mermaid-generated `NSImage` assets.
public final class FolioMediaImageCache: @unchecked Sendable {
    public static let shared = FolioMediaImageCache()
    public static let imageDidLoadNotification = Notification.Name("FolioMediaImageDidLoadNotification")

    private let lock = NSLock()
    private var imageCache: [String: NSImage] = [:]
    private var svgStringCache: [String: String] = [:]
    private var inFlightRemoteURLs: Set<String> = []

    public init() {}

    public func mermaidImage(for source: String, isDark: Bool) -> (image: NSImage?, svg: String) {
        let key = "mermaid:\(isDark ? "dark" : "light"):\(source)"
        lock.lock()
        let cachedImg = imageCache[key]
        let cachedSVG = svgStringCache[key]
        lock.unlock()

        if let svg = cachedSVG, let img = cachedImg {
            return (img, svg)
        }

        let svg = MarkdownLiveStyler.renderMermaidSVG(source, isDark: isDark)
        let img = svg.data(using: .utf8).flatMap { NSImage(data: $0) }
        lock.lock()
        svgStringCache[key] = svg
        if let img = img {
            imageCache[key] = img
        }
        lock.unlock()
        return (img, svg)
    }

    public func svgImage(for rawSVG: String) -> (image: NSImage?, svg: String) {
        let key = "svg:\(rawSVG)"
        lock.lock()
        let cachedImg = imageCache[key]
        let cachedSVG = svgStringCache[key]
        lock.unlock()

        if let svg = cachedSVG, let img = cachedImg {
            return (img, svg)
        }

        let normalized = MarkdownLiveStyler.normalizeSVG(rawSVG)
        let img = normalized.data(using: .utf8).flatMap { NSImage(data: $0) }
        lock.lock()
        svgStringCache[key] = normalized
        if let img = img {
            imageCache[key] = img
        }
        lock.unlock()
        return (img, normalized)
    }

    public func displaySize(
        for rawSource: String,
        explicitWidth: CGFloat? = nil,
        explicitHeight: CGFloat? = nil,
        maxColumnWidth: CGFloat = 680.0,
        baseDirectoryURL: URL? = nil,
        isDark: Bool = false
    ) -> (size: NSSize, isLoaded: Bool) {
        if let img = image(for: rawSource, baseDirectoryURL: baseDirectoryURL, isDark: isDark),
           img.size.width > 0,
           img.size.height > 0 {
            let natW = img.size.width
            let natH = img.size.height
            let aspect = natH / max(1.0, natW)
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
                targetW = natW
                targetH = natH
            }
            let maxW = max(120.0, maxColumnWidth)
            let maxH: CGFloat = 420.0
            let scale = min(1.0, min(maxW / max(1.0, targetW), maxH / max(1.0, targetH)))
            return (NSSize(width: ceil(targetW * scale), height: ceil(targetH * scale)), true)
        }
        let fallbackW = min(max(120.0, maxColumnWidth), explicitWidth ?? 360.0)
        return (NSSize(width: fallbackW, height: 48.0), false)
    }

    public func image(for rawSource: String, baseDirectoryURL: URL? = nil, isDark: Bool = false) -> NSImage? {
        let trimmed = rawSource.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let cacheKey = "\(baseDirectoryURL?.path ?? "")|\(isDark ? "1" : "0")|\(trimmed)"
        lock.lock()
        if let cached = imageCache[cacheKey] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        // 1. Inline <svg ...> string
        if trimmed.lowercased().hasPrefix("<svg") {
            let (img, _) = svgImage(for: trimmed)
            if let img = img {
                storeImage(img, forKey: cacheKey)
            }
            return img
        }

        // 2. data: URI (e.g. data:image/svg+xml;utf8,<svg...> or data:image/png;base64,...)
        if trimmed.lowercased().hasPrefix("data:") {
            if let commaIdx = trimmed.firstIndex(of: ",") {
                let header = String(trimmed[..<commaIdx]).lowercased()
                let payload = String(trimmed[trimmed.index(after: commaIdx)...])
                if header.contains(";base64") {
                    if let data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters) {
                        if header.contains("image/svg"), let svgStr = String(data: data, encoding: .utf8) {
                            let (img, _) = svgImage(for: svgStr)
                            if let img = img { storeImage(img, forKey: cacheKey) }
                            return img
                        } else if let img = NSImage(data: data) {
                            storeImage(img, forKey: cacheKey)
                            return img
                        }
                    }
                } else {
                    let decoded = payload.removingPercentEncoding ?? payload
                    if header.contains("image/svg") || decoded.lowercased().contains("<svg") {
                        let (img, _) = svgImage(for: decoded)
                        if let img = img { storeImage(img, forKey: cacheKey) }
                        return img
                    } else if let data = decoded.data(using: .utf8), let img = NSImage(data: data) {
                        storeImage(img, forKey: cacheKey)
                        return img
                    }
                }
            }
            return nil
        }

        // 3. Remote HTTP/HTTPS URL (check cache or fetch asynchronously)
        if trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://") {
            if let url = URL(string: trimmed) {
                triggerRemoteFetchIfNeeded(url: url, cacheKey: cacheKey)
            }
            return nil
        }

        // 4. Local file:// URL, ~/path, /absolute/path, or relative path
        let resolvedFileURL: URL?
        if trimmed.lowercased().hasPrefix("file://"), let url = URL(string: trimmed) {
            resolvedFileURL = url
        } else {
            let unescaped = trimmed.removingPercentEncoding ?? trimmed
            if unescaped.hasPrefix("~/") {
                let expanded = (unescaped as NSString).expandingTildeInPath
                resolvedFileURL = URL(fileURLWithPath: expanded)
            } else if unescaped.hasPrefix("/") {
                resolvedFileURL = URL(fileURLWithPath: unescaped)
            } else {
                let baseDir = baseDirectoryURL ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
                resolvedFileURL = baseDir.appendingPathComponent(unescaped).standardizedFileURL
            }
        }

        if let fileURL = resolvedFileURL, FileManager.default.fileExists(atPath: fileURL.path) {
            let ext = fileURL.pathExtension.lowercased()
            if ext == "svg",
               let rawSVG = try? String(contentsOf: fileURL, encoding: .utf8) {
                let (img, _) = svgImage(for: rawSVG)
                if let img = img {
                    storeImage(img, forKey: cacheKey)
                    return img
                }
            }
            if ["mp4", "mov", "m4v", "webm"].contains(ext) {
                let asset = AVAsset(url: fileURL)
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 960, height: 540)
                if let cgImg = try? generator.copyCGImage(at: CMTime(seconds: 0.1, preferredTimescale: 600), actualTime: nil) {
                    let img = NSImage(cgImage: cgImg, size: NSSize(width: cgImg.width, height: cgImg.height))
                    storeImage(img, forKey: cacheKey)
                    return img
                }
            }
            if let data = try? Data(contentsOf: fileURL), let img = NSImage(data: data) {
                storeImage(img, forKey: cacheKey)
                return img
            }
            if let img = NSImage(contentsOf: fileURL) {
                storeImage(img, forKey: cacheKey)
                return img
            }
        }

        return nil
    }

    public static func isVideoURL(_ rawURL: String) -> Bool {
        let lower = rawURL.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let pathPart = lower.split(separator: "?").first.map(String.init) ?? lower
        return pathPart.hasSuffix(".mp4")
            || pathPart.hasSuffix(".mov")
            || pathPart.hasSuffix(".m4v")
            || pathPart.hasSuffix(".webm")
            || lower.hasPrefix("data:video/")
    }

    private func storeImage(_ image: NSImage, forKey key: String) {
        lock.lock()
        imageCache[key] = image
        lock.unlock()
    }

    private func triggerRemoteFetchIfNeeded(url: URL, cacheKey: String) {
        lock.lock()
        if inFlightRemoteURLs.contains(cacheKey) || imageCache[cacheKey] != nil {
            lock.unlock()
            return
        }
        inFlightRemoteURLs.insert(cacheKey)
        lock.unlock()

        let task = URLSession.shared.dataTask(with: url) { [weak self] data, response, _ in
            guard let self = self else { return }
            defer {
                self.lock.lock()
                self.inFlightRemoteURLs.remove(cacheKey)
                self.lock.unlock()
            }
            guard let data = data, !data.isEmpty else { return }
            let mime = (response as? HTTPURLResponse)?.mimeType?.lowercased() ?? ""
            var loadedImage: NSImage?
            if mime.contains("svg") || url.pathExtension.lowercased() == "svg",
               let svgStr = String(data: data, encoding: .utf8) {
                loadedImage = self.svgImage(for: svgStr).image
            } else {
                loadedImage = NSImage(data: data)
            }
            if let img = loadedImage {
                self.storeImage(img, forKey: cacheKey)
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: Self.imageDidLoadNotification, object: url)
                }
            }
        }
        task.resume()
    }
}

public final class MarkdownLiveStyler {

    public static let collapsedTokenAttributeKey = NSAttributedString.Key("FolioCollapsedSyntaxToken")
    public static let inlineCodeFontAttributeKey = NSAttributedString.Key("FolioInlineCodeFont")
    /// Marks a source newline inside an inactive paragraph that renders as a space (CommonMark soft line break).
    public static let softLineBreakAttributeKey = NSAttributedString.Key("FolioSoftLineBreak")

    private struct DeferredInlineStyle {
        let line: Int
        let range: NSRange
        let baseFont: NSFont
        let isActive: Bool
        let dimFactor: CGFloat
    }

    private enum ProseLineKind: Equatable {
        case paragraph
        case listItem
        case blockquote(nestLevel: Int)
    }

    /// Renders a Mermaid diagram source block (`flowchart`/`graph`, `sequenceDiagram`, `classDiagram`, `stateDiagram`, `pie`)
    /// into a self-contained SVG string via `folio_engine`.
    public static func renderMermaidSVG(_ source: String, isDark: Bool = false) -> String {
        return source.withCString { srcPtr in
            guard let resPtr = ot_engine_render_mermaid_svg(srcPtr, isDark) else { return "" }
            defer { ot_engine_free_mermaid_result(resPtr) }
            guard let svgPtr = resPtr.pointee.svg else { return "" }
            return String(cString: svgPtr)
        }
    }

    /// Sanitizes and normalizes an SVG markup snippet (adding `xmlns` and `viewBox` if missing) via `folio_engine`.
    public static func normalizeSVG(_ rawSVG: String) -> String {
        return rawSVG.withCString { svgPtr in
            guard let resPtr = ot_engine_normalize_svg(svgPtr) else { return "" }
            defer { ot_engine_free_mermaid_result(resPtr) }
            guard let outPtr = resPtr.pointee.svg else { return "" }
            return String(cString: outPtr)
        }
    }

    /// Renders Markdown to specification-compliant HTML using the upstream `cmark-gfm` parser in `folio_engine`.
    /// Pass `nil` for `extensions` to enable the default GitHub Flavored Markdown extensions
    /// (`table`, `strikethrough`, `autolink`, `tagfilter`, `tasklist`), or pass a custom list (e.g. `[]` for pure CommonMark).
    public static func renderHTML(_ markdown: String, extensions: [String]? = nil) -> String {
        return markdown.withCString { mdPtr in
            let htmlPtr: UnsafeMutablePointer<CChar>?
            if let extensions = extensions {
                let joined = extensions.joined(separator: " ")
                htmlPtr = joined.withCString { extPtr in
                    ot_engine_render_markdown_html(mdPtr, extPtr)
                }
            } else {
                htmlPtr = ot_engine_render_markdown_html(mdPtr, nil)
            }
            guard let validPtr = htmlPtr else { return "" }
            defer { ot_engine_free_string(validPtr) }
            return String(cString: validPtr)
        }
    }

    /// Parses Markdown into a CommonMark 0.31.2 + GFM 0.29.0 AST via `cmark-gfm` in `folio_engine`.
    public static func parseSpecAST(_ markdown: String) -> (blocks: [CmarkAstBlock], inlines: [CmarkAstInline]) {
        return markdown.withCString { mdPtr in
            guard let resPtr = ot_engine_parse_markdown_ast(mdPtr) else {
                return ([], [])
            }
            defer { ot_engine_free_markdown_ast(resPtr) }
            let res = resPtr.pointee

            var blocks: [CmarkAstBlock] = []
            if res.block_count > 0, let blocksBase = res.blocks {
                blocks.reserveCapacity(res.block_count)
                for i in 0..<res.block_count {
                    let b = blocksBase[i]
                    let info = b.info != nil ? String(cString: b.info) : ""
                    blocks.append(CmarkAstBlock(
                        kind: b.kind,
                        startLine: Int(b.start_line),
                        startColumn: Int(b.start_column),
                        endLine: Int(b.end_line),
                        endColumn: Int(b.end_column),
                        level: Int(b.level),
                        flags: b.flags,
                        info: info
                    ))
                }
            }

            var inlines: [CmarkAstInline] = []
            if res.inline_count > 0, let inlinesBase = res.inlines {
                inlines.reserveCapacity(res.inline_count)
                for i in 0..<res.inline_count {
                    let inl = inlinesBase[i]
                    let url = inl.url != nil ? String(cString: inl.url) : ""
                    let literal = inl.literal != nil ? String(cString: inl.literal) : ""
                    inlines.append(CmarkAstInline(
                        kind: inl.kind,
                        startLine: Int(inl.start_line),
                        startColumn: Int(inl.start_column),
                        endLine: Int(inl.end_line),
                        endColumn: Int(inl.end_column),
                        url: url,
                        literal: literal
                    ))
                }
            }

            return (blocks, inlines)
        }
    }

    private static let headingRegex = try! NSRegularExpression(pattern: #"^( {0,3})(#{1,6})(?:([ \t]+)(.*?))?(?:(?<![ \t])[ \t]+#+[ \t]*)?$"#)
    private static let setextH1Regex = try! NSRegularExpression(pattern: #"^ {0,3}=+[ \t]*$"#)
    private static let setextH2Regex = try! NSRegularExpression(pattern: #"^ {0,3}-{2,}[ \t]*$"#)
    private static let blockquoteRegex = try! NSRegularExpression(pattern: #"^(\s*>+[ \t]*)(.*)$"#)
    private static let taskListRegex = try! NSRegularExpression(pattern: #"^([ \t]*)([-*+]|\d+[.)])([ \t]+)(\[[ xX]\])([ \t]+)(.*)$"#)
    private static let unorderedListRegex = try! NSRegularExpression(pattern: #"^([ \t]*)([-*+])([ \t]+)(.+)$"#)
    private static let orderedListRegex = try! NSRegularExpression(pattern: #"^([ \t]*)(\d+[.)])([ \t]+)(.+)$"#)
    private static let hrRegex = try! NSRegularExpression(pattern: #"^ {0,3}(?:(?:-[ \t]*){3,}|(?:\*[ \t]*){3,}|(?:_[ \t]*){3,})$"#)
    private static let codeFenceOpenRegex = try! NSRegularExpression(pattern: #"^ {0,3}(`{3,}|~{3,})([ \t]*[^`~\n]*)$"#)
    private static let linkRefDefRegex = try! NSRegularExpression(pattern: #"^( {0,3}\[[^\]]+\]:)([ \t]*)(<?[^\s>]+>?)(?:([ \t]+)(["'(].*["')]))?[ \t]*$"#)

    // Inline regexes
    private static let escapeRegex = try! NSRegularExpression(pattern: ##"\\([!\"#$%&'()*+,\-./:;<=>?@\[\\\]^_`{|}~])"##)
    private static let htmlBrRegex = try! NSRegularExpression(pattern: #"<br\s*/?>"#, options: [.caseInsensitive])
    private static let htmlImgTagRegex = try! NSRegularExpression(pattern: #"<img\b([^>]*?)/?>"#, options: [.caseInsensitive])
    private static let htmlVideoTagRegex = try! NSRegularExpression(pattern: #"<video\b([^>]*?)(?:/>|>(.*?)</video\s*>)"#, options: [.caseInsensitive])
    private static let htmlPairedTagRegex = try! NSRegularExpression(
        pattern: #"(<(kbd|u|ins|mark|sup|sub|b|strong|i|em|s|del|strike|code|summary)\b[^>]*>)(.*?)(</\2\s*>)"#,
        options: [.caseInsensitive]
    )
    private static let htmlDetailsTagRegex = try! NSRegularExpression(pattern: #"</?details\b[^>]*>"#, options: [.caseInsensitive])
    private static let htmlAttrRegex = try! NSRegularExpression(pattern: #"\b([a-zA-Z_-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+))"#)
    private static let boldItalicRegex = try! NSRegularExpression(pattern: #"(?<!\*)\*\*\*(?!\*)(?=\S)((?:(?!\*\*\*)[\s\S])+?)(?<=\S)\*\*\*(?!\*)|(?<![\p{L}\p{N}_])___(?!_)(?=\S)((?:(?!___)[\s\S])+?)(?<=\S)___(?![\p{L}\p{N}_])"#)
    private static let boldAsteriskRegex = try! NSRegularExpression(pattern: #"(?<!\*)\*\*(?!\*)(?=\S)((?:(?!\*\*)[\s\S])+?)(?<=\S)\*\*(?!\*)"#)
    private static let boldUnderscoreRegex = try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}_])__(?!_)(?=\S)((?:(?!__)[\s\S])+?)(?<=\S)__(?![\p{L}\p{N}_])"#)
    private static let italicAsteriskRegex = try! NSRegularExpression(pattern: #"(?<!\*)\*(?!\*)(?=\S)((?:[^\*]|\*\*(?=\S)[^\*]+?(?<=\S)\*\*)+?)(?<=\S)\*(?!\*)"#)
    private static let italicUnderscoreRegex = try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}_])_(?!_)(?=\S)((?:[^_]|__(?=\S)[^_]+?(?<=\S)__|(?<=[\p{L}\p{N}])_(?=[\p{L}\p{N}]))+?)(?<=\S)_(?![\p{L}\p{N}_])"#)
    private static let strikeRegex = try! NSRegularExpression(pattern: #"(?<!~)(~~)(?!~)(?=\S)((?:(?!~~)[\s\S])+?)(?<=\S)(~~)(?!~)"#)
    private static let highlightRegex = try! NSRegularExpression(pattern: #"(?<!=)(==)(?!=)(?=\S)((?:(?!==)[\s\S])+?)(?<=\S)(==)(?!=)"#)
    private static let inlineMathRegex = try! NSRegularExpression(pattern: #"(?<!\$)(\$)(?!\$)(?=\S)([^\$\n]+?)(?<=\S)(?<!\$)(\$)(?!\$)"#)
    private static let autolinkRegex = try! NSRegularExpression(pattern: #"(<)((?:https?://|mailto:)[^>\s]+|[a-zA-Z0-9._%+\-]+@(?:[a-zA-Z0-9\-]+\.)+[a-zA-Z]{2,})(>)"#)
    private static let multiSpaceRegex = try! NSRegularExpression(pattern: #"[ \t]{2,}"#)
    private static let leadingSpaceRegex = try! NSRegularExpression(pattern: #"^[ \t]+"#, options: [.anchorsMatchLines])
    private static let trailingSpaceRegex = try! NSRegularExpression(pattern: #"[ \t]+$"#, options: [.anchorsMatchLines])

    private static let latexCommandRegex = try! NSRegularExpression(pattern: #"\\[a-zA-Z]+|\\[^a-zA-Z\s]"#)
    private static let latexBracesRegex = try! NSRegularExpression(pattern: #"[\{\}\^_]"#)

    @discardableResult
    public static func applyStyles(
        to storage: NSTextStorage,
        theme: EditorTheme,
        typography: EditorTypographySettings? = nil,
        sourceCodeMode: Bool,
        focusMode: Bool,
        selectedRange: NSRange,
        containerWidth: CGFloat = 0,
        prettyMode: Bool = true,
        baseDirectoryURL: URL? = nil
    ) -> MarkdownDocumentAnalysis {
        let typography = typography ?? theme.typography
        let string = storage.string
        let nsString = string as NSString
        let fullLength = nsString.length
        guard fullLength > 0 else {
            return MarkdownDocumentAnalysis(headings: [], decorations: [])
        }

        let fullRange = NSRange(location: 0, length: fullLength)
        let activeLineRange = nsString.lineRange(for: NSRange(location: min(selectedRange.location, fullLength), length: 0))

        storage.beginEditing()

        let effectiveBaseSize = theme.baseFontSize * typography.fontSizeScale
        let effectiveContainerWidth = containerWidth > 200 ? containerWidth : typography.maxColumnWidth

        // Base paragraph style
        let baseParagraph = NSMutableParagraphStyle()
        baseParagraph.lineHeightMultiple = typography.lineHeightMultiple
        baseParagraph.lineSpacing = typography.lineSpacing
        baseParagraph.paragraphSpacing = max(4.0, typography.paragraphSpacing * 0.65)
        if !sourceCodeMode {
            baseParagraph.tailIndent = effectiveContainerWidth
        }

        let baseFont = sourceCodeMode ? theme.codeFont(size: effectiveBaseSize) : theme.bodyFont(size: effectiveBaseSize)
        let baseColor = theme.textNSColor

        storage.setAttributes([
            .font: baseFont,
            .foregroundColor: baseColor,
            .paragraphStyle: baseParagraph,
            .kern: sourceCodeMode ? 0.0 : typography.characterSpacing
        ], range: fullRange)

        var headings: [OutlineHeading] = []
        var decorations: [LineDecoration] = []

        // Parse CommonMark 0.31.2 + GFM 0.29.0 AST via cmark-gfm for indented code blocks,
        // resolved reference links ([text][ref], [text][], [text]), and GFM extended autolinks.
        let specAST = sourceCodeMode ? (blocks: [CmarkAstBlock](), inlines: [CmarkAstInline]()) : parseSpecAST(string)
        var indentedCodeBlockLines = Set<Int>()
        for block in specAST.blocks where block.kind == 2 && (block.flags & 1) == 0 {
            if block.startLine > 0 && block.endLine >= block.startLine {
                for ln in block.startLine...block.endLine {
                    indentedCodeBlockLines.insert(ln)
                }
            }
        }
        var astLinksByLine: [Int: [CmarkAstInline]] = [:]
        for inl in specAST.inlines where (inl.kind == 5 || inl.kind == 6) && inl.endLine >= inl.startLine && inl.startLine > 0 {
            astLinksByLine[inl.startLine, default: []].append(inl)
        }
        var lineRecords: [Int: (lineRange: NSRange, contentRange: NSRange, lineText: String, isActive: Bool, dimFactor: CGFloat)] = [:]
        var proseLineKinds: [Int: ProseLineKind] = [:]
        // Inline styling of multi-line paragraph lines runs after soft breaks are known, so a
        // span that crosses a soft line break (e.g. `[a\nb](url)`) is styled as one span.
        var multiLineParagraphLines = Set<Int>()
        for block in specAST.blocks where block.kind == 8 && block.startLine > 0 && block.endLine > block.startLine {
            multiLineParagraphLines.formUnion(block.startLine...block.endLine)
        }
        var deferredProseInline: [DeferredInlineStyle] = []

        var inCodeFence = false
        var currentFenceChar: Character = "`"
        var currentFenceLength: Int = 3
        var currentFenceLanguage = ""
        var previousListTextIndent: CGFloat? = nil
        var lineNumber = 1
        var index = 0

        while index < fullLength {
            let lineRange = nsString.lineRange(for: NSRange(location: index, length: 0))
            let contentRange = strippedLineContentRange(nsString: nsString, lineRange: lineRange)
            let lineText = nsString.substring(with: contentRange)
            let isActiveLine = isLineActive(lineRange: lineRange, activeLineRange: activeLineRange, selectedRange: selectedRange)
            let dimFactor: CGFloat = (focusMode && !isActiveLine) ? 0.30 : 1.0
            lineRecords[lineNumber] = (lineRange, contentRange, lineText, isActiveLine, dimFactor)

            if sourceCodeMode {
                if lineText.hasPrefix("#") {
                    let trimmed = lineText.prefix(while: { $0 == "#" })
                    let level = min(6, max(1, trimmed.count))
                    let title = String(lineText.dropFirst(level)).trimmingCharacters(in: .whitespaces)
                    if !title.isEmpty {
                        headings.append(OutlineHeading(
                            level: level,
                            title: title,
                            characterLocation: contentRange.location,
                            lineNumber: lineNumber
                        ))
                    }
                    storage.addAttribute(
                        .foregroundColor,
                        value: theme.headingNSColor.withAlphaComponent(dimFactor),
                        range: contentRange
                    )
                    storage.addAttribute(
                        .font,
                        value: NSFont.monospacedSystemFont(ofSize: effectiveBaseSize, weight: .bold),
                        range: contentRange
                    )
                } else if dimFactor < 1.0 {
                    storage.addAttribute(
                        .foregroundColor,
                        value: baseColor.withAlphaComponent(dimFactor),
                        range: contentRange
                    )
                }
                index = NSMaxRange(lineRange)
                lineNumber += 1
                continue
            }

            let trimmedLine = lineText.trimmingCharacters(in: .whitespaces)

            // 1. Check Code Fence (``` or ~~~ with up to 3 leading spaces)
            if !inCodeFence, let fenceMatch = codeFenceOpenRegex.firstMatch(in: string, options: [], range: contentRange) {
                let markerStr = nsString.substring(with: fenceMatch.range(at: 1))
                let infoStr = nsString.substring(with: fenceMatch.range(at: 2)).trimmingCharacters(in: .whitespaces)
                let fenceChar = markerStr.first ?? "`"
                if !(fenceChar == "`" && infoStr.contains("`")) {
                    let lang = infoStr.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
                    let lowerLang = lang.lowercased()

                    // When Pretty Mode is active, scan ahead for ```mermaid or ```svg blocks and render them as visual cards if inactive
                    if prettyMode && (lowerLang == "mermaid" || lowerLang == "svg") {
                        var blockLines: [(lineRange: NSRange, contentRange: NSRange, text: String, isActive: Bool)] = [
                            (lineRange, contentRange, lineText, isActiveLine)
                        ]
                        var scanIndex = NSMaxRange(lineRange)
                        var scanLineCount = 1
                        var foundClosingFence = false
                        let openFenceLen = markerStr.count

                        while scanIndex < fullLength {
                            let nextLR = nsString.lineRange(for: NSRange(location: scanIndex, length: 0))
                            let nextCR = strippedLineContentRange(nsString: nsString, lineRange: nextLR)
                            let nextText = nsString.substring(with: nextCR)
                            let nextActive = isLineActive(lineRange: nextLR, activeLineRange: activeLineRange, selectedRange: selectedRange)
                            blockLines.append((nextLR, nextCR, nextText, nextActive))
                            scanIndex = NSMaxRange(nextLR)
                            scanLineCount += 1

                            let leadingSpaces = nextText.prefix(while: { $0 == " " }).count
                            let afterLeading = String(nextText.dropFirst(leadingSpaces))
                            let fenceRun = afterLeading.prefix(while: { $0 == fenceChar })
                            let restAfterFence = afterLeading.dropFirst(fenceRun.count).trimmingCharacters(in: .whitespaces)
                            if leadingSpaces <= 3 && fenceRun.count >= openFenceLen && restAfterFence.isEmpty {
                                foundClosingFence = true
                                break
                            }
                        }

                        let fullBlockRange = NSRange(location: lineRange.location, length: scanIndex - lineRange.location)
                        let isDiagramBlockActive = blockLines.contains(where: { $0.isActive }) ||
                            NSIntersectionRange(fullBlockRange, selectedRange).length > 0

                        if foundClosingFence && !isDiagramBlockActive && blockLines.count >= 3 {
                            let bodySource = blockLines
                                .dropFirst()
                                .dropLast()
                                .map(\.text)
                                .joined(separator: "\n")
                                .trimmingCharacters(in: .whitespacesAndNewlines)

                            if !bodySource.isEmpty {
                                previousListTextIndent = nil
                                let blockDim: CGFloat = (focusMode && !isDiagramBlockActive) ? 0.30 : 1.0
                                let diagramImg: NSImage? = (lowerLang == "mermaid")
                                    ? FolioMediaImageCache.shared.mermaidImage(for: bodySource, isDark: theme.isDark).image
                                    : FolioMediaImageCache.shared.svgImage(for: bodySource).image
                                let availW = max(200.0, effectiveContainerWidth - 32.0)
                                let totalCardHeight: CGFloat
                                if let img = diagramImg, img.size.width > 0, img.size.height > 0 {
                                    let scale = min(1.0, availW / img.size.width)
                                    let naturalH = round(img.size.height * scale) + 28.0
                                    totalCardHeight = min(640.0, max(96.0, naturalH))
                                } else {
                                    totalCardHeight = lowerLang == "mermaid" ? 220.0 : 190.0
                                }
                                let perLineHeight = max(6.0, round(totalCardHeight / CGFloat(blockLines.count)))
                                let hiddenLineFont = theme.bodyFont(size: min(effectiveBaseSize, max(4.0, perLineHeight * 0.6)))

                                for (bIdx, bLine) in blockLines.enumerated() {
                                    let cardPara = NSMutableParagraphStyle()
                                    cardPara.alignment = .center
                                    cardPara.lineSpacing = 0.0
                                    cardPara.paragraphSpacingBefore = 0.0
                                    cardPara.paragraphSpacing = (bIdx == blockLines.count - 1) ? max(6.0, typography.paragraphSpacing * 0.55) : 0.0
                                    cardPara.minimumLineHeight = perLineHeight
                                    cardPara.maximumLineHeight = perLineHeight
                                    cardPara.tailIndent = effectiveContainerWidth
                                    storage.addAttributes([
                                        .font: hiddenLineFont,
                                        .foregroundColor: NSColor.clear,
                                        .paragraphStyle: cardPara,
                                        .kern: 0.0
                                    ], range: bLine.lineRange)
                                }

                                if lowerLang == "mermaid" {
                                    decorations.append(LineDecoration(
                                        lineRange: fullBlockRange,
                                        kind: .mermaidBlockRendered(mermaidSource: bodySource, fullBlockRange: fullBlockRange, dimFactor: blockDim)
                                    ))
                                } else {
                                    decorations.append(LineDecoration(
                                        lineRange: fullBlockRange,
                                        kind: .svgBlockRendered(svgSource: bodySource, fullBlockRange: fullBlockRange, dimFactor: blockDim)
                                    ))
                                }

                                index = scanIndex
                                lineNumber += scanLineCount
                                continue
                            }
                        }
                    }

                    inCodeFence = true
                    currentFenceChar = fenceChar
                    currentFenceLength = markerStr.count
                    currentFenceLanguage = lowerLang
                    previousListTextIndent = nil

                    let codeMono = theme.codeFont(size: effectiveBaseSize * 0.88)
                    let fenceRowHeight: CGFloat = 23.0
                    let fencePara = NSMutableParagraphStyle()
                    fencePara.lineSpacing = 0.0
                    fencePara.paragraphSpacingBefore = 0.0
                    fencePara.paragraphSpacing = 0.0
                    fencePara.firstLineHeadIndent = 14.0
                    fencePara.headIndent = 14.0
                    fencePara.minimumLineHeight = fenceRowHeight
                    fencePara.maximumLineHeight = fenceRowHeight
                    fencePara.tailIndent = effectiveContainerWidth

                    storage.addAttributes([
                        .font: codeMono,
                        .foregroundColor: theme.markdownTokenNSColor.withAlphaComponent(isActiveLine ? 0.9 : 0.45 * dimFactor),
                        .paragraphStyle: fencePara,
                        .baselineOffset: 0.0,
                        .kern: 0.0
                    ], range: lineRange)

                    decorations.append(LineDecoration(lineRange: lineRange, kind: .codeFenceStart(language: lang)))
                    index = NSMaxRange(lineRange)
                    lineNumber += 1
                    continue
                }
            } else if inCodeFence {
                let leadingSpaces = lineText.prefix(while: { $0 == " " }).count
                let afterLeading = String(lineText.dropFirst(leadingSpaces))
                let fenceRun = afterLeading.prefix(while: { $0 == currentFenceChar })
                let restAfterFence = afterLeading.dropFirst(fenceRun.count).trimmingCharacters(in: .whitespaces)
                if leadingSpaces <= 3 && fenceRun.count >= currentFenceLength && restAfterFence.isEmpty {
                    inCodeFence = false
                    currentFenceLanguage = ""
                    let codeMono = theme.codeFont(size: effectiveBaseSize * 0.88)
                    let fenceRowHeight: CGFloat = 23.0
                    let fencePara = NSMutableParagraphStyle()
                    fencePara.lineSpacing = 0.0
                    fencePara.paragraphSpacingBefore = 0.0
                    fencePara.paragraphSpacing = max(4.0, typography.paragraphSpacing * 0.55)
                    fencePara.firstLineHeadIndent = 14.0
                    fencePara.headIndent = 14.0
                    fencePara.minimumLineHeight = fenceRowHeight
                    fencePara.maximumLineHeight = fenceRowHeight
                    fencePara.tailIndent = effectiveContainerWidth

                    storage.addAttributes([
                        .font: codeMono,
                        .foregroundColor: theme.markdownTokenNSColor.withAlphaComponent(isActiveLine ? 0.9 : 0.45 * dimFactor),
                        .paragraphStyle: fencePara,
                        .baselineOffset: 0.0,
                        .kern: 0.0
                    ], range: lineRange)

                    decorations.append(LineDecoration(lineRange: lineRange, kind: .codeFenceEnd))
                    index = NSMaxRange(lineRange)
                    lineNumber += 1
                    continue
                }

                decorations.append(LineDecoration(lineRange: lineRange, kind: .codeFenceBody))
                let codeMono = theme.codeFont(size: effectiveBaseSize * 0.90)
                let bodyRowHeight: CGFloat = 22.0
                let codePara = NSMutableParagraphStyle()
                codePara.lineSpacing = 0.0
                codePara.paragraphSpacingBefore = 0.0
                codePara.paragraphSpacing = 0.0
                codePara.firstLineHeadIndent = 14.0
                codePara.headIndent = 14.0
                codePara.minimumLineHeight = bodyRowHeight
                codePara.maximumLineHeight = bodyRowHeight
                codePara.tailIndent = effectiveContainerWidth

                storage.addAttributes([
                    .font: codeMono,
                    .foregroundColor: theme.textNSColor.withAlphaComponent(dimFactor),
                    .paragraphStyle: codePara,
                    .baselineOffset: 0.0,
                    .kern: 0.0
                ], range: lineRange)

                highlightCodeLine(
                    in: storage,
                    range: contentRange,
                    language: currentFenceLanguage,
                    theme: theme,
                    dimFactor: dimFactor
                )
                index = NSMaxRange(lineRange)
                lineNumber += 1
                continue
            }

            // 1a. CommonMark Indented Code Block (4+ leading spaces / tab outside lists/paragraphs as determined by cmark-gfm AST)
            if indentedCodeBlockLines.contains(lineNumber) && (!trimmedLine.isEmpty || lineText.hasPrefix("    ") || lineText.hasPrefix("\t")) {
                previousListTextIndent = nil
                decorations.append(LineDecoration(lineRange: lineRange, kind: .codeFenceBody))
                let codeMono = theme.codeFont(size: effectiveBaseSize * 0.90)
                let bodyRowHeight: CGFloat = 22.0
                let codePara = NSMutableParagraphStyle()
                codePara.lineSpacing = 0.0
                codePara.paragraphSpacingBefore = 0.0
                codePara.paragraphSpacing = 0.0
                codePara.firstLineHeadIndent = 14.0
                codePara.headIndent = 14.0
                codePara.minimumLineHeight = bodyRowHeight
                codePara.maximumLineHeight = bodyRowHeight
                codePara.tailIndent = effectiveContainerWidth

                storage.addAttributes([
                    .font: codeMono,
                    .foregroundColor: theme.textNSColor.withAlphaComponent(dimFactor),
                    .paragraphStyle: codePara,
                    .baselineOffset: 0.0,
                    .kern: 0.0
                ], range: lineRange)

                index = NSMaxRange(lineRange)
                lineNumber += 1
                continue
            }

            // 1b. Blank line outside code fence: use compact height so paragraph breaks don't double-space
            if trimmedLine.isEmpty {
                previousListTextIndent = nil
                let blankPara = NSMutableParagraphStyle()
                let blankH = round(effectiveBaseSize * (isActiveLine ? 1.15 : 0.55))
                blankPara.minimumLineHeight = blankH
                blankPara.maximumLineHeight = blankH
                blankPara.lineSpacing = 0.0
                blankPara.paragraphSpacing = 0.0
                blankPara.paragraphSpacingBefore = 0.0
                blankPara.tailIndent = effectiveContainerWidth
                storage.addAttributes([
                    .paragraphStyle: blankPara,
                    .kern: 0.0
                ], range: lineRange)
                if !isActiveLine && contentRange.length > 0 {
                    collapseWhitespaceRange(in: storage, range: contentRange)
                }
                index = NSMaxRange(lineRange)
                lineNumber += 1
                continue
            }

            // 2. Check Display Math Block ($$ ... $$) as a cohesive unit
            if trimmedLine.hasPrefix("$$") {
                previousListTextIndent = nil
                var mathLines: [(lineRange: NSRange, contentRange: NSRange, text: String, isActive: Bool)] = []
                mathLines.append((lineRange, contentRange, lineText, isActiveLine))

                var scanIndex = NSMaxRange(lineRange)
                var scanLineCount = 1
                let isSingleLineMath = trimmedLine.count > 4 && trimmedLine.hasSuffix("$$")

                if !isSingleLineMath {
                    while scanIndex < fullLength {
                        let nextLR = nsString.lineRange(for: NSRange(location: scanIndex, length: 0))
                        let nextCR = strippedLineContentRange(nsString: nsString, lineRange: nextLR)
                        let nextText = nsString.substring(with: nextCR)
                        let nextActive = isLineActive(lineRange: nextLR, activeLineRange: activeLineRange, selectedRange: selectedRange)
                        mathLines.append((nextLR, nextCR, nextText, nextActive))
                        scanIndex = NSMaxRange(nextLR)
                        scanLineCount += 1
                        if nextText.trimmingCharacters(in: .whitespaces).hasPrefix("$$") {
                            break
                        }
                    }
                }

                let isMathBlockActive = mathLines.contains(where: { $0.isActive }) ||
                    NSIntersectionRange(
                        NSRange(location: lineRange.location, length: scanIndex - lineRange.location),
                        selectedRange
                    ).length > 0
                let blockDim: CGFloat = (focusMode && !isMathBlockActive) ? 0.30 : 1.0
                let fullBlockRange = NSRange(location: lineRange.location, length: scanIndex - lineRange.location)

                var latexParts: [String] = []
                for (idx, mLine) in mathLines.enumerated() {
                    let t = mLine.text.trimmingCharacters(in: .whitespaces)
                    if isSingleLineMath {
                        let inner = String(t.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces)
                        latexParts.append(inner)
                        decorations.append(LineDecoration(lineRange: mLine.lineRange, kind: .mathBlockBody(isActive: isMathBlockActive)))
                    } else if idx == 0 {
                        let afterFence = String(t.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                        if !afterFence.isEmpty { latexParts.append(afterFence) }
                        decorations.append(LineDecoration(lineRange: mLine.lineRange, kind: .mathBlockStart(isActive: isMathBlockActive)))
                    } else if idx == mathLines.count - 1 && t.hasPrefix("$$") {
                        decorations.append(LineDecoration(lineRange: mLine.lineRange, kind: .mathBlockEnd(isActive: isMathBlockActive)))
                    } else {
                        latexParts.append(mLine.text)
                        decorations.append(LineDecoration(lineRange: mLine.lineRange, kind: .mathBlockBody(isActive: isMathBlockActive)))
                    }

                    if isMathBlockActive {
                        let mathMono = theme.codeFont(size: effectiveBaseSize * 0.92)
                        let mathPara = NSMutableParagraphStyle()
                        mathPara.lineSpacing = 3.5
                        mathPara.paragraphSpacing = 2.0
                        mathPara.firstLineHeadIndent = 14.0
                        mathPara.headIndent = 14.0
                        mathPara.tailIndent = effectiveContainerWidth
                        storage.addAttributes([
                            .font: mathMono,
                            .foregroundColor: theme.textNSColor,
                            .paragraphStyle: mathPara,
                            .kern: 0.0
                        ], range: mLine.lineRange)

                        if t.hasPrefix("$$") {
                            storage.addAttribute(.foregroundColor, value: theme.linkNSColor.withAlphaComponent(0.9), range: mLine.contentRange)
                        } else {
                            highlightLaTeXSource(in: storage, range: mLine.contentRange, theme: theme, dimFactor: 1.0)
                        }
                    } else {
                        let mathPara = NSMutableParagraphStyle()
                        mathPara.alignment = .center
                        mathPara.lineSpacing = 4.0
                        mathPara.paragraphSpacing = 4.0
                        mathPara.tailIndent = effectiveContainerWidth
                        storage.addAttributes([
                            .font: theme.bodyFont(size: effectiveBaseSize),
                            .foregroundColor: NSColor.clear,
                            .paragraphStyle: mathPara,
                            .kern: 0.0
                        ], range: mLine.lineRange)
                    }
                }

                let combinedLatex = latexParts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                if !isMathBlockActive && !combinedLatex.isEmpty {
                    decorations.append(LineDecoration(
                        lineRange: fullBlockRange,
                        kind: .mathBlockRendered(latex: combinedLatex, fullBlockRange: fullBlockRange, dimFactor: blockDim)
                    ))
                }

                index = scanIndex
                lineNumber += scanLineCount
                continue
            }

            // 2b. Check Standalone Raw <svg ...> ... </svg> Block
            let lowerTrimmedLine = trimmedLine.lowercased()
            if lowerTrimmedLine.hasPrefix("<svg") {
                previousListTextIndent = nil
                var svgLines: [(lineRange: NSRange, contentRange: NSRange, text: String, isActive: Bool)] = [
                    (lineRange, contentRange, lineText, isActiveLine)
                ]
                var scanIndex = NSMaxRange(lineRange)
                var scanLineCount = 1
                let isSingleLineSVG = lowerTrimmedLine.contains("</svg>") || lowerTrimmedLine.hasSuffix("/>")
                var foundClosingSVG = isSingleLineSVG

                if !isSingleLineSVG {
                    while scanIndex < fullLength {
                        let nextLR = nsString.lineRange(for: NSRange(location: scanIndex, length: 0))
                        let nextCR = strippedLineContentRange(nsString: nsString, lineRange: nextLR)
                        let nextText = nsString.substring(with: nextCR)
                        let nextActive = isLineActive(lineRange: nextLR, activeLineRange: activeLineRange, selectedRange: selectedRange)
                        svgLines.append((nextLR, nextCR, nextText, nextActive))
                        scanIndex = NSMaxRange(nextLR)
                        scanLineCount += 1
                        if nextText.lowercased().contains("</svg>") {
                            foundClosingSVG = true
                            break
                        }
                    }
                }

                let fullBlockRange = NSRange(location: lineRange.location, length: scanIndex - lineRange.location)
                let isSVGBlockActive = svgLines.contains(where: { $0.isActive }) ||
                    NSIntersectionRange(fullBlockRange, selectedRange).length > 0
                let blockDim: CGFloat = (focusMode && !isSVGBlockActive) ? 0.30 : 1.0

                if foundClosingSVG {
                    let combinedSVG = svgLines.map(\.text).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    if prettyMode && !isSVGBlockActive && !combinedSVG.isEmpty {
                        let svgImg = FolioMediaImageCache.shared.svgImage(for: combinedSVG).image
                        let availW = max(200.0, effectiveContainerWidth - 32.0)
                        let totalCardHeight: CGFloat
                        if let img = svgImg, img.size.width > 0, img.size.height > 0 {
                            let scale = min(1.0, availW / img.size.width)
                            let naturalH = round(img.size.height * scale) + 28.0
                            totalCardHeight = min(640.0, max(96.0, naturalH))
                        } else {
                            totalCardHeight = 190.0
                        }
                        let perLineHeight = max(6.0, round(totalCardHeight / CGFloat(svgLines.count)))
                        let hiddenLineFont = theme.bodyFont(size: min(effectiveBaseSize, max(4.0, perLineHeight * 0.6)))
                        for (sIdx, sLine) in svgLines.enumerated() {
                            let svgPara = NSMutableParagraphStyle()
                            svgPara.alignment = .center
                            svgPara.lineSpacing = 0.0
                            svgPara.paragraphSpacingBefore = 0.0
                            svgPara.paragraphSpacing = (sIdx == svgLines.count - 1) ? max(6.0, typography.paragraphSpacing * 0.55) : 0.0
                            svgPara.minimumLineHeight = perLineHeight
                            svgPara.maximumLineHeight = perLineHeight
                            svgPara.tailIndent = effectiveContainerWidth
                            storage.addAttributes([
                                .font: hiddenLineFont,
                                .foregroundColor: NSColor.clear,
                                .paragraphStyle: svgPara,
                                .kern: 0.0
                            ], range: sLine.lineRange)
                        }
                        decorations.append(LineDecoration(
                            lineRange: fullBlockRange,
                            kind: .svgBlockRendered(svgSource: combinedSVG, fullBlockRange: fullBlockRange, dimFactor: blockDim)
                        ))
                    } else {
                        let codeMono = theme.codeFont(size: effectiveBaseSize * 0.90)
                        for sLine in svgLines {
                            decorations.append(LineDecoration(lineRange: sLine.lineRange, kind: .codeFenceBody))
                            let codePara = NSMutableParagraphStyle()
                            codePara.lineSpacing = 2.0
                            codePara.paragraphSpacing = 1.0
                            codePara.firstLineHeadIndent = 14.0
                            codePara.headIndent = 14.0
                            codePara.tailIndent = effectiveContainerWidth
                            storage.addAttributes([
                                .font: codeMono,
                                .foregroundColor: theme.textNSColor.withAlphaComponent(blockDim),
                                .paragraphStyle: codePara,
                                .kern: 0.0
                            ], range: sLine.lineRange)
                            highlightCodeLine(in: storage, range: sLine.contentRange, language: "svg", theme: theme, dimFactor: blockDim)
                        }
                    }

                    index = scanIndex
                    lineNumber += scanLineCount
                    continue
                }
            }

            // 3. Check Horizontal Rule (--- / *** / ___)
            if contentRange.length >= 3,
               hrRegex.firstMatch(in: string, options: [], range: contentRange) != nil {
                previousListTextIndent = nil
                decorations.append(LineDecoration(lineRange: lineRange, kind: .horizontalRule))
                let hrPara = NSMutableParagraphStyle()
                hrPara.minimumLineHeight = 28.0
                hrPara.maximumLineHeight = 28.0
                hrPara.paragraphSpacingBefore = 6.0 * typography.headingSpacingScale
                hrPara.paragraphSpacing = 6.0 * typography.headingSpacingScale
                hrPara.tailIndent = effectiveContainerWidth
                storage.addAttribute(.paragraphStyle, value: hrPara, range: lineRange)
                styleSyntaxToken(
                    in: storage,
                    range: contentRange,
                    isActiveLine: isActiveLine,
                    theme: theme,
                    dimFactor: dimFactor
                )
                index = NSMaxRange(lineRange)
                lineNumber += 1
                continue
            }

            // 4. Check ATX Heading (# .. ###### with 0-3 leading spaces and optional closing #)
            if let match = headingRegex.firstMatch(in: string, options: [], range: contentRange),
               match.range(at: 3).location != NSNotFound || match.range(at: 2).length == contentRange.length - match.range(at: 1).length {
                previousListTextIndent = nil
                let leadingRange = match.range(at: 1)
                let hashesRange = match.range(at: 2)
                let spaceRange = match.range(at: 3)
                let titleRange = match.range(at: 4)
                let level = min(6, max(1, hashesRange.length))
                let titleText = titleRange.location != NSNotFound ? nsString.substring(with: titleRange) : ""

                if !titleText.isEmpty {
                    headings.append(OutlineHeading(
                        level: level,
                        title: titleText,
                        characterLocation: contentRange.location,
                        lineNumber: lineNumber
                    ))
                }

                let hFont = theme.headingFont(level: level, scale: typography.fontSizeScale)
                let hScale = typography.headingSpacingScale
                let hPara = NSMutableParagraphStyle()
                hPara.lineHeightMultiple = max(1.10, typography.lineHeightMultiple * 0.90)
                hPara.lineSpacing = max(1.5, typography.lineSpacing * 0.5)
                hPara.tailIndent = effectiveContainerWidth
                switch level {
                case 1:
                    hPara.paragraphSpacingBefore = 12.0 * hScale
                    hPara.paragraphSpacing = (typography.showHeadingUnderlines ? 14.0 : 8.0) * hScale
                case 2:
                    hPara.paragraphSpacingBefore = 10.0 * hScale
                    hPara.paragraphSpacing = (typography.showHeadingUnderlines ? 12.0 : 7.0) * hScale
                case 3:
                    hPara.paragraphSpacingBefore = 8.0 * hScale
                    hPara.paragraphSpacing = 6.0 * hScale
                default:
                    hPara.paragraphSpacingBefore = 6.0 * hScale
                    hPara.paragraphSpacing = 4.0 * hScale
                }

                storage.addAttributes([
                    .font: hFont,
                    .foregroundColor: theme.headingNSColor.withAlphaComponent(dimFactor),
                    .paragraphStyle: hPara,
                    .kern: typography.headingCharacterSpacing
                ], range: lineRange)

                let prefixEnd = spaceRange.location != NSNotFound ? NSMaxRange(spaceRange) : NSMaxRange(hashesRange)
                let prefixRange = NSRange(location: leadingRange.location, length: prefixEnd - leadingRange.location)
                styleSyntaxToken(
                    in: storage,
                    range: prefixRange,
                    isActiveLine: isActiveLine,
                    theme: theme,
                    dimFactor: dimFactor
                )

                // Collapse optional closing # sequence (e.g. `## Heading ##`)
                if titleRange.location != NSNotFound {
                    let suffixStart = NSMaxRange(titleRange)
                    let suffixLen = NSMaxRange(contentRange) - suffixStart
                    if suffixLen > 0 {
                        styleSyntaxToken(
                            in: storage,
                            range: NSRange(location: suffixStart, length: suffixLen),
                            isActiveLine: isActiveLine,
                            theme: theme,
                            dimFactor: dimFactor
                        )
                    }
                }

                if level <= 2 && typography.showHeadingUnderlines {
                    decorations.append(LineDecoration(lineRange: lineRange, kind: .headingUnderline(level: level)))
                }

                if titleRange.location != NSNotFound && titleRange.length > 0 {
                    styleInlineMarkdown(
                        in: storage,
                        string: string,
                        range: titleRange,
                        lineRange: lineRange,
                        baseFont: hFont,
                        isActiveLine: isActiveLine,
                        theme: theme,
                        dimFactor: dimFactor,
                        normalizeWhitespace: !isActiveLine,
                        prettyMode: prettyMode,
                        baseDirectoryURL: baseDirectoryURL,
                        decorations: &decorations
                    )
                }

                index = NSMaxRange(lineRange)
                lineNumber += 1
                continue
            }

            // 5. Check Blockquote (> ...)
            if let match = blockquoteRegex.firstMatch(in: string, options: [], range: contentRange) {
                previousListTextIndent = nil
                let markerRange = match.range(at: 1)
                let bodyRange = match.range(at: 2)
                let markerText = nsString.substring(with: markerRange)
                let nestLevel = max(1, markerText.filter { $0 == ">" }.count)

                decorations.append(LineDecoration(lineRange: lineRange, kind: .blockquote(nestLevel: nestLevel)))

                let bqPara = NSMutableParagraphStyle()
                bqPara.firstLineHeadIndent = CGFloat(nestLevel) * 16.0
                bqPara.headIndent = CGFloat(nestLevel) * 16.0
                bqPara.lineHeightMultiple = typography.lineHeightMultiple
                bqPara.lineSpacing = max(1.0, typography.lineSpacing * 0.75)
                bqPara.paragraphSpacing = max(3.0, typography.paragraphSpacing * 0.45)
                bqPara.tailIndent = effectiveContainerWidth

                var bqFont = theme.bodyFont(size: effectiveBaseSize, italic: theme.italicBlockquotes)
                var bqColor = theme.blockquoteTextNSColor.withAlphaComponent(dimFactor)
                var inlineRange = bodyRange

                // Support ATX headings nested inside blockquotes (e.g. `> ### Note`)
                if bodyRange.length > 0,
                   let innerHeading = headingRegex.firstMatch(in: string, options: [], range: bodyRange),
                   innerHeading.range(at: 3).location != NSNotFound {
                    let hLevel = min(6, max(1, innerHeading.range(at: 2).length))
                    bqFont = theme.headingFont(level: hLevel, scale: typography.fontSizeScale)
                    bqColor = theme.headingNSColor.withAlphaComponent(dimFactor)
                    let innerPrefixEnd = NSMaxRange(innerHeading.range(at: 3))
                    let innerPrefixRange = NSRange(location: bodyRange.location, length: innerPrefixEnd - bodyRange.location)
                    inlineRange = innerHeading.range(at: 4)
                    storage.addAttributes([
                        .font: bqFont,
                        .foregroundColor: bqColor,
                        .paragraphStyle: bqPara,
                        .kern: typography.headingCharacterSpacing
                    ], range: lineRange)
                    styleSyntaxToken(in: storage, range: innerPrefixRange, isActiveLine: isActiveLine, theme: theme, dimFactor: dimFactor)
                } else {
                    proseLineKinds[lineNumber] = .blockquote(nestLevel: nestLevel)
                    storage.addAttributes([
                        .font: bqFont,
                        .foregroundColor: bqColor,
                        .paragraphStyle: bqPara,
                        .kern: typography.characterSpacing
                    ], range: lineRange)
                }

                styleSyntaxToken(
                    in: storage,
                    range: markerRange,
                    isActiveLine: isActiveLine,
                    theme: theme,
                    dimFactor: dimFactor
                )

                if multiLineParagraphLines.contains(lineNumber) && proseLineKinds[lineNumber] != nil {
                    deferredProseInline.append(DeferredInlineStyle(
                        line: lineNumber, range: inlineRange, baseFont: bqFont, isActive: isActiveLine, dimFactor: dimFactor
                    ))
                } else {
                    styleInlineMarkdown(
                        in: storage,
                        string: string,
                        range: inlineRange,
                        lineRange: lineRange,
                        baseFont: bqFont,
                        isActiveLine: isActiveLine,
                        theme: theme,
                        dimFactor: dimFactor,
                        normalizeWhitespace: !isActiveLine,
                        prettyMode: prettyMode,
                        baseDirectoryURL: baseDirectoryURL,
                        decorations: &decorations
                    )
                }

                index = NSMaxRange(lineRange)
                lineNumber += 1
                continue
            }

            // 6. Check GFM Table Block (contiguous pipe-delimited rows)
            if isTableCandidateLine(nsString: nsString, contentRange: contentRange) {
                var tableRows: [(lineRange: NSRange, contentRange: NSRange, isActive: Bool, isSeparator: Bool)] = []
                var scanIndex = index
                var scanLines = 0

                while scanIndex < fullLength {
                    let nextLR = nsString.lineRange(for: NSRange(location: scanIndex, length: 0))
                    let nextCR = strippedLineContentRange(nsString: nsString, lineRange: nextLR)
                    guard nextCR.length > 0,
                          isTableCandidateLine(nsString: nsString, contentRange: nextCR) else {
                        break
                    }
                    let nextActive = isLineActive(lineRange: nextLR, activeLineRange: activeLineRange, selectedRange: selectedRange)
                    let nextSep = isTableSeparatorRow(nsString: nsString, contentRange: nextCR)
                    tableRows.append((nextLR, nextCR, nextActive, nextSep))
                    scanIndex = NSMaxRange(nextLR)
                    scanLines += 1
                }

                let hasValidTableStructure = tableRows.count >= 2 && tableRows.contains(where: { $0.isSeparator })
                    || (tableRows.count == 1 && nsString.substring(with: tableRows[0].contentRange).trimmingCharacters(in: .whitespaces).hasPrefix("|"))

                if hasValidTableStructure {
                    previousListTextIndent = nil
                    styleTableBlock(
                        rows: tableRows,
                        in: storage,
                        string: string,
                        nsString: nsString,
                        theme: theme,
                        typography: typography,
                        containerWidth: effectiveContainerWidth,
                        focusMode: focusMode,
                        prettyMode: prettyMode,
                        baseDirectoryURL: baseDirectoryURL,
                        decorations: &decorations
                    )

                    index = scanIndex
                    lineNumber += scanLines
                    continue
                }
            }

            // 7. Check Task List (- [ ] / - [x] / 1. [x])
            if let match = taskListRegex.firstMatch(in: string, options: [], range: contentRange) {
                let leadingWSRange = match.range(at: 1)
                let spaceAfterMarkerRange = match.range(at: 3)
                let boxRange = match.range(at: 4)
                let spaceAfterBoxRange = match.range(at: 5)
                let textRange = match.range(at: 6)
                let boxStr = nsString.substring(with: boxRange).lowercased()
                let isChecked = boxStr == "[x]"

                let indentCols = indentationColumnCount(nsString: nsString, range: leadingWSRange)
                let nestLevel = indentCols / 2
                let baseIndent: CGFloat = 10.0 + CGFloat(nestLevel) * 18.0
                let textIndent: CGFloat = baseIndent + 26.0
                previousListTextIndent = textIndent

                let bulletPrefixRange = NSRange(
                    location: leadingWSRange.location,
                    length: NSMaxRange(spaceAfterMarkerRange) - leadingWSRange.location
                )
                styleSyntaxToken(
                    in: storage,
                    range: bulletPrefixRange,
                    isActiveLine: isActiveLine,
                    theme: theme,
                    dimFactor: dimFactor
                )

                proseLineKinds[lineNumber] = .listItem
                let boxFont = NSFont.monospacedSystemFont(ofSize: effectiveBaseSize * 0.92, weight: .bold)
                storage.addAttributes([
                    .font: boxFont,
                    .foregroundColor: (isChecked ? theme.linkNSColor : theme.secondaryTextNSColor).withAlphaComponent(dimFactor),
                    .kern: 0.0
                ], range: boxRange)

                let syntaxFont = NSFont.monospacedSystemFont(ofSize: max(11.0, theme.baseFontSize * 0.85), weight: .regular)
                let activePrefixW = isActiveLine
                    ? (nsString.substring(with: bulletPrefixRange) as NSString).size(withAttributes: [.font: syntaxFont]).width
                    : 0.0

                let listPara = NSMutableParagraphStyle()
                listPara.firstLineHeadIndent = isActiveLine ? max(0.0, baseIndent - activePrefixW) : baseIndent
                listPara.headIndent = textIndent
                listPara.lineHeightMultiple = typography.lineHeightMultiple
                listPara.lineSpacing = max(1.0, typography.lineSpacing * 0.70)
                listPara.paragraphSpacing = max(2.5, typography.paragraphSpacing * 0.35)
                listPara.tailIndent = effectiveContainerWidth
                storage.addAttribute(.paragraphStyle, value: listPara, range: lineRange)

                let boxW = (nsString.substring(with: boxRange) as NSString).size(withAttributes: [.font: boxFont]).width
                if !isActiveLine && spaceAfterBoxRange.length > 0 {
                    let desiredGap = max(4.0, (textIndent - baseIndent) - boxW)
                    collapseWhitespaceRange(in: storage, range: spaceAfterBoxRange)
                    storage.addAttribute(.kern, value: desiredGap, range: NSRange(location: spaceAfterBoxRange.location, length: 1))
                } else if isActiveLine && spaceAfterBoxRange.length > 0 {
                    let spaceW = (nsString.substring(with: spaceAfterBoxRange) as NSString).size(withAttributes: [.font: baseFont]).width
                    let extraKern = max(0.0, (textIndent - baseIndent) - boxW - spaceW)
                    storage.addAttribute(.kern, value: extraKern, range: NSRange(location: NSMaxRange(spaceAfterBoxRange) - 1, length: 1))
                }

                if isChecked {
                    storage.addAttributes([
                        .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                        .foregroundColor: theme.secondaryTextNSColor.withAlphaComponent(0.75 * dimFactor)
                    ], range: textRange)
                } else if dimFactor < 1.0 {
                    storage.addAttribute(.foregroundColor, value: baseColor.withAlphaComponent(dimFactor), range: textRange)
                }

                if multiLineParagraphLines.contains(lineNumber) && proseLineKinds[lineNumber] != nil {
                    deferredProseInline.append(DeferredInlineStyle(
                        line: lineNumber, range: textRange, baseFont: baseFont, isActive: isActiveLine, dimFactor: dimFactor
                    ))
                } else {
                    styleInlineMarkdown(
                        in: storage,
                        string: string,
                        range: textRange,
                        lineRange: lineRange,
                        baseFont: baseFont,
                        isActiveLine: isActiveLine,
                        theme: theme,
                        dimFactor: dimFactor,
                        normalizeWhitespace: !isActiveLine,
                        prettyMode: prettyMode,
                        baseDirectoryURL: baseDirectoryURL,
                        decorations: &decorations
                    )
                }

                index = NSMaxRange(lineRange)
                lineNumber += 1
                continue
            }

            // 8. Check Unordered / Ordered Lists
            if let match = unorderedListRegex.firstMatch(in: string, options: [], range: contentRange) ??
                orderedListRegex.firstMatch(in: string, options: [], range: contentRange) {
                let leadingWSRange = match.range(at: 1)
                let markerSymbolRange = match.range(at: 2)
                let postMarkerWSRange = match.range(at: 3)
                let bodyRange = match.range(at: 4)

                let indentCols = indentationColumnCount(nsString: nsString, range: leadingWSRange)
                let nestLevel = indentCols / 2
                let isOrdered = orderedListRegex.firstMatch(in: string, options: [], range: contentRange) != nil
                let baseIndent: CGFloat = 10.0 + CGFloat(nestLevel) * 18.0
                let markerAdvance: CGFloat = isOrdered ? 22.0 : 16.0
                let textIndent: CGFloat = baseIndent + markerAdvance
                previousListTextIndent = textIndent
                proseLineKinds[lineNumber] = .listItem

                let markerFont = theme.bodyFont(size: effectiveBaseSize, bold: true)
                let markerStr = nsString.substring(with: markerSymbolRange) as NSString
                let markerW = markerStr.size(withAttributes: [.font: markerFont]).width
                let leadW = isActiveLine && leadingWSRange.length > 0
                    ? (nsString.substring(with: leadingWSRange) as NSString).size(withAttributes: [.font: markerFont]).width
                    : 0.0

                let listPara = NSMutableParagraphStyle()
                listPara.firstLineHeadIndent = isActiveLine ? max(0.0, baseIndent - leadW) : baseIndent
                listPara.headIndent = textIndent
                listPara.lineHeightMultiple = typography.lineHeightMultiple
                listPara.lineSpacing = max(1.0, typography.lineSpacing * 0.70)
                listPara.paragraphSpacing = max(2.5, typography.paragraphSpacing * 0.35)
                listPara.tailIndent = effectiveContainerWidth
                storage.addAttribute(.paragraphStyle, value: listPara, range: lineRange)

                storage.addAttributes([
                    .font: markerFont,
                    .foregroundColor: (!isActiveLine && !isOrdered)
                        ? NSColor.clear
                        : theme.linkNSColor.withAlphaComponent(dimFactor),
                    .kern: 0.0
                ], range: markerSymbolRange)

                if !isActiveLine {
                    if !isOrdered {
                        decorations.append(LineDecoration(
                            lineRange: lineRange,
                            kind: .listBullet(range: markerSymbolRange, dimFactor: dimFactor)
                        ))
                    }
                    if leadingWSRange.length > 0 {
                        collapseWhitespaceRange(in: storage, range: leadingWSRange)
                    }
                    if postMarkerWSRange.length > 0 {
                        let desiredGap = max(4.0, markerAdvance - markerW)
                        collapseWhitespaceRange(in: storage, range: postMarkerWSRange)
                        storage.addAttribute(.kern, value: desiredGap, range: NSRange(location: postMarkerWSRange.location, length: 1))
                    }
                } else {
                    storage.addAttributes([
                        .font: markerFont,
                        .foregroundColor: theme.linkNSColor.withAlphaComponent(dimFactor)
                    ], range: NSRange(location: leadingWSRange.location, length: NSMaxRange(postMarkerWSRange) - leadingWSRange.location))
                    if !isOrdered && markerStr.isEqual(to: "*") {
                        storage.addAttribute(.baselineOffset, value: -effectiveBaseSize * 0.14, range: markerSymbolRange)
                    }
                    if postMarkerWSRange.length > 0 {
                        let postW = (nsString.substring(with: postMarkerWSRange) as NSString).size(withAttributes: [.font: markerFont]).width
                        let extraKern = max(0.0, markerAdvance - markerW - postW)
                        storage.addAttribute(.kern, value: extraKern, range: NSRange(location: NSMaxRange(postMarkerWSRange) - 1, length: 1))
                    }
                }

                if dimFactor < 1.0 {
                    storage.addAttribute(.foregroundColor, value: baseColor.withAlphaComponent(dimFactor), range: bodyRange)
                }

                if multiLineParagraphLines.contains(lineNumber) && proseLineKinds[lineNumber] != nil {
                    deferredProseInline.append(DeferredInlineStyle(
                        line: lineNumber, range: bodyRange, baseFont: baseFont, isActive: isActiveLine, dimFactor: dimFactor
                    ))
                } else {
                    styleInlineMarkdown(
                        in: storage,
                        string: string,
                        range: bodyRange,
                        lineRange: lineRange,
                        baseFont: baseFont,
                        isActiveLine: isActiveLine,
                        theme: theme,
                        dimFactor: dimFactor,
                        normalizeWhitespace: !isActiveLine,
                        prettyMode: prettyMode,
                        baseDirectoryURL: baseDirectoryURL,
                        decorations: &decorations
                    )
                }

                index = NSMaxRange(lineRange)
                lineNumber += 1
                continue
            }

            // 9. Check Setext Heading (current paragraph line followed immediately by `===` or `---` underline)
            let nextLineStart = NSMaxRange(lineRange)
            if nextLineStart < fullLength {
                let nextLR = nsString.lineRange(for: NSRange(location: nextLineStart, length: 0))
                let nextCR = strippedLineContentRange(nsString: nsString, lineRange: nextLR)
                if nextCR.length > 0 {
                    let isSetextH1 = setextH1Regex.firstMatch(in: string, options: [], range: nextCR) != nil
                    let isSetextH2 = !isSetextH1 && setextH2Regex.firstMatch(in: string, options: [], range: nextCR) != nil
                    if isSetextH1 || isSetextH2 {
                        previousListTextIndent = nil
                        let level = isSetextH1 ? 1 : 2
                        let nextActive = isLineActive(lineRange: nextLR, activeLineRange: activeLineRange, selectedRange: selectedRange)
                        let combinedActive = isActiveLine || nextActive
                        let setextDim: CGFloat = (focusMode && !combinedActive) ? 0.30 : 1.0

                        let titleText = trimmedLine
                        if !titleText.isEmpty {
                            headings.append(OutlineHeading(
                                level: level,
                                title: titleText,
                                characterLocation: contentRange.location,
                                lineNumber: lineNumber
                            ))
                        }

                        let hFont = theme.headingFont(level: level, scale: typography.fontSizeScale)
                        let hScale = typography.headingSpacingScale
                        let hPara = NSMutableParagraphStyle()
                        hPara.lineHeightMultiple = max(1.10, typography.lineHeightMultiple * 0.90)
                        hPara.lineSpacing = max(1.5, typography.lineSpacing * 0.5)
                        hPara.paragraphSpacingBefore = (level == 1 ? 12.0 : 10.0) * hScale
                        hPara.paragraphSpacing = (typography.showHeadingUnderlines ? (level == 1 ? 14.0 : 12.0) : 8.0) * hScale
                        hPara.tailIndent = effectiveContainerWidth

                        storage.addAttributes([
                            .font: hFont,
                            .foregroundColor: theme.headingNSColor.withAlphaComponent(setextDim),
                            .paragraphStyle: hPara,
                            .kern: typography.headingCharacterSpacing
                        ], range: lineRange)

                        if typography.showHeadingUnderlines {
                            decorations.append(LineDecoration(lineRange: lineRange, kind: .headingUnderline(level: level)))
                        }

                        styleInlineMarkdown(
                            in: storage,
                            string: string,
                            range: contentRange,
                            lineRange: lineRange,
                            baseFont: hFont,
                            isActiveLine: combinedActive,
                            theme: theme,
                            dimFactor: setextDim,
                            normalizeWhitespace: !combinedActive,
                            prettyMode: prettyMode,
                            baseDirectoryURL: baseDirectoryURL,
                            decorations: &decorations
                        )

                        // Style or collapse the Setext underline row
                        let underlinePara = NSMutableParagraphStyle()
                        underlinePara.lineSpacing = 0.0
                        underlinePara.paragraphSpacing = 0.0
                        underlinePara.paragraphSpacingBefore = 0.0
                        underlinePara.minimumLineHeight = combinedActive ? 20.0 : 1.0
                        underlinePara.maximumLineHeight = combinedActive ? 20.0 : 1.0
                        underlinePara.tailIndent = effectiveContainerWidth
                        storage.addAttribute(.paragraphStyle, value: underlinePara, range: nextLR)
                        styleSyntaxToken(in: storage, range: nextCR, isActiveLine: combinedActive, theme: theme, dimFactor: setextDim)

                        index = NSMaxRange(nextLR)
                        lineNumber += 2
                        continue
                    }
                }
            }

            // 10b. CommonMark Link Reference Definition ([label]: url "title")
            if previousListTextIndent == nil,
               let refDefMatch = linkRefDefRegex.firstMatch(in: string, options: [], range: contentRange) {
                let labelRange = refDefMatch.range(at: 1)
                let destRange = refDefMatch.range(at: 2)
                let prefixLen = (labelRange.location - contentRange.location) + labelRange.length + 2 // includes `]:`
                let prefixRange = NSRange(location: contentRange.location, length: min(contentRange.length, prefixLen))

                storage.addAttributes([
                    .font: theme.codeFont(size: max(11.0, effectiveBaseSize * 0.86)),
                    .foregroundColor: theme.markdownTokenNSColor.withAlphaComponent((isActiveLine ? 0.90 : 0.65) * dimFactor)
                ], range: prefixRange)
                storage.addAttributes([
                    .font: theme.codeFont(size: max(11.0, effectiveBaseSize * 0.86)),
                    .foregroundColor: theme.linkNSColor.withAlphaComponent((isActiveLine ? 0.95 : 0.75) * dimFactor),
                    .underlineStyle: NSUnderlineStyle.single.rawValue
                ], range: destRange)

                index = NSMaxRange(lineRange)
                lineNumber += 1
                continue
            }

            // Default paragraph line (or indented list continuation line)
            if let listIndent = previousListTextIndent,
               let leadMatch = leadingSpaceRegex.firstMatch(in: string, options: [], range: contentRange),
               indentationColumnCount(nsString: nsString, range: leadMatch.range) >= 2 {
                let leadW = isActiveLine && leadMatch.range.length > 0
                    ? (nsString.substring(with: leadMatch.range) as NSString).size(withAttributes: [.font: baseFont]).width
                    : 0.0
                if !isActiveLine && leadMatch.range.length > 0 {
                    collapseWhitespaceRange(in: storage, range: leadMatch.range)
                }
                let contPara = NSMutableParagraphStyle()
                contPara.firstLineHeadIndent = isActiveLine ? max(0.0, listIndent - leadW) : listIndent
                contPara.headIndent = listIndent
                contPara.lineHeightMultiple = typography.lineHeightMultiple
                contPara.lineSpacing = max(1.0, typography.lineSpacing * 0.70)
                contPara.paragraphSpacing = max(2.5, typography.paragraphSpacing * 0.35)
                contPara.tailIndent = effectiveContainerWidth
                storage.addAttribute(.paragraphStyle, value: contPara, range: lineRange)
            } else {
                previousListTextIndent = nil
            }

            proseLineKinds[lineNumber] = .paragraph
            if dimFactor < 1.0 {
                storage.addAttribute(.foregroundColor, value: baseColor.withAlphaComponent(dimFactor), range: contentRange)
            }

            if multiLineParagraphLines.contains(lineNumber) && proseLineKinds[lineNumber] != nil {
                deferredProseInline.append(DeferredInlineStyle(
                    line: lineNumber, range: contentRange, baseFont: baseFont, isActive: isActiveLine, dimFactor: dimFactor
                ))
            } else {
                styleInlineMarkdown(
                    in: storage,
                    string: string,
                    range: contentRange,
                    lineRange: lineRange,
                    baseFont: baseFont,
                    isActiveLine: isActiveLine,
                    theme: theme,
                    dimFactor: dimFactor,
                    normalizeWhitespace: !isActiveLine,
                    prettyMode: prettyMode,
                    baseDirectoryURL: baseDirectoryURL,
                    decorations: &decorations
                )
            }

            index = NSMaxRange(lineRange)
            lineNumber += 1
        }

        applySoftLineBreaks(
            to: storage,
            blocks: specAST.blocks,
            lineRecords: lineRecords,
            proseLineKinds: proseLineKinds
        )

        // Style each run of lines joined by soft breaks as one inline range.
        var runStart = 0
        for i in deferredProseInline.indices {
            let item = deferredProseInline[i]
            let continuesRun = i + 1 < deferredProseInline.count
                && deferredProseInline[i + 1].line == item.line + 1
                && lineRecords[item.line].map { rec in
                    NSMaxRange(rec.contentRange) < fullLength
                        && storage.attribute(softLineBreakAttributeKey, at: NSMaxRange(rec.contentRange), effectiveRange: nil) != nil
                } == true
            guard !continuesRun else { continue }
            let run = deferredProseInline[runStart...i]
            let first = deferredProseInline[runStart]
            // Style consecutive lines with the same activity as one range: the cursor line reveals
            // its syntax, and the lines around it keep spans that cross soft breaks folded.
            var segmentStart = runStart
            for j in runStart...i where j == i || deferredProseInline[j + 1].isActive != deferredProseInline[j].isActive {
                let segFirst = deferredProseInline[segmentStart]
                let segLast = deferredProseInline[j]
                styleInlineMarkdown(
                    in: storage,
                    string: string,
                    range: NSRange(location: segFirst.range.location, length: NSMaxRange(segLast.range) - segFirst.range.location),
                    lineRange: (segmentStart == j) ? lineRecords[segFirst.line]?.lineRange : nil,
                    baseFont: first.baseFont,
                    isActiveLine: segFirst.isActive,
                    theme: theme,
                    dimFactor: segFirst.dimFactor,
                    normalizeWhitespace: !segFirst.isActive,
                    prettyMode: prettyMode,
                    baseDirectoryURL: baseDirectoryURL,
                    decorations: &decorations
                )
                segmentStart = j + 1
            }
            if run.count > 1 {
                // Whitespace at a soft break is not content: hide continuation indentation and
                // trailing spaces even while the paragraph is being edited.
                for entry in run {
                    guard let rec = lineRecords[entry.line] else { continue }
                    for regex in [leadingSpaceRegex, trailingSpaceRegex] {
                        let isLeading = regex === leadingSpaceRegex
                        if isLeading && entry.line == first.line { continue }
                        if !isLeading && entry.line == item.line { continue }
                        if let match = regex.firstMatch(in: string, options: [], range: rec.contentRange) {
                            collapseWhitespaceRange(in: storage, range: match.range)
                        }
                    }
                }
            }
            runStart = i + 1
        }

        // Apply cmark-gfm AST-resolved reference links ([text][ref], [text][], [text])
        // and GFM extended autolinks (www.example.com, https://...)
        if !astLinksByLine.isEmpty {
            for (ln, links) in astLinksByLine {
                guard var rec = lineRecords[ln] else { continue }
                for reported in links {
                    let link = correctedInlineStart(reported, lineRecords: lineRecords)
                    let spanLines = link.startLine...link.endLine
                    if link.endLine > link.startLine {
                        // A multi-line span is only one visual span when its lines are joined.
                        let joined = (link.startLine..<link.endLine).allSatisfy { l in
                            guard let r = lineRecords[l], NSMaxRange(r.contentRange) < fullLength else { return false }
                            return storage.attribute(softLineBreakAttributeKey, at: NSMaxRange(r.contentRange), effectiveRange: nil) != nil
                        }
                        guard joined else { continue }
                    }
                    guard let docStart = documentOffset(lineRecords[link.startLine], byteColumn: link.startColumn - 1),
                          let docEnd = documentOffset(lineRecords[link.endLine], byteColumn: link.endColumn),
                          docEnd > docStart else {
                        continue
                    }
                    let docRange = NSRange(location: docStart, length: docEnd - docStart)
                    guard NSMaxRange(docRange) <= fullLength, docRange.length > 0 else { continue }
                    rec.isActive = spanLines.contains { lineRecords[$0]?.isActive ?? false }

                    let spanText = nsString.substring(with: docRange)
                    if spanText.hasPrefix("[") || spanText.hasPrefix("![") {
                        let isImg = spanText.hasPrefix("![")
                        let openLen = isImg ? 2 : 1
                        let spanNS = spanText as NSString
                        var scan = openLen
                        var depth = 1
                        var closeBracketOffset: Int? = nil
                        while scan < spanNS.length {
                            let c = spanNS.character(at: scan)
                            if c == 0x5C { // backslash escape
                                scan += 2
                                continue
                            } else if c == 0x5B {
                                depth += 1
                            } else if c == 0x5D {
                                depth -= 1
                                if depth == 0 {
                                    closeBracketOffset = scan
                                    break
                                }
                            }
                            scan += 1
                        }
                        guard let closeBracket = closeBracketOffset, closeBracket >= openLen else { continue }
                        // Inline `[label](url)` links were already styled by scanMarkdownLinks
                        if closeBracket + 1 < spanNS.length && spanNS.character(at: closeBracket + 1) == 0x28 {
                            continue
                        }
                        let openSyntaxRange = NSRange(location: docRange.location, length: openLen)
                        let labelRange = NSRange(location: docRange.location + openLen, length: closeBracket - openLen)
                        let trailingSyntaxRange = NSRange(
                            location: docRange.location + closeBracket,
                            length: docRange.length - closeBracket
                        )
                        if isImg && prettyMode && !rec.isActive && !link.url.isEmpty {
                            let altStr = nsString.substring(with: labelRange)
                            reserveMediaCardHeight(in: storage, lineRange: rec.lineRange, targetHeight: 176.0)
                            collapseWhitespaceRange(in: storage, range: docRange)
                            decorations.append(LineDecoration(
                                lineRange: rec.lineRange,
                                kind: .imageRendered(
                                    url: link.url,
                                    alt: altStr,
                                    fullRange: docRange,
                                    explicitWidth: nil,
                                    explicitHeight: nil,
                                    baseDirectoryURL: baseDirectoryURL,
                                    dimFactor: rec.dimFactor
                                )
                            ))
                        } else {
                            applyAttributesToVisibleCharacters(
                                in: storage,
                                range: labelRange,
                                attributes: [
                                    .foregroundColor: theme.linkNSColor.withAlphaComponent(rec.dimFactor),
                                    .underlineStyle: NSUnderlineStyle.single.rawValue
                                ]
                            )
                            styleSyntaxToken(in: storage, range: openSyntaxRange, isActiveLine: rec.isActive || !prettyMode, theme: theme, dimFactor: rec.dimFactor)
                            styleSyntaxToken(in: storage, range: trailingSyntaxRange, isActiveLine: rec.isActive || !prettyMode, theme: theme, dimFactor: rec.dimFactor)
                        }
                    } else if !spanText.hasPrefix("<") {
                        // GFM extended bare autolink (e.g. www.example.com, https://example.com)
                        applyAttributesToVisibleCharacters(
                            in: storage,
                            range: docRange,
                            attributes: [
                                .foregroundColor: theme.linkNSColor.withAlphaComponent(rec.dimFactor),
                                .underlineStyle: NSUnderlineStyle.single.rawValue
                            ]
                        )
                    }
                }
            }
        }

        storage.endEditing()
        return MarkdownDocumentAnalysis(headings: headings, decorations: decorations)
    }

    // MARK: - Helpers for Line Ranges & Indentation
    /// Marks source newlines inside cmark paragraphs as soft line breaks, so the layout manager
    /// renders them as spaces and the paragraph wraps to the container width. This includes the
    /// paragraph that contains the cursor, so entering a paragraph does not change its layout.
    private static func applySoftLineBreaks(
        to storage: NSTextStorage,
        blocks: [CmarkAstBlock],
        lineRecords: [Int: (lineRange: NSRange, contentRange: NSRange, lineText: String, isActive: Bool, dimFactor: CGFloat)],
        proseLineKinds: [Int: ProseLineKind]
    ) {
        let nsString = storage.string as NSString
        for block in blocks where block.kind == 8 && block.endLine > block.startLine && block.startLine > 0 {
            for ln in block.startLine..<block.endLine {
                guard let rec = lineRecords[ln],
                      canJoinProseLines(proseLineKinds[ln], proseLineKinds[ln + 1]),
                      !endsWithHardLineBreak(rec.lineText) else {
                    continue
                }
                let newlineLocation = NSMaxRange(rec.contentRange)
                guard newlineLocation < NSMaxRange(rec.lineRange),
                      nsString.character(at: newlineLocation) == 10 else {
                    continue
                }
                // TextKit lays out the joined paragraph with the style of its first source line.
                storage.addAttribute(softLineBreakAttributeKey, value: true, range: NSRange(location: newlineLocation, length: 1))
            }
        }
    }

    /// cmark-gfm reports the closing line as the start line of a link that crosses a line break
    /// (e.g. `3:36-3:10` for a link that starts on line 2). When the reported start is not `[` or
    /// `!`, uses the nearest earlier line that has one at the reported start column.
    private static func correctedInlineStart(
        _ inline: CmarkAstInline,
        lineRecords: [Int: (lineRange: NSRange, contentRange: NSRange, lineText: String, isActive: Bool, dimFactor: CGFloat)]
    ) -> CmarkAstInline {
        let col = inline.startColumn - 1
        let startsWithBracket: (Int) -> Bool = { line in
            guard let rec = lineRecords[line] else { return false }
            let bytes = Array(rec.lineText.utf8)
            return col >= 0 && col < bytes.count && (bytes[col] == UInt8(ascii: "[") || bytes[col] == UInt8(ascii: "!"))
        }
        guard !startsWithBracket(inline.startLine) else { return inline }
        var line = inline.startLine - 1
        while line >= 1, lineRecords[line] != nil {
            if startsWithBracket(line) {
                return CmarkAstInline(
                    kind: inline.kind,
                    startLine: line,
                    startColumn: inline.startColumn,
                    endLine: inline.endLine,
                    endColumn: inline.endColumn,
                    url: inline.url,
                    literal: inline.literal
                )
            }
            line -= 1
        }
        return inline
    }

    /// UTF-16 document offset of a 0-based UTF-8 byte column in a line's content.
    private static func documentOffset(
        _ rec: (lineRange: NSRange, contentRange: NSRange, lineText: String, isActive: Bool, dimFactor: CGFloat)?,
        byteColumn: Int
    ) -> Int? {
        guard let rec = rec else { return nil }
        let utf8 = rec.lineText.utf8
        guard let idx = utf8.index(utf8.startIndex, offsetBy: max(0, min(byteColumn, utf8.count)), limitedBy: utf8.endIndex) else {
            return nil
        }
        return rec.contentRange.location + NSRange(utf8.startIndex..<idx, in: rec.lineText).length
    }

    private static func canJoinProseLines(_ current: ProseLineKind?, _ next: ProseLineKind?) -> Bool {
        switch (current, next) {
        case (.paragraph?, .paragraph?), (.listItem?, .paragraph?):
            return true
        case let (.blockquote(a)?, .blockquote(b)?):
            return a == b
        default:
            return false
        }
    }

    /// CommonMark hard line break: two or more trailing spaces, a trailing unescaped backslash, or `<br>`.
    private static func endsWithHardLineBreak(_ lineText: String) -> Bool {
        if lineText.hasSuffix("  ") {
            return true
        }
        let trailingBackslashes = lineText.reversed().prefix(while: { $0 == "\\" }).count
        if trailingBackslashes % 2 == 1 {
            return true
        }
        let lower = lineText.lowercased().trimmingCharacters(in: .whitespaces)
        return lower.hasSuffix("<br>") || lower.hasSuffix("<br/>") || lower.hasSuffix("<br />")
    }

    private static func strippedLineContentRange(nsString: NSString, lineRange: NSRange) -> NSRange {
        var contentRange = lineRange
        while contentRange.length > 0 {
            let lastChar = nsString.character(at: contentRange.location + contentRange.length - 1)
            if lastChar == 10 || lastChar == 13 {
                contentRange.length -= 1
            } else {
                break
            }
        }
        return contentRange
    }

    private static func isLineActive(lineRange: NSRange, activeLineRange: NSRange, selectedRange: NSRange) -> Bool {
        return NSIntersectionRange(lineRange, activeLineRange).length > 0 ||
            (selectedRange.location == lineRange.location + lineRange.length && lineRange.location == activeLineRange.location)
    }

    private static func indentationColumnCount(nsString: NSString, range: NSRange) -> Int {
        var cols = 0
        let end = NSMaxRange(range)
        var i = range.location
        while i < end {
            let ch = nsString.character(at: i)
            if ch == 9 { // tab
                cols += 4 - (cols % 4)
            } else if ch == 32 {
                cols += 1
            }
            i += 1
        }
        return cols
    }

    // MARK: - Table Block Layout & Column Alignment
    private struct ParsedTableCell {
        let leadingDelimiterRange: NSRange // pipe (if any) + leading spaces before cell content
        let contentRange: NSRange          // trimmed cell text
        let trailingSpacesRange: NSRange   // trailing spaces before the next pipe
    }

    private struct ParsedTableRow {
        let cells: [ParsedTableCell]
        let closingPipeRange: NSRange
    }

    /// Scans `contentRange` for unescaped, unprotected `|` pipe locations (ignoring pipes inside `` `code` `` or `$math$`).
    private static func scanUnprotectedTablePipes(nsString: NSString, contentRange: NSRange) -> [Int] {
        var pipes: [Int] = []
        let endLoc = NSMaxRange(contentRange)
        var idx = contentRange.location
        var failedTickLengths = Set<Int>()
        var noClosingDollar = false

        while idx < endLoc {
            let ch = nsString.character(at: idx)
            if ch == 0x5C { // '\' escape
                idx += 2
                continue
            }
            if ch == 0x60 { // '`' inline code span
                var tickCount = 0
                while idx + tickCount < endLoc && nsString.character(at: idx + tickCount) == 0x60 {
                    tickCount += 1
                }
                if failedTickLengths.contains(tickCount) {
                    idx += tickCount
                    continue
                }
                var searchIdx = idx + tickCount
                var foundClose = false
                while searchIdx < endLoc {
                    if nsString.character(at: searchIdx) == 0x60 {
                        var closeTicks = 0
                        while searchIdx + closeTicks < endLoc && nsString.character(at: searchIdx + closeTicks) == 0x60 {
                            closeTicks += 1
                        }
                        if closeTicks == tickCount {
                            idx = searchIdx + closeTicks
                            foundClose = true
                            break
                        }
                        searchIdx += closeTicks
                    } else {
                        searchIdx += 1
                    }
                }
                if !foundClose {
                    failedTickLengths.insert(tickCount)
                    idx += tickCount
                }
                continue
            }
            if ch == 0x24 && !noClosingDollar { // '$' inline math span
                if idx + 1 < endLoc && nsString.character(at: idx + 1) != 0x24 {
                    var searchIdx = idx + 1
                    var foundClose = false
                    while searchIdx < endLoc {
                        let mCh = nsString.character(at: searchIdx)
                        if mCh == 0x5C {
                            searchIdx += 2
                            continue
                        }
                        if mCh == 0x24 {
                            idx = searchIdx + 1
                            foundClose = true
                            break
                        }
                        searchIdx += 1
                    }
                    if !foundClose {
                        noClosingDollar = true
                        idx += 1
                    }
                    continue
                }
            }
            if ch == 0x7C { // '|'
                pipes.append(idx)
            }
            idx += 1
        }
        return pipes
    }

    private static func isTableCandidateLine(nsString: NSString, contentRange: NSRange) -> Bool {
        guard contentRange.length > 0 else { return false }
        let pipes = scanUnprotectedTablePipes(nsString: nsString, contentRange: contentRange)
        return !pipes.isEmpty
    }

    private static func isTableSeparatorRow(nsString: NSString, contentRange: NSRange) -> Bool {
        guard let parsed = parseTableRowCells(nsString: nsString, contentRange: contentRange),
              !parsed.cells.isEmpty else {
            return false
        }
        for cell in parsed.cells {
            let text = nsString.substring(with: cell.contentRange).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return false }
            var slice = text[...]
            if slice.first == ":" { slice = slice.dropFirst() }
            if slice.last == ":" { slice = slice.dropLast() }
            if slice.isEmpty || !slice.allSatisfy({ $0 == "-" }) {
                return false
            }
        }
        return true
    }

    private static func parseTableRowCells(nsString: NSString, contentRange: NSRange) -> ParsedTableRow? {
        let pipeLocations = scanUnprotectedTablePipes(nsString: nsString, contentRange: contentRange)
        guard !pipeLocations.isEmpty else { return nil }

        let endLoc = NSMaxRange(contentRange)
        var firstNonWS = contentRange.location
        while firstNonWS < endLoc {
            let c = nsString.character(at: firstNonWS)
            if c == 32 || c == 9 { firstNonWS += 1 } else { break }
        }
        var lastNonWS = endLoc
        while lastNonWS > firstNonWS {
            let c = nsString.character(at: lastNonWS - 1)
            if c == 32 || c == 9 { lastNonWS -= 1 } else { break }
        }

        let hasLeadingPipe = (pipeLocations.first == firstNonWS)
        let hasTrailingPipe = (pipeLocations.last == lastNonWS - 1)

        // Build virtual boundary positions
        var boundaries: [Int] = []
        if !hasLeadingPipe {
            boundaries.append(firstNonWS - 1) // virtual pipe before first char
        }
        boundaries.append(contentsOf: pipeLocations)
        if !hasTrailingPipe {
            boundaries.append(lastNonWS) // virtual pipe at end
        }

        guard boundaries.count >= 2 else { return nil }

        var cells: [ParsedTableCell] = []
        for i in 0..<(boundaries.count - 1) {
            let pipePos = boundaries[i]
            let nextPipePos = boundaries[i + 1]

            let rawCellStart = max(contentRange.location, pipePos + 1)
            var contentStart = rawCellStart
            while contentStart < nextPipePos {
                let c = nsString.character(at: contentStart)
                if c == 32 || c == 9 { contentStart += 1 } else { break }
            }

            var contentEnd = nextPipePos
            while contentEnd > contentStart {
                let c = nsString.character(at: contentEnd - 1)
                if c == 32 || c == 9 { contentEnd -= 1 } else { break }
            }

            let startLoc = (i == 0) ? contentRange.location : pipePos
            let leadingRange = NSRange(location: startLoc, length: max(0, contentStart - startLoc))
            let cellRange = NSRange(location: contentStart, length: max(0, contentEnd - contentStart))
            let trailingRange = NSRange(location: contentEnd, length: max(0, nextPipePos - contentEnd))
            cells.append(ParsedTableCell(
                leadingDelimiterRange: leadingRange,
                contentRange: cellRange,
                trailingSpacesRange: trailingRange
            ))
        }

        let closingRange: NSRange
        if hasTrailingPipe, let lastPipe = pipeLocations.last {
            closingRange = NSRange(location: lastPipe, length: endLoc - lastPipe)
        } else {
            closingRange = NSRange(location: lastNonWS, length: endLoc - lastNonWS)
        }
        return ParsedTableRow(cells: cells, closingPipeRange: closingRange)
    }

    private static func styleTableBlock(
        rows: [(lineRange: NSRange, contentRange: NSRange, isActive: Bool, isSeparator: Bool)],
        in storage: NSTextStorage,
        string: String,
        nsString: NSString,
        theme: EditorTheme,
        typography: EditorTypographySettings,
        containerWidth: CGFloat,
        focusMode: Bool,
        prettyMode: Bool = true,
        baseDirectoryURL: URL? = nil,
        decorations: inout [LineDecoration]
    ) {
        guard !rows.isEmpty else { return }

        let effectiveBaseSize = theme.baseFontSize * typography.fontSizeScale
        let parsedRows: [ParsedTableRow?] = rows.map { parseTableRowCells(nsString: nsString, contentRange: $0.contentRange) }
        let numCols = max(1, parsedRows.compactMap({ $0?.cells.count }).max() ?? 1)

        // Extract column alignments from separator row if present
        var alignments = Array(repeating: TableColumnAlignment.left, count: numCols)
        for (rIdx, row) in rows.enumerated() where row.isSeparator {
            if let parsed = parsedRows[rIdx] {
                for (cIdx, cell) in parsed.cells.enumerated() where cIdx < numCols {
                    let spec = nsString.substring(with: cell.contentRange).trimmingCharacters(in: .whitespaces)
                    if spec.hasPrefix(":") && spec.hasSuffix(":") {
                        alignments[cIdx] = .center
                    } else if spec.hasSuffix(":") {
                        alignments[cIdx] = .right
                    } else {
                        alignments[cIdx] = .left
                    }
                }
            }
        }

        // First pass: style text & inline Markdown inside each row and measure natural cell widths
        var measuredWidths: [[CGFloat]] = Array(repeating: Array(repeating: 0, count: numCols), count: rows.count)
        var maxActiveRowWidth: CGFloat = 0
        var inlineTableDecorations: [LineDecoration] = []

        for (rIdx, row) in rows.enumerated() {
            let dimFactor: CGFloat = (focusMode && !row.isActive) ? 0.30 : 1.0
            let isHeader = (rIdx == 0)

            if row.isSeparator {
                if row.isActive {
                    let activeMono = theme.codeFont(size: effectiveBaseSize * 0.88)
                    let activeRowHeight: CGFloat = 26.0
                    let activePara = NSMutableParagraphStyle()
                    activePara.lineSpacing = 0.0
                    activePara.paragraphSpacing = 0.0
                    activePara.minimumLineHeight = activeRowHeight
                    activePara.maximumLineHeight = activeRowHeight
                    activePara.lineBreakMode = .byClipping
                    activePara.tailIndent = 0.0
                    let naturalH = activeMono.ascender + abs(activeMono.descender)
                    let shift = max(0.0, floor((activeRowHeight - naturalH) * 0.5))
                    storage.addAttributes([
                        .font: activeMono,
                        .foregroundColor: theme.markdownTokenNSColor.withAlphaComponent(0.9 * dimFactor),
                        .paragraphStyle: activePara,
                        .baselineOffset: shift,
                        .kern: 0.0
                    ], range: row.lineRange)
                    let activeW = ceil(storage.attributedSubstring(from: row.contentRange).size().width) + 28.0
                    maxActiveRowWidth = max(maxActiveRowWidth, activeW)
                } else {
                    // Collapse separator row on inactive line into a clean hairline
                    let collapsedPara = NSMutableParagraphStyle()
                    collapsedPara.minimumLineHeight = 2.0
                    collapsedPara.maximumLineHeight = 2.0
                    collapsedPara.lineSpacing = 0.0
                    collapsedPara.paragraphSpacing = 0.0
                    collapsedPara.lineBreakMode = .byClipping
                    collapsedPara.tailIndent = 0.0
                    storage.addAttributes([
                        .font: NSFont.systemFont(ofSize: 0.001),
                        .foregroundColor: NSColor.clear,
                        .paragraphStyle: collapsedPara,
                        .baselineOffset: 0.0,
                        .kern: 0.0,
                        collapsedTokenAttributeKey: true
                    ], range: row.lineRange)
                }
                continue
            }

            let cellFont: NSFont
            if row.isActive {
                cellFont = theme.codeFont(size: effectiveBaseSize * 0.90)
            } else {
                cellFont = theme.bodyFont(size: effectiveBaseSize * 0.93, bold: isHeader)
            }

            let rowHeight: CGFloat = 32.0
            let rowPara = NSMutableParagraphStyle()
            rowPara.lineSpacing = 0.0
            rowPara.paragraphSpacing = (rIdx == rows.count - 1) ? max(4.0, typography.paragraphSpacing * 0.55) : 0.0
            rowPara.minimumLineHeight = rowHeight
            rowPara.maximumLineHeight = rowHeight
            rowPara.lineBreakMode = .byClipping
            rowPara.tailIndent = 0.0

            let naturalFontHeight = cellFont.ascender + abs(cellFont.descender)
            let baselineShift = max(0.0, floor((rowHeight - naturalFontHeight) * 0.5))

            storage.addAttributes([
                .font: cellFont,
                .foregroundColor: (isHeader ? theme.headingNSColor : theme.textNSColor).withAlphaComponent(dimFactor),
                .paragraphStyle: rowPara,
                .baselineOffset: baselineShift,
                .kern: 0.0
            ], range: row.lineRange)

            guard let parsed = parsedRows[rIdx] else { continue }

            for (cIdx, cell) in parsed.cells.enumerated() where cIdx < numCols {
                if cell.contentRange.length > 0 {
                    styleInlineMarkdown(
                        in: storage,
                        string: string,
                        range: cell.contentRange,
                        lineRange: row.lineRange,
                        baseFont: cellFont,
                        isActiveLine: row.isActive,
                        theme: theme,
                        dimFactor: dimFactor,
                        normalizeWhitespace: !row.isActive,
                        prettyMode: prettyMode,
                        baseDirectoryURL: baseDirectoryURL,
                        decorations: &inlineTableDecorations
                    )
                    let cellAttr = storage.attributedSubstring(from: cell.contentRange)
                    measuredWidths[rIdx][cIdx] = ceil(cellAttr.size().width) + 4.0
                }
            }

            if row.isActive {
                // Highlight pipe delimiters in muted token color when editing the row
                for cell in parsed.cells where cell.leadingDelimiterRange.length > 0 {
                    let firstChar = nsString.character(at: cell.leadingDelimiterRange.location)
                    if firstChar == 0x7C {
                        let pipeRange = NSRange(location: cell.leadingDelimiterRange.location, length: 1)
                        storage.addAttribute(.foregroundColor, value: theme.markdownTokenNSColor.withAlphaComponent(0.85), range: pipeRange)
                    }
                }
                if parsed.closingPipeRange.length > 0 {
                    storage.addAttribute(.foregroundColor, value: theme.markdownTokenNSColor.withAlphaComponent(0.85), range: parsed.closingPipeRange)
                }
                let activeW = ceil(storage.attributedSubstring(from: row.contentRange).size().width) + 28.0
                maxActiveRowWidth = max(maxActiveRowWidth, activeW)
            }
        }

        // Compute column widths and column start X coordinates.
        // IMPORTANT: Never shrink columns below their natural content width! Wide tables extend beyond containerWidth and scroll horizontally.
        let cellHorizontalPadding: CGFloat = 16.0
        var colWidths: [CGFloat] = (0..<numCols).map { cIdx in
            let maxCellW = (0..<rows.count).map({ measuredWidths[$0][cIdx] }).max() ?? 40.0
            return max(64.0, maxCellW + cellHorizontalPadding * 2.0)
        }

        let naturalSum = colWidths.reduce(0, +)
        if naturalSum > 0 && naturalSum < containerWidth {
            let extra = containerWidth - naturalSum
            let perCol = floor(extra / CGFloat(numCols))
            colWidths = colWidths.map { $0 + perCol }
            let expandedSum = colWidths.reduce(0, +)
            if numCols > 0 && expandedSum < containerWidth {
                colWidths[numCols - 1] += (containerWidth - expandedSum)
            }
        }

        var colStartX: [CGFloat] = Array(repeating: 0, count: numCols)
        var runningX: CGFloat = 0
        for cIdx in 0..<numCols {
            colStartX[cIdx] = runningX
            runningX += colWidths[cIdx]
        }
        let totalTableWidth = max(runningX, maxActiveRowWidth)
        let tableOffsetX: CGFloat = 0.0
        let columnDividerX = Array(colStartX.dropFirst())

        // Second pass: apply exact .kern alignment to inactive non-separator rows and emit decorations
        var bodyCounter = 0
        for (rIdx, row) in rows.enumerated() {
            let isHeader = (rIdx == 0)
            let isFirst = (rIdx == 0)
            let isLast = (rIdx == rows.count - 1)
            let currentBodyIdx = (!isHeader && !row.isSeparator) ? bodyCounter : 0
            if !isHeader && !row.isSeparator {
                bodyCounter += 1
            }

            decorations.append(LineDecoration(
                lineRange: row.lineRange,
                kind: .tableRow(
                    isHeader: isHeader,
                    isSeparator: row.isSeparator,
                    isFirstRow: isFirst,
                    isLastRow: isLast,
                    bodyRowIndex: currentBodyIdx,
                    tableOffsetX: tableOffsetX,
                    tableWidth: totalTableWidth,
                    columnDividers: columnDividerX
                )
            ))

            guard !row.isActive, !row.isSeparator, let parsed = parsedRows[rIdx] else { continue }

            // Hide closing pipe
            if parsed.closingPipeRange.length > 0 {
                collapseWhitespaceRange(in: storage, range: parsed.closingPipeRange)
            }

            var currentCursorX: CGFloat = 0.0

            for (cIdx, cell) in parsed.cells.enumerated() where cIdx < numCols {
                // Hide leading delimiter (pipe + spaces) and trailing spaces
                if cell.leadingDelimiterRange.length > 0 {
                    collapseWhitespaceRange(in: storage, range: cell.leadingDelimiterRange)
                }

                if cell.trailingSpacesRange.length > 0 {
                    collapseWhitespaceRange(in: storage, range: cell.trailingSpacesRange)
                }

                let actualCellW = cell.contentRange.length > 0
                    ? max(0.0, measuredWidths[rIdx][cIdx] - 4.0)
                    : 0.0
                let colW = colWidths[cIdx]
                let alignOffset: CGFloat
                switch alignments[cIdx] {
                case .left:
                    alignOffset = cellHorizontalPadding
                case .center:
                    alignOffset = max(cellHorizontalPadding, floor((colW - actualCellW) * 0.5))
                case .right:
                    alignOffset = max(cellHorizontalPadding, colW - actualCellW - cellHorizontalPadding)
                }

                let targetCellStartX = tableOffsetX + colStartX[cIdx] + alignOffset
                let deltaKern = max(1.0, targetCellStartX - currentCursorX)

                if cell.leadingDelimiterRange.length > 0 {
                    let anchorRange = NSRange(location: cell.leadingDelimiterRange.location, length: 1)
                    storage.addAttribute(.kern, value: deltaKern, range: anchorRange)
                    currentCursorX = targetCellStartX + actualCellW
                } else if cell.contentRange.length > 0 {
                    let firstLineIndent = max(0.0, targetCellStartX)
                    if let existingPara = storage.attribute(.paragraphStyle, at: row.lineRange.location, effectiveRange: nil) as? NSParagraphStyle,
                       let mutablePara = existingPara.mutableCopy() as? NSMutableParagraphStyle {
                        mutablePara.firstLineHeadIndent = firstLineIndent
                        mutablePara.headIndent = firstLineIndent
                        storage.addAttribute(.paragraphStyle, value: mutablePara, range: row.lineRange)
                    }
                    currentCursorX = targetCellStartX + actualCellW
                }
            }
        }

        // Append inline decorations (inline code pills, inline math) after tableRow backgrounds so they render on top
        decorations.append(contentsOf: inlineTableDecorations)
    }

    // MARK: - Inline Markdown Styling
    private static func sortedRangesOverlap(_ ranges: [NSRange], _ target: NSRange) -> Bool {
        guard !ranges.isEmpty, target.length > 0 else { return false }
        let targetEnd = target.location + target.length
        var low = 0
        var high = ranges.count
        while low < high {
            let mid = (low + high) >> 1
            let r = ranges[mid]
            if r.location + r.length <= target.location {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low < ranges.count && ranges[low].location < targetEnd
    }

    private static func insertSortedRange(_ range: NSRange, into ranges: inout [NSRange]) {
        guard range.length > 0 else { return }
        if let last = ranges.last, last.location <= range.location {
            ranges.append(range)
            return
        }
        var low = 0
        var high = ranges.count
        while low < high {
            let mid = (low + high) >> 1
            if ranges[mid].location < range.location {
                low = mid + 1
            } else {
                high = mid
            }
        }
        ranges.insert(range, at: low)
    }

    private static func reserveMediaCardHeight(in storage: NSTextStorage, lineRange: NSRange, targetHeight: CGFloat) {
        guard lineRange.length > 0, lineRange.location < storage.length else { return }
        let currentPara = (storage.attribute(.paragraphStyle, at: lineRange.location, effectiveRange: nil) as? NSParagraphStyle)
        let mutablePara = (currentPara?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        mutablePara.minimumLineHeight = max(mutablePara.minimumLineHeight, targetHeight)
        mutablePara.maximumLineHeight = max(mutablePara.maximumLineHeight, targetHeight)
        storage.addAttribute(.paragraphStyle, value: mutablePara, range: lineRange)
    }

    private static func parseHTMLMediaAttributes(attrsStr: String) -> (src: String, alt: String, width: CGFloat?, height: CGFloat?) {
        let attrsNS = attrsStr as NSString
        var src = ""
        var alt = ""
        var widthVal: CGFloat? = nil
        var heightVal: CGFloat? = nil

        htmlAttrRegex.enumerateMatches(in: attrsStr, options: [], range: NSRange(location: 0, length: attrsNS.length)) { attrMatch, _, _ in
            guard let attrMatch = attrMatch else { return }
            let name = attrsNS.substring(with: attrMatch.range(at: 1)).lowercased()
            let valRange: NSRange
            if attrMatch.range(at: 2).location != NSNotFound {
                valRange = attrMatch.range(at: 2)
            } else if attrMatch.range(at: 3).location != NSNotFound {
                valRange = attrMatch.range(at: 3)
            } else if attrMatch.range(at: 4).location != NSNotFound {
                valRange = attrMatch.range(at: 4)
            } else {
                return
            }
            let val = attrsNS.substring(with: valRange)
            switch name {
            case "src":
                src = val
            case "alt", "title", "poster":
                if alt.isEmpty || name == "alt" { alt = val }
            case "width":
                let numStr = val.replacingOccurrences(of: "px", with: "")
                if let d = Double(numStr), d > 0 { widthVal = CGFloat(d) }
            case "height":
                let numStr = val.replacingOccurrences(of: "px", with: "")
                if let d = Double(numStr), d > 0 { heightVal = CGFloat(d) }
            default:
                break
            }
        }
        return (src, alt, widthVal, heightVal)
    }

    private static func styleInlineMarkdown(
        in storage: NSTextStorage,
        string: String,
        range: NSRange,
        lineRange: NSRange? = nil,
        baseFont: NSFont,
        isActiveLine: Bool,
        theme: EditorTheme,
        dimFactor: CGFloat,
        normalizeWhitespace: Bool = false,
        prettyMode: Bool = true,
        baseDirectoryURL: URL? = nil,
        decorations: inout [LineDecoration]
    ) {
        guard range.length > 0 else { return }
        let nsString = string as NSString
        let fontSize = baseFont.pointSize
        let effectiveLineRange = lineRange ?? range

        // Ranges inside inline code or inline math are completely opaque to other inline syntax
        var codeAndMathRanges: [NSRange] = []
        // Ranges of escaped characters or link URL destinations `(url)` cannot act as emphasis delimiters
        var protectedDelimiterRanges: [NSRange] = []

        let isInCodeOrMath: (NSRange) -> Bool = { r in
            sortedRangesOverlap(codeAndMathRanges, r)
        }
        let isDelimiterProtected: (NSRange) -> Bool = { r in
            sortedRangesOverlap(codeAndMathRanges, r) || sortedRangesOverlap(protectedDelimiterRanges, r)
        }

        // 1. Inline Code (`code` or `` ` ``) - highest precedence in CommonMark (even `\` inside code is literal)
        let codeSpans = scanInlineCodeSpans(nsString: nsString, range: range)
        if !codeSpans.isEmpty {
            let codeFontSize = fontSize * 0.88
            let codeFont = theme.codeFont(size: codeFontSize)
            let inlineCodeAttrs: [NSAttributedString.Key: Any] = [
                .font: codeFont,
                .foregroundColor: theme.inlineCodeNSColor.withAlphaComponent(dimFactor),
                inlineCodeFontAttributeKey: true
            ]
            for codeSpan in codeSpans {
                let fullMatchRange = codeSpan.fullRange
                insertSortedRange(fullMatchRange, into: &codeAndMathRanges)

                var openRange = codeSpan.openRange
                var innerRange = codeSpan.innerRange
                var closeRange = codeSpan.closeRange

                // CommonMark rule: if code span has a leading AND trailing space (and is not all spaces), strip one space from each end
                if innerRange.length >= 2 {
                    let firstChar = nsString.character(at: innerRange.location)
                    let lastChar = nsString.character(at: NSMaxRange(innerRange) - 1)
                    let innerSub = nsString.substring(with: innerRange)
                    if firstChar == 32 && lastChar == 32 && innerSub.contains(where: { $0 != " " }) {
                        openRange.length += 1
                        innerRange.location += 1
                        innerRange.length -= 2
                        closeRange.location -= 1
                        closeRange.length += 1
                    }
                }

                storage.addAttributes(inlineCodeAttrs, range: innerRange)
                decorations.append(LineDecoration(
                    lineRange: innerRange,
                    kind: .inlineCode(range: innerRange, fontSize: codeFontSize, dimFactor: dimFactor)
                ))
                styleSyntaxToken(in: storage, range: openRange, isActiveLine: isActiveLine, theme: theme, dimFactor: dimFactor)
                styleSyntaxToken(in: storage, range: closeRange, isActiveLine: isActiveLine, theme: theme, dimFactor: dimFactor)
            }
        }

        // 2. Inline Math ($E = mc^2$)
        inlineMathRegex.enumerateMatches(in: string, options: [], range: range) { match, _, _ in
            guard let match = match else { return }
            let fullMatchRange = match.range(at: 0)
            if isInCodeOrMath(fullMatchRange) {
                return
            }
            insertSortedRange(fullMatchRange, into: &codeAndMathRanges)

            let openRange = match.range(at: 1)
            let innerRange = match.range(at: 2)
            let closeRange = match.range(at: 3)
            let latexStr = nsString.substring(with: innerRange)

            if isActiveLine {
                let mathMono = theme.codeFont(size: fontSize * 0.90)
                storage.addAttributes([
                    .font: mathMono,
                    .foregroundColor: theme.textNSColor.withAlphaComponent(dimFactor),
                    .backgroundColor: theme.codeBackgroundNSColor.withAlphaComponent(0.55 * dimFactor)
                ], range: innerRange)
                highlightLaTeXSource(in: storage, range: innerRange, theme: theme, dimFactor: dimFactor)
                styleSyntaxToken(in: storage, range: openRange, isActiveLine: true, theme: theme, dimFactor: dimFactor)
                styleSyntaxToken(in: storage, range: closeRange, isActiveLine: true, theme: theme, dimFactor: dimFactor)
            } else {
                let mathBox = LaTeXMathRenderer.layoutLatex(latexStr, baseFontSize: fontSize, isDisplayStyle: false)
                let targetWidth = max(12.0, mathBox.width + 6.0)

                let tinyFont = NSFont.monospacedSystemFont(ofSize: 2.0, weight: .regular)
                let rawSubstr = nsString.substring(with: fullMatchRange) as NSString
                let baseW = rawSubstr.size(withAttributes: [.font: tinyFont]).width
                let perCharKern = (targetWidth - baseW) / CGFloat(max(1, fullMatchRange.length))

                storage.addAttributes([
                    .font: tinyFont,
                    .foregroundColor: NSColor.clear,
                    .kern: perCharKern
                ], range: fullMatchRange)

                decorations.append(LineDecoration(
                    lineRange: fullMatchRange,
                    kind: .inlineMathRendered(
                        latex: latexStr,
                        range: fullMatchRange,
                        fontSize: fontSize,
                        dimFactor: dimFactor
                    )
                ))
            }
        }

        // 3. Backslash escapes (\*, \_, \|, \[, etc.) outside inline code/math
        escapeRegex.enumerateMatches(in: string, options: [], range: range) { match, _, _ in
            guard let match = match, !isInCodeOrMath(match.range) else { return }
            let slashRange = NSRange(location: match.range.location, length: 1)
            let escapedCharRange = match.range(at: 1)
            insertSortedRange(match.range, into: &protectedDelimiterRanges)
            styleSyntaxToken(in: storage, range: slashRange, isActiveLine: isActiveLine, theme: theme, dimFactor: dimFactor)
            _ = escapedCharRange
        }

        // 4. HTML <br/> tags outside inline code/math
        htmlBrRegex.enumerateMatches(in: string, options: [], range: range) { match, _, _ in
            guard let match = match, !isInCodeOrMath(match.range) else { return }
            insertSortedRange(match.range, into: &protectedDelimiterRanges)
            styleSyntaxToken(in: storage, range: match.range, isActiveLine: isActiveLine || !prettyMode, theme: theme, dimFactor: dimFactor)
            if !isActiveLine && prettyMode && match.range.length > 0 {
                storage.addAttribute(.kern, value: 6.0, range: NSRange(location: match.range.location, length: 1))
            }
        }

        let currentParaTail = (storage.attribute(.paragraphStyle, at: effectiveLineRange.location, effectiveRange: nil) as? NSParagraphStyle)?.tailIndent ?? 0.0
        let maxMediaColumnWidth = currentParaTail > 120.0 ? max(200.0, currentParaTail - 16.0) : 660.0

        // 5. Links ([label](url)), Images (![alt](url)), and Anchor Images ([![alt](img_url)](link_url)) — scanned with code-span & balanced-paren awareness
        let linkMatches = scanMarkdownLinks(nsString: nsString, range: range, isDelimiterProtected: isDelimiterProtected)
        for link in linkMatches {
            if link.isImage && prettyMode && !isActiveLine && !link.url.isEmpty {
                insertSortedRange(link.fullRange, into: &protectedDelimiterRanges)
                let altStr = nsString.substring(with: link.labelRange)
                let display = FolioMediaImageCache.shared.displaySize(
                    for: link.url,
                    explicitWidth: nil,
                    explicitHeight: nil,
                    maxColumnWidth: maxMediaColumnWidth,
                    baseDirectoryURL: baseDirectoryURL,
                    isDark: theme.isDark
                )
                let targetH = display.isLoaded ? max(26.0, display.size.height + 10.0) : 52.0
                reserveMediaCardHeight(in: storage, lineRange: effectiveLineRange, targetHeight: targetH)
                collapseWhitespaceRange(in: storage, range: link.fullRange)
                decorations.append(LineDecoration(
                    lineRange: effectiveLineRange,
                    kind: .imageRendered(
                        url: link.url,
                        alt: altStr,
                        fullRange: link.fullRange,
                        explicitWidth: nil,
                        explicitHeight: nil,
                        baseDirectoryURL: baseDirectoryURL,
                        dimFactor: dimFactor
                    )
                ))
            } else {
                insertSortedRange(link.openSyntaxRange, into: &protectedDelimiterRanges)
                insertSortedRange(link.trailingSyntaxRange, into: &protectedDelimiterRanges)

                applyAttributesToVisibleCharacters(
                    in: storage,
                    range: link.labelRange,
                    attributes: [
                        .foregroundColor: theme.linkNSColor.withAlphaComponent(dimFactor),
                        .underlineStyle: NSUnderlineStyle.single.rawValue
                    ]
                )
                let showTokens = isActiveLine || (link.isImage && !prettyMode)
                styleSyntaxToken(in: storage, range: link.openSyntaxRange, isActiveLine: showTokens, theme: theme, dimFactor: dimFactor)
                styleSyntaxToken(in: storage, range: link.trailingSyntaxRange, isActiveLine: showTokens, theme: theme, dimFactor: dimFactor)
            }
        }

        // 5b. Autolinks (<https://...> or <user@example.com>)
        autolinkRegex.enumerateMatches(in: string, options: [], range: range) { match, _, _ in
            guard let match = match, !isDelimiterProtected(match.range) else { return }
            let openAngle = match.range(at: 1)
            let urlRange = match.range(at: 2)
            let closeAngle = match.range(at: 3)
            insertSortedRange(match.range, into: &protectedDelimiterRanges)

            applyAttributesToVisibleCharacters(
                in: storage,
                range: urlRange,
                attributes: [
                    .foregroundColor: theme.linkNSColor.withAlphaComponent(dimFactor),
                    .underlineStyle: NSUnderlineStyle.single.rawValue
                ]
            )
            styleSyntaxToken(in: storage, range: openAngle, isActiveLine: isActiveLine, theme: theme, dimFactor: dimFactor)
            styleSyntaxToken(in: storage, range: closeAngle, isActiveLine: isActiveLine, theme: theme, dimFactor: dimFactor)
        }

        // 5c. HTML <img ...> and <video ...> tags
        for mediaRegex in [htmlImgTagRegex, htmlVideoTagRegex] {
            mediaRegex.enumerateMatches(in: string, options: [], range: range) { match, _, _ in
                guard let match = match, !isDelimiterProtected(match.range) else { return }
                insertSortedRange(match.range, into: &protectedDelimiterRanges)

                let attrsStr = nsString.substring(with: match.range(at: 1))
                var (src, alt, widthVal, heightVal) = parseHTMLMediaAttributes(attrsStr: attrsStr)
                if src.isEmpty && match.numberOfRanges > 2 && match.range(at: 2).location != NSNotFound {
                    let innerStr = nsString.substring(with: match.range(at: 2))
                    let innerParsed = parseHTMLMediaAttributes(attrsStr: innerStr)
                    if !innerParsed.src.isEmpty {
                        src = innerParsed.src
                    }
                }

                if prettyMode && !isActiveLine && !src.isEmpty {
                    let isVideo = FolioMediaImageCache.isVideoURL(src) || (mediaRegex === htmlVideoTagRegex)
                    let display = FolioMediaImageCache.shared.displaySize(
                        for: src,
                        explicitWidth: widthVal,
                        explicitHeight: heightVal,
                        maxColumnWidth: maxMediaColumnWidth,
                        baseDirectoryURL: baseDirectoryURL,
                        isDark: theme.isDark
                    )
                    let targetH: CGFloat
                    if display.isLoaded {
                        targetH = max(26.0, display.size.height + 10.0)
                    } else if isVideo {
                        targetH = 56.0
                    } else {
                        targetH = 52.0
                    }
                    reserveMediaCardHeight(in: storage, lineRange: effectiveLineRange, targetHeight: targetH)
                    collapseWhitespaceRange(in: storage, range: match.range)
                    decorations.append(LineDecoration(
                        lineRange: effectiveLineRange,
                        kind: .imageRendered(
                            url: src,
                            alt: alt,
                            fullRange: match.range,
                            explicitWidth: widthVal,
                            explicitHeight: heightVal,
                            baseDirectoryURL: baseDirectoryURL,
                            dimFactor: dimFactor
                        )
                    ))
                } else {
                    styleSyntaxToken(in: storage, range: match.range, isActiveLine: true, theme: theme, dimFactor: dimFactor)
                }
            }
        }

        // 5d. Inline HTML paired markup (<kbd>, <u>, <ins>, <mark>, <sup>, <sub>, <b>, <strong>, <i>, <em>, <s>, <del>, <code>, <summary>)
        htmlPairedTagRegex.enumerateMatches(in: string, options: [], range: range) { match, _, _ in
            guard let match = match else { return }
            let openTagRange = match.range(at: 1)
            let tagNameRange = match.range(at: 2)
            let innerRange = match.range(at: 3)
            let closeTagRange = match.range(at: 4)
            guard !isDelimiterProtected(openTagRange), !isDelimiterProtected(closeTagRange) else { return }

            insertSortedRange(openTagRange, into: &protectedDelimiterRanges)
            insertSortedRange(closeTagRange, into: &protectedDelimiterRanges)

            let tagName = nsString.substring(with: tagNameRange).lowercased()
            let showRawTag = isActiveLine || !prettyMode

            if prettyMode && innerRange.length > 0 {
                switch tagName {
                case "kbd":
                    let kbdFontSize = fontSize * 0.84
                    let kbdFont = theme.codeFont(size: kbdFontSize)
                    applyAttributesToVisibleCharacters(
                        in: storage,
                        range: innerRange,
                        attributes: [
                            .font: kbdFont,
                            .foregroundColor: theme.textNSColor.withAlphaComponent(dimFactor),
                            inlineCodeFontAttributeKey: true
                        ]
                    )
                    decorations.append(LineDecoration(
                        lineRange: innerRange,
                        kind: .kbdPill(range: innerRange, fontSize: kbdFontSize, dimFactor: dimFactor)
                    ))
                case "u", "ins":
                    applyAttributesToVisibleCharacters(
                        in: storage,
                        range: innerRange,
                        attributes: [.underlineStyle: NSUnderlineStyle.single.rawValue]
                    )
                case "mark":
                    let highlightBg = theme.isDark
                        ? NSColor(srgbRed: 0.55, green: 0.45, blue: 0.12, alpha: 0.55 * dimFactor)
                        : NSColor(srgbRed: 1.0, green: 0.93, blue: 0.45, alpha: 0.65 * dimFactor)
                    applyAttributesToVisibleCharacters(
                        in: storage,
                        range: innerRange,
                        attributes: [.backgroundColor: highlightBg]
                    )
                case "sup":
                    let subFont = theme.bodyFont(size: fontSize * 0.74)
                    applyAttributesToVisibleCharacters(
                        in: storage,
                        range: innerRange,
                        attributes: [
                            .font: subFont,
                            .baselineOffset: fontSize * 0.32
                        ]
                    )
                case "sub":
                    let subFont = theme.bodyFont(size: fontSize * 0.74)
                    applyAttributesToVisibleCharacters(
                        in: storage,
                        range: innerRange,
                        attributes: [
                            .font: subFont,
                            .baselineOffset: -fontSize * 0.18
                        ]
                    )
                case "b", "strong", "summary":
                    applyFontTraitToVisibleCharacters(in: storage, range: innerRange, trait: .boldFontMask, fallbackFont: baseFont)
                case "i", "em":
                    applyFontTraitToVisibleCharacters(in: storage, range: innerRange, trait: .italicFontMask, fallbackFont: baseFont)
                case "s", "del", "strike":
                    applyAttributesToVisibleCharacters(
                        in: storage,
                        range: innerRange,
                        attributes: [
                            .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                            .foregroundColor: theme.secondaryTextNSColor.withAlphaComponent(dimFactor)
                        ]
                    )
                case "code":
                    let codeFontSize = fontSize * 0.88
                    let codeFont = theme.codeFont(size: codeFontSize)
                    applyAttributesToVisibleCharacters(
                        in: storage,
                        range: innerRange,
                        attributes: [
                            .font: codeFont,
                            .foregroundColor: theme.inlineCodeNSColor.withAlphaComponent(dimFactor),
                            inlineCodeFontAttributeKey: true
                        ]
                    )
                    decorations.append(LineDecoration(
                        lineRange: innerRange,
                        kind: .inlineCode(range: innerRange, fontSize: codeFontSize, dimFactor: dimFactor)
                    ))
                default:
                    break
                }
            }

            styleSyntaxToken(in: storage, range: openTagRange, isActiveLine: showRawTag, theme: theme, dimFactor: dimFactor)
            styleSyntaxToken(in: storage, range: closeTagRange, isActiveLine: showRawTag, theme: theme, dimFactor: dimFactor)
        }

        // 5e. HTML <details> and </details> tags
        htmlDetailsTagRegex.enumerateMatches(in: string, options: [], range: range) { match, _, _ in
            guard let match = match, !isDelimiterProtected(match.range) else { return }
            insertSortedRange(match.range, into: &protectedDelimiterRanges)
            styleSyntaxToken(in: storage, range: match.range, isActiveLine: isActiveLine || !prettyMode, theme: theme, dimFactor: dimFactor)
        }

        // 6. Bold + Italic (***text*** or ___text___)
        boldItalicRegex.enumerateMatches(in: string, options: [], range: range) { match, _, _ in
            guard let match = match else { return }
            let innerRange = match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range(at: 2)
            guard innerRange.location != NSNotFound else { return }
            let openRange = NSRange(location: match.range.location, length: 3)
            let closeRange = NSRange(location: NSMaxRange(innerRange), length: 3)
            guard !isDelimiterProtected(openRange), !isDelimiterProtected(closeRange) else { return }

            insertSortedRange(openRange, into: &protectedDelimiterRanges)
            insertSortedRange(closeRange, into: &protectedDelimiterRanges)
            applyFontTraitToVisibleCharacters(in: storage, range: innerRange, trait: [.boldFontMask, .italicFontMask], fallbackFont: baseFont)
            styleSyntaxToken(in: storage, range: openRange, isActiveLine: isActiveLine, theme: theme, dimFactor: dimFactor)
            styleSyntaxToken(in: storage, range: closeRange, isActiveLine: isActiveLine, theme: theme, dimFactor: dimFactor)
        }

        // 7. Bold (**text** or __text__)
        for regex in [boldAsteriskRegex, boldUnderscoreRegex] {
            regex.enumerateMatches(in: string, options: [], range: range) { match, _, _ in
                guard let match = match else { return }
                let innerRange = match.range(at: 1)
                let openRange = NSRange(location: match.range.location, length: 2)
                let closeRange = NSRange(location: NSMaxRange(innerRange), length: 2)
                guard !isDelimiterProtected(openRange), !isDelimiterProtected(closeRange) else { return }

                insertSortedRange(openRange, into: &protectedDelimiterRanges)
                insertSortedRange(closeRange, into: &protectedDelimiterRanges)
                applyFontTraitToVisibleCharacters(in: storage, range: innerRange, trait: .boldFontMask, fallbackFont: baseFont)
                styleSyntaxToken(in: storage, range: openRange, isActiveLine: isActiveLine, theme: theme, dimFactor: dimFactor)
                styleSyntaxToken(in: storage, range: closeRange, isActiveLine: isActiveLine, theme: theme, dimFactor: dimFactor)
            }
        }

        // 8. Italic (*text* or _text_)
        for regex in [italicAsteriskRegex, italicUnderscoreRegex] {
            regex.enumerateMatches(in: string, options: [], range: range) { match, _, _ in
                guard let match = match else { return }
                let innerRange = match.range(at: 1)
                let openRange = NSRange(location: match.range.location, length: 1)
                let closeRange = NSRange(location: NSMaxRange(innerRange), length: 1)
                guard !isDelimiterProtected(openRange), !isDelimiterProtected(closeRange) else { return }

                insertSortedRange(openRange, into: &protectedDelimiterRanges)
                insertSortedRange(closeRange, into: &protectedDelimiterRanges)
                applyFontTraitToVisibleCharacters(in: storage, range: innerRange, trait: .italicFontMask, fallbackFont: baseFont)
                styleSyntaxToken(in: storage, range: openRange, isActiveLine: isActiveLine, theme: theme, dimFactor: dimFactor)
                styleSyntaxToken(in: storage, range: closeRange, isActiveLine: isActiveLine, theme: theme, dimFactor: dimFactor)
            }
        }

        // 9. Strikethrough (~~text~~)
        strikeRegex.enumerateMatches(in: string, options: [], range: range) { match, _, _ in
            guard let match = match else { return }
            let openRange = match.range(at: 1)
            let innerRange = match.range(at: 2)
            let closeRange = match.range(at: 3)
            guard !isDelimiterProtected(openRange), !isDelimiterProtected(closeRange) else { return }

            insertSortedRange(openRange, into: &protectedDelimiterRanges)
            insertSortedRange(closeRange, into: &protectedDelimiterRanges)
            applyAttributesToVisibleCharacters(
                in: storage,
                range: innerRange,
                attributes: [
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    .foregroundColor: theme.secondaryTextNSColor.withAlphaComponent(dimFactor)
                ]
            )
            styleSyntaxToken(in: storage, range: openRange, isActiveLine: isActiveLine, theme: theme, dimFactor: dimFactor)
            styleSyntaxToken(in: storage, range: closeRange, isActiveLine: isActiveLine, theme: theme, dimFactor: dimFactor)
        }

        // 10. Highlight (==text==)
        highlightRegex.enumerateMatches(in: string, options: [], range: range) { match, _, _ in
            guard let match = match else { return }
            let openRange = match.range(at: 1)
            let innerRange = match.range(at: 2)
            let closeRange = match.range(at: 3)
            guard !isDelimiterProtected(openRange), !isDelimiterProtected(closeRange) else { return }

            insertSortedRange(openRange, into: &protectedDelimiterRanges)
            insertSortedRange(closeRange, into: &protectedDelimiterRanges)
            let highlightBg = theme.isDark
                ? NSColor(srgbRed: 0.55, green: 0.45, blue: 0.12, alpha: 0.55 * dimFactor)
                : NSColor(srgbRed: 1.0, green: 0.93, blue: 0.45, alpha: 0.65 * dimFactor)
            applyAttributesToVisibleCharacters(
                in: storage,
                range: innerRange,
                attributes: [.backgroundColor: highlightBg]
            )
            styleSyntaxToken(in: storage, range: openRange, isActiveLine: isActiveLine, theme: theme, dimFactor: dimFactor)
            styleSyntaxToken(in: storage, range: closeRange, isActiveLine: isActiveLine, theme: theme, dimFactor: dimFactor)
        }

        // 11. CommonMark Whitespace Normalization on inactive lines (outside inline code & math)
        if normalizeWhitespace && !isActiveLine {
            normalizeProseWhitespace(
                in: storage,
                string: string,
                range: range,
                isInCodeOrMath: isInCodeOrMath
            )
        }
    }

    private struct ScannedInlineCodeSpan {
        let fullRange: NSRange
        let openRange: NSRange
        let innerRange: NSRange
        let closeRange: NSRange
    }

    /// Linear-time $O(N)$ CommonMark inline code span scanner.
    /// Collects contiguous backtick runs in a single pass and pairs matching run lengths without quadratic rescanning.
    private static func scanInlineCodeSpans(nsString: NSString, range: NSRange) -> [ScannedInlineCodeSpan] {
        let end = NSMaxRange(range)
        var runs: [(location: Int, length: Int)] = []
        var runsByLength: [Int: [Int]] = [:]

        var idx = range.location
        while idx < end {
            let ch = nsString.character(at: idx)
            if ch == 0x0A { // '\n' - inline code in single-line styler does not cross line breaks
                idx += 1
                continue
            }
            if ch == 0x60 { // '`'
                let start = idx
                while idx < end && nsString.character(at: idx) == 0x60 {
                    idx += 1
                }
                let len = idx - start
                let runIdx = runs.count
                runs.append((location: start, length: len))
                runsByLength[len, default: []].append(runIdx)
            } else {
                idx += 1
            }
        }

        guard runs.count >= 2 else { return [] }

        var results: [ScannedInlineCodeSpan] = []
        var cursorByLength: [Int: Int] = [:]
        var i = 0
        while i < runs.count {
            let openRun = runs[i]
            guard let candidates = runsByLength[openRun.length] else {
                i += 1
                continue
            }
            var cursor = cursorByLength[openRun.length] ?? 0
            while cursor < candidates.count && candidates[cursor] <= i {
                cursor += 1
            }
            cursorByLength[openRun.length] = cursor

            if cursor < candidates.count {
                let closeRunIdx = candidates[cursor]
                let closeRun = runs[closeRunIdx]
                let openEnd = openRun.location + openRun.length
                let innerLen = closeRun.location - openEnd
                if innerLen > 0 {
                    let fullRange = NSRange(location: openRun.location, length: (closeRun.location + closeRun.length) - openRun.location)
                    let openRange = NSRange(location: openRun.location, length: openRun.length)
                    let innerRange = NSRange(location: openEnd, length: innerLen)
                    let closeRange = NSRange(location: closeRun.location, length: closeRun.length)
                    results.append(ScannedInlineCodeSpan(
                        fullRange: fullRange,
                        openRange: openRange,
                        innerRange: innerRange,
                        closeRange: closeRange
                    ))
                    cursorByLength[openRun.length] = cursor + 1
                    i = closeRunIdx + 1
                    continue
                }
            }
            i += 1
        }

        return results
    }

    private struct ScannedMarkdownLink {
        let isImage: Bool
        let fullRange: NSRange
        let openSyntaxRange: NSRange      // `[` or `![`
        let labelRange: NSRange           // `label`
        let trailingSyntaxRange: NSRange  // `](url)`
        let url: String
    }

    /// Linear-time $O(N)$ Markdown link & image scanner (`[label](url)` and `![alt](url)`).
    /// Precomputes balanced parentheses in one pass and uses an explicit bracket stack to avoid $O(N^2)$ rescanning on unmatched `[` or `](`.
    private static func scanMarkdownLinks(
        nsString: NSString,
        range: NSRange,
        isDelimiterProtected: (NSRange) -> Bool
    ) -> [ScannedMarkdownLink] {
        let end = NSMaxRange(range)
        guard range.length >= 4 else { return [] }

        // Pass 1: Precompute matching ')' for every '(' in O(N) time using a stack
        var matchingCloseParen: [Int: Int] = [:]
        var parenStack: [Int] = []
        var pIdx = range.location
        while pIdx < end {
            let ch = nsString.character(at: pIdx)
            if ch == 0x5C { // '\' escape
                pIdx += 2
                continue
            }
            if ch == 0x28 { // '('
                if !isDelimiterProtected(NSRange(location: pIdx, length: 1)) {
                    parenStack.append(pIdx)
                }
            } else if ch == 0x29 { // ')'
                if !isDelimiterProtected(NSRange(location: pIdx, length: 1)),
                   let openParen = parenStack.popLast() {
                    matchingCloseParen[openParen] = pIdx
                }
            }
            pIdx += 1
        }

        // Pass 2: Single linear scan with an open-bracket stack
        struct OpenBracketEntry {
            let openStart: Int
            let bracketPos: Int
            let isImage: Bool
        }

        var results: [ScannedMarkdownLink] = []
        var openStack: [OpenBracketEntry] = []
        var idx = range.location

        while idx < end {
            let ch = nsString.character(at: idx)
            if ch == 0x21 && idx + 1 < end && nsString.character(at: idx + 1) == 0x5B { // `![`
                let openSyntaxRange = NSRange(location: idx, length: 2)
                if !isDelimiterProtected(openSyntaxRange) {
                    openStack.append(OpenBracketEntry(openStart: idx, bracketPos: idx + 1, isImage: true))
                    idx += 2
                    continue
                }
            } else if ch == 0x5B { // `[`
                let openSyntaxRange = NSRange(location: idx, length: 1)
                if !isDelimiterProtected(openSyntaxRange) {
                    openStack.append(OpenBracketEntry(openStart: idx, bracketPos: idx, isImage: false))
                    idx += 1
                    continue
                }
            } else if ch == 0x5D { // `]`
                let closeRange = NSRange(location: idx, length: 1)
                if !isDelimiterProtected(closeRange), let open = openStack.popLast() {
                    if idx + 1 < end,
                       nsString.character(at: idx + 1) == 0x28,
                       !isDelimiterProtected(NSRange(location: idx, length: 2)),
                       let closeParen = matchingCloseParen[idx + 1] {
                        let labelRange = NSRange(location: open.bracketPos + 1, length: idx - (open.bracketPos + 1))
                        if labelRange.length > 0 || open.isImage {
                            let rawDestRange = NSRange(location: idx + 2, length: max(0, closeParen - (idx + 2)))
                            var rawDest = nsString.substring(with: rawDestRange).trimmingCharacters(in: .whitespacesAndNewlines)
                            if rawDest.hasPrefix("<"), let closeAngleIdx = rawDest.firstIndex(of: ">") {
                                rawDest = String(rawDest[rawDest.index(after: rawDest.startIndex)..<closeAngleIdx])
                            } else if let spaceIdx = rawDest.firstIndex(where: { $0 == " " || $0 == "\t" }) {
                                rawDest = String(rawDest[..<spaceIdx])
                            }

                            // Check for anchor image `[![alt](img_url)](link_url)`
                            if open.isImage,
                               let outer = openStack.last,
                               !outer.isImage,
                               outer.openStart + 1 == open.openStart,
                               closeParen + 2 < end,
                               nsString.character(at: closeParen + 1) == 0x5D,
                               nsString.character(at: closeParen + 2) == 0x28,
                               !isDelimiterProtected(NSRange(location: closeParen + 1, length: 2)),
                               let outerCloseParen = matchingCloseParen[closeParen + 2] {
                                openStack.removeLast()
                                let openSyntaxRange = NSRange(location: outer.openStart, length: 3)
                                let trailingRange = NSRange(location: idx, length: (outerCloseParen + 1) - idx)
                                let fullRange = NSRange(location: outer.openStart, length: (outerCloseParen + 1) - outer.openStart)
                                results.append(ScannedMarkdownLink(
                                    isImage: true,
                                    fullRange: fullRange,
                                    openSyntaxRange: openSyntaxRange,
                                    labelRange: labelRange,
                                    trailingSyntaxRange: trailingRange,
                                    url: rawDest
                                ))
                                openStack.removeAll(keepingCapacity: true)
                                idx = outerCloseParen + 1
                                continue
                            }

                            let openSyntaxRange = NSRange(location: open.openStart, length: open.isImage ? 2 : 1)
                            let trailingRange = NSRange(location: idx, length: (closeParen + 1) - idx)
                            let fullRange = NSRange(location: open.openStart, length: (closeParen + 1) - open.openStart)
                            results.append(ScannedMarkdownLink(
                                isImage: open.isImage,
                                fullRange: fullRange,
                                openSyntaxRange: openSyntaxRange,
                                labelRange: labelRange,
                                trailingSyntaxRange: trailingRange,
                                url: rawDest
                            ))
                            if !open.isImage {
                                openStack.removeAll(keepingCapacity: true)
                            }
                            idx = closeParen + 1
                            continue
                        }
                    }
                }
            }
            idx += 1
        }

        return results
    }

    private static func applyFontTraitToVisibleCharacters(
        in storage: NSTextStorage,
        range: NSRange,
        trait: NSFontTraitMask,
        fallbackFont: NSFont
    ) {
        guard range.length > 0 else { return }
        storage.enumerateAttributes(in: range, options: []) { attrs, subrange, _ in
            if attrs[collapsedTokenAttributeKey] != nil {
                return
            }
            let currentFont = (attrs[.font] as? NSFont) ?? fallbackFont
            let converted = NSFontManager.shared.convert(currentFont, toHaveTrait: trait)
            storage.addAttribute(.font, value: converted, range: subrange)
        }
    }

    private static func applyAttributesToVisibleCharacters(
        in storage: NSTextStorage,
        range: NSRange,
        attributes: [NSAttributedString.Key: Any]
    ) {
        guard range.length > 0 else { return }
        storage.enumerateAttributes(in: range, options: []) { attrs, subrange, _ in
            if attrs[collapsedTokenAttributeKey] != nil {
                return
            }
            storage.addAttributes(attributes, range: subrange)
        }
    }

    private static func normalizeProseWhitespace(
        in storage: NSTextStorage,
        string: String,
        range: NSRange,
        isInCodeOrMath: (NSRange) -> Bool
    ) {
        guard range.length > 0 else { return }

        // 1-2. Collapse leading and trailing spaces/tabs on each source line of the range
        for regex in [leadingSpaceRegex, trailingSpaceRegex] {
            regex.enumerateMatches(in: string, options: [], range: range) { match, _, _ in
                guard let match = match, match.range.length > 0, !isInCodeOrMath(match.range) else { return }
                collapseWhitespaceRange(in: storage, range: match.range)
            }
        }

        // 3. Collapse extra spaces in runs of 2+ internal spaces/tabs (preserving the first space)
        multiSpaceRegex.enumerateMatches(in: string, options: [], range: range) { match, _, _ in
            guard let match = match, match.range.length >= 2, !isInCodeOrMath(match.range) else { return }
            if storage.attribute(collapsedTokenAttributeKey, at: match.range.location, effectiveRange: nil) != nil {
                return
            }
            let extraRange = NSRange(location: match.range.location + 1, length: match.range.length - 1)
            collapseWhitespaceRange(in: storage, range: extraRange)
        }
    }

    nonisolated(unsafe) private static let collapsedTokenAttributes: [NSAttributedString.Key: Any] = [
        .foregroundColor: NSColor.clear,
        .backgroundColor: NSColor.clear,
        .font: NSFont.systemFont(ofSize: 0.001),
        .kern: 0.0,
        .underlineStyle: 0,
        .strikethroughStyle: 0,
        collapsedTokenAttributeKey: true
    ]

    private static func collapseWhitespaceRange(
        in storage: NSTextStorage,
        range: NSRange
    ) {
        guard range.length > 0 else { return }
        storage.addAttributes(collapsedTokenAttributes, range: range)
    }

    private static func styleSyntaxToken(
        in storage: NSTextStorage,
        range: NSRange,
        isActiveLine: Bool,
        theme: EditorTheme,
        dimFactor: CGFloat
    ) {
        guard range.length > 0 else { return }
        if isActiveLine {
            storage.addAttributes([
                .foregroundColor: theme.markdownTokenNSColor.withAlphaComponent(0.85 * dimFactor),
                .font: theme.codeFont(size: max(11.0, theme.baseFontSize * 0.85))
            ], range: range)
        } else {
            collapseWhitespaceRange(in: storage, range: range)
        }
    }

    private static func highlightLaTeXSource(
        in storage: NSTextStorage,
        range: NSRange,
        theme: EditorTheme,
        dimFactor: CGFloat
    ) {
        guard range.length > 0 else { return }
        let string = storage.string
        latexCommandRegex.enumerateMatches(in: string, options: [], range: range) { match, _, _ in
            if let r = match?.range {
                storage.addAttribute(.foregroundColor, value: theme.linkNSColor.withAlphaComponent(dimFactor), range: r)
            }
        }
        latexBracesRegex.enumerateMatches(in: string, options: [], range: range) { match, _, _ in
            if let r = match?.range {
                storage.addAttribute(.foregroundColor, value: theme.inlineCodeNSColor.withAlphaComponent(dimFactor), range: r)
            }
        }
    }

    // MARK: - Language-Aware Code Fence Syntax Highlighter
    private struct LanguageSyntaxProfile {
        let keywords: NSRegularExpression?
        let typesAndBuiltins: NSRegularExpression?
        let attributesOrMacros: NSRegularExpression?
        let comments: NSRegularExpression?
        let strings: NSRegularExpression
        let numbers: NSRegularExpression
        let functions: NSRegularExpression
        let keywordColorLight: NSColor
        let keywordColorDark: NSColor
    }

    private static let sharedStringsRegex = try! NSRegularExpression(pattern: #""(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`"#)
    private static let sharedNumbersRegex = try! NSRegularExpression(pattern: #"\b(?:0x[0-9a-fA-F]+|\d+(?:\.\d+)?)\b"#)
    private static let sharedFunctionsRegex = try! NSRegularExpression(pattern: #"\b([a-zA-Z_][a-zA-Z0-9_]*)\s*(?=\()"#)

    private static func syntaxProfile(for rawLanguage: String) -> LanguageSyntaxProfile? {
        let lang = rawLanguage.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lang.isEmpty else { return nil }

        switch lang {
        case "swift":
            return LanguageSyntaxProfile(
                keywords: try? NSRegularExpression(pattern: #"\b(func|let|var|struct|class|enum|protocol|extension|import|return|if|else|switch|case|default|for|while|in|guard|try|catch|throw|throws|async|await|public|private|internal|fileprivate|open|static|final|override|mutating|init|deinit|self|super|true|false|nil|where|some|any|typealias|inout|defer|repeat)\b"#),
                typesAndBuiltins: try? NSRegularExpression(pattern: #"\b([A-Z][a-zA-Z0-9_]*)\b"#),
                attributesOrMacros: try? NSRegularExpression(pattern: #"@[a-zA-Z_][a-zA-Z0-9_]*|#[a-zA-Z_][a-zA-Z0-9_]*"#),
                comments: try? NSRegularExpression(pattern: #"//.*$|/\*.*?\*/"#),
                strings: sharedStringsRegex,
                numbers: sharedNumbersRegex,
                functions: sharedFunctionsRegex,
                keywordColorLight: NSColor(srgbRed: 0.68, green: 0.09, blue: 0.54, alpha: 1.0),
                keywordColorDark: NSColor(srgbRed: 0.99, green: 0.37, blue: 0.64, alpha: 1.0)
            )

        case "python", "py":
            return LanguageSyntaxProfile(
                keywords: try? NSRegularExpression(pattern: #"\b(def|class|return|if|elif|else|for|while|in|import|from|as|with|try|except|finally|raise|pass|break|continue|lambda|yield|async|await|global|nonlocal|assert|del|is|not|and|or|True|False|None|self|cls)\b"#),
                typesAndBuiltins: try? NSRegularExpression(pattern: #"\b(int|str|float|bool|list|dict|set|tuple|bytes|object|type|print|len|range|enumerate|zip|map|filter|sorted|super|isinstance|getattr|setattr|open)\b"#),
                attributesOrMacros: try? NSRegularExpression(pattern: #"@[a-zA-Z_][a-zA-Z0-9_\.]*"#),
                comments: try? NSRegularExpression(pattern: #"#.*$"#),
                strings: sharedStringsRegex,
                numbers: sharedNumbersRegex,
                functions: sharedFunctionsRegex,
                keywordColorLight: NSColor(srgbRed: 0.05, green: 0.38, blue: 0.68, alpha: 1.0),
                keywordColorDark: NSColor(srgbRed: 0.38, green: 0.72, blue: 0.98, alpha: 1.0)
            )

        case "javascript", "js", "jsx", "typescript", "ts", "tsx":
            return LanguageSyntaxProfile(
                keywords: try? NSRegularExpression(pattern: #"\b(const|let|var|function|return|if|else|switch|case|default|for|while|do|of|in|import|export|from|default|class|extends|new|this|super|try|catch|finally|throw|async|await|typeof|instanceof|void|delete|yield|interface|type|implements|readonly|public|private|protected|true|false|null|undefined)\b"#),
                typesAndBuiltins: try? NSRegularExpression(pattern: #"\b(Promise|Array|Object|String|Number|Boolean|Map|Set|WeakMap|WeakSet|Date|RegExp|Error|Math|JSON|console|window|document|globalThis|number|string|boolean|any|unknown|never|Record|Partial)\b"#),
                attributesOrMacros: try? NSRegularExpression(pattern: #"@[a-zA-Z_][a-zA-Z0-9_]*"#),
                comments: try? NSRegularExpression(pattern: #"//.*$|/\*.*?\*/"#),
                strings: sharedStringsRegex,
                numbers: sharedNumbersRegex,
                functions: sharedFunctionsRegex,
                keywordColorLight: NSColor(srgbRed: 0.56, green: 0.24, blue: 0.78, alpha: 1.0),
                keywordColorDark: NSColor(srgbRed: 0.78, green: 0.56, blue: 0.98, alpha: 1.0)
            )

        case "rust", "rs":
            return LanguageSyntaxProfile(
                keywords: try? NSRegularExpression(pattern: #"\b(fn|let|mut|const|static|struct|enum|trait|impl|pub|crate|mod|use|as|where|for|in|while|loop|if|else|match|return|break|continue|async|await|move|ref|type|unsafe|extern|dyn|self|Self|super|true|false)\b"#),
                typesAndBuiltins: try? NSRegularExpression(pattern: #"\b(u8|u16|u32|u64|u128|usize|i8|i16|i32|i64|i128|isize|f32|f64|bool|char|str|String|Vec|Option|Result|Some|None|Ok|Err|Box|Rc|Arc|Cow|HashMap|HashSet)\b"#),
                attributesOrMacros: try? NSRegularExpression(pattern: #"#!?\[[^\]]*\]|\b[a-zA-Z_][a-zA-Z0-9_]*!"#),
                comments: try? NSRegularExpression(pattern: #"//.*$|/\*.*?\*/"#),
                strings: sharedStringsRegex,
                numbers: sharedNumbersRegex,
                functions: sharedFunctionsRegex,
                keywordColorLight: NSColor(srgbRed: 0.75, green: 0.28, blue: 0.08, alpha: 1.0),
                keywordColorDark: NSColor(srgbRed: 0.96, green: 0.58, blue: 0.34, alpha: 1.0)
            )

        case "go", "golang":
            return LanguageSyntaxProfile(
                keywords: try? NSRegularExpression(pattern: #"\b(func|package|import|var|const|type|struct|interface|map|chan|go|defer|return|if|else|switch|case|default|select|for|range|break|continue|fallthrough|goto|true|false|nil|iota)\b"#),
                typesAndBuiltins: try? NSRegularExpression(pattern: #"\b(int|int8|int16|int32|int64|uint|uint8|uint16|uint32|uint64|uintptr|float32|float64|complex64|complex128|byte|rune|string|bool|error|any|make|len|cap|new|append|copy|close|delete|panic|recover|print|println)\b"#),
                attributesOrMacros: nil,
                comments: try? NSRegularExpression(pattern: #"//.*$|/\*.*?\*/"#),
                strings: sharedStringsRegex,
                numbers: sharedNumbersRegex,
                functions: sharedFunctionsRegex,
                keywordColorLight: NSColor(srgbRed: 0.0, green: 0.48, blue: 0.62, alpha: 1.0),
                keywordColorDark: NSColor(srgbRed: 0.28, green: 0.82, blue: 0.92, alpha: 1.0)
            )

        case "c", "cpp", "c++", "h", "hpp", "objc", "objective-c":
            return LanguageSyntaxProfile(
                keywords: try? NSRegularExpression(pattern: #"\b(if|else|switch|case|default|for|while|do|return|break|continue|goto|struct|class|union|enum|typedef|using|namespace|template|typename|public|private|protected|virtual|override|final|static|extern|const|constexpr|volatile|inline|sizeof|new|delete|try|catch|throw|nullptr|NULL|true|false)\b"#),
                typesAndBuiltins: try? NSRegularExpression(pattern: #"\b(void|int|long|short|char|float|double|bool|unsigned|signed|size_t|uint8_t|uint16_t|uint32_t|uint64_t|int32_t|int64_t|std|string|vector|map|set|shared_ptr|unique_ptr)\b"#),
                attributesOrMacros: try? NSRegularExpression(pattern: #"^\s*#\s*[a-zA-Z_]+"#),
                comments: try? NSRegularExpression(pattern: #"//.*$|/\*.*?\*/"#),
                strings: sharedStringsRegex,
                numbers: sharedNumbersRegex,
                functions: sharedFunctionsRegex,
                keywordColorLight: NSColor(srgbRed: 0.58, green: 0.12, blue: 0.45, alpha: 1.0),
                keywordColorDark: NSColor(srgbRed: 0.88, green: 0.48, blue: 0.75, alpha: 1.0)
            )

        case "json", "jsonc", "yaml", "yml", "toml":
            return LanguageSyntaxProfile(
                keywords: try? NSRegularExpression(pattern: #"\b(true|false|null|yes|no|on|off)\b"#),
                typesAndBuiltins: nil,
                attributesOrMacros: try? NSRegularExpression(pattern: #""[^"\n]*"\s*(?=:)|^\s*[a-zA-Z0-9_-]+\s*(?=:)"#),
                comments: lang == "json" ? nil : (try? NSRegularExpression(pattern: #"#.*$|//.*$"#)),
                strings: sharedStringsRegex,
                numbers: sharedNumbersRegex,
                functions: sharedFunctionsRegex,
                keywordColorLight: NSColor(srgbRed: 0.12, green: 0.48, blue: 0.34, alpha: 1.0),
                keywordColorDark: NSColor(srgbRed: 0.42, green: 0.85, blue: 0.65, alpha: 1.0)
            )

        case "bash", "sh", "zsh", "shell":
            return LanguageSyntaxProfile(
                keywords: try? NSRegularExpression(pattern: #"\b(if|then|else|elif|fi|for|while|until|do|done|in|case|esac|function|return|exit|export|local|readonly|set|unset|shift|source)\b"#),
                typesAndBuiltins: try? NSRegularExpression(pattern: #"\b(echo|printf|cd|pwd|ls|cp|mv|rm|mkdir|cat|grep|sed|awk|find|xargs|curl|git|swift|npm|npx|python3|brew|chmod|chown)\b"#),
                attributesOrMacros: try? NSRegularExpression(pattern: #"\$[a-zA-Z0-9_@*#?-]+|\$\{[^\}]+\}"#),
                comments: try? NSRegularExpression(pattern: #"#.*$"#),
                strings: sharedStringsRegex,
                numbers: sharedNumbersRegex,
                functions: sharedFunctionsRegex,
                keywordColorLight: NSColor(srgbRed: 0.16, green: 0.46, blue: 0.22, alpha: 1.0),
                keywordColorDark: NSColor(srgbRed: 0.48, green: 0.86, blue: 0.54, alpha: 1.0)
            )

        case "html", "xml", "svg", "css", "scss":
            return LanguageSyntaxProfile(
                keywords: try? NSRegularExpression(pattern: #"</?[a-zA-Z0-9_-]+|/?>|@[a-zA-Z_-]+"#),
                typesAndBuiltins: try? NSRegularExpression(pattern: #"\b[a-zA-Z-]+(?=\s*=|\s*:)"#),
                attributesOrMacros: try? NSRegularExpression(pattern: #"#[0-9a-fA-F]{3,8}\b|\.[a-zA-Z_-][a-zA-Z0-9_-]*"#),
                comments: try? NSRegularExpression(pattern: #"<!--.*?-->|/\*.*?\*/"#),
                strings: sharedStringsRegex,
                numbers: sharedNumbersRegex,
                functions: sharedFunctionsRegex,
                keywordColorLight: NSColor(srgbRed: 0.72, green: 0.14, blue: 0.26, alpha: 1.0),
                keywordColorDark: NSColor(srgbRed: 0.95, green: 0.45, blue: 0.55, alpha: 1.0)
            )

        case "mermaid", "mmd":
            return LanguageSyntaxProfile(
                keywords: try? NSRegularExpression(pattern: #"\b(flowchart|graph|sequenceDiagram|classDiagram|stateDiagram|stateDiagram-v2|pie|erDiagram|subgraph|end|participant|actor|class|title|direction|TD|TB|LR|RL|BT|showData)\b"#),
                typesAndBuiltins: try? NSRegularExpression(pattern: #"-->|-\.->|==>|-->>|->>|--|==|\[\*\]"#),
                attributesOrMacros: try? NSRegularExpression(pattern: #"\|[^\|]+\|"#),
                comments: try? NSRegularExpression(pattern: #"%%.*$"#),
                strings: sharedStringsRegex,
                numbers: sharedNumbersRegex,
                functions: sharedFunctionsRegex,
                keywordColorLight: NSColor(srgbRed: 0.45, green: 0.18, blue: 0.72, alpha: 1.0),
                keywordColorDark: NSColor(srgbRed: 0.76, green: 0.52, blue: 0.98, alpha: 1.0)
            )

        case "sql":
            return LanguageSyntaxProfile(
                keywords: try? NSRegularExpression(pattern: #"(?i)\b(SELECT|FROM|WHERE|INSERT|INTO|VALUES|UPDATE|SET|DELETE|CREATE|TABLE|DROP|ALTER|INDEX|VIEW|JOIN|INNER|LEFT|RIGHT|FULL|ON|AS|AND|OR|NOT|NULL|IS|IN|EXISTS|BETWEEN|LIKE|ORDER|BY|GROUP|HAVING|LIMIT|OFFSET|UNION|ALL|DISTINCT|PRIMARY|KEY|FOREIGN|REFERENCES|DEFAULT|BEGIN|COMMIT|ROLLBACK)\b"#),
                typesAndBuiltins: try? NSRegularExpression(pattern: #"(?i)\b(INT|INTEGER|BIGINT|TEXT|VARCHAR|BOOLEAN|DATE|TIMESTAMP|FLOAT|DOUBLE|DECIMAL|UUID|JSONB|COUNT|SUM|AVG|MIN|MAX|COALESCE|NOW)\b"#),
                attributesOrMacros: nil,
                comments: try? NSRegularExpression(pattern: #"--.*$|/\*.*?\*/"#),
                strings: sharedStringsRegex,
                numbers: sharedNumbersRegex,
                functions: sharedFunctionsRegex,
                keywordColorLight: NSColor(srgbRed: 0.10, green: 0.36, blue: 0.72, alpha: 1.0),
                keywordColorDark: NSColor(srgbRed: 0.44, green: 0.72, blue: 0.98, alpha: 1.0)
            )

        default:
            // Unknown/custom language tag: provide lightweight generic highlighting
            return LanguageSyntaxProfile(
                keywords: try? NSRegularExpression(pattern: #"\b(if|else|for|while|return|function|class|import|true|false|null)\b"#),
                typesAndBuiltins: nil,
                attributesOrMacros: nil,
                comments: try? NSRegularExpression(pattern: #"//.*$|#.*$"#),
                strings: sharedStringsRegex,
                numbers: sharedNumbersRegex,
                functions: sharedFunctionsRegex,
                keywordColorLight: NSColor(srgbRed: 0.45, green: 0.25, blue: 0.65, alpha: 1.0),
                keywordColorDark: NSColor(srgbRed: 0.72, green: 0.55, blue: 0.88, alpha: 1.0)
            )
        }
    }

    private static func highlightCodeLine(
        in storage: NSTextStorage,
        range: NSRange,
        language: String,
        theme: EditorTheme,
        dimFactor: CGFloat
    ) {
        guard range.length > 0, let profile = syntaxProfile(for: language) else { return }
        let string = storage.string

        let keywordColor = (theme.isDark ? profile.keywordColorDark : profile.keywordColorLight).withAlphaComponent(dimFactor)
        let typeColor = (theme.isDark
            ? NSColor(srgbRed: 0.38, green: 0.84, blue: 0.78, alpha: dimFactor)
            : NSColor(srgbRed: 0.04, green: 0.45, blue: 0.48, alpha: dimFactor))
        let functionColor = (theme.isDark
            ? NSColor(srgbRed: 0.45, green: 0.72, blue: 0.96, alpha: dimFactor)
            : NSColor(srgbRed: 0.14, green: 0.36, blue: 0.74, alpha: dimFactor))
        let numberColor = (theme.isDark
            ? NSColor(srgbRed: 0.88, green: 0.68, blue: 0.38, alpha: dimFactor)
            : NSColor(srgbRed: 0.68, green: 0.36, blue: 0.04, alpha: dimFactor))
        let attrColor = (theme.isDark
            ? NSColor(srgbRed: 0.94, green: 0.62, blue: 0.42, alpha: dimFactor)
            : NSColor(srgbRed: 0.64, green: 0.28, blue: 0.12, alpha: dimFactor))
        let stringColor = (theme.isDark
            ? NSColor(srgbRed: 0.60, green: 0.82, blue: 0.50, alpha: dimFactor)
            : NSColor(srgbRed: 0.12, green: 0.46, blue: 0.18, alpha: dimFactor))
        let commentColor = theme.secondaryTextNSColor.withAlphaComponent(0.72 * dimFactor)

        // 1. Numbers
        profile.numbers.enumerateMatches(in: string, options: [], range: range) { match, _, _ in
            if let r = match?.range {
                storage.addAttribute(.foregroundColor, value: numberColor, range: r)
            }
        }

        // 2. Function calls/names
        profile.functions.enumerateMatches(in: string, options: [], range: range) { match, _, _ in
            if let r = match?.range(at: 1) {
                storage.addAttribute(.foregroundColor, value: functionColor, range: r)
            }
        }

        // 3. Types & Builtins
        profile.typesAndBuiltins?.enumerateMatches(in: string, options: [], range: range) { match, _, _ in
            if let r = match?.range {
                storage.addAttribute(.foregroundColor, value: typeColor, range: r)
            }
        }

        // 4. Keywords (override function/type matches if a keyword is followed by '(')
        profile.keywords?.enumerateMatches(in: string, options: [], range: range) { match, _, _ in
            if let r = match?.range {
                storage.addAttribute(.foregroundColor, value: keywordColor, range: r)
            }
        }

        // 5. Attributes / Decorators / Preprocessor / JSON keys
        profile.attributesOrMacros?.enumerateMatches(in: string, options: [], range: range) { match, _, _ in
            if let r = match?.range {
                storage.addAttribute(.foregroundColor, value: attrColor, range: r)
            }
        }

        // 6. Strings (override keywords inside string literals)
        profile.strings.enumerateMatches(in: string, options: [], range: range) { match, _, _ in
            if let r = match?.range {
                storage.addAttribute(.foregroundColor, value: stringColor, range: r)
            }
        }

        // 7. Comments (override everything inside a comment)
        profile.comments?.enumerateMatches(in: string, options: [], range: range) { match, _, _ in
            if let r = match?.range {
                storage.addAttribute(.foregroundColor, value: commentColor, range: r)
            }
        }
    }
}
