use folio_engine::{
    analyze_macro_template, classify_latex_line, normalize_display_math, parse_bibtex_entries,
    scan_latex_directives, scan_latex_inlines, LatexDirectiveKind, LatexInlineSpanKind,
    LatexLineKind,
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
