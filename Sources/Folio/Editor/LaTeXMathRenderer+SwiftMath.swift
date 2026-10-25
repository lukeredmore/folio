import AppKit
import Foundation
import SwiftMath

private struct SwiftMathCacheKey: Hashable {
    let latex: String
    let macrosVersion: UInt64
    let fontSizeTenths: Int
    let isDisplayStyle: Bool
}

extension LaTeXMathRenderer {
    private static let swiftMathLock = NSLock()
    nonisolated(unsafe) private static var didRegisterSymbols = false
    nonisolated(unsafe) private static var fontCache: [Int: MTFont] = [:]
    nonisolated(unsafe) private static var layoutCache: [SwiftMathCacheKey: MathLayoutBox] = [:]
    nonisolated(unsafe) private static var activeDocumentMacros: [String: LaTeXMacroDefinition] = [:]
    nonisolated(unsafe) private static var activeMacrosVersion: UInt64 = 1

    public static func setDocumentMacros(_ macros: [String: LaTeXMacroDefinition]) {
        swiftMathLock.lock()
        if activeDocumentMacros != macros {
            activeDocumentMacros = macros
            activeMacrosVersion &+= 1
            registerExtraSymbolsUnlocked()
            LaTeXMacroExpander.registerCustomOperators(from: macros)
        }
        swiftMathLock.unlock()
    }

    public static func currentDocumentMacros() -> [String: LaTeXMacroDefinition] {
        swiftMathLock.lock()
        defer { swiftMathLock.unlock() }
        return activeDocumentMacros
    }

    public static func layoutWithSwiftMath(
        _ latex: String,
        baseFontSize: CGFloat,
        isDisplayStyle: Bool,
        macros: [String: LaTeXMacroDefinition]? = nil
    ) -> MathLayoutBox? {
        swiftMathLock.lock()
        defer { swiftMathLock.unlock() }

        registerExtraSymbolsUnlocked()
        let effectiveSize = isDisplayStyle ? baseFontSize * 1.18 : baseFontSize * 1.04
        let sizeTenths = Int((effectiveSize * 10.0).rounded())

        if macros == nil {
            let rawKey = SwiftMathCacheKey(
                latex: latex,
                macrosVersion: activeMacrosVersion,
                fontSizeTenths: sizeTenths,
                isDisplayStyle: isDisplayStyle
            )
            if let cached = layoutCache[rawKey] {
                return cached
            }
        }

        var effectiveMacros = activeDocumentMacros
        if let macros {
            for (k, v) in macros { effectiveMacros[k] = v }
            LaTeXMacroExpander.registerCustomOperators(from: effectiveMacros)
        }

        let (expanded, tag) = LaTeXMacroExpander.expandAndNormalize(latex, macros: effectiveMacros)
        if expanded.isEmpty {
            return MathLayoutBox(
                width: 0,
                ascent: baseFontSize * 0.72,
                descent: baseFontSize * 0.22,
                tag: tag,
                usesNativeOpenTypeMath: true
            ) { _, _, _ in }
        }

        let cacheKey = SwiftMathCacheKey(
            latex: macros == nil ? latex : expanded,
            macrosVersion: macros == nil ? activeMacrosVersion : 0,
            fontSizeTenths: sizeTenths,
            isDisplayStyle: isDisplayStyle
        )
        if macros != nil, let cached = layoutCache[cacheKey] {
            return cached
        }

        let box: MathLayoutBox
        if expanded.contains("\\boxed"),
           let boxedComposite = layoutBoxedSwiftMathUnlocked(
               expanded,
               sizeTenths: sizeTenths,
               baseFontSize: baseFontSize,
               isDisplayStyle: isDisplayStyle,
               tag: tag
           ) {
            box = boxedComposite
        } else if let single = layoutSingleSwiftMathUnlocked(
            expanded,
            sizeTenths: sizeTenths,
            baseFontSize: baseFontSize,
            isDisplayStyle: isDisplayStyle,
            tag: tag
        ) {
            box = single
        } else {
            return nil
        }

        if layoutCache.count >= 512 {
            layoutCache.removeAll(keepingCapacity: true)
        }
        layoutCache[cacheKey] = box
        return box
    }

