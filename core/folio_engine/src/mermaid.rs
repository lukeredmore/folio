use mermaid_rs_renderer::{
    compute_layout, measure_svg_dimensions, parse_mermaid, render::render_svg_with_dimensions,
    DiagramKind, LayoutConfig, Theme,
};

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

impl From<DiagramKind> for MermaidDiagramKind {
    fn from(kind: DiagramKind) -> Self {
        match kind {
            DiagramKind::Flowchart => Self::Flowchart,
            DiagramKind::Sequence | DiagramKind::ZenUML => Self::Sequence,
            DiagramKind::State => Self::State,
            DiagramKind::Class | DiagramKind::Er | DiagramKind::Requirement => Self::Class,
            DiagramKind::Pie => Self::Pie,
            DiagramKind::Mindmap => Self::Mindmap,
            DiagramKind::Gantt | DiagramKind::Timeline | DiagramKind::Journey => Self::Gantt,
            _ => Self::Unknown,
        }
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

fn folio_mermaid_theme(is_dark: bool) -> Theme {
    if is_dark {
        let mut theme = Theme::dark();
        theme.font_family = Theme::modern().font_family;
        theme.font_size = 14.0;
        theme.background = "#161922".to_string();
        theme.primary_color = "#232838".to_string();
        theme.primary_text_color = "#E8ECF4".to_string();
        theme.primary_border_color = "#4B6BFB".to_string();
        theme.line_color = "#7C8AA5".to_string();
        theme.secondary_color = "#283352".to_string();
        theme.tertiary_color = "#1C202B".to_string();
        theme.edge_label_background = "#1A1E29".to_string();
        theme.cluster_background = "#191D28".to_string();
        theme.cluster_border = "#36405A".to_string();
        theme.sequence_actor_fill = "#232838".to_string();
        theme.sequence_actor_border = "#4B6BFB".to_string();
        theme.sequence_actor_line = "#7C8AA5".to_string();
        theme.sequence_note_fill = "#283352".to_string();
        theme.sequence_note_border = "#4B6BFB".to_string();
        theme.sequence_activation_fill = "#283352".to_string();
        theme.sequence_activation_border = "#5E81F4".to_string();
        theme.text_color = "#E8ECF4".to_string();
        theme.pie_title_text_color = "#E8ECF4".to_string();
        theme.pie_section_text_color = "#E8ECF4".to_string();
        theme.pie_legend_text_color = "#E8ECF4".to_string();
        theme.pie_stroke_color = "#161922".to_string();
        theme.pie_outer_stroke_color = "#36405A".to_string();
        theme.pie_colors = [
            "#5E81F4", "#38BDF8", "#34D399", "#FBBF24", "#F87171", "#A78BFA", "#F472B6",
            "#FB923C", "#60A5FA", "#4ADE80", "#FACC15", "#C084FC",
        ]
        .map(str::to_string);
        theme
    } else {
        let mut theme = Theme::modern();
        theme.background = "#FFFFFF".to_string();
        theme
    }
}

/// Strips the opaque fill from the outer SVG canvas `<rect>` using SVG 1.1 `fill="none"`.
/// Note: macOS CoreSVG (`NSImage`) is an SVG 1.1 renderer and treats CSS `fill="transparent"`
/// as an unrecognized paint server, falling back to solid black (`#000000`). Using `fill="none"`
/// makes the outer canvas rect genuinely transparent while keeping a valid hex `theme.background`
/// for internal node/state/label contrast calculations in `mermaid-rs-renderer`.
fn make_canvas_rect_transparent(svg: String, theme_bg: &str) -> String {
    let target = format!(r#"fill="{theme_bg}""#);
    svg.replacen(&target, r#"fill="none""#, 1)
        .replace(r#"fill="transparent""#, r#"fill="none""#)
}

/// Renders Mermaid diagram source to SVG using the `mermaid-rs-renderer` crate.
/// Uses an SVG 1.1 `fill="none"` canvas background so the host editor card (`MERMAID` block)
/// provides the background without an inner box or CoreSVG black-fill fallback.
pub fn render_mermaid_to_svg(source: &str, is_dark: bool) -> MermaidRenderResult {
    let detected_kind = detect_mermaid_kind(source);
    let theme = folio_mermaid_theme(is_dark);
    let config = LayoutConfig::default();

    match parse_mermaid(source) {
        Ok(parsed) => {
            let kind = if detected_kind != MermaidDiagramKind::Unknown {
                detected_kind
            } else {
                MermaidDiagramKind::from(parsed.graph.kind)
            };
            let layout = compute_layout(&parsed.graph, &theme, &config);
            let dims = measure_svg_dimensions(&layout, &config, None);
            let width = dims.width.max(120.0);
            let height = dims.height.max(60.0);
            let raw_svg =
                render_svg_with_dimensions(&layout, &theme, &config, Some((width, height)));
            let svg = make_canvas_rect_transparent(raw_svg, &theme.background);

            let node_count = match parsed.graph.kind {
                DiagramKind::Pie => parsed.graph.pie_slices.len(),
                DiagramKind::Sequence => parsed
                    .graph
                    .sequence_participants
                    .len()
                    .max(parsed.graph.nodes.len()),
                DiagramKind::Gantt => parsed
                    .graph
                    .gantt_tasks
                    .len()
                    .max(parsed.graph.nodes.len()),
                _ => parsed.graph.nodes.len().max(layout.nodes.len()),
            };
            let edge_count = parsed.graph.edges.len().max(layout.edges.len());
            let title = parsed
                .graph
                .pie_title
                .clone()
                .or_else(|| parsed.graph.gantt_title.clone())
                .or_else(|| parsed.graph.journey_title.clone())
                .or_else(|| parsed.graph.timeline.title.clone());

            MermaidRenderResult {
                kind,
                svg,
                width,
                height,
                title,
                node_count,
                edge_count,
            }
        }
        Err(_) => render_fallback_code_svg(source, detected_kind, &theme),
    }
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
    theme: &Theme,
) -> MermaidRenderResult {
    let lines: Vec<&str> = source
        .lines()
        .map(str::trim_end)
        .filter(|l| !l.trim().is_empty())
        .take(12)
        .collect();
    let max_chars = lines
        .iter()
        .map(|l| l.chars().count())
        .max()
        .unwrap_or(20);
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
            r#"<text x="20" y="{y:.1}" fill="{}" font-family="ui-monospace, SFMono-Regular, Menlo, monospace" font-size="12">{}</text>"#,
            theme.primary_text_color,
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

/// Ensures an inline or fenced `<svg>...</svg>` string has a valid `xmlns` attribute
/// and extracts its intrinsic `(width, height)` dimensions (defaulting to `(320.0, 180.0)`).
pub fn normalize_svg_markup(raw_svg: &str) -> Option<(String, f32, f32)> {
    let trimmed = raw_svg.trim();
    let start = trimmed.find("<svg")?;
    let end = trimmed.rfind("</svg>")?;
    let svg_slice = &trimmed[start..end + "</svg>".len()];
    let open_end = svg_slice.find('>')?;
    let open_tag = &svg_slice[..open_end];

    let explicit_width = extract_svg_numeric_attr(open_tag, "width");
    let explicit_height = extract_svg_numeric_attr(open_tag, "height");
    let mut width = explicit_width;
    let mut height = explicit_height;

    if (width.is_none() || height.is_none())
        && (open_tag.contains("viewBox=") || open_tag.contains("viewbox="))
    {
        if let Some((vb_w, vb_h)) = extract_svg_viewbox_size(open_tag) {
            width = width.or(Some(vb_w));
            height = height.or(Some(vb_h));
        }
    }

    let w = width.unwrap_or(320.0).clamp(24.0, 1600.0);
    let h = height.unwrap_or(180.0).clamp(24.0, 1600.0);

    let mut normalized = String::with_capacity(svg_slice.len() + 96);
    normalized.push_str(&svg_slice[..open_end]);
    if !open_tag.contains("xmlns=") {
        normalized.push_str(r#" xmlns="http://www.w3.org/2000/svg""#);
    }
    if explicit_width.is_none() {
        normalized.push_str(&format!(r#" width="{w:.0}""#));
    }
    if explicit_height.is_none() {
        normalized.push_str(&format!(r#" height="{h:.0}""#));
    }
    normalized.push_str(&svg_slice[open_end..].replace(r#"fill="transparent""#, r#"fill="none""#));
    Some((normalized, w, h))
}

fn extract_svg_numeric_attr(tag: &str, attr_name: &str) -> Option<f32> {
    let pattern = format!("{attr_name}=");
    let idx = tag.find(&pattern)?;
    let rest = tag[idx + pattern.len()..].trim_start();
    let quote = rest.chars().next()?;
    if quote != '"' && quote != '\'' {
        return None;
    }
    let inner = &rest[1..];
    let end_q = inner.find(quote)?;
    let val_str = inner[..end_q]
        .trim()
        .trim_end_matches("px")
        .trim_end_matches("pt")
        .trim();
    val_str.parse::<f32>().ok().filter(|v| *v > 0.0)
}

fn extract_svg_viewbox_size(tag: &str) -> Option<(f32, f32)> {
    let idx = tag.find("viewBox=").or_else(|| tag.find("viewbox="))?;
    let rest = tag[idx + 8..].trim_start();
    let quote = rest.chars().next()?;
    if quote != '"' && quote != '\'' {
        return None;
    }
    let inner = &rest[1..];
    let end_q = inner.find(quote)?;
    let nums: Vec<f32> = inner[..end_q]
        .split(|c: char| c.is_whitespace() || c == ',')
        .filter(|s| !s.is_empty())
        .filter_map(|s| s.parse::<f32>().ok())
        .collect();
    if nums.len() == 4 && nums[2] > 0.0 && nums[3] > 0.0 {
        Some((nums[2], nums[3]))
    } else {
        None
    }
}
