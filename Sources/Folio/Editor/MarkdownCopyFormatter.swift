import AppKit
import Foundation

public enum MarkdownCopyFormatter {

    public static func rawMarkdown(in documentText: String, range: NSRange) -> String {
        let nsStr = documentText as NSString
        let clampedLoc = max(0, min(range.location, nsStr.length))
        let clampedLen = max(0, min(range.length, nsStr.length - clampedLoc))
        guard clampedLen > 0 else { return "" }
        return nsStr.substring(with: NSRange(location: clampedLoc, length: clampedLen))
    }

    public static func styledAttributedString(
        in documentText: String,
        range: NSRange,
        theme: EditorTheme = .daylight,
        typography: EditorTypographySettings? = nil
    ) -> NSAttributedString {
        let nsStr = documentText as NSString
        let clampedLoc = max(0, min(range.location, nsStr.length))
        let clampedLen = max(0, min(range.length, nsStr.length - clampedLoc))
        guard clampedLen > 0 else { return NSAttributedString(string: "") }
        let safeRange = NSRange(location: clampedLoc, length: clampedLen)

        // Append a trailing newline and place the cursor at the end so all selected lines are styled as inactive (folded).
        let workingString = documentText + "\n"
        let workingNS = workingString as NSString
        let storage = NSTextStorage(string: workingString)
        let inactiveCursor = NSRange(location: workingNS.length, length: 0)
        let effectiveTypography = typography ?? theme.typography
        let effectiveBaseSize = theme.baseFontSize * effectiveTypography.fontSizeScale
        let bodyFont = theme.bodyFont(size: effectiveBaseSize)

        let analysis = MarkdownLiveStyler.applyStyles(
            to: storage,
            theme: theme,
            typography: effectiveTypography,
            sourceCodeMode: false,
            focusMode: false,
            selectedRange: inactiveCursor,
            prettyMode: true
        )

        var bulletMarkerLocations = Set<Int>()
        for dec in analysis.decorations {
            if case let .listBullet(markerRange, _) = dec.kind {
                bulletMarkerLocations.insert(markerRange.location)
            }
        }

        let result = NSMutableAttributedString()
        var index = safeRange.location
        let maxRange = NSMaxRange(safeRange)

        while index < maxRange {
            var effectiveRange = NSRange(location: 0, length: 0)
            let attrs = storage.attributes(at: index, effectiveRange: &effectiveRange)
            let runRange = NSIntersectionRange(effectiveRange, safeRange)
            guard runRange.length > 0 else {
                index += 1
                continue
            }

            let isCollapsed = (attrs[MarkdownLiveStyler.collapsedTokenAttributeKey] as? Bool) == true
            let isSoftBreak = (attrs[MarkdownLiveStyler.softLineBreakAttributeKey] as? Bool) == true

            if bulletMarkerLocations.contains(runRange.location) {
                var bulletAttrs = cleanedCopyAttributes(from: attrs, defaultFont: bodyFont, defaultColor: theme.textNSColor)
                bulletAttrs[.foregroundColor] = theme.linkNSColor
                result.append(NSAttributedString(string: "• ", attributes: bulletAttrs))
                index = NSMaxRange(runRange)
                // Skip immediately following collapsed post-marker whitespace
                if index < maxRange,
                    (storage.attribute(MarkdownLiveStyler.collapsedTokenAttributeKey, at: index, effectiveRange: &effectiveRange) as? Bool) == true
                {
                    let wsRun = NSIntersectionRange(effectiveRange, safeRange)
                    let wsText = workingNS.substring(with: wsRun)
                    if wsText.allSatisfy({ $0 == " " || $0 == "\t" }) {
                        index = NSMaxRange(wsRun)
                    }
                }
                continue
            }

            if isCollapsed {
                let runText = workingNS.substring(with: runRange)
                // Preserve a single space after ordered list markers ("1.") or task checkboxes ("[x]" / "[ ]")
                if runText.allSatisfy({ $0 == " " || $0 == "\t" }),
                    result.length > 0
                {
                    let prevChar = (result.string as NSString).substring(from: result.length - 1)
                    if prevChar == "." || prevChar == ")" || prevChar == "]" {
                        let spaceAttrs = cleanedCopyAttributes(from: attrs, defaultFont: bodyFont, defaultColor: theme.textNSColor)
                        result.append(NSAttributedString(string: " ", attributes: spaceAttrs))
                    }
                }
                index = NSMaxRange(runRange)
                continue
            }

            var cleanAttrs = cleanedCopyAttributes(from: attrs, defaultFont: bodyFont, defaultColor: theme.textNSColor)
            let substring = workingNS.substring(with: runRange)
            if isSoftBreak && substring == "\n" {
                result.append(NSAttributedString(string: " ", attributes: cleanAttrs))
            } else {
                if let fg = cleanAttrs[.foregroundColor] as? NSColor, fg.alphaComponent < 0.05 {
                    cleanAttrs[.foregroundColor] = theme.textNSColor
                }
                result.append(NSAttributedString(string: substring, attributes: cleanAttrs))
            }
            index = NSMaxRange(runRange)
        }

        return result
    }

