use folio_engine::markdown::split_gfm_table_cells;
use folio_engine::{
    analyze_markdown_document, layout_latex, plain_text_summary, MarkdownBlockDecorationKind,
    SyntaxTokenKind,
};

#[test]
fn test_commonmark_atx_headings_indentation_and_closing_hashes() {
    let md = "   # Indented H1\n## Heading with closing hashes ###   \n### Keep # hash\n";
    let analysis = analyze_markdown_document(md, 999, false, false);
    assert_eq!(analysis.headings.len(), 3);
    assert_eq!(analysis.headings[0].level, 1);
    assert_eq!(analysis.headings[0].title, "Indented H1");
    assert_eq!(analysis.headings[1].level, 2);
    assert_eq!(analysis.headings[1].title, "Heading with closing hashes");
    assert_eq!(analysis.headings[2].level, 3);
    assert_eq!(analysis.headings[2].title, "Keep # hash");
}

#[test]
fn test_commonmark_setext_headings() {
    let md = "Setext Heading 1\n================\n\nSetext Heading 2\n----------------\n";
    let analysis = analyze_markdown_document(md, 999, false, false);
    assert_eq!(analysis.headings.len(), 2);
    assert_eq!(analysis.headings[0].level, 1);
    assert_eq!(analysis.headings[0].title, "Setext Heading 1");
    assert_eq!(analysis.headings[1].level, 2);
    assert_eq!(analysis.headings[1].title, "Setext Heading 2");
}

#[test]
fn test_commonmark_intraword_underscores_and_code_protection() {
    let md = "Identifier foo_bar_baz and `FUNCTIONS_EMAIL_CREDENTIALS_JSON` and _real italic_.\n";
    let analysis = analyze_markdown_document(md, 999, false, false);
    let italic_folds: Vec<_> = analysis
        .syntax_fold_spans
        .iter()
        .filter(|s| s.kind == SyntaxTokenKind::ItalicMarker)
        .collect();
    assert_eq!(italic_folds.len(), 2);
    assert_eq!(&md[italic_folds[0].byte_range.clone()], "_");
    assert_eq!(&md[italic_folds[1].byte_range.clone()], "_");
}

#[test]
fn test_nested_bold_link_with_inline_code() {
    let md = "| **[`architecture/`](./architecture/README.md)** | System design |\n";
    let analysis = analyze_markdown_document(md, 999, false, false);
    assert!(analysis
        .syntax_fold_spans
        .iter()
        .any(|s| s.kind == SyntaxTokenKind::BoldMarker));
    assert!(analysis
        .syntax_fold_spans
        .iter()
        .any(|s| s.kind == SyntaxTokenKind::LinkSyntax));
    assert!(analysis
        .syntax_fold_spans
        .iter()
        .any(|s| s.kind == SyntaxTokenKind::InlineCodeBackticks));
    assert!(analysis
        .block_decorations
        .iter()
        .any(|b| matches!(b.kind, MarkdownBlockDecorationKind::InlineCode)));
}

#[test]
fn test_gfm_table_splitting_with_code_pipes_and_escaped_pipes() {
    let row = "| `a | b` | Escaped \\| pipe | $|x|$ | Plain <br/> cell |";
    let cells = split_gfm_table_cells(row);
    assert_eq!(
        cells,
        vec!["`a | b`", "Escaped | pipe", "$|x|$", "Plain   cell"]
    );
}

#[test]
fn test_commonmark_tilde_and_backtick_fences() {
    let md = "~~~python\ndef foo():\n    # Not a heading\n    pass\n~~~\n";
    let analysis = analyze_markdown_document(md, 999, false, false);
    assert!(analysis.headings.is_empty());
    assert!(analysis.block_decorations.iter().any(|b| matches!(
        &b.kind,
        MarkdownBlockDecorationKind::CodeFenceStart { language } if language == "python"
    )));
}

