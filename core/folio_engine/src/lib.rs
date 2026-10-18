pub mod ffi;
pub mod markdown;
pub mod math;
pub mod stats;
pub mod theme;

pub use markdown::{
    analyze_markdown_document, compute_newline_continuation, replace_code_fence_language,
    MarkdownAnalysis, MarkdownBlockDecoration, MarkdownBlockDecorationKind, NewlineAction,
    OutlineHeadingItem, SyntaxFoldSpan, SyntaxTokenKind,
};
pub use math::{
    layout_latex, layout_math_node, parse_latex, plain_text_summary, MathDrawPrimitive,
    MathFontStyle, MathLayoutPlan, MathNode,
};
pub use stats::DocumentStats;
pub use theme::{language_accent_color, RgbaColor, ThemeId, ThemeMetrics};

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_document_stats() {
        let text = "Hello world from Folio.\nSecond line here.";
        let stats = DocumentStats::compute(text, Some((0, 11)));
        assert_eq!(stats.words, 7);
        assert_eq!(stats.lines, 2);
        assert_eq!(stats.selected_words, 2);
        assert_eq!(stats.selected_characters, 11);
    }

    #[test]
    fn test_latex_parser_and_layout() {
        let latex = r"\nabla \cdot \mathbf{E} = \frac{\rho}{\varepsilon_0}";
        let plan = layout_latex(latex, 18.0, true);
        assert!(plan.width > 60.0);
        assert!(plan.ascent > 12.0);
        assert!(plan.descent > 6.0);
        assert!(!plan.primitives.is_empty());

        let summary = plain_text_summary(latex);
        assert!(summary.contains("∇"));
        assert!(summary.contains("ρ"));
    }

    #[test]
    fn test_markdown_analysis_and_newline() {
        let sample = "# Main Title\nSome **bold** and `code` and $\\alpha + \\beta$.\n\n$$\n\\int_0^1 x^2 dx\n$$\n";
        let analysis = analyze_markdown_document(sample, 0, false, false);
        assert_eq!(analysis.headings.len(), 1);
        assert_eq!(analysis.headings[0].title, "Main Title");
        assert!(analysis.syntax_fold_spans.iter().any(|s| s.is_revealed));
        assert!(analysis.syntax_fold_spans.iter().any(|s| !s.is_revealed));
        assert!(analysis
            .block_decorations
            .iter()
            .any(|b| matches!(b.kind, MarkdownBlockDecorationKind::InlineCode)));

        assert_eq!(
            compute_newline_continuation("- [x] Finish engine"),
            NewlineAction::InsertPrefix("- [ ] ".to_string())
        );
        assert_eq!(
            compute_newline_continuation("- [ ]   "),
            NewlineAction::ClearEmptyListLine
        );
        assert_eq!(
            compute_newline_continuation("  1. First item"),
            NewlineAction::InsertPrefix("  2. ".to_string())
        );
    }

    #[test]
    fn test_replace_code_fence_language_and_table_headers() {
        let md = "Intro\n```swift\nlet x = 1\n```\n| Col A | Col B |\n| :--- | :--- |\n| `v1` | `v2` |\n";
        let fence_offset = md.find("```swift").unwrap();
        let updated = replace_code_fence_language(md, fence_offset, "rust").unwrap();
        assert!(updated.contains("```rust\nlet x = 1\n```"));

        let cleared = replace_code_fence_language(&updated, fence_offset, "").unwrap();
        assert!(cleared.contains("```\nlet x = 1\n```"));

        let analysis = analyze_markdown_document(md, 0, false, false);
        let table_rows: Vec<_> = analysis
            .block_decorations
            .iter()
            .filter_map(|b| match &b.kind {
                MarkdownBlockDecorationKind::TableRow {
                    is_header,
                    is_separator,
                    columns,
                } => Some((*is_header, *is_separator, columns.clone())),
                _ => None,
            })
            .collect();
        assert_eq!(table_rows.len(), 3);
        assert_eq!(table_rows[0].0, true); // Header row
        assert_eq!(table_rows[1].1, true); // Separator row
        assert_eq!(table_rows[2].0, false); // Body row
        assert_eq!(table_rows[2].1, false);
    }

    #[test]
    fn test_all_six_themes() {
        for &theme in ThemeId::all() {
            let m = ThemeMetrics::for_theme(theme);
            assert!(m.base_font_size > 12.0);
            assert!(m.max_write_width > 600.0);
        }
        assert!(ThemeMetrics::for_theme(ThemeId::Midnight).is_dark);
        assert!(!ThemeMetrics::for_theme(ThemeId::Daylight).is_dark);
    }
}