    private static func cleanedCopyAttributes(
        from attrs: [NSAttributedString.Key: Any],
        defaultFont: NSFont,
        defaultColor: NSColor
    ) -> [NSAttributedString.Key: Any] {
        var clean: [NSAttributedString.Key: Any] = [:]
        if let font = attrs[.font] as? NSFont {
            clean[.font] = font.pointSize < 1.0 ? defaultFont : font
        } else {
            clean[.font] = defaultFont
        }
        if let fg = attrs[.foregroundColor] as? NSColor, fg.alphaComponent > 0.05 {
            clean[.foregroundColor] = fg
        } else {
            clean[.foregroundColor] = defaultColor
        }
        if let bg = attrs[.backgroundColor] as? NSColor, bg.alphaComponent > 0.01 {
            clean[.backgroundColor] = bg
        }
        if let underline = attrs[.underlineStyle] as? Int, underline != 0 {
            clean[.underlineStyle] = underline
        }
        if let strike = attrs[.strikethroughStyle] as? Int, strike != 0 {
            clean[.strikethroughStyle] = strike
        }
        if let link = attrs[.link] {
            clean[.link] = link
        }
        if let baseline = attrs[.baselineOffset] as? CGFloat, baseline != 0 {
            clean[.baselineOffset] = baseline
        }
        if let para = attrs[.paragraphStyle] as? NSParagraphStyle {
            clean[.paragraphStyle] = para
        }
        return clean
    }

    public static func strippedPlainText(
        in documentText: String,
        range: NSRange,
        theme: EditorTheme = .daylight,
        typography: EditorTypographySettings? = nil
    ) -> String {
        styledAttributedString(
            in: documentText,
            range: range,
            theme: theme,
            typography: typography
        ).string
    }

    public static func strippedPlainText(from markdownFragment: String) -> String {
        let fullRange = NSRange(location: 0, length: (markdownFragment as NSString).length)
        return strippedPlainText(in: markdownFragment, range: fullRange)
    }

    public static func htmlFragment(from markdownFragment: String) -> String {
        let lines = markdownFragment.components(separatedBy: .newlines)
        var htmlParts: [String] = []
        var inCodeFence = false
        var codeFenceLang = ""
        var codeLines: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                if !inCodeFence {
                    inCodeFence = true
                    codeFenceLang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    codeLines.removeAll()
                } else {
                    inCodeFence = false
                    let escapedCode = escapeHTML(codeLines.joined(separator: "\n"))
                    let classAttr = codeFenceLang.isEmpty ? "" : " class=\"language-\(escapeHTML(codeFenceLang))\""
                    htmlParts.append("<pre><code\(classAttr)>\(escapedCode)</code></pre>")
                    codeFenceLang = ""
                }
                continue
            }
            if inCodeFence {
                codeLines.append(line)
                continue
            }