#[test]
fn test_anchor_image_scanning_folds_outer_link_syntax() {
    let md = "[![Download Latest Folio.dmg](https://img.shields.io/badge/Download_Folio.dmg-blue)](https://github.com/lukeredmore/folio/releases/latest/download/Folio.dmg)";
    let analysis = analyze_markdown_document(md, 99, false, false);
    assert_eq!(analysis.syntax_fold_spans.len(), 2);
    assert_eq!(analysis.syntax_fold_spans[0].byte_range, 0..3);
    assert_eq!(analysis.syntax_fold_spans[1].byte_range, 28..md.len());

    let img_decos: Vec<_> = analysis
        .block_decorations
        .iter()
        .filter_map(|d| match &d.kind {
            MarkdownBlockDecorationKind::Image { alt, url, .. } => {
                Some((d.byte_range.clone(), alt.clone(), url.clone()))
            }
            _ => None,
        })
        .collect();
    assert_eq!(img_decos.len(), 1);
    assert_eq!(img_decos[0].0, 0..md.len());
    assert_eq!(img_decos[0].1, "Download Latest Folio.dmg");
    assert_eq!(
        img_decos[0].2,
        "https://img.shields.io/badge/Download_Folio.dmg-blue"
    );
}

fn min_duration(runs: usize, mut work: impl FnMut()) -> std::time::Duration {
    (0..runs)
        .map(|_| {
            let start = std::time::Instant::now();
            work();
            start.elapsed()
        })
        .min()
        .unwrap_or_default()
}

fn assert_near_linear_scaling(label: &str, small: usize, mut work: impl FnMut(usize)) {
    const FACTOR: usize = 4;
    const MAX_RATIO: f64 = 10.0;
    work(small);
    let t_small = min_duration(3, || work(small));
    let t_large = min_duration(3, || work(small * FACTOR));
    let ratio = t_large.as_secs_f64() / t_small.as_secs_f64().max(1e-6);
    eprintln!("{label}: {t_small:?} -> {t_large:?} ({ratio:.2}x for {FACTOR}x input)");
    assert!(
        ratio < MAX_RATIO,
        "{label}: {FACTOR}x input took {ratio:.1}x longer ({t_small:?} -> {t_large:?}); linear is ~{FACTOR}x, quadratic ~{}x",
        FACTOR * FACTOR
    );
    assert!(
        t_large.as_secs() < 10,
        "{label}: {t_large:?} for the large input exceeds the 10 s hang cap"
    );
}

fn adversarial_markdown(n: usize) -> String {
    [
        "`a ".repeat(n),
        "``a ".repeat(n),
        "```a ".repeat(n),
        "*a ".repeat(n),
        "_a ".repeat(n),
        "**a ".repeat(n),
        "__a ".repeat(n),
        "***a ".repeat(n),
        "~~a ".repeat(n),
        "==a ".repeat(n),
        "$a ".repeat(n),
        "[a ".repeat(n),
        "[a](http://example.com/".repeat(n / 2),
        format!("{}[inner](https://example.com)", "[outer ".repeat(n)),
        "<http://example.com/".repeat(n / 2),
    ]
    .join("\n\n")
}

#[test]
fn test_adversarial_markdown_scales_linearly() {
    let analysis = analyze_markdown_document(&adversarial_markdown(500), 99999, false, false);
    assert!(!analysis.syntax_fold_spans.is_empty());
    assert_near_linear_scaling("adversarial markdown analysis", 500, |n| {
        let md = adversarial_markdown(n);
        std::hint::black_box(analyze_markdown_document(&md, 99999, false, false));
    });
}

#[test]
fn test_adversarial_math_scales_linearly() {
    let deep_braces = |d: usize| format!("{}{}{}", "{".repeat(d), "x+1", "}".repeat(d));
    let deep_supers = |d: usize| "x^".repeat(d) + "2";
    let stray_closing_braces = "}}}}}}x+y}}}}}}";
    let left_with_rightarrow = r"\left( a \rightarrow b } c \right)";

    assert!(layout_latex(&deep_braces(500), 16.0, false).width > 0.0);
    assert!(layout_latex(&deep_supers(500), 16.0, false).width > 0.0);
    assert!(layout_latex(stray_closing_braces, 16.0, false).width > 0.0);
    assert!(layout_latex(left_with_rightarrow, 16.0, false).width > 0.0);
    assert!(plain_text_summary(left_with_rightarrow).contains('→'));

    assert_near_linear_scaling("nested LaTeX layout", 125, |d| {
        for _ in 0..20 {
            std::hint::black_box(layout_latex(&deep_braces(d), 16.0, false));
            std::hint::black_box(layout_latex(&deep_supers(d), 16.0, false));
        }
    });
}
