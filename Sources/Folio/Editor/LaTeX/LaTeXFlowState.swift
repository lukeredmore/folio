import AppKit
import Foundation

/// The TeX groups and environments that are open at a line, with the font declarations made
/// in each. The body styler carries it from line to line, so a line such as
/// `\itshape\fontsize{20}{0}\selectfont` styles the text that follows it until its group ends.
struct LaTeXFlowState: Equatable, Hashable, Sendable {
    struct Frame: Equatable, Hashable, Sendable {
        /// The environment that opened the frame, or nil for a `{` group.
        var environment: String?
        var style = LaTeXProseStyle()
        var alignment: NSTextAlignment?
    }

    /// Deepest nesting that the state tracks. Deeper groups share the innermost frame.
    static let maxDepth = 24

    private(set) var frames: [Frame] = [Frame(environment: nil)]

    var style: LaTeXProseStyle { frames[frames.count - 1].style }
    var alignment: NSTextAlignment? { frames[frames.count - 1].alignment }
    var isDefault: Bool { style == LaTeXProseStyle() && alignment == nil }

    /// Applies `effects` in order. `documentFontSize` is the class option size in points, which
    /// `\fontsize` is relative to.
    mutating func apply(_ effects: [LaTeXFlowEffect], documentFontSize: CGFloat) {
        for effect in effects {
            switch effect {
            case .beginEnvironment(let name):
                push(environment: name)
            case .openGroup:
                push(environment: nil)
            case .endEnvironment(let name):
                guard let index = frames.indices.dropFirst().last(where: { frames[$0].environment == name }) else { continue }
                frames.removeSubrange(index...)
            case .closeGroup:
                if frames.count > 1 && frames[frames.count - 1].environment == nil { frames.removeLast() }
            case .declaration(let declaration):
                Self.apply(declaration, to: &frames[frames.count - 1], documentFontSize: documentFontSize)
            }
        }
    }

    private mutating func push(environment: String?) {
        guard frames.count < Self.maxDepth else { return }
        var frame = frames[frames.count - 1]
        frame.environment = environment
        switch environment {
        case "flushleft": frame.alignment = .left
        case "flushright": frame.alignment = .right
        case "center": frame.alignment = .center
        default: break
        }
        frames.append(frame)
    }

    private static func apply(_ declaration: LaTeXFlowDeclaration, to frame: inout Frame, documentFontSize: CGFloat) {
        if case .alignment(let alignment) = declaration {
            frame.alignment = alignment
        } else {
            apply(declaration, to: &frame.style, documentFontSize: documentFontSize)
        }
    }

    /// Applies a font declaration to `style`. Alignment declarations do not change it.
    static func apply(_ declaration: LaTeXFlowDeclaration, to style: inout LaTeXProseStyle, documentFontSize: CGFloat) {
        switch declaration {
        case .named(let name):
            _ = LaTeXProseMacroExpander.applyDeclaration(name, to: &style)
        case .fontSize(let points):
            style.sizeScale = min(3.0, max(0.5, points / max(1.0, documentFontSize)))
        case let .fontSelection(command, value):
            LaTeXProseMacroExpander.applyFontSelection(command, value: value, to: &style)
        case .alignment:
            break
        }
    }
}
