use folio_engine::{
    analyze_markdown_document, analyze_markdown_document_with_options,
    compute_newline_continuation, layout_latex, normalize_svg_markup, plain_text_summary,
    render_mermaid_to_svg, replace_code_fence_language, DocumentStats, HtmlInlineTagKind,
    MarkdownBlockDecorationKind, NewlineAction, SyntaxTokenKind, ThemeId, ThemeMetrics,
};

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
    assert!(summary.contains('∇'));
    assert!(summary.contains('ρ'));
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
    assert!(table_rows[0].0); // Header row
    assert!(table_rows[1].1); // Separator row
    assert!(!table_rows[2].0); // Body row
    assert!(!table_rows[2].1);
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

#[test]
fn test_flowchart_mermaid_to_svg() {
    let src = "flowchart TD\n    A[Start] --> B{Decision}\n    B -->|Yes| C((Done))\n";
    let res = render_mermaid_to_svg(src, false);
    assert!(res.svg.starts_with("<svg"));
    assert!(res.svg.contains("Start"));
    assert!(res.svg.contains("Decision"));
    assert!(res.svg.contains("Done"));
    assert!(res.width > 100.0);
    assert!(res.height > 100.0);
}

#[test]
fn test_sequence_diagram_to_svg() {
    let src = "sequenceDiagram\n    Alice->>Bob: Hello Bob\n    Bob-->>Alice: Hi Alice\n";
    let res = render_mermaid_to_svg(src, true);
    assert!(res.svg.contains("Alice"));
    assert!(res.svg.contains("Bob"));
    assert!(res.svg.contains("Hello Bob"));
}

#[test]
fn test_pie_and_state_and_class_diagrams() {
    let pie = "pie title Pets\n    \"Dogs\" : 60\n    \"Cats\" : 40\n";
    let pie_svg = render_mermaid_to_svg(pie, false);
    assert!(pie_svg.svg.contains("Pets"));
    assert!(pie_svg.svg.contains("Dogs"));

    let state = "stateDiagram-v2\n    [*] --> Idle\n    Idle --> Running : start\n";
    let state_svg = render_mermaid_to_svg(state, false);
    assert!(state_svg.svg.contains("Idle"));
    assert!(state_svg.svg.contains("Running"));

    let class = "classDiagram\n    Animal <|-- Duck\n    class Duck {\n        +swim()\n    }\n";
    let class_svg = render_mermaid_to_svg(class, false);
    assert!(class_svg.svg.contains("Animal"));
    assert!(class_svg.svg.contains("Duck"));
}

#[test]
fn test_normalize_svg_markup() {
    let raw = "<svg viewBox=\"0 0 320 180\"><circle cx=\"50\" cy=\"50\" r=\"40\"/></svg>";
    let (svg, width, height) = normalize_svg_markup(raw).unwrap();
    assert!((width - 320.0).abs() < f32::EPSILON);
    assert!((height - 180.0).abs() < f32::EPSILON);
    assert!(svg.contains("xmlns="));
}

#[test]
fn test_flowchart_ampersand_in_quoted_label_and_cyclic_state_diagram() {
    let flow = "flowchart LR\n    A[\"R&D & QA\"] --> B[\"Ship <v1>\"]\n";
    let flow_svg = render_mermaid_to_svg(flow, false);
    assert!(flow_svg.svg.contains("R&amp;D &amp; QA"));
    assert!(flow_svg.svg.contains("Ship &lt;v1&gt;"));

    let cyclic_state = "stateDiagram-v2\n    Idle --> Running : start\n    Running --> Idle : stop\n";
    let state_svg = render_mermaid_to_svg(cyclic_state, false);
    assert!(state_svg.svg.contains("Idle"));
    assert!(state_svg.svg.contains("Running"));
}

#[test]
fn test_rich_media_images_mermaid_svg_and_inline_html() {
    let doc = "# Rich Media\n\
        ![Diagram](https://example.com/diagram.png \"Arch\")\n\
        <img src=\"assets/logo.svg\" alt=\"Logo\" width=\"240\" height=\"80\" />\n\
        Press <kbd>Cmd+P</kbd> for <mark>highlight</mark>, H<sub>2</sub>O, x<sup>2</sup>, and <u>underline</u>.\n\
        ```mermaid\n\
        flowchart LR\n\
            A[Source] --> B[Rendered SVG]\n\
        ```\n\
        <svg viewBox=\"0 0 200 80\"><rect width=\"200\" height=\"80\" rx=\"8\"/></svg>\n";

    let analysis = analyze_markdown_document_with_options(doc, 0, false, false, true, false);
    assert!(analysis.block_decorations.iter().any(|b| matches!(
        &b.kind,
        MarkdownBlockDecorationKind::Image { alt, url, is_html: false, .. }
            if alt == "Diagram" && url == "https://example.com/diagram.png"
    )));
    assert!(analysis.block_decorations.iter().any(|b| matches!(
        &b.kind,
        MarkdownBlockDecorationKind::Image { alt, url, width: Some(240), height: Some(80), is_html: true, .. }
            if alt == "Logo" && url == "assets/logo.svg"
    )));
    assert!(analysis.block_decorations.iter().any(|b| matches!(
        &b.kind,
        MarkdownBlockDecorationKind::MermaidBlock { svg, .. } if svg.starts_with("<svg")
    )));
    assert!(analysis.block_decorations.iter().any(|b| matches!(
        &b.kind,
        MarkdownBlockDecorationKind::SvgBlock { width, height, .. }
            if (*width - 200.0).abs() < 0.1 && (*height - 80.0).abs() < 0.1
    )));
    assert!(analysis.block_decorations.iter().any(|b| matches!(
        &b.kind,
        MarkdownBlockDecorationKind::HtmlInline { tag: HtmlInlineTagKind::Kbd, .. }
    )));
    assert!(analysis
        .syntax_fold_spans
        .iter()
        .any(|s| s.kind == SyntaxTokenKind::HtmlTag && !s.is_revealed));

    let raw_analysis = analyze_markdown_document_with_options(doc, 999, false, false, false, false);
    assert!(raw_analysis.syntax_fold_spans.iter().all(|s| s.is_revealed));
}
