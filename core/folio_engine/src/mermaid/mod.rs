mod svg_inline;
mod svg_markers;
mod svg_norm;
mod theme;

use merman::{OperationControl, RenderOutput, RenderTarget};
use svg_inline::inline_core_svg_styles;
use svg_markers::materialize_svg_markers;
pub use svg_norm::normalize_svg_markup;
use theme::{fallback_text_color, folio_mermaid_renderer, theme_colors};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MermaidDiagramKind {
    Flowchart,
    Sequence,
    State,
    Class,
    Pie,
    Mindmap,
    Gantt,
    Unknown,
}

impl MermaidDiagramKind {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Flowchart => "flowchart",
            Self::Sequence => "sequenceDiagram",
            Self::State => "stateDiagram",
            Self::Class => "classDiagram",
            Self::Pie => "pie",
            Self::Mindmap => "mindmap",
            Self::Gantt => "gantt",
            Self::Unknown => "diagram",
        }
    }
}

fn kind_from_semantic(kind: &str) -> MermaidDiagramKind {
    match kind {
        "flowchart" => MermaidDiagramKind::Flowchart,
        "sequence" | "zenuml" => MermaidDiagramKind::Sequence,
        "state" => MermaidDiagramKind::State,
        "class" | "er" | "requirement" => MermaidDiagramKind::Class,
        "pie" => MermaidDiagramKind::Pie,
        "mindmap" => MermaidDiagramKind::Mindmap,
        "gantt" | "timeline" | "journey" => MermaidDiagramKind::Gantt,
        _ => MermaidDiagramKind::Unknown,
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct MermaidRenderResult {
    pub kind: MermaidDiagramKind,
    pub svg: String,
    pub width: f32,
    pub height: f32,
    pub title: Option<String>,
    pub node_count: usize,
    pub edge_count: usize,
}

pub fn detect_mermaid_kind(source: &str) -> MermaidDiagramKind {
    for raw_line in source.lines() {
        let line = raw_line.trim();
        if line.is_empty() || line.starts_with("%%") {
            continue;
        }
        let lower = line.to_ascii_lowercase();
        if lower.starts_with("flowchart") || lower.starts_with("graph") {
            return MermaidDiagramKind::Flowchart;
        } else if lower.starts_with("sequencediagram") {
            return MermaidDiagramKind::Sequence;
        } else if lower.starts_with("statediagram") {
            return MermaidDiagramKind::State;
        } else if lower.starts_with("classdiagram") {
            return MermaidDiagramKind::Class;
        } else if lower.starts_with("pie") {
            return MermaidDiagramKind::Pie;
        } else if lower.starts_with("mindmap") {
            return MermaidDiagramKind::Mindmap;
        } else if lower.starts_with("gantt") {
            return MermaidDiagramKind::Gantt;
        }
        break;
    }
    MermaidDiagramKind::Unknown
}

/// Renders Mermaid diagram source to SVG using the `merman` headless Mermaid engine.
/// Produces an SVG 1.1 compatible document with explicit dimensions and a transparent root
/// background so both macOS AppKit (`NSImage` / CoreSVG) and Zed GPUI render it cleanly.
pub fn render_mermaid_to_svg(source: &str, is_dark: bool) -> MermaidRenderResult {
    let detected_kind = detect_mermaid_kind(source);
    let folio_renderer = folio_mermaid_renderer(is_dark);

    if let Ok(Some(semantic)) = folio_renderer
        .renderer
        .prepare_semantic(source, OperationControl::new())
    {
        if semantic.semantic_kind() != "error" {
            let kind = if detected_kind != MermaidDiagramKind::Unknown {
                detected_kind
            } else {
                kind_from_semantic(semantic.semantic_kind())
            };
            let title = semantic
                .metadata()
                .title
                .clone()
                .or_else(|| extract_inline_title(source));

            if let Ok(RenderOutput::Svg(Some(svg_output))) =
                semantic.render(RenderTarget::Svg(folio_renderer.svg_request.clone()))
            {
                if let Some((normalized, raw_w, raw_h)) = normalize_svg_markup(svg_output.svg()) {
                    let colors = theme_colors(is_dark);
                    let inlined = inline_core_svg_styles(&normalized, colors);
                    let svg = materialize_svg_markers(&inlined, colors);
                    let width = raw_w.max(120.0);
                    let height = raw_h.max(60.0);
                    let (node_count, edge_count) = count_svg_elements(&svg);
                    return MermaidRenderResult {
                        kind,
                        svg,
                        width,
                        height,
                        title,
                        node_count,
                        edge_count,
                    };
                }
            }
        }
    }

    render_fallback_code_svg(source, detected_kind, fallback_text_color(is_dark))
}

fn extract_inline_title(source: &str) -> Option<String> {
    for raw_line in source.lines() {
        let trimmed = raw_line.trim();
        let lower = trimmed.to_ascii_lowercase();
        if let Some(rest) = lower.strip_prefix("pie title ") {
            let offset = trimmed.len() - rest.len();
            let title = trimmed[offset..].trim();
            if !title.is_empty() {
                return Some(title.to_string());
            }
        } else if let Some(rest) = lower.strip_prefix("title ") {
            let offset = trimmed.len() - rest.len();
            let title = trimmed[offset..].trim();
            if !title.is_empty() {
                return Some(title.to_string());
            }
        }
    }
    None
}

fn count_svg_elements(svg: &str) -> (usize, usize) {
    let nodes = svg
        .matches(r#"class="node"#)
        .count()
        .max(svg.matches(r#"class="actor"#).count())
        .max(svg.matches(r#"class="pieCircle"#).count())
        .max(svg.matches(r#"class="task"#).count())
        .max(1);
    let edges = svg
        .matches("flowchart-link")
        .count()
        .max(svg.matches("messageLine").count())
        .max(svg.matches("transition").count())
        .max(svg.matches("relation").count());
    (nodes, edges)
}

fn xml_escape(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    for ch in input.chars() {
        match ch {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&apos;"),
            _ => out.push(ch),
        }
    }
    out
}

fn render_fallback_code_svg(
    source: &str,
    kind: MermaidDiagramKind,
    text_color: &str,
) -> MermaidRenderResult {
    let lines: Vec<&str> = source
        .lines()
        .map(str::trim_end)
        .filter(|l| !l.trim().is_empty())
        .take(12)
        .collect();
    let max_chars = lines.iter().map(|l| l.chars().count()).max().unwrap_or(20);
    let width = ((max_chars as f32) * 7.6 + 48.0).clamp(280.0, 680.0);
    let height = ((lines.len() as f32) * 20.0 + 48.0).clamp(110.0, 320.0);

    let mut svg = String::with_capacity(1024);
    svg.push_str(&format!(
        r#"<svg xmlns="http://www.w3.org/2000/svg" width="{width:.0}" height="{height:.0}" viewBox="0 0 {width:.0} {height:.0}">"#
    ));
    svg.push_str(&format!(
        r#"<rect x="0" y="0" width="{width:.0}" height="{height:.0}" fill="none"/>"#
    ));
    for (idx, line) in lines.iter().enumerate() {
        let y = 28.0 + (idx as f32) * 20.0;
        svg.push_str(&format!(
            r#"<text x="20" y="{y:.1}" fill="{text_color}" font-family="ui-monospace, SFMono-Regular, Menlo, monospace" font-size="12">{}</text>"#,
            xml_escape(line)
        ));
    }
    svg.push_str("</svg>");

    MermaidRenderResult {
        kind,
        svg,
        width,
        height,
        title: None,
        node_count: lines.len(),
        edge_count: 0,
    }
}
