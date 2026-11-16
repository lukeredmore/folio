use folio_engine::mermaid::postprocess_mermaid_svg;
use folio_engine::{
    analyze_markdown_document, analyze_markdown_document_with_options,
    compute_newline_continuation, extract_xml_attr, layout_latex, normalize_svg_markup,
    plain_text_summary, render_mermaid_to_svg, replace_code_fence_language, DocumentStats,
    HtmlInlineTagKind, MarkdownBlockDecorationKind, NewlineAction, SyntaxTokenKind, ThemeId,
    ThemeMetrics,
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
    let md =
        "Intro\n```swift\nlet x = 1\n```\n| Col A | Col B |\n| :--- | :--- |\n| `v1` | `v2` |\n";
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
fn test_all_five_themes_light_and_dark_variants() {
    let mut dark_bgs = Vec::new();
    for &theme in ThemeId::all() {
        let light = ThemeMetrics::for_theme(theme, false);
        let dark = ThemeMetrics::for_theme(theme, true);
        assert!(!light.is_dark);
        assert!(dark.is_dark);
        assert!(light.base_font_size > 12.0);
        assert!(light.max_write_width > 600.0);
        assert_eq!(light.base_font_size, dark.base_font_size);
        assert_eq!(light.max_write_width, dark.max_write_width);
        assert_ne!(light.editor_bg, dark.editor_bg);
        assert_ne!(light.text_fg, dark.text_fg);
        dark_bgs.push(dark.editor_bg);
    }
    for i in 0..dark_bgs.len() {
        for j in (i + 1)..dark_bgs.len() {
            assert_ne!(dark_bgs[i], dark_bgs[j]);
        }
    }
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
    assert!(!res.svg.contains(r#"dy="1em""#));
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
    let flow = "flowchart LR\n    A[\"R&D & QA\"] --> B[\"Ship &lt;v1&gt;\"]\n";
    let flow_svg = render_mermaid_to_svg(flow, false);
    assert!(flow_svg.svg.contains("R&amp;D &amp; QA"));
    assert!(flow_svg.svg.contains("Ship &lt;v1&gt;"));

    let styler_flow = "flowchart LR\n    Styler[\"Live Buffer Folds & Inlays\"] --> View[\"HybridMarkdownTextView\"]\n";
    let styler_svg = render_mermaid_to_svg(styler_flow, false);
    assert!(
        styler_svg.svg.contains("Live Buffer Folds &amp; Inlays"),
        "SVG was: {}",
        styler_svg.svg
    );

    let cyclic_state =
        "stateDiagram-v2\n    Idle --> Running : start\n    Running --> Idle : stop\n";
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
        MarkdownBlockDecorationKind::HtmlInline {
            tag: HtmlInlineTagKind::Kbd,
            ..
        }
    )));
    assert!(analysis
        .syntax_fold_spans
        .iter()
        .any(|s| s.kind == SyntaxTokenKind::HtmlTag && !s.is_revealed));

    let raw_analysis = analyze_markdown_document_with_options(doc, 999, false, false, false, false);
    assert!(raw_analysis.syntax_fold_spans.iter().all(|s| s.is_revealed));
}

#[test]
fn test_svg_normalizer_closing_before_opening_and_stroke_width_collision() {
    let (_, width, height) =
        normalize_svg_markup("</svg><svg viewBox=\"0 0 100 50\"><rect/></svg>").unwrap();
    assert!((width - 100.0).abs() < f32::EPSILON);
    assert!((height - 50.0).abs() < f32::EPSILON);
    assert!(normalize_svg_markup("</svg><svg>").is_none());

    let (wide_svg, wide_w, wide_h) = normalize_svg_markup(
        "<svg stroke-width=\"1.5\" width=\"400\" height=\"220\"><rect width=\"400\" height=\"220\"/></svg>",
    )
    .unwrap();
    assert!((wide_w - 400.0).abs() < f32::EPSILON);
    assert!((wide_h - 220.0).abs() < f32::EPSILON);
    assert!(wide_svg.contains("stroke-width=\"1.5\""));

    let (styled_svg, _, _) = postprocess_mermaid_svg(
        "<svg viewBox=\"0 0 120 60\"><!-- </style> --><style>svg{fill:red;}</style><rect/></svg>",
        false,
    )
    .unwrap();
    assert!(styled_svg.contains("<style>svg {"));

    let tag = "<img alt=\"width=10\" data-stroke-width=\"2\" width=\"320\" height=\"160\" src=\"diagram.svg\" />";
    assert_eq!(extract_xml_attr(tag, "width"), Some("320"));
    assert_eq!(extract_xml_attr(tag, "height"), Some("160"));
}

#[test]
fn test_svg_markers_scientific_notation_and_stateful_path_commands() {
    let sci_raw = "<svg viewBox=\"0 0 100 100\"><path d=\"M 10 10 l 6.123e-17 40\" marker-end=\"url(#my-svg_flowchart-v2-pointEnd)\"/></svg>";
    let (sci_svg, _, _) = postprocess_mermaid_svg(sci_raw, false).unwrap();
    assert!(
        sci_svg.contains("translate(10.00,50.00) rotate(90.00)"),
        "Expected vertical 90 deg marker tangent for scientific notation delta, got: {sci_svg}"
    );

    let hv_raw = "<svg viewBox=\"0 0 100 100\"><path d=\"M 10 10 H 60 V 50\" marker-start=\"url(#my-svg_flowchart-v2-pointStart)\" marker-end=\"url(#my-svg_flowchart-v2-pointEnd)\"/></svg>";
    let (hv_svg, _, _) = postprocess_mermaid_svg(hv_raw, false).unwrap();
    assert!(
        hv_svg.contains("translate(10.00,10.00) rotate(180.00)"),
        "Expected 180 deg outward start marker for rightward H command, got: {hv_svg}"
    );
    assert!(
        hv_svg.contains("translate(60.00,50.00) rotate(90.00)"),
        "Expected 90 deg end tangent for downward V command, got: {hv_svg}"
    );

    let arc_raw = "<svg viewBox=\"0 0 100 100\"><path d=\"M 10 50 A 20 20 0 0 1 50 50\" marker-start=\"url(#my-svg_flowchart-v2-pointStart)\" marker-end=\"url(#my-svg_flowchart-v2-pointEnd)\"/></svg>";
    let (arc_svg, _, _) = postprocess_mermaid_svg(arc_raw, false).unwrap();
    assert!(
        arc_svg.contains("translate(10.00,50.00) rotate(90.00)"),
        "Expected 90 deg outward start marker for upward (-90 deg) semicircular arc, got: {arc_svg}"
    );
    assert!(
        arc_svg.contains("translate(50.00,50.00) rotate(90.00)"),
        "Expected 90 deg end tangent on semicircular SVG arc, got: {arc_svg}"
    );
}

#[test]
fn test_document_stats_utf8_and_utf16_streaming_parity() {
    let text = "café 🦀 naïve\nsecond line";
    let crab_byte = text.find('🦀').unwrap();
    let naive_end_byte = text.find('\n').unwrap();
    // "café " = 5 UTF-16 units; "🦀 naïve" = 2 + 1 + 5 = 8 UTF-16 units.
    let s_u16 = DocumentStats::compute(text, Some((5, 8)));
    let s_u8 = DocumentStats::compute_utf8(text, Some(crab_byte..naive_end_byte));
    assert_eq!(s_u16, s_u8);
    assert_eq!(s_u8.words, 4);
    assert_eq!(s_u8.lines, 2);
    assert_eq!(s_u8.selected_characters, 8);
    assert_eq!(s_u8.selected_words, 1);
}
