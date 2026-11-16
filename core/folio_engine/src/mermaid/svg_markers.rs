use crate::markdown::inline_helpers::{extract_xml_attr, remove_xml_attr};

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
        let open_end = tag_start + gt_rel + 1;
        let raw_tag = &svg[tag_start..open_end];
        let mut tag_end = open_end;
        if !raw_tag.ends_with("/>") {
            let close_pat = if is_path { "</path>" } else { "</line>" };
            if let Some(close_rel) = svg[open_end..].find(close_pat) {
                tag_end = open_end + close_rel + close_pat.len();
            }
        }

        let marker_start = extract_marker_url(raw_tag, "marker-start");
        let marker_end = extract_marker_url(raw_tag, "marker-end");
        if marker_start.is_none() && marker_end.is_none() {
            out.push_str(&svg[tag_start..tag_end]);
            cursor = tag_end;
            continue;
        }

        let pts = if is_path {
            extract_xml_attr(raw_tag, "d")
                .map(parse_path_points)
                .unwrap_or_default()
        } else {
            parse_line_points(raw_tag)
        };

        out.push_str(&strip_marker_attrs(raw_tag));
        out.push_str(&svg[open_end..tag_end]);

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

fn extract_marker_url<'a>(tag: &'a str, attr: &str) -> Option<&'a str> {
    let val = extract_xml_attr(tag, attr)?;
    let hash = val.find('#')?;
    let rest = &val[hash + 1..];
    let end = rest.find(')')?;
    Some(&rest[..end])
}

fn strip_marker_attrs(open_tag: &str) -> String {
    let without_start = remove_xml_attr(open_tag, "marker-start");
    remove_xml_attr(&without_start, "marker-end")
}

fn parse_line_points(tag: &str) -> Vec<(f64, f64)> {
    let (Some(x1), Some(y1), Some(x2), Some(y2)) = (
        extract_xml_attr(tag, "x1").and_then(|v| v.parse::<f64>().ok()),
        extract_xml_attr(tag, "y1").and_then(|v| v.parse::<f64>().ok()),
        extract_xml_attr(tag, "x2").and_then(|v| v.parse::<f64>().ok()),
        extract_xml_attr(tag, "y2").and_then(|v| v.parse::<f64>().ok()),
    ) else {
        return Vec::new();
    };
    vec![(x1, y1), (x2, y2)]
}

fn skip_path_separators(bytes: &[u8], pos: &mut usize) {
    while *pos < bytes.len() && (bytes[*pos].is_ascii_whitespace() || bytes[*pos] == b',') {
        *pos += 1;
    }
}

fn read_svg_number(d: &str, pos: &mut usize) -> Option<f64> {
    let bytes = d.as_bytes();
    skip_path_separators(bytes, pos);
    let start = *pos;
    let mut i = start;
    if matches!(bytes.get(i), Some(b'+' | b'-')) {
        i += 1;
    }
    let mut has_digits = false;
    while i < bytes.len() && bytes[i].is_ascii_digit() {
        has_digits = true;
        i += 1;
    }
    if bytes.get(i) == Some(&b'.') {
        i += 1;
        while i < bytes.len() && bytes[i].is_ascii_digit() {
            has_digits = true;
            i += 1;
        }
    }
    if !has_digits {
        return None;
    }
    if matches!(bytes.get(i), Some(b'e' | b'E')) {
        let mut exp_i = i + 1;
        if matches!(bytes.get(exp_i), Some(b'+' | b'-')) {
            exp_i += 1;
        }
        let exp_digits_start = exp_i;
        while exp_i < bytes.len() && bytes[exp_i].is_ascii_digit() {
            exp_i += 1;
        }
        if exp_i > exp_digits_start {
            i = exp_i;
        }
    }
    let val = d[start..i].parse::<f64>().ok()?;
    *pos = i;
    Some(val)
}

fn read_svg_flag(d: &str, pos: &mut usize) -> Option<bool> {
    let bytes = d.as_bytes();
    skip_path_separators(bytes, pos);
    match bytes.get(*pos) {
        Some(b'0') => {
            *pos += 1;
            Some(false)
        }
        Some(b'1') => {
            *pos += 1;
            Some(true)
        }
        _ => None,
    }
}

struct PathEvalState {
    cur: (f64, f64),
    subpath_start: (f64, f64),
    last_ctrl: Option<(f64, f64)>,
    pts: Vec<(f64, f64)>,
}

impl PathEvalState {
    fn resolve(&self, x: f64, y: f64, rel: bool) -> (f64, f64) {
        if rel {
            (self.cur.0 + x, self.cur.1 + y)
        } else {
            (x, y)
        }
    }

    fn reflected_ctrl(&self) -> (f64, f64) {
        match self.last_ctrl {
            Some((cx, cy)) => (2.0 * self.cur.0 - cx, 2.0 * self.cur.1 - cy),
            None => self.cur,
        }
    }
}

