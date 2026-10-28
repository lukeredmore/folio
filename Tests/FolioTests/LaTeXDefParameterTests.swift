import XCTest
@testable import Folio

/// `\def` parameter text: parsing, argument reading, and use in math expansion.
final class LaTeXDefParameterTests: XCTestCase {
    private func definition(_ source: String) -> LaTeXMacroDefinition? {
        LaTeXMacroExpander.extractDocumentMacros(from: source).values.first
    }

    private func arguments(_ def: LaTeXMacroDefinition, _ call: String) -> [String]? {
        let chars = Array(call)
        let (_, afterName) = LaTeXMacroExpander.readControlWord(chars, at: 0)
        return LaTeXMacroExpander.readArguments(for: def, in: chars, from: afterName)?.args
    }

    func testSpaceDelimitedParametersParse() throws {
        let def = try XCTUnwrap(definition(#"\def\IT#1 #2 {[#1|#2]}"#))
        XCTAssertEqual(def.name, #"\IT"#)
        XCTAssertEqual(def.argCount, 2)
        XCTAssertEqual(def.parameterText, LaTeXParameterText(leading: "", delimiters: [" ", " "]))
        XCTAssertEqual(def.replacement, "[#1|#2]")
    }

    func testLeadingAndLiteralDelimitersParse() throws {
        let def = try XCTUnwrap(definition(#"\def\pt(#1,#2){P_{#1#2}}"#))
        XCTAssertEqual(def.argCount, 2)
        XCTAssertEqual(def.parameterText, LaTeXParameterText(leading: "(", delimiters: [",", ")"]))
    }

    func testUndelimitedParametersKeepPlainDefinition() throws {
        let def = try XCTUnwrap(definition(#"\def\pair#1#2{(#1,#2)}"#))
        XCTAssertEqual(def.argCount, 2)
        XCTAssertNil(def.parameterText)
        XCTAssertEqual(arguments(def, #"\pair{a} b"#), ["a", "b"])
    }

    func testUnsupportedParameterTextFailsSafely() {
        XCTAssertNil(definition(#"\def\bad##1{x}"#), "## is not supported")
        XCTAssertNil(definition(#"\def\bad#2{x}"#), "parameters must be numbered in order")
        XCTAssertNil(definition(#"\def\bad#1}{x}"#), "a closing brace in parameter text is malformed")
        XCTAssertNil(definition(#"\def\bad#{x}"#), "a # before the body brace is not supported")
        XCTAssertNil(definition(#"\def\bad#1 "#), "there is no body")
    }

    func testDelimitedArgumentsFollowTeXRules() throws {
        let def = try XCTUnwrap(definition(#"\def\IT#1 #2 {[#1|#2]}"#))
        XCTAssertEqual(arguments(def, #"\IT{a b} {c d} rest"#), ["a b", "c d"], "a single braced group loses its braces")
        XCTAssertEqual(arguments(def, #"\IT x   y rest"#), ["x", "y"], "a space delimiter matches a run of spaces")
        XCTAssertEqual(arguments(def, #"\IT{a} {b}"#), ["a", "b"], "the end of the line counts as a space")
        XCTAssertEqual(arguments(def, #"\IT{a b}c {d}"#), ["{a b}c", "d"], "braces stay when the argument is not one group")

        let paren = try XCTUnwrap(definition(#"\def\pt(#1){<#1>}"#))
        XCTAssertEqual(arguments(paren, #"\pt({)}x) tail"#), ["{)}x"], "delimiters only match at brace depth zero")
        XCTAssertNil(arguments(paren, #"\pt(x"#), "a missing delimiter fails")
        XCTAssertNil(arguments(paren, #"\pt x)"#), "missing leading text fails")
    }

    func testMathExpansionUsesDelimitedArguments() {
        let macros = LaTeXMacroExpander.extractDocumentMacros(from: #"\def\pt(#1,#2){P_{#1#2}}"#)
        let (expanded, _) = LaTeXMacroExpander.expandAndNormalize(#"\pt(a,b) + 1"#, macros: macros)
        XCTAssertEqual(expanded, "P_{ab} + 1")
    }

    func testNewEnvironmentIsStoredUnderEnvironmentKey() throws {
        let macros = LaTeXMacroExpander.extractDocumentMacros(
            from: "\\newenvironment{LIST}[1]%\n  {\\begin{list}{}{#1}}%\n  {\\end{list}}\n\\newcommand{\\x}{y}"
        )
        let env = try XCTUnwrap(macros[LaTeXMacroDefinition.environmentKey("LIST")])
        XCTAssertTrue(env.isEnvironment)
        XCTAssertEqual(env.argCount, 1)
        XCTAssertEqual(env.environmentEnd, #"\end{list}"#)
        XCTAssertNotNil(macros[#"\x"#])
    }
}
