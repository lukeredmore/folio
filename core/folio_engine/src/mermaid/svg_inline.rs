use super::theme::FolioMermaidColors;

/// Inlines explicit SVG 1.1 presentation attributes (`fill`, `stroke`, `stroke-width`,
/// `stroke-dasharray`, `rx`, `ry`, `text-anchor`, `font-size`, `font-weight`) onto elements
/// and replaces complex CSS selector blocks in `<style>` so that macOS CoreSVG (`NSImage`)
/// and `resvg` both render diagrams identically without CSS selector bleed.
pub(super) fn inline_core_svg_styles(svg: &str, c: FolioMermaidColors) -> String {
    let cleaned_css = replace_style_block(svg, c);
    let mut out = String::with_capacity(cleaned_css.len() + 2048);
    let mut cursor = 0;

    while let Some(lt_rel) = cleaned_css[cursor..].find('<') {
        let start = cursor + lt_rel;
        out.push_str(&cleaned_css[cursor..start]);
        let rest = &cleaned_css[start..];
        let Some(gt_rel) = rest.find('>') else {
            out.push_str(rest);
            return out;
        };
        let end = start + gt_rel + 1;
        out.push_str(&rewrite_tag(&cleaned_css[start..end], c));
        cursor = end;
    }

    out.push_str(&cleaned_css[cursor..]);
    out
}

fn replace_style_block(svg: &str, c: FolioMermaidColors) -> String {
    let (Some(s_start), Some(s_end)) = (svg.find("<style>"), svg.find("</style>")) else {
        return svg.to_string();
    };
    let (text, line, border, surface) = (c.text, c.line, c.border, c.surface);
    let minimal_style = format!(
        r#"<style>svg {{ font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif; font-size: 14px; fill: {text}; }} .edgePath .path, .flowchart-link, .transition, .relation, .relationshipLine {{ fill: none; stroke: {line}; stroke-width: 1.5px; }} .label-container {{ fill: {surface}; stroke: {border}; stroke-width: 1.5px; }}</style>"#
    );
    format!("{}{minimal_style}{}", &svg[..s_start], &svg[s_end + "</style>".len()..])
}

fn rewrite_tag(tag: &str, c: FolioMermaidColors) -> String {
    if tag.starts_with("</") || tag.starts_with("<!") || tag.starts_with("<?") {
        return tag.to_string();
    }
    let class = extract_attr(tag, "class").unwrap_or("");
    let style = extract_attr(tag, "style").unwrap_or("");

    if tag.starts_with("<path ") {
        rewrite_path_tag(tag, class, c)
    } else if tag.starts_with("<line ") {
        rewrite_line_tag(tag, class, c)
    } else if tag.starts_with("<rect ") {
        rewrite_rect_tag(tag, class, style, c)
    } else if tag.starts_with("<polygon ") {
        rewrite_polygon_tag(tag, class, c)
    } else if tag.starts_with("<circle ") {
        rewrite_circle_tag(tag, class, c)
    } else if tag.starts_with("<text ") {
        rewrite_text_tag(tag, class, style, c)
    } else if tag.starts_with("<tspan ") && extract_attr(tag, "fill").is_none() {
        set_attr(tag, "fill", c.text)
    } else {
        tag.to_string()
    }
}

fn rewrite_path_tag(tag: &str, class: &str, c: FolioMermaidColors) -> String {
    if class.contains("pieCircle") {
        return set_attrs(
            tag,
            &[("stroke", c.canvas), ("stroke-width", "2"), ("stroke-linejoin", "round")],
        );
    }
    let is_edge = ["flowchart-link", "transition", "relation", "relationshipLine", "edge-thickness"]
        .iter()
        .any(|k| class.contains(k));
    if is_edge {
        let mut t = strip_style_prop(tag, "stroke-dasharray");
        t = set_attrs(&t, &[("fill", "none"), ("stroke", c.line), ("stroke-width", "1.5")]);
        if class.contains("dashed") || class.contains("dotted") {
            t = set_attr(&t, "stroke-dasharray", "5,4");
        }
        return t;
    }
    tag.to_string()
}

fn rewrite_line_tag(tag: &str, class: &str, c: FolioMermaidColors) -> String {
    if class.contains("messageLine0") {
        return set_attrs(tag, &[("stroke", c.line), ("stroke-width", "1.5")]);
    }
    if class.contains("messageLine1") {
        return set_attrs(
            tag,
            &[("stroke", c.line), ("stroke-width", "1.5"), ("stroke-dasharray", "5,4")],
        );
    }
    if class.contains("actor-line") {
        return set_attrs(
            tag,
            &[("stroke", c.subtle_text), ("stroke-width", "1.2"), ("stroke-dasharray", "4,4")],
        );
    }
    tag.to_string()
}