pub(crate) fn parse_path_points(d: &str) -> Vec<(f64, f64)> {
    let bytes = d.as_bytes();
    let mut pos = 0;
    let mut cmd = 0u8;
    let mut state = PathEvalState {
        cur: (0.0, 0.0),
        subpath_start: (0.0, 0.0),
        last_ctrl: None,
        pts: Vec::with_capacity(16),
    };

    while pos < bytes.len() {
        skip_path_separators(bytes, &mut pos);
        if pos >= bytes.len() {
            break;
        }
        if bytes[pos].is_ascii_alphabetic() {
            cmd = bytes[pos];
            pos += 1;
            if matches!(cmd, b'Z' | b'z') {
                if (state.cur.0 - state.subpath_start.0).hypot(state.cur.1 - state.subpath_start.1)
                    > 1e-5
                {
                    state.pts.push(state.subpath_start);
                }
                state.cur = state.subpath_start;
                state.last_ctrl = None;
                cmd = 0;
                continue;
            }
        }
        if (cmd == 0 || !step_path_command(d, &mut pos, &mut cmd, &mut state))
            && pos < bytes.len()
            && !bytes[pos].is_ascii_alphabetic()
        {
            pos += 1;
        }
    }
    state.pts
}

fn step_path_command(d: &str, pos: &mut usize, cmd: &mut u8, state: &mut PathEvalState) -> bool {
    let rel = cmd.is_ascii_lowercase();
    match cmd.to_ascii_uppercase() {
        b'M' => {
            let (Some(x), Some(y)) = (read_svg_number(d, pos), read_svg_number(d, pos)) else {
                return false;
            };
            let pt = state.resolve(x, y, rel);
            state.cur = pt;
            state.subpath_start = pt;
            state.last_ctrl = None;
            state.pts.push(pt);
            *cmd = if rel { b'l' } else { b'L' };
            true
        }
        b'L' => {
            let (Some(x), Some(y)) = (read_svg_number(d, pos), read_svg_number(d, pos)) else {
                return false;
            };
            state.cur = state.resolve(x, y, rel);
            state.last_ctrl = None;
            state.pts.push(state.cur);
            true
        }
        b'H' => {
            let Some(x) = read_svg_number(d, pos) else {
                return false;
            };
            state.cur.0 = if rel { state.cur.0 + x } else { x };
            state.last_ctrl = None;
            state.pts.push(state.cur);
            true
        }
        b'V' => {
            let Some(y) = read_svg_number(d, pos) else {
                return false;
            };
            state.cur.1 = if rel { state.cur.1 + y } else { y };
            state.last_ctrl = None;
            state.pts.push(state.cur);
            true
        }
        b'C' | b'S' | b'Q' | b'T' => step_curve_command(d, pos, *cmd, rel, state),
        b'A' => step_arc_command(d, pos, rel, state),
        _ => false,
    }
}

fn step_curve_command(
    d: &str,
    pos: &mut usize,
    cmd: u8,
    rel: bool,
    state: &mut PathEvalState,
) -> bool {
    match cmd.to_ascii_uppercase() {
        b'C' => {
            let (Some(x1), Some(y1), Some(x2), Some(y2), Some(x), Some(y)) = (
                read_svg_number(d, pos),
                read_svg_number(d, pos),
                read_svg_number(d, pos),
                read_svg_number(d, pos),
                read_svg_number(d, pos),
                read_svg_number(d, pos),
            ) else {
                return false;
            };
            let (p1, p2, end) = (
                state.resolve(x1, y1, rel),
                state.resolve(x2, y2, rel),
                state.resolve(x, y, rel),
            );
            state.pts.extend([p1, p2, end]);
            state.last_ctrl = Some(p2);
            state.cur = end;
            true
        }
        b'S' => {
            let (Some(x2), Some(y2), Some(x), Some(y)) = (
                read_svg_number(d, pos),
                read_svg_number(d, pos),
                read_svg_number(d, pos),
                read_svg_number(d, pos),
            ) else {
                return false;
            };
            let p1 = state.reflected_ctrl();
            let (p2, end) = (state.resolve(x2, y2, rel), state.resolve(x, y, rel));
            state.pts.extend([p1, p2, end]);
            state.last_ctrl = Some(p2);
            state.cur = end;
            true
        }
        b'Q' => {
            let (Some(x1), Some(y1), Some(x), Some(y)) = (
                read_svg_number(d, pos),
                read_svg_number(d, pos),
                read_svg_number(d, pos),
                read_svg_number(d, pos),
            ) else {
                return false;
            };
            let (p1, end) = (state.resolve(x1, y1, rel), state.resolve(x, y, rel));
            state.pts.extend([p1, end]);
            state.last_ctrl = Some(p1);
            state.cur = end;
            true
        }
        b'T' => {
            let (Some(x), Some(y)) = (read_svg_number(d, pos), read_svg_number(d, pos)) else {
                return false;
            };
            let p1 = state.reflected_ctrl();
            let end = state.resolve(x, y, rel);
            state.pts.extend([p1, end]);
            state.last_ctrl = Some(p1);
            state.cur = end;
            true
        }
        _ => false,
    }
}

