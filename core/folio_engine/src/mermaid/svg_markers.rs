use super::theme::FolioMermaidColors;

/// Materializes SVG `<marker>` references (`marker-end="url(#...)"` and `marker-start="url(#...)"`)
/// on `<path>` and `<line>` elements into explicit `<polygon>` and `<g>` geometry so that macOS
/// CoreSVG (`NSImage`)—which ignores `<marker>` definitions—renders crisp arrowheads, UML
/// triangles/diamonds, and ER crow's-foot cardinality symbols.
pub(super) fn materialize_svg_markers(svg: &str, colors: FolioMermaidColors) -> String {
    let mut out = String::with_capacity(svg.len() + 2048);
    let mut cursor = 0;

    while let Some(lt_rel) = svg[cursor..].find('<') {
        let tag_start = cursor + lt_rel;
        out.push_str(&svg[cursor..tag_start]);

        let rest = &svg[tag_start..];
        let is_path = rest.starts_with("<path ");
        let is_line = rest.starts_with("<line ");
        if !is_path && !is_line {
            out.push('<');
            cursor = tag_start + 1;
            continue;
        }

        let Some(gt_rel) = rest.find('>') else {
            out.push_str(rest);
            return out;
        };
        let mut tag_end = tag_start + gt_rel + 1;
        let raw_tag = &svg[tag_start..tag_end];
        let self_closing = raw_tag.ends_with("/>");
        if !self_closing {
            let close_pat = if is_path { "</path>" } else { "</line>" };
            if let Some(close_rel) = svg[tag_end..].find(close_pat) {
                tag_end = tag_end + close_rel + close_pat.len();
            }
        }
        let full_elem = &svg[tag_start..tag_end];

        let marker_start = extract_marker_url(raw_tag, "marker-start");
        let marker_end = extract_marker_url(raw_tag, "marker-end");
        if marker_start.is_none() && marker_end.is_none() {
            out.push_str(full_elem);
            cursor = tag_end;
            continue;
        }

        let pts = if is_path {
            extract_attr(raw_tag, "d").map(parse_path_points).unwrap_or_default()
        } else {
            parse_line_points(raw_tag)
        };

        let cleaned = strip_marker_attrs(full_elem);
        out.push_str(&cleaned);

        if pts.len() >= 2 {
            if let Some(m_start) = marker_start {
                if let Some((sx, sy, sdeg)) = start_tangent(&pts) {
                    emit_marker_shape(&mut out, m_start, sx, sy, sdeg, true, colors);
                }
            }
            if let Some(m_end) = marker_end {
                if let Some((ex, ey, edeg)) = end_tangent(&pts) {
                    emit_marker_shape(&mut out, m_end, ex, ey, edeg, false, colors);
                }
            }
        }

        cursor = tag_end;
    }

    out.push_str(&svg[cursor..]);
    out
}

fn extract_attr<'a>(tag: &'a str, attr: &str) -> Option<&'a str> {
    let pat = format!(r#"{attr}=""#);
    for (idx, _) in tag.match_indices(&pat) {
        if idx == 0 || tag.as_bytes()[idx - 1].is_ascii_whitespace() {
            let val_start = idx + pat.len();
            let end_q = tag[val_start..].find('"')?;
            return Some(&tag[val_start..val_start + end_q]);
        }
    }
    None
}

fn extract_marker_url<'a>(tag: &'a str, attr: &str) -> Option<&'a str> {
    let val = extract_attr(tag, attr)?;
    let hash = val.find('#')?;
    let rest = &val[hash + 1..];
    let end = rest.find(')')?;
    Some(&rest[..end])
}

fn strip_marker_attrs(elem: &str) -> String {
    let mut s = elem.to_string();
    for attr in ["marker-start", "marker-end"] {
        let pat = format!(r#" {attr}="url(#"#);
        while let Some(idx) = s.find(&pat) {
            if let Some(end_q) = s[idx + pat.len()..].find('"') {
                let end = idx + pat.len() + end_q + 1;
                s.replace_range(idx..end, "");
            } else {
                break;
            }
        }
    }
    s
}

fn parse_line_points(tag: &str) -> Vec<(f64, f64)> {
    let (Some(x1), Some(y1), Some(x2), Some(y2)) = (
        extract_attr(tag, "x1").and_then(|v| v.parse::<f64>().ok()),
        extract_attr(tag, "y1").and_then(|v| v.parse::<f64>().ok()),
        extract_attr(tag, "x2").and_then(|v| v.parse::<f64>().ok()),
        extract_attr(tag, "y2").and_then(|v| v.parse::<f64>().ok()),
    ) else {
        return Vec::new();
    };
    vec![(x1, y1), (x2, y2)]
}

fn parse_path_points(d: &str) -> Vec<(f64, f64)> {
    let mut nums = Vec::with_capacity(16);
    let bytes = d.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        let b = bytes[i];
        if b.is_ascii_digit() || b == b'-' || b == b'+' || b == b'.' {
            let start = i;
            if b == b'-' || b == b'+' {
                i += 1;
            }
            let mut seen_dot = b == b'.';
            while i < bytes.len() {
                let c = bytes[i];
                if c.is_ascii_digit() {
                    i += 1;
                } else if c == b'.' && !seen_dot {
                    seen_dot = true;
                    i += 1;
                } else {
                    break;
                }
            }
            if let Ok(val) = d[start..i].parse::<f64>() {
                nums.push(val);
            }
        } else {
            i += 1;
        }
    }
    nums.as_chunks::<2>().0.iter().map(|&[x, y]| (x, y)).collect()
}