            if trimmed.isEmpty {
                continue
            }
            if let headingMatch = MarkdownLiveStyler.headingRegex.firstMatch(
                in: line,
                options: [],
                range: NSRange(location: 0, length: (line as NSString).length)
            ), headingMatch.range(at: 3).location != NSNotFound {
                let nsLine = line as NSString
                let level = min(6, max(1, headingMatch.range(at: 2).length))
                let title =
                    headingMatch.range(at: 4).location != NSNotFound
                    ? nsLine.substring(with: headingMatch.range(at: 4))
                    : ""
                htmlParts.append("<h\(level)>\(renderInlineHTML(title))</h\(level)>")
            } else if trimmed.hasPrefix("> ") || trimmed == ">" {
                let body = String(trimmed.dropFirst(trimmed.hasPrefix("> ") ? 2 : 1))
                htmlParts.append("<blockquote>\(renderInlineHTML(body))</blockquote>")
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                let body = String(trimmed.dropFirst(2))
                htmlParts.append("<li>\(renderInlineHTML(body))</li>")
            } else {
                htmlParts.append("<p>\(renderInlineHTML(line))</p>")
            }
        }

        if inCodeFence && !codeLines.isEmpty {
            let escapedCode = escapeHTML(codeLines.joined(separator: "\n"))
            htmlParts.append("<pre><code>\(escapedCode)</code></pre>")
        }
        if htmlParts.count == 1, htmlParts[0].hasPrefix("<p>"), htmlParts[0].hasSuffix("</p>"), !markdownFragment.contains("\n") {
            return String(htmlParts[0].dropFirst(3).dropLast(4))
        }
        return htmlParts.joined(separator: "\n")
    }

    private static func renderInlineHTML(_ text: String) -> String {
        var out = escapeHTML(text)
        out = out.replacingOccurrences(of: #"!\[([^\]]*)\]\(([^)]+)\)"#, with: #"<img alt="$1" src="$2"/>"#, options: .regularExpression)
        out = out.replacingOccurrences(of: #"\[([^\]]+)\]\(([^)]+)\)"#, with: #"<a href="$2">$1</a>"#, options: .regularExpression)
        out = out.replacingOccurrences(of: #"`([^`]+)`"#, with: #"<code>$1</code>"#, options: .regularExpression)
        out = out.replacingOccurrences(of: #"\*\*([^*]+)\*\*"#, with: #"<strong>$1</strong>"#, options: .regularExpression)
        out = out.replacingOccurrences(of: #"__([^_]+)__"#, with: #"<strong>$1</strong>"#, options: .regularExpression)
        out = out.replacingOccurrences(of: #"(?<!\*)\*([^*]+)\*(?!\*)"#, with: #"<em>$1</em>"#, options: .regularExpression)
        out = out.replacingOccurrences(of: #"~~([^~]+)~~"#, with: #"<del>$1</del>"#, options: .regularExpression)
        out = out.replacingOccurrences(of: #"==([^=]+)=="#, with: #"<mark>$1</mark>"#, options: .regularExpression)
        return out
    }

    private static func escapeHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    @discardableResult
    public static func copyFormatted(
        in documentText: String,
        range: NSRange,
        theme: EditorTheme = .daylight,
        typography: EditorTypographySettings? = nil,
        pasteboard: NSPasteboard = .general
    ) -> String {
        let raw = rawMarkdown(in: documentText, range: range)
        let attrStr = styledAttributedString(in: documentText, range: range, theme: theme, typography: typography)
        let plain = attrStr.string
        let html = htmlFragment(from: raw)

        pasteboard.clearContents()
        let fullAttrRange = NSRange(location: 0, length: attrStr.length)
        if fullAttrRange.length > 0,
            let rtfData = try? attrStr.data(
                from: fullAttrRange,
                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
            )
        {
            pasteboard.setData(rtfData, forType: .rtf)
        }
        if !html.isEmpty {
            pasteboard.setString(html, forType: .html)
        }
        pasteboard.setString(plain, forType: .string)
        return plain
    }

    @discardableResult
    public static func copyRaw(
        in documentText: String,
        range: NSRange,
        pasteboard: NSPasteboard = .general
    ) -> String {
        let raw = rawMarkdown(in: documentText, range: range)
        pasteboard.clearContents()
        pasteboard.setString(raw, forType: .string)
        return raw
    }
}
