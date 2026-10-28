use folio_engine::{
    analyze_macro_template, classify_latex_line, normalize_display_math, parse_bibtex_entries,
    scan_latex_directives, scan_latex_inlines, LatexDirectiveKind, LatexInlineSpan,
    LatexInlineSpanKind, LatexLineKind,
};

#[test]
fn test_scan_latex_inlines_single_pass() {
    let line = r"Hello $\alpha + \beta$ and \textbf{bold \emph{italic}} with \cite[p.~4]{knuth84} ``quotes'' \& \%";
    let spans = scan_latex_inlines(line);
    assert!(spans
        .iter()
        .any(|s| s.kind == LatexInlineSpanKind::InlineMath && s.arg == r"\alpha + \beta"));
    assert!(spans
        .iter()
        .any(|s| s.kind == LatexInlineSpanKind::StyleCmd && s.cmd == "textbf"));
    assert!(spans
        .iter()
        .any(|s| s.kind == LatexInlineSpanKind::StyleCmd && s.cmd == "emph"));
    assert!(spans
        .iter()
        .any(|s| s.kind == LatexInlineSpanKind::Cite && s.arg == "knuth84"));
    assert_eq!(
        spans
            .iter()
            .filter(|s| s.kind == LatexInlineSpanKind::TexQuote)
            .count(),
        2
    );
    assert_eq!(
        spans
            .iter()
            .filter(|s| s.kind == LatexInlineSpanKind::EscapedChar)
            .count(),
        2
    );
}

#[test]
fn test_scan_latex_directives_preamble_and_body() {
    let d1 = scan_latex_directives(r"\documentclass[11pt,a4paper]{article}", true);
    assert_eq!(d1.len(), 1);
    assert_eq!(d1[0].kind, LatexDirectiveKind::DocumentClass);
    assert_eq!(d1[0].opt_arg, "11pt,a4paper");
    assert_eq!(d1[0].arg1, "article");

    let d2 = scan_latex_directives(r"\newif\ifblind \blindfalse % \blindtrue in comment", true);
    assert_eq!(d2.len(), 2);
    assert_eq!(d2[0].kind, LatexDirectiveKind::NewIf);
    assert_eq!(d2[0].arg1, "blind");
    assert_eq!(d2[1].kind, LatexDirectiveKind::ToggleIf);
    assert_eq!(d2[1].arg1, "blind");
    assert_eq!(d2[1].arg2, "false");

    let d3 = scan_latex_directives(r"\definecolor{accent}{HTML}{1E5AA8}", true);
    assert_eq!(d3.len(), 1);
    assert_eq!(d3[0].kind, LatexDirectiveKind::DefineColor);
    assert_eq!(d3[0].arg1, "accent");
    assert_eq!(d3[0].arg2, "HTML");
    assert_eq!(d3[0].arg3, "1E5AA8");

    let d4 = scan_latex_directives(r"  \subsection*{Variational \textbf{Principle}}", false);
    assert_eq!(d4.len(), 1);
    assert_eq!(d4[0].kind, LatexDirectiveKind::Section);
    assert!(d4[0].starred);
    assert_eq!(d4[0].cmd, "subsection");
    assert_eq!(d4[0].arg1, "Variational Principle");
}

#[test]
fn test_classify_latex_line_and_macro_template() {
    let c1 = classify_latex_line(r"  \item[Step 1] Compute the gradient");
    assert_eq!(c1.kind, LatexLineKind::Item);
    assert!(c1.has_opt_arg);
    assert_eq!(c1.opt_arg, "Step 1");

    let c2 = classify_latex_line(r"  \toprule  ");
    assert_eq!(c2.kind, LatexLineKind::TableRule);

    let c3 = classify_latex_line(r"\answer[4cm]{");
    assert_eq!(c3.kind, LatexLineKind::MacroBlockOpen);
    assert_eq!(c3.cmd, "answer");
    assert!(c3.has_opt_arg);
    assert_eq!(c3.opt_arg, "4cm");

    let tpl = analyze_macro_template(r"{\color{accent}\textbf{Solution:} #2}", "#2");
    assert!(tpl.shows_body);
    assert_eq!(tpl.color_name, "accent");
    assert_eq!(tpl.prefix_label, "Solution:");

    let math = normalize_display_math(
        r"a &= b \label{eq:1} \tag{A.1} \\ c &= d \nonumber",
        "align*",
    );
    assert_eq!(math.explicit_tag, "A.1");
    assert!(math.cleaned_latex.starts_with(r"\begin{aligned}"));
    assert!(!math.cleaned_latex.contains(r"\label"));
    assert!(!math.cleaned_latex.contains(r"\tag"));
}

