import AppKit
import Foundation

extension MarkdownLiveStyler {

    /// Styles a CommonMark HTML block that renders in a web view. On inactive lines in Pretty
    /// Mode the source lines are hidden and sized to the block's measured height, and an
    /// `.htmlBlockRendered` decoration marks where the web view goes. When the caret or the
    /// selection is in the block, the source shows as highlighted HTML. Returns nil when the
    /// block keeps its native styling.
    static func tryStyleHTMLBlock(
        in storage: NSTextStorage,
        nsString: NSString,
        lineRange: NSRange,
        endLineCount: Int,
        activeLineRange: NSRange,
        selectedRange: NSRange,
        theme: EditorTheme,
        typography: EditorTypographySettings,
        effectiveBaseSize: CGFloat,
        effectiveContainerWidth: CGFloat,
        focusMode: Bool,
        prettyMode: Bool,
        decorations: inout [LineDecoration]
    ) -> (nextIndex: Int, lineDelta: Int)? {
        guard prettyMode, endLineCount >= 1 else { return nil }

        let firstLine = nsString.substring(with: strippedLineContentRange(nsString: nsString, lineRange: lineRange))
        let closingTag = rawTextBlockClosingTag(firstLine: firstLine)
        var lines: [(lineRange: NSRange, contentRange: NSRange, isActive: Bool)] = []
        var scanIndex = lineRange.location
        while scanIndex < nsString.length {
            let nextLR = nsString.lineRange(for: NSRange(location: scanIndex, length: 0))
            let nextCR = strippedLineContentRange(nsString: nsString, lineRange: nextLR)
            let active = isLineActive(lineRange: nextLR, activeLineRange: activeLineRange, selectedRange: selectedRange)
            lines.append((nextLR, nextCR, active))
            scanIndex = NSMaxRange(nextLR)
            if let closingTag {
                if nsString.substring(with: nextCR).lowercased().contains(closingTag) { break }
            } else if lines.count >= endLineCount {
                break
            }
        }
        guard let lastLine = lines.last else { return nil }

        let sourceRange = NSRange(location: lineRange.location, length: NSMaxRange(lastLine.contentRange) - lineRange.location)
        let source = nsString.substring(with: sourceRange)
        guard HTMLBlockMarkup.rendersInWebView(source) else { return nil }

        let fullBlockRange = NSRange(location: lineRange.location, length: scanIndex - lineRange.location)
        storage.addAttribute(noSpellCheckAttributeKey, value: true, range: fullBlockRange)
        let isBlockActive = lines.contains(where: { $0.isActive }) || NSIntersectionRange(fullBlockRange, selectedRange).length > 0
        let blockDim: CGFloat = (focusMode && !isBlockActive) ? 0.30 : 1.0

        if isBlockActive {
            let codeMono = theme.codeFont(size: effectiveBaseSize * 0.90)
            for line in lines {
                decorations.append(LineDecoration(lineRange: line.lineRange, kind: .codeFenceBody))
                let codePara = NSMutableParagraphStyle()
                codePara.lineSpacing = 2.0
                codePara.paragraphSpacing = 1.0
                codePara.firstLineHeadIndent = 14.0
                codePara.headIndent = 14.0
                codePara.tailIndent = effectiveContainerWidth
                storage.addAttributes(
                    [
                        .font: codeMono,
                        .foregroundColor: theme.textNSColor,
                        .paragraphStyle: codePara,
                        .kern: 0.0
                    ], range: line.lineRange)
                highlightCodeLine(in: storage, range: line.contentRange, language: "html", theme: theme, dimFactor: 1.0)
            }
            return (scanIndex, lines.count)
        }

        let style = HTMLBlockPageStyle(theme: theme, typography: typography)
        let key = HTMLBlockLayoutCache.key(source: source, width: effectiveContainerWidth, style: style)
        let blockHeight =
            HTMLBlockLayoutCache.shared.height(for: key)
            ?? HTMLBlockLayoutCache.estimatedHeight(lineCount: lines.count, fontSize: effectiveBaseSize, lineHeight: style.lineHeight)
        let lineHeights = hiddenLineHeights(totalHeight: blockHeight, lineCount: lines.count)
        for (index, line) in lines.enumerated() {
            let lineHeight = lineHeights[index]
            let para = NSMutableParagraphStyle()
            para.lineSpacing = 0.0
            para.paragraphSpacingBefore = 0.0
            para.paragraphSpacing = index == lines.count - 1 ? max(6.0, typography.paragraphSpacing * 0.65) : 0.0
            para.minimumLineHeight = lineHeight
            para.maximumLineHeight = lineHeight
            para.lineBreakMode = .byClipping
            para.tailIndent = effectiveContainerWidth
            storage.addAttributes(
                [
                    .font: theme.bodyFont(size: max(1.0, min(effectiveBaseSize, lineHeight * 0.5))),
                    .foregroundColor: NSColor.clear,
                    .paragraphStyle: para,
                    .kern: 0.0
                ], range: line.lineRange)
        }
        decorations.append(
            LineDecoration(
                lineRange: fullBlockRange,
                kind: .htmlBlockRendered(
                    htmlSource: source, fullBlockRange: fullBlockRange,
                    layoutWidth: effectiveContainerWidth, dimFactor: blockDim
                )
            ))
        return (scanIndex, lines.count)
    }

    /// The end tag that closes a CommonMark type 1 HTML block (`<pre>`, `<script>`, `<style>`,
    /// `<textarea>`), which ends on the line with that tag rather than at a blank line. cmark
    /// reports these blocks one line short, so the styler finds the end itself.
    static func rawTextBlockClosingTag(firstLine: String) -> String? {
        let lower = firstLine.trimmingCharacters(in: .whitespaces).lowercased()
        for tag in ["pre", "script", "style", "textarea"] where lower.hasPrefix("<\(tag)") {
            let next = lower.dropFirst(tag.count + 1).first
            if next == nil || next == ">" || next?.isWhitespace == true {
                return "</\(tag)"
            }
        }
        return nil
    }

    /// Heights of the hidden source lines, which add up to `totalHeight` (each line is at
    /// least 2 points, so a short block with many source lines can come out taller).
    static func hiddenLineHeights(totalHeight: CGFloat, lineCount: Int) -> [CGFloat] {
        guard lineCount > 0 else { return [] }
        let minimum: CGFloat = 2.0
        let total = max(totalHeight, minimum * CGFloat(lineCount))
        let perLine = floor(total / CGFloat(lineCount))
        var heights = Array(repeating: perLine, count: lineCount)
        heights[lineCount - 1] = total - perLine * CGFloat(lineCount - 1)
        return heights
    }
}
