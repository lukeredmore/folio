use crate::markdown::inline_helpers::{extract_xml_attr, remove_xml_attr};

/// Ensures an inline or fenced `<svg>...</svg>` string has a valid `xmlns` attribute,
/// explicit pixel `width` and `height` attributes (replacing percentage widths such as
/// `width="100%"` emitted by `merman`), and SVG 1.1 `none` paint values in place of CSS
/// `transparent` keywords so macOS CoreSVG (`NSImage`) never falls back to solid black.
pub fn normalize_svg_markup(raw_svg: &str) -> Option<(String, f32, f32)> {
    let trimmed = raw_svg.trim();
    let start = find_svg_open_tag(trimmed)?;
    let open_end = trimmed[start..].find('>')?;
    let after_open = start + open_end + 1;
    let close_rel = trimmed[after_open..].rfind("</svg>")?;
    let svg_end = after_open + close_rel + "</svg>".len();
    let svg_slice = &trimmed[start..svg_end];
    let open_tag = &svg_slice[..open_end];

    let explicit_width = extract_svg_numeric_attr(open_tag, "width");
    let explicit_height = extract_svg_numeric_attr(open_tag, "height");
    let mut width = explicit_width;
    let mut height = explicit_height;

    if width.is_none() || height.is_none() {
        if let Some((vb_w, vb_h)) = extract_svg_viewbox_size(open_tag) {
            width = width.or(Some(vb_w));
            height = height.or(Some(vb_h));
        }
    }

    let w = width.unwrap_or(320.0).clamp(24.0, 4096.0);
    let h = height.unwrap_or(180.0).clamp(24.0, 4096.0);

    let cleaned_open_tag =
        strip_non_numeric_svg_dimensions(open_tag, explicit_width, explicit_height);
    let mut normalized = String::with_capacity(svg_slice.len() + 96);
    normalized.push_str(&cleaned_open_tag);
    if extract_xml_attr(&cleaned_open_tag, "xmlns").is_none() {
        normalized.push_str(r#" xmlns="http://www.w3.org/2000/svg""#);
    }
    if explicit_width.is_none() {
        normalized.push_str(&format!(r#" width="{w:.0}""#));
    }
    if explicit_height.is_none() {
        normalized.push_str(&format!(r#" height="{h:.0}""#));
    }
    normalized.push_str(&sanitize_transparent_paints(&svg_slice[open_end..]));
    Some((normalized, w, h))
}

fn find_svg_open_tag(input: &str) -> Option<usize> {
    let mut search_from = 0;
    while let Some(rel) = input[search_from..].find("<svg") {
        let pos = search_from + rel;
        let next = input.as_bytes().get(pos + 4).copied();
        if matches!(next, Some(b) if b.is_ascii_whitespace() || b == b'>' || b == b'/') {
            return Some(pos);
        }
        search_from = pos + 4;
    }
    None
}

fn strip_non_numeric_svg_dimensions(
    open_tag: &str,
    explicit_width: Option<f32>,
    explicit_height: Option<f32>,
) -> String {
    let mut tag = open_tag.to_string();
    if explicit_width.is_none() {
        tag = remove_xml_attr(&tag, "width");
    }
    if explicit_height.is_none() {
        tag = remove_xml_attr(&tag, "height");
    }
    tag
}

pub(super) fn sanitize_transparent_paints(svg_body: &str) -> String {
    svg_body
        .replace(r#"fill="transparent""#, r#"fill="none""#)
        .replace(r#"stroke="transparent""#, r#"stroke="none""#)
        .replace("fill:transparent", "fill:none")
        .replace("fill: transparent", "fill: none")
        .replace("stroke:transparent", "stroke:none")
        .replace("stroke: transparent", "stroke: none")
}

fn extract_svg_numeric_attr(tag: &str, attr_name: &str) -> Option<f32> {
    let raw = extract_xml_attr(tag, attr_name)?;
    let val_str = raw
        .trim()
        .trim_end_matches("px")
        .trim_end_matches("pt")
        .trim();
    if val_str.ends_with('%') {
        return None;
    }
    val_str.parse::<f32>().ok().filter(|v| *v > 0.0)
}

fn extract_svg_viewbox_size(tag: &str) -> Option<(f32, f32)> {
    let raw = extract_xml_attr(tag, "viewBox")?;
    let nums: Vec<f32> = raw
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
