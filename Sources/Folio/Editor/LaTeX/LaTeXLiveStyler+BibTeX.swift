import AppKit
import Foundation

extension LaTeXLiveStyler {
    static func applyBibTeXStyles(
        to storage: NSTextStorage, string: String, nsString: NSString, fullLength: Int,
        theme: EditorTheme, effectiveBaseSize: CGFloat, effectiveContainerWidth: CGFloat, fileURL: URL?
    ) -> MarkdownDocumentAnalysis {
        let codeFont = theme.codeFont(size: effectiveBaseSize * 0.92)
        let boldFont = NSFontManager.shared.convert(codeFont, toHaveTrait: .boldFontMask)
        let fullRange = NSRange(location: 0, length: fullLength)
        storage.addAttributes([.font: codeFont, MKey.noSpellCheck: true], range: fullRange)

        let entries = LaTeXDocumentIndexer.parseBibTeXEntries(from: string, fileURL: fileURL)
        var headings: [OutlineHeading] = []
        var lineNum = 1
        var idx = 0
        var charToLine: [Int: Int] = [:]
        while idx < fullLength {
            let lr = nsString.lineRange(for: NSRange(location: idx, length: 0))
            charToLine[lr.location] = lineNum
            let lineStr = nsString.substring(with: lr) as NSString
            let lineLen = lineStr.length
            var p = 0
            while p < lineLen && (lineStr.character(at: p) == 0x20 || lineStr.character(at: p) == 0x09) { p += 1 }
            if p < lineLen {
                let firstCh = lineStr.character(at: p)
                if firstCh == 0x40 {
                    let braceRange = lineStr.range(of: "{", options: [], range: NSRange(location: p + 1, length: lineLen - (p + 1)))
                    if braceRange.location != NSNotFound && braceRange.location > p + 1 {
                        let typeEnd = braceRange.location
                        let commaRange = lineStr.range(of: ",", options: [], range: NSRange(location: typeEnd + 1, length: lineLen - (typeEnd + 1)))
                        if commaRange.location != NSNotFound && commaRange.location > typeEnd + 1 {
                            storage.addAttributes(
                                [.font: boldFont, .foregroundColor: theme.linkNSColor], range: NSRange(location: lr.location + p, length: typeEnd - p))
                            storage.addAttributes(
                                [.font: boldFont, .foregroundColor: theme.headingNSColor],
                                range: NSRange(location: lr.location + typeEnd + 1, length: commaRange.location - (typeEnd + 1)))
                        }
                    }
                } else if (firstCh >= 0x41 && firstCh <= 0x5A) || (firstCh >= 0x61 && firstCh <= 0x7A) {
                    var nameEnd = p + 1
                    while nameEnd < lineLen {
                        let c = lineStr.character(at: nameEnd)
                        if (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F { nameEnd += 1 } else { break }
                    }
                    var eqPos = nameEnd
                    while eqPos < lineLen && (lineStr.character(at: eqPos) == 0x20 || lineStr.character(at: eqPos) == 0x09) { eqPos += 1 }
                    if eqPos < lineLen && lineStr.character(at: eqPos) == 0x3D {
                        storage.addAttribute(.foregroundColor, value: theme.inlineCodeNSColor, range: NSRange(location: lr.location + p, length: nameEnd - p))
                    }
                }
            }
            idx = NSMaxRange(lr)
            lineNum += 1
        }

        for entry in entries {
            let title = "@\(entry.entryType){\(entry.key)} — \(entry.shortCitation)"
            let line = charToLine[entry.characterLocation] ?? 1
            headings.append(OutlineHeading(level: 1, title: title, characterLocation: entry.characterLocation, lineNumber: line))
        }

        _ = effectiveContainerWidth
        return MarkdownDocumentAnalysis(headings: headings, decorations: [])
    }
}
