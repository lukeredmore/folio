/// Ensures an inline or fenced `<svg>...</svg>` string has a valid `xmlns` attribute,
/// explicit pixel `width` and `height` attributes (replacing percentage widths such as
/// `width="100%"` emitted by `merman`), and SVG 1.1 `none` paint values in place of CSS
/// `transparent` keywords so macOS CoreSVG (`NSImage`) never falls back to solid black.
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

    let w = width.unwrap_or(320.0).clamp(24.0, 4096.0);
    let h = height.unwrap_or(180.0).clamp(24.0, 4096.0);

    let cleaned_open_tag = strip_non_numeric_svg_dimensions(open_tag, explicit_width, explicit_height);
    let mut normalized = String::with_capacity(svg_slice.len() + 96);
    normalized.push_str(&cleaned_open_tag);
    if !cleaned_open_tag.contains("xmlns=") {
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

fn strip_non_numeric_svg_dimensions(
    open_tag: &str,
    explicit_width: Option<f32>,
    explicit_height: Option<f32>,
) -> String {
    let mut tag = open_tag.to_string();
    if explicit_width.is_none() {
        tag = remove_svg_attr(&tag, "width");
    }
    if explicit_height.is_none() {
        tag = remove_svg_attr(&tag, "height");
    }
    tag
}

fn remove_svg_attr(tag: &str, attr_name: &str) -> String {
    let pattern = format!(" {attr_name}=");
    let Some(idx) = tag.find(&pattern) else {
        return tag.to_string();
    };
    let rest = &tag[idx + pattern.len()..];
    let trimmed_rest = rest.trim_start();
    let ws_len = rest.len() - trimmed_rest.len();
    let Some(quote) = trimmed_rest.chars().next() else {
        return tag.to_string();
    };
    if quote != '"' && quote != '\'' {
        return tag.to_string();
    }
    let inner = &trimmed_rest[1..];
    let Some(end_q) = inner.find(quote) else {
        return tag.to_string();
    };
    let remove_end = idx + pattern.len() + ws_len + 1 + end_q + 1;
    let mut out = String::with_capacity(tag.len());
    out.push_str(&tag[..idx]);
    out.push_str(&tag[remove_end..]);
    out
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
    if val_str.ends_with('%') {
        return None;
    }
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