    private static func layoutSingleSwiftMathUnlocked(
        _ latex: String,
        sizeTenths: Int,
        baseFontSize: CGFloat,
        isDisplayStyle: Bool,
        tag: String?
    ) -> MathLayoutBox? {
        guard let mathList = buildMathListUnlocked(from: latex),
              let mtFont = mtFontUnlocked(sizeTenths: sizeTenths),
              let displayList = mathList.folioTypeset(
                  font: mtFont,
                  style: isDisplayStyle ? .display : .text
              ) else {
            return nil
        }

        let width = max(1.0, ceil(displayList.width))
        let ascent = max(baseFontSize * 0.68, ceil(displayList.ascent))
        let descent = max(baseFontSize * 0.20, ceil(displayList.descent))

        return MathLayoutBox(
            width: width,
            ascent: ascent,
            descent: descent,
            tag: tag,
            usesNativeOpenTypeMath: true
        ) { originX, baselineY, color in
            guard let cgContext = NSGraphicsContext.current?.cgContext else { return }
            let isFlipped = NSGraphicsContext.current?.isFlipped ?? false
            cgContext.saveGState()
            if isFlipped {
                cgContext.translateBy(x: originX, y: baselineY)
                cgContext.scaleBy(x: 1.0, y: -1.0)
                cgContext.textMatrix = .identity
                displayList.folioDraw(in: cgContext, at: .zero, color: color)
            } else {
                cgContext.textMatrix = .identity
                displayList.folioDraw(in: cgContext, at: CGPoint(x: originX, y: baselineY), color: color)
            }
            cgContext.restoreGState()
        }
    }

    private static func layoutBoxedSwiftMathUnlocked(
        _ expanded: String,
        sizeTenths: Int,
        baseFontSize: CGFloat,
        isDisplayStyle: Bool,
        tag: String?
    ) -> MathLayoutBox? {
        let chars = Array(expanded)
        var segments: [(text: String, isBoxed: Bool)] = []
        var current = ""
        var i = 0
        var foundBoxed = false
        while i < chars.count {
            if chars[i] == "\\",
               String(chars[i...]).hasPrefix("\\boxed") {
                var j = i + 6
                while j < chars.count && chars[j].isWhitespace { j += 1 }
                if j < chars.count && chars[j] == "{" {
                    var depth = 1
                    var k = j + 1
                    while k < chars.count && depth > 0 {
                        if chars[k] == "\\" { k += 2; continue }
                        if chars[k] == "{" { depth += 1 }
                        else if chars[k] == "}" { depth -= 1 }
                        k += 1
                    }
                    if depth == 0 {
                        let trimmedCur = current.trimmingCharacters(in: .whitespaces)
                        if !trimmedCur.isEmpty { segments.append((trimmedCur, false)) }
                        current = ""
                        let inner = String(chars[(j + 1)..<(k - 1)])
                        segments.append((inner, true))
                        foundBoxed = true
                        i = k
                        continue
                    }
                }
            }
            current.append(chars[i])
            i += 1
        }
        let trailing = current.trimmingCharacters(in: .whitespaces)
        if !trailing.isEmpty { segments.append((trailing, false)) }
        guard foundBoxed, !segments.isEmpty else { return nil }

        var boxes: [(box: MathLayoutBox, isPunct: Bool)] = []
        for seg in segments {
            guard let rawBox = layoutSingleSwiftMathUnlocked(
                seg.text,
                sizeTenths: sizeTenths,
                baseFontSize: baseFontSize,
                isDisplayStyle: isDisplayStyle,
                tag: nil
            ) else {
                return nil
            }
            let finalBox = seg.isBoxed ? wrapInBoxedFrame(rawBox) : rawBox
            let isPunct = !seg.isBoxed && (seg.text == "." || seg.text == "," || seg.text == ";")
            boxes.append((finalBox, isPunct))
        }

        var totalW: CGFloat = 0
        var maxAsc: CGFloat = baseFontSize * 0.68
        var maxDesc: CGFloat = baseFontSize * 0.20
        for (idx, item) in boxes.enumerated() {
            if idx > 0 { totalW += item.isPunct ? 1.5 : 4.0 }
            totalW += item.box.width
            maxAsc = max(maxAsc, item.box.ascent)
            maxDesc = max(maxDesc, item.box.descent)
        }
        return MathLayoutBox(
            width: totalW,
            ascent: maxAsc,
            descent: maxDesc,
            tag: tag,
            usesNativeOpenTypeMath: true
        ) { x, baselineY, color in
            var curX = x
            for (idx, item) in boxes.enumerated() {
                if idx > 0 { curX += item.isPunct ? 1.5 : 4.0 }
                item.box.drawBox(curX, baselineY, color)
                curX += item.box.width
            }
        }
    }

    private static func mtFontUnlocked(sizeTenths: Int) -> MTFont? {
        if let cached = fontCache[sizeTenths] {
            return cached
        }
        let font = MTFontManager().font(withName: "latinmodern-math", size: CGFloat(sizeTenths) / 10.0)
        if let font {
            fontCache[sizeTenths] = font
        }
        return font
    }

    private static func buildMathListUnlocked(from latex: String) -> MTMathList? {
        var error: NSError?
        if let list = MTMathListBuilder.build(fromString: latex, error: &error), error == nil {
            return list
        }
        let balanced = autoBalanceIncompleteLatex(latex)
        guard balanced != latex else { return nil }
        var retryError: NSError?
        if let list = MTMathListBuilder.build(fromString: balanced, error: &retryError), retryError == nil {
            return list
        }
        return nil
    }