#[test]
fn test_parse_bibtex_entries() {
    let bib = r#"
@article{knuth1984,
  author = {Knuth, Donald E.},
  title = {Literate {Programming}},
  year = 1984
}
"#;
    let entries = parse_bibtex_entries(bib);
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0].key, "knuth1984");
    assert_eq!(entries[0].entry_type, "article");
    assert_eq!(entries[0].author, "Knuth, Donald E.");
    assert_eq!(entries[0].year, "1984");
}

fn candidates(line: &str) -> Vec<LatexInlineSpan> {
    scan_latex_inlines(line)
        .into_iter()
        .filter(|s| s.kind == LatexInlineSpanKind::ProseMacroCandidate)
        .collect()
}

fn slice(line: &str, loc: usize, len: usize) -> String {
    let units: Vec<u16> = line.encode_utf16().collect();
    String::from_utf16(&units[loc..loc + len]).unwrap()
}

#[test]
fn test_prose_macro_candidate_covers_adjacent_argument_groups() {
    let line = r"All \VAR{number}s and \pair[o]{a}{b} end";
    let spans = candidates(line);
    assert_eq!(spans.len(), 2);
    assert_eq!(spans[0].cmd, "VAR");
    assert_eq!(
        slice(line, spans[0].full_loc, spans[0].full_len),
        r"\VAR{number}"
    );
    assert_eq!(slice(line, spans[0].open_loc, spans[0].open_len), r"\VAR");
    assert_eq!(
        slice(line, spans[0].close_loc, spans[0].close_len),
        "{number}"
    );
    assert_eq!(spans[1].cmd, "pair");
    assert_eq!(
        slice(line, spans[1].full_loc, spans[1].full_len),
        r"\pair[o]{a}{b}"
    );
}

#[test]
fn test_prose_macro_candidate_keeps_nested_candidates_and_star() {
    let line = r"(\FU*{=}\RP{\VAR{x}})";
    let spans = candidates(line);
    let names: Vec<&str> = spans.iter().map(|s| s.cmd.as_str()).collect();
    assert_eq!(names, ["FU*", "RP", "VAR"]);
    assert_eq!(
        slice(line, spans[0].full_loc, spans[0].full_len),
        r"\FU*{=}"
    );
    assert_eq!(
        slice(line, spans[1].full_loc, spans[1].full_len),
        r"\RP{\VAR{x}}"
    );
}

#[test]
fn test_prose_macro_candidate_edge_forms() {
    let empty = candidates(r"\foo{} x");
    assert_eq!(empty.len(), 1);
    assert_eq!(empty[0].full_len, 6);

    let unclosed = r"\foo{bar";
    let spans = candidates(unclosed);
    assert_eq!(spans.len(), 1);
    assert_eq!(
        slice(unclosed, spans[0].full_loc, spans[0].full_len),
        r"\foo"
    );

    let spaced = r"\foo {x}";
    let spans = candidates(spaced);
    assert_eq!(slice(spaced, spans[0].full_loc, spans[0].full_len), r"\foo");
}

#[test]
fn test_known_commands_are_not_prose_macro_candidates() {
    let line = r"\textbf{b} \cite{k} \index{key@$k$} \href{u}{t}";
    assert!(candidates(line).is_empty());
    assert!(scan_latex_inlines(line)
        .iter()
        .any(|s| s.kind == LatexInlineSpanKind::HiddenMeta && s.cmd == "index"));
}

fn inline_math(text: &str) -> Vec<String> {
    scan_latex_inlines(text)
        .into_iter()
        .filter(|s| s.kind == LatexInlineSpanKind::InlineMath)
        .map(|s| slice(text, s.full_loc, s.full_len))
        .collect()
}

#[test]
fn test_inline_math_continues_across_one_line_break() {
    assert_eq!(
        inline_math("\\retval{$\\cos\n  a$}, $b$"),
        ["$\\cos\n  a$", "$b$"]
    );
    assert!(
        inline_math("$a\n  \nb$").is_empty(),
        "a blank line ends the paragraph and the math"
    );
    assert!(inline_math("$a\n").is_empty());
}
