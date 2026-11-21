import AppKit
import XCTest
@testable import FolioEditor
@testable import FolioEditorTestSupport
@testable import FolioModels

/// End-to-end rendering of custom `.cls`/`.sty` CV projects (altacv-style templates, sidebars,
/// conditionals, `\colorlet` dark-mode contrast, `\cvevent`, `\cvskill`, `\divider`, and
/// setter/header macros).
@MainActor
final class LaTeXCustomClassCVTests: XCTestCase {
    override func setUp() {
        super.setUp()
        LaTeXProjectContext.removeAll()
    }

    override func tearDown() {
        LaTeXProjectContext.removeAll()
        super.tearDown()
    }

    private func altaCVClassSource() -> String {
        #"""
        \NeedsTeXFormat{LaTeX2e}[1995/12/01]
        \ProvidesClass{altacv}[2018/12/01 AltaCV test class]
        \newif\if@raggedtwoe
        \DeclareOption{ragged2e}{\@raggedtwoetrue}
        \ProcessOptions\relax
        \LoadClass{extarticle}
        \RequirePackage[margin=2cm]{geometry}
        \RequirePackage{fontawesome}
        \RequirePackage{ifxetex,ifluatex}

        \newif\ifxetexorluatex
        \ifxetex
          \xetexorluatextrue
        \else
          \ifluatex
            \xetexorluatextrue
          \else
            \xetexorluatexfalse
          \fi
        \fi

        \RequirePackage{xcolor}
        \colorlet{accent}{blue!70!black}
        \colorlet{heading}{black}
        \colorlet{emphasis}{black}
        \colorlet{body}{black!80!white}
        \newcommand{\itemmarker}{{\small\textbullet}}
        \newcommand{\ratingmarker}{\faStar}

        \RequirePackage{etoolbox}
        \RequirePackage{dashrule}
        \RequirePackage{afterpage}

        \setlength{\parindent}{0pt}
        \newcommand{\divider}{\textcolor{body!30}{\hdashrule{\linewidth}{0.6pt}{0.5ex}}\smallskip}
        \newcommand{\sidedivider}{\textcolor{body!30}{\hdashrule{\linewidth}{0.6pt}{0.5ex}}\medskip}
        \newenvironment{fullwidth}{\begin{adjustwidth}{}{\dimexpr-\marginparwidth-\marginparsep\relax}}{\end{adjustwidth}}

        \newcommand{\emailsymbol}{\faAt}
        \newcommand{\phonesymbol}{\faPhone}
        \newcommand{\homepagesymbol}{\faChain}
        \newcommand{\locationsymbol}{\faMapMarker}
        \newcommand{\printinfo}[2]{\mbox{\textcolor{accent}{\normalfont #1}\hspace{0.5em}#2\hspace{2em}}}
        \newcommand{\name}[1]{\def\@name{#1}}
        \newcommand{\tagline}[1]{\def\@tagline{#1}}
        \newcommand{\photo}[2]{\def\@photo{#2}\def\@photodiameter{#1}}
        \newcommand{\email}[1]{\printinfo{\emailsymbol}{#1}}
        \newcommand{\phone}[1]{\printinfo{\phonesymbol}{#1}}
        \newcommand{\homepage}[1]{\printinfo{\homepagesymbol}{#1}}
        \newcommand{\location}[1]{\printinfo{\locationsymbol}{#1}}
        \newcommand{\personalinfo}[1]{\def\@personalinfo{#1}}

        \newcommand{\makecvheader}{%
          \begingroup
            \raggedright\color{emphasis}%
            {\Huge\bfseries{\@name}\par}
            \medskip
            {\large\bfseries\color{accent}\@tagline\par}
            \medskip
            {\footnotesize\bfseries\@personalinfo\par}
          \endgroup\medskip
        }

        \newcommand{\cvsection}[2][]{%
          \bigskip%
          \ifstrequal{#1}{}{}{\marginpar{\vspace*{\dimexpr1pt-\baselineskip}\raggedright\input{#1}}}%
          {\color{heading}\LARGE\bfseries{#2}}\\[-1ex]%
          {\color{heading}\rule{\linewidth}{2pt}\par}\medskip
        }

        \newcommand{\cvsubsection}[1]{%
          \smallskip%
          {\color{emphasis}\large\bfseries{#1}\par}\medskip
        }

        \newcommand{\cvevent}[6]{%
          {\large\color{emphasis}#1\par}
          \smallskip\normalsize
          \ifstrequal{#2}{}{}{
          \textbf{\color{accent}#2}\par
          \smallskip}
          \ifstrequal{#3}{}{}{{\small\makebox[0.5\linewidth][l]{\faCalendar\hspace{0.5em}#3}}}%
          \ifstrequal{#4}{}{}{{\small\makebox[0.5\linewidth][l]{\faMapMarker\hspace{0.5em}#4}}}\par
          \smallskip
          \ifstrequal{#5}{}{}{{\small\makebox[0.5\linewidth][l]{\faChain\hspace{0.5em}#5}}}\par
          \smallskip
          \ifstrequal{#6}{}{}{{\small\makebox[0.5\linewidth][l]{\faChain\hspace{0.5em}#6}}}\par
          \smallskip\normalsize
        }

        \newcommand{\cvsideevent}[4]{%
          {\large\color{emphasis}#1\par}
          \smallskip\normalsize
          \ifstrequal{#2}{}{}{
          \textbf{\color{accent}#2}\par
          \smallskip}
          \ifstrequal{#3}{}{}{{\small\makebox[0.5\linewidth][l]{\faCalendar\hspace{0.5em}#3}}}\par
          \smallskip
          \ifstrequal{#4}{}{}{{\small\makebox[0.5\linewidth][l]{\faMapMarker\hspace{0.5em}#4}}}\par
          \smallskip\normalsize
        }

        \newcommand{\cvachievement}[3]{%
          {\Large\color{accent}#1}\hspace{0.5em}\textbf{\textcolor{emphasis}{#2}} -- #3\par\smallskip
        }

        \newcommand{\cvskill}[2]{%
        \textcolor{emphasis}{\textbf{#1}}\hfill
        \foreach \x in {1,...,5}{%
          \space{\ifnumgreater{\x}{#2}{\color{body!30}}{\color{accent}}\ratingmarker}}\par%
        }

        \newcommand{\addsidebar}[2][]{\marginpar{\ifstrequal{#1}{}{}{\vspace*{#1}}\input{#2}}}
        \newcommand{\addnextpagesidebar}[2][]{\afterpage{\addsidebar[#1]{#2}}}
        """#
    }

    func testAltaCVCustomClassAndSidebarProjectRendering() throws {
        let dir = try makeTemporaryDirectory("AltaCVTest")
        let cvSource = #"""
            \PassOptionsToPackage{dvipsnames}{xcolor}
            \documentclass[10pt,a4paper,ragged2e, normalphoto]{altacv}
            \ifxetexorluatex
              \setmainfont{Georgia}
            \else
              \usepackage[default]{lato}
            \fi
            \definecolor{IFBlue}{HTML}{000000}
            \definecolor{IFLightBlue}{HTML}{000000}
            \definecolor{IFMediumGrey}{HTML}{000000}
            \definecolor{IFGrey}{HTML}{000000}
            \colorlet{heading}{IFBlue}
            \colorlet{accent}{IFLightBlue}
            \colorlet{emphasis}{IFMediumGrey}
            \colorlet{body}{IFGrey}
            \renewcommand{\itemmarker}{{\small\textbullet}}
            \renewcommand{\ratingmarker}{\faCircle}
            \begin{document}
            \name{Níckolas Alves}
            \tagline{Undergraduate Student - Institute of Physics}
            \photo{2.8cm}{avatar}
            \personalinfo{%
              % contact section comment
              \email{nickolas@example.edu}
              \phone{+55 11 90000-0000}
              \location{São Paulo, Brazil}
              \homepage{\url{http://example.edu/~nickolas}}
              % trailing comment
            }
            \begin{fullwidth}
            \makecvheader
            \end{fullwidth}
            \cvsection[page1sidebar]{Formal Education/Degree}
            \cvevent{Physics Undergraduate}{University of São Paulo}{February 2017 -- Ongoing}{São Paulo, Brazil}{}{}
            \divider
            \cvsection{Organization of Events}
            \cvevent{An Introduction to \LaTeX}{I Jayme Tiomno School}{July 2019}{São Paulo, Brazil}{http://example.edu/~nickolas/jayme/2018/latex.html}{\url{http://example.edu/~nickolas/pdf/As_Time_Goes_By___Poster.pdf}}
            \addnextpagesidebar[-1ex]{page2sidebar}
            \end{document}
            """#

        let p1Source = #"""
            \cvsection{More Information}
            \cvachievement{\faChain}{Academic Record}{\url{http://example.edu/~nickolas/summary.pdf}}
            \sidedivider
            \cvsideevent{Mathematical Physics I}{University of São Paulo}{2019}{Brazil}
            """#

        let p2Source = #"""
            \cvsection{Languages}
            \cvskill{Portuguese}{5}
            \sidedivider
            \cvskill{English}{4}
            """#

        try LaTeXProjectFixtures.write(
            [
                "altacv.cls": altaCVClassSource(),
                "cv.tex": cvSource,
                "page1sidebar.tex": p1Source,
                "page2sidebar.tex": p2Source
            ],
            in: dir
        )

        let cvURL = dir.appendingPathComponent("cv.tex")
        let p1URL = dir.appendingPathComponent("page1sidebar.tex")
        let p2URL = dir.appendingPathComponent("page2sidebar.tex")

        let (docIndex, docMacros) = LaTeXDocumentIndexer.cachedIndexAndMacros(
            string: cvSource,
            nsString: cvSource as NSString,
            baseDirectoryURL: dir,
            fileURL: cvURL,
            sourceCodeMode: false
        )

        XCTAssertEqual(docIndex.documentStyle.effectiveMainFontFamily, "Georgia")
        XCTAssertEqual(docIndex.documentStyle.parindent, .points(0))
        XCTAssertEqual(docMacros["\\ratingmarker"]?.replacement, #"\faCircle"#)
        XCTAssertNotNil(docMacros["\\cvevent"])
        XCTAssertNotNil(docMacros["\\cvsection"])

        // Dark mode must lift #000000 print colors so text stays legible on dark themes.
        var darkTheme = EditorTheme.daylight
        darkTheme.isDark = true
        let darkHeading = try XCTUnwrap(docIndex.resolveColor(named: "heading", fallbackTheme: darkTheme).usingColorSpace(.sRGB))
        let darkLum = 0.2126 * darkHeading.redComponent + 0.7152 * darkHeading.greenComponent + 0.0722 * darkHeading.blueComponent
        XCTAssertGreaterThan(darkLum, 0.65, "black custom colors must adapt in dark mode")

        let lightHeading = try XCTUnwrap(docIndex.resolveColor(named: "heading", fallbackTheme: .daylight).usingColorSpace(.sRGB))
        XCTAssertEqual(lightHeading.redComponent, 0.0, accuracy: 0.01, "light mode preserves exact #000000")

        let blueBlack = try XCTUnwrap(LaTeXDocumentIndexer.resolveColorExpression("blue!70!black", customColors: [:]))
        XCTAssertGreaterThan(blueBlack.b, 0.45)
        XCTAssertLessThan(blueBlack.b, 0.55)
        let fadedBody = try XCTUnwrap(
            LaTeXDocumentIndexer.resolveColorExpression("body!30", customColors: docIndex.documentStyle.customColors))
        XCTAssertEqual(fadedBody.r, 0.70, accuracy: 0.02)

        let (storage, analysis) = try LaTeXProjectFixtures.style(cvURL, cursorLine: 0, width: 900)
        let ns = storage.string as NSString
        let richTexts = analysis.decorations.compactMap { dec -> [String]? in
            guard case let .latexInlineRichText(lines, _, _) = dec.kind else { return nil }
            return lines.map { runs in
                runs.map { run -> String in
                    if case let .text(text, _, _, _, _) = run { return text }
                    return ""
                }.joined()
            }
        }
        let allRichJoined = richTexts.flatMap { $0 }.joined(separator: "\n")

        // Outline & section underlines for \cvsection (not \name or \tagline).
        XCTAssertEqual(analysis.headings.map(\.title), ["Formal Education/Degree", "Organization of Events"])
        let underlineCount = analysis.decorations.filter {
            if case let .headingUnderline(level) = $0.kind { return level == 2 }
            return false
        }.count
        XCTAssertEqual(underlineCount, 2)

        // \name and \tagline style larger than body without section underlines.
        let bodyFont = docIndex.bodyFont(size: EditorTheme.daylight.baseFontSize, fallbackTheme: .daylight)
        let nameLoc = ns.range(of: "Níckolas Alves").location
        let nameFont = try XCTUnwrap(storage.attribute(.font, at: nameLoc, effectiveRange: nil) as? NSFont)
        XCTAssertGreaterThan(nameFont.pointSize, bodyFont.pointSize * 1.4)

        // \makecvheader + \divider both render as horizontal rules.
        let ruleCount = analysis.decorations.filter {
            if case .horizontalRule = $0.kind { return true }
            return false
        }.count
        XCTAssertEqual(ruleCount, 2)

        // \addnextpagesidebar renders as an INCLUDE card pointing to page2sidebar.tex.
        let sidebarCard = analysis.decorations.first {
            if case let .latexInputCard(path, _, _, _) = $0.kind { return path == "page2sidebar" }
            return false
        }
        if case let .latexInputCard(_, resolvedURL, _, _) = sidebarCard?.kind {
            XCTAssertEqual(resolvedURL?.standardizedFileURL, p2URL.standardizedFileURL)
        } else {
            XCTFail("Expected latexInputCard for page2sidebar")
        }

        // \personalinfo icons + verbatim ~nickolas preserved.
        XCTAssertTrue(allRichJoined.contains("@ nickolas@example.edu"))
        XCTAssertTrue(allRichJoined.contains("☎ +55 11 90000-0000"))
        XCTAssertTrue(allRichJoined.contains("📍 São Paulo, Brazil"))
        XCTAssertTrue(allRichJoined.contains("🔗 http://example.edu/~nickolas"))

        // Comment inside \personalinfo is collapsed when cursor is away.
        let commentLoc = ns.range(of: "% contact section comment").location
        XCTAssertEqual(storage.attribute(.foregroundColor, at: commentLoc, effectiveRange: nil) as? NSColor, .clear)

        // 6-argument \cvevent renders multi-line rich text with intact links and no trailing empty 🔗 lines.
        let event1 = richTexts.first { $0.contains("Physics Undergraduate") }
        XCTAssertNotNil(event1)
        XCTAssertTrue(event1?.contains("University of São Paulo") == true)
        XCTAssertTrue(event1?.contains(where: { $0.contains("📅 February 2017 – Ongoing") && $0.contains("📍 São Paulo, Brazil") }) == true)
        XCTAssertFalse(event1?.contains(where: { $0.contains("🔗") }) == true, "empty args 5 and 6 should not emit empty link lines")

        XCTAssertTrue(allRichJoined.contains("http://example.edu/~nickolas/jayme/2018/latex.html"))
        XCTAssertTrue(allRichJoined.contains("http://example.edu/~nickolas/pdf/As_Time_Goes_By___Poster.pdf"))

        // Child sidebar files automatically discover cv.tex as sibling master and inherit altacv.cls macros.
        var resolver = LaTeXProjectResolver(fileSystem: .live, limits: LaTeXProjectLimits(), cache: LaTeXFileFactsCache())
        let p1Sig = LaTeXDocumentIndexer.buildIndex(string: p1Source, nsString: p1Source as NSString).projectSignature
        let p2Sig = LaTeXDocumentIndexer.buildIndex(string: p2Source, nsString: p2Source as NSString).projectSignature
        XCTAssertEqual(resolver.resolveMaster(for: p1URL, signature: p1Sig)?.url.standardizedFileURL, cvURL.standardizedFileURL)
        XCTAssertEqual(resolver.resolveMaster(for: p2URL, signature: p2Sig)?.url.standardizedFileURL, cvURL.standardizedFileURL)

        let (_, p1Analysis) = try LaTeXProjectFixtures.style(p1URL, cursorLine: 0, width: 900)
        let p1Joined = p1Analysis.decorations.compactMap { dec -> String? in
            guard case let .latexInlineRichText(lines, _, _) = dec.kind else { return nil }
            return lines.map { $0.compactMap { if case let .text(t, _, _, _, _) = $0 { return t } else { return nil } }.joined() }.joined(separator: "\n")
        }.joined(separator: "\n")
        XCTAssertTrue(p1Joined.contains("🔗"))
        XCTAssertTrue(p1Joined.contains("Academic Record"))
        XCTAssertTrue(p1Joined.contains("Mathematical Physics I"))

        let (_, p2Analysis) = try LaTeXProjectFixtures.style(p2URL, cursorLine: 0, width: 900)
        let p2Joined = p2Analysis.decorations.compactMap { dec -> String? in
            guard case let .latexInlineRichText(lines, _, _) = dec.kind else { return nil }
            return lines.map { $0.compactMap { if case let .text(t, _, _, _, _) = $0 { return t } else { return nil } }.joined() }.joined(separator: "\n")
        }.joined(separator: "\n")
        XCTAssertTrue(p2Joined.contains("Portuguese"))
        XCTAssertTrue(p2Joined.contains("● ● ● ● ●"), "\\foreach loop with \\ratingmarker override should render 5 circles")
    }

    func testLocalStyPackageSubtextAndUserEnvironment() throws {
        let dir = try makeTemporaryDirectory("TLCResumeTest")
        let sty = #"""
            \setmainfont{Baskerville}
            \definecolor{highlight}{RGB}{0, 0, 0}
            \newcommand{\subtext}[1]{\textit{#1}\par\vspace{-.75em}}
            \newenvironment{zitemize}{\begin{itemize}}{\end{itemize}}
            """#
        let doc = #"""
            \documentclass[letter,10pt]{article}
            \usepackage{TLCresume}
            \begin{document}
            \subtext{Company A \hfill Austin, TX}
            \begin{zitemize}
            \item Built distributed builds
            \end{zitemize}
            \end{document}
            """#
        try LaTeXProjectFixtures.write(["TLCresume.sty": sty, "resume.tex": doc], in: dir)
        let docURL = dir.appendingPathComponent("resume.tex")

        let (docIndex, _) = LaTeXDocumentIndexer.cachedIndexAndMacros(
            string: doc,
            nsString: doc as NSString,
            baseDirectoryURL: dir,
            fileURL: docURL,
            sourceCodeMode: false
        )
        XCTAssertEqual(docIndex.documentStyle.effectiveMainFontFamily, "Baskerville")

        let (storage, _) = try LaTeXProjectFixtures.style(docURL, cursorLine: 0, width: 800)
        let ns = storage.string as NSString
        let companyLoc = ns.range(of: "Company A").location
        let font = try XCTUnwrap(storage.attribute(.font, at: companyLoc, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(NSFontManager.shared.traits(of: font).contains(.italicFontMask), "\\subtext body should render italic")

        let zBeginLoc = ns.range(of: #"\begin{zitemize}"#).location
        XCTAssertEqual(storage.attribute(.foregroundColor, at: zBeginLoc, effectiveRange: nil) as? NSColor, .clear)
    }

    func testShowcaseCVClassExampleRendersCleanly() throws {
        let showcaseURL = try copyOfExample(
            "latex_cv_class_showcase.tex",
            companions: ["altacv_showcase.cls", "latex_cv_sidebar.tex"]
        )
        let (_, analysis) = try LaTeXProjectFixtures.style(showcaseURL, cursorLine: 0, width: 900)
        XCTAssertEqual(analysis.headings.map(\.title), ["Education", "Publications & Talks"])
        let rich = analysis.decorations.compactMap { dec -> String? in
            guard case let .latexInlineRichText(lines, _, _) = dec.kind else { return nil }
            return lines.map { $0.compactMap { if case let .text(t, _, _, _, _) = $0 { return t } else { return nil } }.joined() }.joined(separator: "\n")
        }.joined(separator: "\n")
        XCTAssertTrue(rich.contains("Ph.D. in Computational Physics"))
        XCTAssertTrue(rich.contains("Meridian Institute of Technology"))
        XCTAssertTrue(rich.contains("@ elena.rostova@example.edu"))
        XCTAssertTrue(rich.contains("https://example.edu/~erostova"))

        let sidebarURL = showcaseURL.deletingLastPathComponent().appendingPathComponent("latex_cv_sidebar.tex")
        let (_, sidebarAnalysis) = try LaTeXProjectFixtures.style(sidebarURL, cursorLine: 0, width: 900)
        XCTAssertEqual(sidebarAnalysis.headings.map(\.title), ["Research Interests", "Links & Honors", "Teaching", "Languages"])
    }
}