    private static func autoBalanceIncompleteLatex(_ latex: String) -> String {
        var result = latex
        while result.hasSuffix("\\") {
            result.removeLast()
        }
        var openBraces = 0
        let chars = Array(result)
        var i = 0
        while i < chars.count {
            if chars[i] == "\\" {
                i += 2
                continue
            }
            if chars[i] == "{" { openBraces += 1 }
            else if chars[i] == "}" { openBraces = max(0, openBraces - 1) }
            i += 1
        }
        if openBraces > 0 {
            result.append(String(repeating: "}", count: openBraces))
        }
        let leftCount = result.components(separatedBy: "\\left").count - 1
        let rightCount = result.components(separatedBy: "\\right").count - 1
        if leftCount > rightCount {
            result.append(String(repeating: " \\right.", count: leftCount - rightCount))
        }
        return result
    }

    private static func registerExtraSymbolsUnlocked() {
        guard !didRegisterSymbols else { return }
        didRegisterSymbols = true

        let largeOps: [(String, String, Bool)] = [
            ("iint", "\u{222C}", false), ("iiint", "\u{222D}", false), ("iiiint", "\u{2A0C}", false),
            ("oiint", "\u{222F}", false), ("oiiint", "\u{2230}", false), ("argmin", "arg min", true),
            ("argmax", "arg max", true), ("Tr", "Tr", false), ("tr", "tr", false),
            ("rank", "rank", false), ("diag", "diag", false), ("sgn", "sgn", false),
            ("cov", "cov", false), ("Var", "Var", false), ("erf", "erf", false),
            ("erfc", "erfc", false), ("sech", "sech", false), ("csch", "csch", false),
        ]
        for (name, val, limits) in largeOps {
            MTMathAtomFactory.add(latexSymbol: name, value: MTMathAtomFactory.operatorWithName(val, limits: limits))
        }

        let relations: [(String, String)] = [
            ("implies", "\u{27F9}"), ("impliedby", "\u{27F8}"), ("longmapsto", "\u{27FC}"),
            ("hookrightarrow", "\u{21AA}"), ("hookleftarrow", "\u{21A9}"), ("rightharpoonup", "\u{21C0}"),
            ("rightharpoondown", "\u{21C1}"), ("leftharpoonup", "\u{21BC}"), ("leftharpoondown", "\u{21BD}"),
            ("rightleftharpoons", "\u{21CC}"), ("coloneqq", "\u{2254}"), ("coloneq", "\u{2254}"),
            ("eqqcolon", "\u{2255}"), ("eqcolon", "\u{2255}"), ("triangleq", "\u{225C}"),
            ("lesssim", "\u{2272}"), ("gtrsim", "\u{2273}"), ("leqslant", "\u{2A7D}"),
            ("geqslant", "\u{2A7E}"), ("subsetneq", "\u{228A}"), ("supsetneq", "\u{228B}"),
            ("nleq", "\u{2270}"), ("ngeq", "\u{2271}"), ("vDash", "\u{22A8}"),
            ("vdash", "\u{22A2}"), ("dashv", "\u{22A3}"), ("nvdash", "\u{22AC}"),
            ("nvDash", "\u{22AD}"), ("bowtie", "\u{22C8}"),
        ]
        for (name, val) in relations {
            MTMathAtomFactory.folioAddSymbol(name, type: .relation, value: val)
        }

        let ordinaries: [(String, MTMathAtomType, String)] = [
            ("varnothing", .ordinary, "\u{2205}"), ("nexists", .ordinary, "\u{2204}"), ("complement", .ordinary, "\u{2201}"),
            ("checkmark", .ordinary, "\u{2713}"), ("Box", .ordinary, "\u{25A1}"), ("blacksquare", .ordinary, "\u{25A0}"),
            ("qed", .ordinary, "\u{25A0}"), ("dots", .ordinary, "\u{2026}"), ("dotsc", .ordinary, "\u{2026}"),
            ("dotsb", .ordinary, "\u{22EF}"), ("dotsm", .ordinary, "\u{22EF}"), ("dotsi", .ordinary, "\u{22EF}"),
            ("dotso", .ordinary, "\u{2026}"), ("lvert", .open, "|"), ("rvert", .close, "|"),
            ("lVert", .open, "\u{2016}"), ("rVert", .close, "\u{2016}"), ("llbracket", .open, "\u{27E6}"),
            ("rrbracket", .close, "\u{27E7}"), ("diamond", .binaryOperator, "\u{22C4}"),
            ("triangleleft", .binaryOperator, "\u{25C3}"), ("triangleright", .binaryOperator, "\u{25B9}"),
        ]
        for (name, kind, val) in ordinaries {
            MTMathAtomFactory.folioAddSymbol(name, type: kind, value: val)
        }
    }
}
