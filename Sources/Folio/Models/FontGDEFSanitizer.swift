import AppKit
import CoreText
import Foundation

/// Sanitizes fonts whose OpenType `GDEF` (`GlyphClassDef`) table misclassifies standalone spacing
/// characters (such as ASCII backtick `U+0060`) as Class 3 (`Mark`). CoreText zeroes the advance
/// width of all GDEF Class 3 glyphs during GPOS shaping, collapsing them onto neighboring glyphs.
package enum FontGDEFSanitizer {
    private static let gdefClassBase: UInt16 = 1
    private static let gdefClassMark: UInt16 = 3
    private static let sfntChecksumAdjustmentMagic: UInt32 = 0xB1B0_AFBA

    private static let spacingCodepointRanges: [ClosedRange<UInt32>] = [
        0x0021...0x007E,
        0x00A1...0x00AC,
        0x00AE...0x00FF,
        0x02B0...0x02FF
    ]

    private struct CachedEntry {
        let sanitizedDescriptor: CTFontDescriptor?
        let unsanitizedPrototype: NSFont
    }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: CachedEntry] = [:]

    /// Returns a sanitized copy of `font` with any misclassified spacing glyphs moved from GDEF
    /// Class 3 (`Mark`) to Class 1 (`Base`), or `font` unchanged when no fix is needed.
    package static func sanitize(_ font: NSFont) -> NSFont {
        let ctFont = font as CTFont
        let key = cacheKey(for: font, ctFont: ctFont)

        cacheLock.lock()
        let cached = cache[key]
        cacheLock.unlock()

        if let cached {
            guard let desc = cached.sanitizedDescriptor else {
                return font
            }
            return CTFontCreateWithFontDescriptor(desc, font.pointSize, nil) as NSFont
        }

        let sanitizedDescriptor = buildSanitizedDescriptor(for: font, ctFont: ctFont)
        let entry = CachedEntry(
            sanitizedDescriptor: sanitizedDescriptor,
            unsanitizedPrototype: font
        )

        cacheLock.lock()
        cache[key] = entry
        cacheLock.unlock()

        guard let sanitizedDescriptor else {
            return font
        }
        return CTFontCreateWithFontDescriptor(sanitizedDescriptor, font.pointSize, nil) as NSFont
    }

    /// Converts `font` to have `trait` using its original registered face when sanitized so that
    /// `NSFontManager` still resolves bold/italic family members, then sanitizes the resulting face.
    package static func convert(_ font: NSFont, toHaveTrait trait: NSFontTraitMask) -> NSFont {
        let base = unsanitizedFont(matching: font)
        let converted = NSFontManager.shared.convert(base, toHaveTrait: trait)
        return sanitize(converted)
    }

    /// Converts `font` to remove `trait` using its original registered face when sanitized, then
    /// sanitizes the resulting face.
    package static func convert(_ font: NSFont, toNotHaveTrait trait: NSFontTraitMask) -> NSFont {
        let base = unsanitizedFont(matching: font)
        let converted = NSFontManager.shared.convert(base, toNotHaveTrait: trait)
        return sanitize(converted)
    }

    private static func unsanitizedFont(matching font: NSFont) -> NSFont {
        let key = cacheKey(for: font, ctFont: font as CTFont)
        cacheLock.lock()
        let entry = cache[key]
        cacheLock.unlock()

        guard let entry, entry.sanitizedDescriptor != nil else {
            return font
        }
        return NSFont(descriptor: entry.unsanitizedPrototype.fontDescriptor, size: font.pointSize) ?? font
    }

    private static func cacheKey(for font: NSFont, ctFont: CTFont) -> String {
        guard let variation = CTFontCopyVariation(ctFont) as? [NSNumber: Any], !variation.isEmpty else {
            return font.fontName
        }
        let axes = variation.keys
            .sorted { $0.intValue < $1.intValue }
            .map { key -> String in
                let val = (variation[key] as? NSNumber)?.doubleValue ?? 0.0
                return "\(key.intValue)=\(val)"
            }
            .joined(separator: ",")
        return "\(font.fontName)#\(axes)"
    }

    private static func buildSanitizedDescriptor(for font: NSFont, ctFont: CTFont) -> CTFontDescriptor? {
        guard let gdefData = CTFontCopyTable(ctFont, CTFontTableTag(kCTFontTableGDEF), []) as Data? else {
            return nil
        }
        let gdef = [UInt8](gdefData)
        guard let markGlyphs = collectGDEFMarkGlyphs(gdef) else {
            return nil
        }
        let misclassified = collectMisclassifiedSpacingGlyphs(font: font, ctFont: ctFont, markGlyphs: markGlyphs)
        guard !misclassified.isEmpty,
            let patchedGDEF = patchGDEFSpacingMarks(gdef, misclassified: misclassified),
            let sfnt = rebuildSFNT(ctFont: ctFont, patchedGDEF: patchedGDEF),
            let baseDesc = CTFontManagerCreateFontDescriptorFromData(sfnt as CFData)
        else {
            return nil
        }

        if let variation = CTFontCopyVariation(ctFont), CFDictionaryGetCount(variation) > 0 {
            let attrs = [kCTFontVariationAttribute: variation] as CFDictionary
            return CTFontDescriptorCreateCopyWithAttributes(baseDesc, attrs)
        }
        return baseDesc
    }

    private static func readUInt16BE(_ bytes: [UInt8], at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= bytes.count else { return nil }
        return (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
    }

    private static func writeUInt16BE(_ bytes: inout [UInt8], at offset: Int, value: UInt16) {
        bytes[offset] = UInt8(value >> 8)
        bytes[offset + 1] = UInt8(value & 0xFF)
    }

    private static func appendUInt16BE(_ bytes: inout [UInt8], _ value: UInt16) {
        bytes.append(UInt8(value >> 8))
        bytes.append(UInt8(value & 0xFF))
    }

    private static func appendUInt32BE(_ bytes: inout [UInt8], _ value: UInt32) {
        appendUInt16BE(&bytes, UInt16(value >> 16))
        appendUInt16BE(&bytes, UInt16(value & 0xFFFF))
    }

    private static func collectGDEFMarkGlyphs(_ gdef: [UInt8]) -> Set<UInt16>? {
        guard gdef.count >= 12,
            readUInt16BE(gdef, at: 0) == 1,
            let gcOffU16 = readUInt16BE(gdef, at: 4)
        else {
            return nil
        }
        let gcOff = Int(gcOffU16)
        guard gcOff > 0, gcOff + 4 <= gdef.count,
            let format = readUInt16BE(gdef, at: gcOff)
        else {
            return nil
        }

        var marks = Set<UInt16>()
        switch format {
        case 1:
            guard let startGlyph = readUInt16BE(gdef, at: gcOff + 2),
                let glyphCountU16 = readUInt16BE(gdef, at: gcOff + 4)
            else {
                return nil
            }
            let glyphCount = Int(glyphCountU16)
            guard gcOff + 6 + glyphCount * 2 <= gdef.count else { return nil }
            for i in 0..<glyphCount {
                if readUInt16BE(gdef, at: gcOff + 6 + i * 2) == gdefClassMark,
                    let delta = UInt16(exactly: i),
                    let gid = startGlyph.addingReportingOverflow(delta) as (partialValue: UInt16, overflow: Bool)?,
                    !gid.overflow
                {
                    marks.insert(gid.partialValue)
                }
            }
        case 2:
            guard let rangeCountU16 = readUInt16BE(gdef, at: gcOff + 2) else { return nil }
            let rangeCount = Int(rangeCountU16)
            guard gcOff + 4 + rangeCount * 6 <= gdef.count else { return nil }
            for r in 0..<rangeCount {
                let off = gcOff + 4 + r * 6
                guard let startGid = readUInt16BE(gdef, at: off),
                    let endGid = readUInt16BE(gdef, at: off + 2),
                    let cls = readUInt16BE(gdef, at: off + 4)
                else {
                    return nil
                }
                if cls == gdefClassMark && startGid <= endGid {
                    for gid in startGid...endGid {
                        marks.insert(gid)
                    }
                }
            }
        default:
            return nil
        }

        return marks.isEmpty ? nil : marks
    }

    private static func collectMisclassifiedSpacingGlyphs(
        font: NSFont,
        ctFont: CTFont,
        markGlyphs: Set<UInt16>
    ) -> Set<UInt16> {
        var codeUnits: [UniChar] = []
        for range in spacingCodepointRanges {
            for cp in range {
                codeUnits.append(UniChar(cp))
            }
        }
        var glyphs = [CGGlyph](repeating: 0, count: codeUnits.count)
        CTFontGetGlyphsForCharacters(ctFont, &codeUnits, &glyphs, codeUnits.count)

        var misclassified = Set<UInt16>()
        for gid in glyphs where gid != 0 && markGlyphs.contains(gid) {
            if font.advancement(forCGGlyph: gid).width > 0.0 {
                misclassified.insert(gid)
            }
        }
        return misclassified
    }

    private static func pushClassRange(
        _ ranges: inout [(start: UInt16, end: UInt16, cls: UInt16)],
        start: UInt16,
        end: UInt16,
        cls: UInt16
    ) {
        if let lastIndex = ranges.indices.last,
            ranges[lastIndex].cls == cls,
            ranges[lastIndex].end < UInt16.max,
            ranges[lastIndex].end + 1 == start
        {
            ranges[lastIndex].end = end
            return
        }
        ranges.append((start, end, cls))
    }

    private static func patchGDEFSpacingMarks(_ gdef: [UInt8], misclassified: Set<UInt16>) -> [UInt8]? {
        guard let gcOffU16 = readUInt16BE(gdef, at: 4) else { return nil }
        let gcOff = Int(gcOffU16)
        guard let format = readUInt16BE(gdef, at: gcOff) else { return nil }
        var patched = gdef

        switch format {
        case 1:
            guard let startGlyph = readUInt16BE(patched, at: gcOff + 2),
                let glyphCountU16 = readUInt16BE(patched, at: gcOff + 4)
            else {
                return nil
            }
            let glyphCount = Int(glyphCountU16)
            var changed = false
            for gid in misclassified where gid >= startGlyph {
                let index = Int(gid - startGlyph)
                if index < glyphCount, readUInt16BE(patched, at: gcOff + 6 + index * 2) == gdefClassMark {
                    writeUInt16BE(&patched, at: gcOff + 6 + index * 2, value: gdefClassBase)
                    changed = true
                }
            }
            return changed ? patched : nil
        case 2:
            guard let rangeCountU16 = readUInt16BE(patched, at: gcOff + 2) else { return nil }
            let rangeCount = Int(rangeCountU16)
            var merged: [(start: UInt16, end: UInt16, cls: UInt16)] = []
            merged.reserveCapacity(rangeCount + 4)
            var changed = false

            for r in 0..<rangeCount {
                let off = gcOff + 4 + r * 6
                guard let startGid = readUInt16BE(patched, at: off),
                    let endGid = readUInt16BE(patched, at: off + 2),
                    let cls = readUInt16BE(patched, at: off + 4)
                else {
                    return nil
                }
                if cls == gdefClassMark && startGid <= endGid
                    && (startGid...endGid).contains(where: { misclassified.contains($0) })
                {
                    changed = true
                    for gid in startGid...endGid {
                        let nextCls = misclassified.contains(gid) ? gdefClassBase : gdefClassMark
                        pushClassRange(&merged, start: gid, end: gid, cls: nextCls)
                    }
                } else {
                    pushClassRange(&merged, start: startGid, end: endGid, cls: cls)
                }
            }

            guard changed, let newCount = UInt16(exactly: merged.count) else { return nil }
            if merged.count <= rangeCount {
                writeUInt16BE(&patched, at: gcOff + 2, value: newCount)
                for (index, entry) in merged.enumerated() {
                    let off = gcOff + 4 + index * 6
                    writeUInt16BE(&patched, at: off, value: entry.start)
                    writeUInt16BE(&patched, at: off + 2, value: entry.end)
                    writeUInt16BE(&patched, at: off + 4, value: entry.cls)
                }
                let usedEnd = gcOff + 4 + merged.count * 6
                let origEnd = gcOff + 4 + rangeCount * 6
                for i in usedEnd..<origEnd {
                    patched[i] = 0
                }
            } else {
                if patched.count % 2 != 0 {
                    patched.append(0)
                }
                guard let newOff = UInt16(exactly: patched.count) else { return nil }
                writeUInt16BE(&patched, at: 4, value: newOff)
                appendUInt16BE(&patched, 2)
                appendUInt16BE(&patched, newCount)
                for entry in merged {
                    appendUInt16BE(&patched, entry.start)
                    appendUInt16BE(&patched, entry.end)
                    appendUInt16BE(&patched, entry.cls)
                }
            }
            return patched
        default:
            return nil
        }
    }

    private static func sfntChecksum(_ bytes: [UInt8]) -> UInt32 {
        var sum: UInt32 = 0
        var index = 0
        while index < bytes.count {
            let b0 = UInt32(bytes[index]) << 24
            let b1 = (index + 1 < bytes.count ? UInt32(bytes[index + 1]) : 0) << 16
            let b2 = (index + 2 < bytes.count ? UInt32(bytes[index + 2]) : 0) << 8
            let b3 = (index + 3 < bytes.count ? UInt32(bytes[index + 3]) : 0)
            sum = sum &+ (b0 | b1 | b2 | b3)
            index += 4
        }
        return sum
    }

    private static func rebuildSFNT(ctFont: CTFont, patchedGDEF: [UInt8]) -> Data? {
        guard let tagsCF = CTFontCopyAvailableTables(ctFont, []) else { return nil }
        let tagCount = CFArrayGetCount(tagsCF)
        var tables: [(tag: UInt32, data: [UInt8])] = []
        tables.reserveCapacity(tagCount)

        var hasCFF = false
        let tagGDEF = UInt32(kCTFontTableGDEF)
        let tagCFF = UInt32(kCTFontTableCFF)
        let tagCFF2 = UInt32(kCTFontTableCFF2)
        let tagHead = UInt32(kCTFontTableHead)

        for i in 0..<tagCount {
            let rawPtr = CFArrayGetValueAtIndex(tagsCF, i)
            let tag = UInt32(UInt(bitPattern: rawPtr))
            if tag == tagCFF || tag == tagCFF2 {
                hasCFF = true
            }
            if tag == tagGDEF {
                tables.append((tag, patchedGDEF))
                continue
            }
            guard let tableData = CTFontCopyTable(ctFont, CTFontTableTag(tag), []) as Data? else {
                return nil
            }
            var bytes = [UInt8](tableData)
            if tag == tagHead && bytes.count >= 12 {
                for j in 8..<12 {
                    bytes[j] = 0
                }
            }
            tables.append((tag, bytes))
        }

        tables.sort { $0.tag < $1.tag }
        guard let numTables = UInt16(exactly: tables.count) else { return nil }

        var searchRange: UInt16 = 16
        var entrySelector: UInt16 = 0
        while searchRange <= numTables &* 8 {
            searchRange &*= 2
            entrySelector &+= 1
        }
        let rangeShift = numTables &* 16 &- searchRange
        let sfntVersion: UInt32 = hasCFF ? 0x4F54_544F : 0x0001_0000

        var sfnt: [UInt8] = []
        let headerLen = 12 + Int(numTables) * 16
        let totalBodyEstimate = tables.reduce(0) { $0 + $1.data.count + 3 }
        sfnt.reserveCapacity(headerLen + totalBodyEstimate)

        appendUInt32BE(&sfnt, sfntVersion)
        appendUInt16BE(&sfnt, numTables)
        appendUInt16BE(&sfnt, searchRange)
        appendUInt16BE(&sfnt, entrySelector)
        appendUInt16BE(&sfnt, rangeShift)

        var offset = headerLen
        var headOffsetAndLen: (offset: Int, length: Int)?
        for table in tables {
            guard let offsetU32 = UInt32(exactly: offset),
                let lengthU32 = UInt32(exactly: table.data.count)
            else {
                return nil
            }
            if table.tag == tagHead {
                headOffsetAndLen = (offset, table.data.count)
            }
            appendUInt32BE(&sfnt, table.tag)
            appendUInt32BE(&sfnt, sfntChecksum(table.data))
            appendUInt32BE(&sfnt, offsetU32)
            appendUInt32BE(&sfnt, lengthU32)
            offset += (table.data.count + 3) & ~3
        }

        for table in tables {
            sfnt.append(contentsOf: table.data)
            let pad = (4 - (table.data.count % 4)) % 4
            if pad > 0 {
                sfnt.append(contentsOf: repeatElement(UInt8(0), count: pad))
            }
        }

        if let head = headOffsetAndLen, head.length >= 12 {
            let adjustment = sfntChecksumAdjustmentMagic &- sfntChecksum(sfnt)
            sfnt[head.offset + 8] = UInt8((adjustment >> 24) & 0xFF)
            sfnt[head.offset + 9] = UInt8((adjustment >> 16) & 0xFF)
            sfnt[head.offset + 10] = UInt8((adjustment >> 8) & 0xFF)
            sfnt[head.offset + 11] = UInt8(adjustment & 0xFF)
        }

        return Data(sfnt)
    }
}