fn start_tangent(pts: &[(f64, f64)]) -> Option<(f64, f64, f64)> {
    let (sx, sy) = *pts.first()?;
    for &(nx, ny) in &pts[1..] {
        let (dx, dy) = (nx - sx, ny - sy);
        if dx.hypot(dy) > 0.5 {
            return Some((sx, sy, dy.atan2(dx).to_degrees()));
        }
    }
    None
}

fn end_tangent(pts: &[(f64, f64)]) -> Option<(f64, f64, f64)> {
    let (ex, ey) = *pts.last()?;
    for &(px, py) in pts[..pts.len() - 1].iter().rev() {
        let (dx, dy) = (ex - px, ey - py);
        if dx.hypot(dy) > 0.5 {
            return Some((ex, ey, dy.atan2(dx).to_degrees()));
        }
    }
    None
}

fn emit_marker_shape(
    out: &mut String,
    marker_id: &str,
    x: f64,
    y: f64,
    deg: f64,
    is_start: bool,
    colors: FolioMermaidColors,
) {
    let line = colors.line;
    let surface = colors.surface;
    let dir_deg = if is_start { deg + 180.0 } else { deg };

    if marker_id.contains("zeroOrMore") || marker_id.contains("oneOrMore") {
        let extra = if marker_id.contains("zeroOrMore") {
            format!(r#"<circle cx="20" cy="0" r="4.5" fill="{surface}" stroke="{line}" stroke-width="1.5"/>"#)
        } else {
            r#"<path d="M 15,-6.5 L 15,6.5"/>"#.to_string()
        };
        let rot = if is_start { deg } else { deg + 180.0 };
        out.push_str(&format!(
            r#"<g transform="translate({x:.2},{y:.2}) rotate({rot:.2})" stroke="{line}" stroke-width="1.5" fill="none"><path d="M 0,-6.5 L 13,0 L 0,6.5"/>{extra}</g>"#
        ));
    } else if marker_id.contains("onlyOne") || marker_id.contains("zeroOrOne") {
        let rot = if is_start { deg } else { deg + 180.0 };
        let inner = if marker_id.contains("zeroOrOne") {
            format!(r#"<path d="M 9,-6.5 L 9,6.5"/><circle cx="19" cy="0" r="4.5" fill="{surface}" stroke="{line}" stroke-width="1.5"/>"#)
        } else {
            r#"<path d="M 9,-6.5 L 9,6.5 M 15,-6.5 L 15,6.5"/>"#.to_string()
        };
        out.push_str(&format!(
            r#"<g transform="translate({x:.2},{y:.2}) rotate({rot:.2})" stroke="{line}" stroke-width="1.5" fill="none">{inner}</g>"#
        ));
    } else if marker_id.contains("extension") {
        let pts = if is_start {
            "0,0 -11,-5.5 -11,5.5"
        } else {
            "11,0 0,-5.5 0,5.5"
        };
        out.push_str(&format!(
            r#"<polygon points="{pts}" fill="{surface}" stroke="{line}" stroke-width="1.5" transform="translate({x:.2},{y:.2}) rotate({dir_deg:.2})"/>"#
        ));
    } else if marker_id.contains("composition") || marker_id.contains("aggregation") {
        let fill = if marker_id.contains("composition") { line } else { surface };
        out.push_str(&format!(
            r#"<polygon points="0,0 -7,-4.5 -14,0 -7,4.5" fill="{fill}" stroke="{line}" stroke-width="1.5" transform="translate({x:.2},{y:.2}) rotate({dir_deg:.2})"/>"#
        ));
    } else if marker_id.contains("point") || marker_id.contains("dependency") {
        out.push_str(&format!(
            r#"<polygon points="4,0 -5.5,-4.5 -3.8,0 -5.5,4.5" fill="{line}" stroke="none" transform="translate({x:.2},{y:.2}) rotate({dir_deg:.2})"/>"#
        ));
    } else if marker_id.contains("cross") {
        out.push_str(&format!(
            r#"<g transform="translate({x:.2},{y:.2}) rotate({dir_deg:.2})" stroke="{line}" stroke-width="1.8"><path d="M -8,-4.5 L 0,4.5 M -8,4.5 L 0,-4.5"/></g>"#
        ));
    } else {
        out.push_str(&format!(
            r#"<polygon points="1,0 -8.5,-4.5 -6.8,0 -8.5,4.5" fill="{line}" stroke="none" transform="translate({x:.2},{y:.2}) rotate({dir_deg:.2})"/>"#
        ));
    }
}
