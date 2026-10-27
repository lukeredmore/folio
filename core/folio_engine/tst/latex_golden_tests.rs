//! Golden test for the LaTeX directive and inline scanners.
//!
//! Regenerate after an intended change:
//! `UPDATE_GOLDENS=1 bazel run //core/folio_engine:latex_golden_tests`

use std::fmt::Write;
use std::path::{Path, PathBuf};

use folio_engine::latex::{scan_latex_directives, scan_latex_inlines};

fn data_path(env_var: &str, relative: &str) -> PathBuf {
    std::env::var(env_var).map_or_else(
        |_| Path::new(env!("CARGO_MANIFEST_DIR")).join(relative),
        PathBuf::from,
    )
}

fn render_scan(corpus: &str) -> String {
    let mut out = String::new();
    for (n, line) in corpus.lines().enumerate() {
        writeln!(out, "## line {}: {line}", n + 1).unwrap();
        writeln!(out, "preamble: {:?}", scan_latex_directives(line, true)).unwrap();
        writeln!(out, "body: {:?}", scan_latex_directives(line, false)).unwrap();
    }
    for span in scan_latex_inlines(corpus) {
        writeln!(out, "{span:?}").unwrap();
    }
    out
}

#[test]
fn latex_scanners_match_golden_output() {
    let corpus_path = data_path("LATEX_CORPUS", "tst/corpus/latex_commands.tex");
    let corpus = std::fs::read_to_string(&corpus_path).unwrap();
    let actual = render_scan(&corpus);

    if std::env::var_os("UPDATE_GOLDENS").is_some() {
        let root = std::env::var("BUILD_WORKSPACE_DIRECTORY").map_or_else(
            |_| PathBuf::from(env!("CARGO_MANIFEST_DIR")),
            |dir| Path::new(&dir).join("core/folio_engine"),
        );
        std::fs::write(root.join("tst/golden/latex_scan.txt"), &actual).unwrap();
        return;
    }

    let golden_path = data_path("LATEX_GOLDEN", "tst/golden/latex_scan.txt");
    let expected = std::fs::read_to_string(&golden_path).unwrap();
    assert!(
        actual == expected,
        "LaTeX scan output differs from {}. If the change is intended, regenerate with \
         UPDATE_GOLDENS=1 bazel run //core/folio_engine:latex_golden_tests",
        golden_path.display()
    );
}
