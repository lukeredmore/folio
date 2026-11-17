import AppKit
import XCTest
@testable import FolioEditor
@testable import FolioEditorTestSupport
@testable import FolioModels

final class AutolinkRangeTests: XCTestCase {

    @MainActor
    func testBareAutolinkStylesExactlyTheURL() {
        let sample = """
            Cursor line.

            1. **Onboarding.** In https://example.com/#/, onboard the client.
            2. **Relationship.** Open https://example.com/services/a?tabId=add, then request.
            3. **Wrapped.** Open the page
               at https://example.com/wrapped and submit.

            **Bold.** See www.example.com/www for details.

            Plain text with https://example.com/plain inside.
            """
        let storage = NSTextStorage(string: sample)
        _ = MarkdownLiveStyler.applyStyles(
            to: storage,
            theme: .daylight,
            sourceCodeMode: false,
            focusMode: false,
            selectedRange: NSRange(location: 0, length: 0),
            containerWidth: 720
        )

        let ns = sample as NSString
        for url in [
            "https://example.com/#/",
            "https://example.com/services/a?tabId=add",
            "https://example.com/wrapped",
            "www.example.com/www",
            "https://example.com/plain"
        ] {
            let urlRange = ns.range(of: url)
            XCTAssertNotEqual(urlRange.location, NSNotFound, url)
            XCTAssertEqual(underlinedRange(in: storage, around: urlRange.location), urlRange, "Underline must cover exactly '\(url)'")
        }
    }

    private func underlinedRange(in storage: NSTextStorage, around location: Int) -> NSRange? {
        var effective = NSRange(location: NSNotFound, length: 0)
        let style =
            storage.attribute(
                .underlineStyle,
                at: location,
                longestEffectiveRange: &effective,
                in: NSRange(location: 0, length: storage.length)
            ) as? Int
        return style == NSUnderlineStyle.single.rawValue ? effective : nil
    }
}