fn step_arc_command(d: &str, pos: &mut usize, rel: bool, state: &mut PathEvalState) -> bool {
    let (Some(rx_in), Some(ry_in), Some(rot_deg), Some(large_arc), Some(sweep), Some(x), Some(y)) = (
        read_svg_number(d, pos),
        read_svg_number(d, pos),
        read_svg_number(d, pos),
        read_svg_flag(d, pos),
        read_svg_flag(d, pos),
        read_svg_number(d, pos),
        read_svg_number(d, pos),
    ) else {
        return false;
    };
    let start = state.cur;
    let end = state.resolve(x, y, rel);
    state.last_ctrl = None;
    let mut rx = rx_in.abs();
    let mut ry = ry_in.abs();
    let chord = (end.0 - start.0).hypot(end.1 - start.1);
    if rx <= 1e-6 || ry <= 1e-6 || chord <= 1e-6 {
        state.pts.push(end);
        state.cur = end;
        return true;
    }

    let (sin_phi, cos_phi) = rot_deg.to_radians().sin_cos();
    let (dx2, dy2) = ((start.0 - end.0) * 0.5, (start.1 - end.1) * 0.5);
    let x1p = cos_phi * dx2 + sin_phi * dy2;
    let y1p = -sin_phi * dx2 + cos_phi * dy2;
    let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry);
    if lambda > 1.0 {
        let scale = lambda.sqrt();
        rx *= scale;
        ry *= scale;
    }
    let rx2 = rx * rx;
    let ry2 = ry * ry;
    let num = (rx2 * ry2 - rx2 * y1p * y1p - ry2 * x1p * x1p).max(0.0);
    let den = (rx2 * y1p * y1p + ry2 * x1p * x1p).max(1e-12);
    let sign = if large_arc == sweep { -1.0 } else { 1.0 };
    let coef = sign * (num / den).sqrt();
    let cxp = coef * (rx * y1p / ry);
    let cyp = coef * (-ry * x1p / rx);

    let ux = (x1p - cxp) / rx;
    let uy = (y1p - cyp) / ry;
    let vx = (-x1p - cxp) / rx;
    let vy = (-y1p - cyp) / ry;
    let theta1 = uy.atan2(ux);
    let mut dtheta = (ux * vy - uy * vx).atan2(ux * vx + uy * vy);
    if !sweep && dtheta > 0.0 {
        dtheta -= std::f64::consts::TAU;
    } else if sweep && dtheta < 0.0 {
        dtheta += std::f64::consts::TAU;
    }
    let dir = if dtheta >= 0.0 { 1.0 } else { -1.0 };
    let arc_tan = |theta: f64| -> (f64, f64) {
        let (st, ct) = theta.sin_cos();
        let tx = dir * (-rx * st * cos_phi - ry * ct * sin_phi);
        let ty = dir * (-rx * st * sin_phi + ry * ct * cos_phi);
        let norm = tx.hypot(ty).max(1e-12);
        (tx / norm * chord * 0.1, ty / norm * chord * 0.1)
    };
    let t_start = arc_tan(theta1);
    let t_end = arc_tan(theta1 + dtheta);
    state.pts.push((start.0 + t_start.0, start.1 + t_start.1));
    state.pts.push((end.0 - t_end.0, end.1 - t_end.1));
    state.pts.push(end);
    state.cur = end;
    true
}

fn start_tangent(pts: &[(f64, f64)]) -> Option<(f64, f64, f64)> {
    let (sx, sy) = *pts.first()?;
    for &(nx, ny) in &pts[1..] {
        let (dx, dy) = (nx - sx, ny - sy);
        if dx.hypot(dy) > 1e-5 {
            return Some((sx, sy, dy.atan2(dx).to_degrees()));
        }
    }
    None
}

fn end_tangent(pts: &[(f64, f64)]) -> Option<(f64, f64, f64)> {
    let (ex, ey) = *pts.last()?;
    for &(px, py) in pts[..pts.len() - 1].iter().rev() {
        let (dx, dy) = (ex - px, ey - py);
        if dx.hypot(dy) > 1e-5 {
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
            format!(
                r#"<circle cx="20" cy="0" r="4.5" fill="{surface}" stroke="{line}" stroke-width="1.5"/>"#
            )
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
            format!(
                r#"<path d="M 9,-6.5 L 9,6.5"/><circle cx="19" cy="0" r="4.5" fill="{surface}" stroke="{line}" stroke-width="1.5"/>"#
            )
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
        let fill = if marker_id.contains("composition") {
            line
        } else {
            surface
        };
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
