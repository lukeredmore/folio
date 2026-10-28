import AppKit
@testable import Folio

/// Input for `EditorHarness`. Key events are real `NSEvent.keyEvent`s sent through
/// `NSWindow.sendEvent`, so they take the AppKit path `keyDown` -> `interpretKeyEvents` ->
/// `NSTextInputContext` -> `insertText` / `insertNewline` and the text view delegate. Events are
/// dispatched from inside a main run loop pass, as in the app, so `MainThreadStallMonitor` sees
/// the handling time. Not exercised: the window server event queue, `NSApplication.sendEvent`
/// (key equivalents and menu shortcuts), and input-method marked text.
extension EditorHarness {
    /// ANSI key codes for the characters `type(_:)` supports.
    private static let keyCodes: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19,
        "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29, "o": 31,
        "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46, " ": 49,
        "-": 27, "]": 30, "[": 33, "`": 50, "#": 20, "$": 21, "|": 42, ":": 41, "/": 44
    ]

    /// Characters that `type(_:)` sends with the Shift modifier, as on a US keyboard.
    private static let shiftedCharacters: Set<Character> = ["#", "$", "|", ":"]

    enum Arrow {
        case left
        case right

        var keyCode: UInt16 { self == .left ? 123 : 124 }
        var character: String {
            let scalar = self == .left ? NSLeftArrowFunctionKey : NSRightArrowFunctionKey
            return String(Character(UnicodeScalar(UInt32(scalar))!))
        }
    }

    /// Types lowercase letters, digits, spaces, and the Markdown punctuation in `keyCodes`, one
    /// key at a time. Drains the run loop until idle after each key.
    func type(_ text: String) {
        for character in text {
            guard let keyCode = Self.keyCodes[character] else {
                preconditionFailure("EditorHarness.type does not support \(character.debugDescription)")
            }
            let modifiers: NSEvent.ModifierFlags = Self.shiftedCharacters.contains(character) ? [.shift] : []
            sendKey(keyCode: keyCode, characters: String(character), modifiers: modifiers)
        }
    }

    func pressReturn() {
        sendKey(keyCode: 36, characters: "\r")
    }

    func pressBackspace() {
        sendKey(keyCode: 51, characters: "\u{7f}")
    }

    func press(_ arrow: Arrow) {
        sendKey(keyCode: arrow.keyCode, characters: arrow.character, modifiers: [.numericPad, .function])
    }

    /// Places the insertion point as a click would, on a zero-based line and UTF-16 column.
    func moveCursor(toLine line: Int, column: Int = 0) {
        let nsText = textView.string as NSString
        let location = lineStart(line)
        let lineRange = nsText.lineRange(for: NSRange(location: location, length: 0))
        let contentEnd = NSMaxRange(lineRange) - (NSMaxRange(lineRange) > location ? 1 : 0)
        let target = location + min(max(0, column), max(0, contentEnd - location))
        textView.setSelectedRange(NSRange(location: target, length: 0))
        textView.scrollRangeToVisible(textView.selectedRange())
        drainUntilIdle()
    }

    /// Scrolls the editor down by `deltaY` points through its clip view, as `NSScrollView` does
    /// for a wheel event. Synthesized scroll-wheel `NSEvent`s are not used: `NSScrollView`
    /// ignores them when the window server did not deliver them, so the wheel-event decoding
    /// step is not exercised. Bounds-change notifications, tiling, and drawing are.
    func scroll(by deltaY: CGFloat) {
        guard let scrollView = textView.enclosingScrollView else {
            preconditionFailure("The editor has no scroll view")
        }
        let clip = scrollView.contentView
        let maxY = max(0, textView.frame.height - clip.bounds.height)
        let target = NSPoint(x: clip.bounds.origin.x, y: min(maxY, max(0, clip.bounds.origin.y + deltaY)))
        dispatchInRunLoop {
            clip.scroll(to: target)
            scrollView.reflectScrolledClipView(clip)
        }
        drainUntilIdle()
    }

    /// Resizes the window as one frame of a live resize. Runs the run loop for `frameInterval`
    /// seconds, so a burst of calls paces like a 60 Hz drag.
    func resize(width: CGFloat, frameInterval: TimeInterval = 1.0 / 60.0) {
        var frame = window.frame
        frame.size.width = width
        dispatchInRunLoop { self.window.setFrame(frame, display: true) }
        RunLoop.main.run(until: Date().addingTimeInterval(frameInterval))
    }

    private func sendKey(keyCode: UInt16, characters: String, modifiers: NSEvent.ModifierFlags = []) {
        let events = [NSEvent.EventType.keyDown, .keyUp].compactMap { type in
            NSEvent.keyEvent(
                with: type,
                location: .zero,
                modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: keyCode
            )
        }
        precondition(events.count == 2, "Could not create key events")
        dispatchInRunLoop {
            for event in events {
                self.window.sendEvent(event)
            }
        }
        drainUntilIdle()
    }

    /// Runs `work` inside a main run loop pass and returns after it ran.
    private func dispatchInRunLoop(_ work: @escaping @MainActor () -> Void) {
        var done = false
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
            MainActor.assumeIsolated {
                work()
                done = true
            }
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
        while !done {
            RunLoop.main.run(until: Date().addingTimeInterval(0.001))
        }
    }
}
