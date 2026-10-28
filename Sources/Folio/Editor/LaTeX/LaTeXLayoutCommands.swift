import AppKit
import Foundation

/// A font or alignment declaration that lasts until its TeX group ends.
enum LaTeXFlowDeclaration: Equatable, Hashable, Sendable {
    /// A declaration without arguments, such as `\itshape` or `\large`.
    case named(String)
    /// `\fontsize{size}{skip}`, with the size in points.
    case fontSize(CGFloat)
    /// `\fontfamily`, `\fontseries`, or `\fontshape` with its value.
    case fontSelection(command: String, value: String)
    case alignment(NSTextAlignment)
}

/// A change to the TeX group and font state that a source line makes.
enum LaTeXFlowEffect: Equatable, Hashable, Sendable {
    case beginEnvironment(String)
    case endEnvironment(String)
    case openGroup
    case closeGroup
    case declaration(LaTeXFlowDeclaration)
}

/// Commands that print nothing: font declarations, spacing, rules, page styles, length and
/// register settings, and definitions. Folio hides them in prose lines, folds lines that hold only
/// them, and applies font declarations to the text that follows.
enum LaTeXLayoutCommands {
    enum Kind: Equatable {
        /// Prints nothing and has no effect that Folio shows.
        case invisible
        /// A font or alignment declaration.
        case declaration
        /// A rule. `\rule` draws a visible bar unless its width or height is zero.
        case rule
    }

    struct Entry {
        let kind: Kind
        /// Optional `[..]` arguments before the braced ones.
        var brackets = 0
        /// Required `{..}` arguments.
        var braces = 0
        /// Optional `[..]` arguments after the braced ones.
        var trailingBrackets = 0
        /// A TeX dimension such as `-1.5mm` follows the name.
        var dimension = false
    }

    /// Environments whose `\begin` and `\end` lines Folio folds while it styles the lines between
    /// them as usual.
    static let flowWrapperEnvironments: Set<String> = [
        "titlepage", "minipage", "multicols", "multicols*", "flushleft", "flushright", "raggedright", "samepage"
    ]

    static let entries: [String: Entry] = {
        var table: [String: Entry] = [:]
        let invisible = [
            "hfill", "vfill", "hfil", "vfil", "hss", "vss", "newline", "par", "indent", "noindent", "smallskip", "medskip",
            "bigskip", "clearpage", "newpage", "cleardoublepage", "protect", "relax", "unskip", "null", "leavevmode", "strut",
            "selectfont", "boldmath", "unboldmath", "makeatletter", "makeatother", "tableofcontents", "listoffigures",
            "listoftables", "nopagebreak", "allowbreak", "nobreak", "frenchspacing", "nonfrenchspacing", "sloppy", "fussy",
            "printindex", "appendix", "mainmatter", "frontmatter", "backmatter", "recalctypearea", "normalcolor"
        ]
        for name in invisible { table[name] = Entry(kind: .invisible) }
        for name in ["linebreak", "pagebreak"] { table[name] = Entry(kind: .invisible, brackets: 1) }
        let oneArgument = [
            "vspace", "hspace", "pagestyle", "thispagestyle", "markright", "pagenumbering", "newcounter", "stepcounter",
            "refstepcounter", "enlargethispage", "linespread", "color", "pagecolor", "addvspace", "hyphenation", "label", "index",
            "addcontentsline"
        ]
        for name in oneArgument { table[name] = Entry(kind: .invisible, braces: 1) }
        table["addcontentsline"] = Entry(kind: .invisible, braces: 3)
        table["color"] = Entry(kind: .invisible, brackets: 1, braces: 1)
        let twoArguments = ["markboth", "setlength", "addtolength", "settowidth", "settoheight", "settodepth", "setcounter", "addtocounter"]
        for name in twoArguments { table[name] = Entry(kind: .invisible, braces: 2) }
        for name in ["kern", "hskip", "vskip", "mkern", "mskip", "penalty"] { table[name] = Entry(kind: .invisible, dimension: true) }
        table["rule"] = Entry(kind: .rule, brackets: 1, braces: 2)
        table["hrule"] = Entry(kind: .rule)
        table["vrule"] = Entry(kind: .invisible)
        let declarations = [
            "rmfamily", "sffamily", "ttfamily", "mdseries", "bfseries", "itshape", "upshape", "slshape", "scshape", "normalfont",
            "em", "tiny", "scriptsize", "footnotesize", "small", "normalsize", "large", "Large", "LARGE", "huge", "Huge",
            "centering", "raggedleft", "raggedright"
        ]
        for name in declarations { table[name] = Entry(kind: .declaration) }
        for name in ["fontfamily", "fontseries", "fontshape"] { table[name] = Entry(kind: .declaration, braces: 1) }
        table["fontsize"] = Entry(kind: .declaration, braces: 2)
        return table
    }()

    /// Commands that define macros, lengths, counters, or registers. A line that holds only
    /// these prints nothing.
    static let definitionCommands: Set<String> = [
        "newcommand", "renewcommand", "providecommand", "DeclareRobustCommand", "def", "gdef", "edef", "xdef", "let",
        "newenvironment", "renewenvironment", "newlength", "newcount", "newdimen", "newskip", "newtoks", "newbox", "newif",
        "advance", "multiply", "divide", "global"
    ]

    /// LaTeX lengths that a document sets with `\name<value>` or `\name=<value>`.
    static let lengthRegisters: Set<String> = [
        "arraycolsep", "tabcolsep", "parindent", "parskip", "baselineskip", "columnsep", "columnseprule", "itemsep",
        "topsep", "partopsep", "parsep", "leftmargin", "rightmargin", "itemindent", "labelsep", "labelwidth", "fboxsep",
        "fboxrule", "arrayrulewidth", "doublerulesep", "oddsidemargin", "evensidemargin", "topmargin", "headsep",
        "footskip", "textwidth", "textheight", "linewidth", "unitlength", "lineskip", "emergencystretch", "looseness",
        "tolerance", "pretolerance", "hbadness", "vbadness", "hfuzz", "vfuzz", "linepenalty", "hyphenpenalty"
    ]

    /// The declaration that a declaration command with its arguments makes.
    static func declaration(named name: String, arguments: [String]) -> LaTeXFlowDeclaration? {
        switch name {
        case "fontsize":
            guard let first = arguments.first, let size = LaTeXLength.parse(first)?.resolvedPoints(baseSize: 10), size > 0 else { return nil }
            return .fontSize(size)
        case "fontfamily", "fontseries", "fontshape":
            guard let value = arguments.first else { return nil }
            return .fontSelection(command: name, value: value.trimmingCharacters(in: .whitespaces))
        case "centering":
            return .alignment(.center)
        case "raggedleft":
            return .alignment(.right)
        case "raggedright":
            return .alignment(.left)
        default:
            return .named(name)
        }
    }
}
