import Foundation

extension MarkdownLiveStyler {

    /// Converts cmark's UTF-8 byte columns in one line to UTF-16 offsets. Line text is bridged
    /// from `NSString`, where each UTF-8 index operation rescans the line, so the bytes are
    /// copied once. A lookup continues from the previous one, so the links on a line cost one
    /// pass over it instead of one pass per link.
    struct LineUTF8Columns {
        let bytes: [UInt8]
        private var byteCursor = 0
        private var utf16Cursor = 0

        init(_ text: String) {
            bytes = Array(text.utf8)
        }

        /// UTF-16 offset of a 0-based byte column, clamped to the line. A column inside a
        /// multi-byte character maps to the start of that character.
        mutating func utf16Offset(ofByteColumn byteColumn: Int) -> Int {
            let target = max(0, min(byteColumn, bytes.count))
            if target < byteCursor {
                byteCursor = 0
                utf16Cursor = 0
            }
            while byteCursor < target {
                let lead = bytes[byteCursor]
                let width = lead < 0xC0 ? 1 : lead < 0xE0 ? 2 : lead < 0xF0 ? 3 : 4
                guard byteCursor + width <= target else { break }
                byteCursor += width
                utf16Cursor += width == 4 ? 2 : 1
            }
            return utf16Cursor
        }
    }

    /// `LineUTF8Columns` for each line of a style pass, built when a line is first used.
    struct LineUTF8ColumnCache {
        let lineRecords: [Int: LineRecord]
        private var columns: [Int: LineUTF8Columns] = [:]

        init(lineRecords: [Int: LineRecord]) {
            self.lineRecords = lineRecords
        }

        /// UTF-8 byte at a 0-based column of a line, or nil when the line or column does not exist.
        mutating func byte(line: Int, column: Int) -> UInt8? {
            guard let rec = lineRecords[line] else { return nil }
            let entry = columns[line] ?? LineUTF8Columns(rec.lineText)
            columns[line] = entry
            return entry.bytes.indices.contains(column) ? entry.bytes[column] : nil
        }

        /// UTF-16 document offset of a 0-based UTF-8 byte column in a line's content.
        mutating func documentOffset(line: Int, byteColumn: Int) -> Int? {
            guard let rec = lineRecords[line] else { return nil }
            // The defaulted subscript stores the new entry, so the cursor persists between calls.
            return rec.contentRange.location
                + columns[line, default: LineUTF8Columns(rec.lineText)].utf16Offset(ofByteColumn: byteColumn)
        }
    }
}