fn rewrite_rect_tag(tag: &str, class: &str, style: &str, c: FolioMermaidColors) -> String {
    if class.contains("actor") || class.contains("label-container") || class.contains("entityBox") {
        return set_attrs(
            tag,
            &[("fill", c.surface), ("stroke", c.border), ("stroke-width", "1.5"), ("rx", "6"), ("ry", "6")],
        );
    }
    if class.contains("activation") {
        return set_attrs(
            tag,
            &[("fill", c.surface_alt), ("stroke", c.border), ("stroke-width", "1.2"), ("rx", "2"), ("ry", "2")],
        );
    }
    if class.contains("attributeBoxOdd") || class.contains("attributeBoxEven") {
        let fill = if class.contains("Odd") { c.surface_alt } else { c.surface };
        return set_attrs(tag, &[("fill", fill), ("stroke", c.border), ("stroke-width", "1")]);
    }
    if class.contains("relationshipLabelBox") {
        return set_attrs(
            tag,
            &[("fill", c.edge_label_bg), ("stroke", "none"), ("rx", "4"), ("ry", "4")],
        );
    }
    if let Some(fill) = extract_style_prop(style, "fill") {
        let stroke = extract_style_prop(style, "stroke").unwrap_or(fill);
        return set_attrs(tag, &[("fill", fill), ("stroke", stroke), ("rx", "3"), ("ry", "3")]);
    }
    if extract_attr(tag, "fill").is_some() && extract_attr(tag, "stroke").is_none() {
        return set_attrs(tag, &[("stroke", "none"), ("rx", "4"), ("ry", "4")]);
    }
    tag.to_string()
}

fn rewrite_polygon_tag(tag: &str, class: &str, c: FolioMermaidColors) -> String {
    if class.contains("label-container") {
        return set_attrs(
            tag,
            &[
                ("fill", c.surface_alt),
                ("stroke", c.border),
                ("stroke-width", "1.5"),
                ("stroke-linejoin", "round"),
            ],
        );
    }
    tag.to_string()
}

fn rewrite_circle_tag(tag: &str, class: &str, c: FolioMermaidColors) -> String {
    if class.contains("pieOuterCircle") {
        return set_attrs(tag, &[("fill", "none"), ("stroke", "none")]);
    }
    if class.contains("state-start") {
        return set_attrs(tag, &[("fill", c.border), ("stroke", c.border)]);
    }
    if class.contains("state-end") {
        return set_attrs(tag, &[("fill", c.surface), ("stroke", c.border), ("stroke-width", "2")]);
    }
    tag.to_string()
}

fn rewrite_text_tag(tag: &str, class: &str, style: &str, c: FolioMermaidColors) -> String {
    let mut t = tag.to_string();
    if extract_attr(&t, "font-family").is_none() {
        t = set_attr(&t, "font-family", "-apple-system, BlinkMacSystemFont, SF Pro Text, Helvetica Neue, sans-serif");
    }
    if let Some(anchor) = extract_style_prop(style, "text-anchor") {
        if extract_attr(&t, "text-anchor").is_none() {
            t = set_attr(&t, "text-anchor", anchor);
        }
    }
    if class.contains("pieTitleText") {
        return set_attrs(&t, &[("fill", c.text), ("text-anchor", "middle"), ("font-size", "16"), ("font-weight", "600")]);
    }
    if class.contains("slice") {
        return set_attrs(&t, &[("fill", "#FFFFFF"), ("text-anchor", "middle"), ("font-size", "12"), ("font-weight", "600")]);
    }
    if class.contains("messageText") {
        return set_attrs(&t, &[("fill", c.text), ("font-size", "13")]);
    }
    if class.contains("actor") {
        return set_attrs(&t, &[("fill", c.text), ("font-size", "14"), ("font-weight", "600")]);
    }
    if extract_attr(&t, "fill").is_none() {
        t = set_attr(&t, "fill", c.text);
    }
    t
}

fn extract_attr<'a>(tag: &'a str, attr: &str) -> Option<&'a str> {
    let pat = format!(r#"{attr}=""#);
    for (idx, _) in tag.match_indices(&pat) {
        if idx == 0 || tag.as_bytes()[idx - 1].is_ascii_whitespace() {
            let start = idx + pat.len();
            let end_q = tag[start..].find('"')?;
            return Some(&tag[start..start + end_q]);
        }
    }
    None
}

fn extract_style_prop<'a>(style: &'a str, prop: &str) -> Option<&'a str> {
    style.split(';').find_map(|part| {
        let (k, v) = part.split_once(':')?;
        k.trim().eq_ignore_ascii_case(prop).then_some(v.trim())
    })
}

fn strip_style_prop(tag: &str, prop: &str) -> String {
    let Some(style) = extract_attr(tag, "style") else { return tag.to_string() };
    let kept: Vec<&str> = style
        .split(';')
        .filter(|p| p.split_once(':').map(|(k, _)| !k.trim().eq_ignore_ascii_case(prop)).unwrap_or(true))
        .collect();
    set_attr(tag, "style", &kept.join(";"))
}

fn set_attrs(tag: &str, pairs: &[(&str, &str)]) -> String {
    let mut out = tag.to_string();
    for &(attr, val) in pairs {
        out = set_attr(&out, attr, val);
    }
    out
}

fn set_attr(tag: &str, attr: &str, val: &str) -> String {
    let pat = format!(r#"{attr}=""#);
    for (idx, _) in tag.match_indices(&pat) {
        if idx == 0 || tag.as_bytes()[idx - 1].is_ascii_whitespace() {
            let start = idx + pat.len();
            if let Some(end_q) = tag[start..].find('"') {
                return format!("{}{val}{}", &tag[..start], &tag[start + end_q..]);
            }
        }
    }
    let pos = if tag.ends_with("/>") { tag.len() - 2 } else { tag.len() - 1 };
    format!(r#"{} {attr}="{val}"{}"#, &tag[..pos], &tag[pos..])
}
