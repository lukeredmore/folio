use super::{
    clean_tex_inline_text, read_balanced_braces, read_bracket_group, read_control_word,
    skip_ascii_ws, skip_hspace, LatexDirectiveItem, LatexDirectiveKind, MacroTemplateAnalysis,
    NormalizedDisplayMath,
};

fn push_item(
    out: &mut Vec<LatexDirectiveItem>,
    kind: LatexDirectiveKind,
    starred: bool,
    cmd: &str,
    opt: &str,
    args: (&str, &str, &str),
) {
    out.push(LatexDirectiveItem {
        kind,
        starred,
        cmd: cmd.to_string(),
        opt_arg: opt.to_string(),
        arg1: args.0.to_string(),
        arg2: args.1.to_string(),
        arg3: args.2.to_string(),
    });
}

fn read_opt_and_brace(text: &str, pos: usize) -> Option<(&str, &str, usize)> {
    let bytes = text.as_bytes();
    let (mut p, mut opt) = (pos, "");
    if let Some((os, oe, after_o)) = read_bracket_group(bytes, p) {
        opt = &text[os..oe];
        p = after_o;
    }
    let (as_, ae, after_a) = read_balanced_braces(bytes, p)?;
    Some((opt, &text[as_..ae], after_a))
}

fn strip_comment(line: &str) -> &str {
    let bytes = line.as_bytes();
    for i in 0..bytes.len() {
        if bytes[i] == b'%' {
            let mut bs = 0usize;
            let mut p = i;
            while p > 0 && bytes[p - 1] == b'\\' {
                bs += 1;
                p -= 1;
            }
            if bs.is_multiple_of(2) {
                return &line[..i];
            }
        }
    }
    line
}

fn read_cmd_at(text: &str, slash: usize) -> Option<(&str, usize)> {
    let bytes = text.as_bytes();
    if slash >= bytes.len() || bytes[slash] != b'\\' {
        return None;
    }
    let mut end = slash + 1;
    while end < bytes.len() && (bytes[end].is_ascii_alphabetic() || bytes[end] == b'@') {
        end += 1;
    }
    (end > slash + 1).then(|| (&text[(slash + 1)..end], end))
}

pub fn scan_latex_directives(line: &str, is_preamble: bool) -> Vec<LatexDirectiveItem> {
    let text = strip_comment(line);
    let bytes = text.as_bytes();
    let first_non_ws = skip_ascii_ws(bytes, 0);
    let mut out = Vec::new();
    if is_preamble {
        match text.trim() {
            "\\onehalfspacing" => push_item(&mut out, LatexDirectiveKind::SetStretch, false, "onehalfspacing", "", ("1.25", "", "")),
            "\\doublespacing" => push_item(&mut out, LatexDirectiveKind::SetStretch, false, "doublespacing", "", ("1.65", "", "")),
            "\\singlespacing" => push_item(&mut out, LatexDirectiveKind::SetStretch, false, "singlespacing", "", ("1.0", "", "")),
            _ => {}
        }
    }
    let mut i = 0;
    while i < bytes.len() {
        let Some((cmd, after)) = read_cmd_at(text, i) else {
            i += 1;
            continue;
        };
        let at_start = i == first_non_ws;
        i = try_scan_directive(text, cmd, after, at_start, is_preamble, &mut out).unwrap_or(after);
    }
    out
}

fn try_scan_directive(
    text: &str,
    cmd: &str,
    after: usize,
    at_start: bool,
    is_preamble: bool,
    out: &mut Vec<LatexDirectiveItem>,
) -> Option<usize> {
    let bytes = text.as_bytes();
    match cmd {
        "documentclass" => {
            let (opt, a1, next) = read_opt_and_brace(text, after)?;
            push_item(out, LatexDirectiveKind::DocumentClass, false, cmd, opt, (a1, "", ""));
            return Some(next);
        }
        "usepackage" if is_preamble => {
            let (opt, a1, next) = read_opt_and_brace(text, after)?;
            push_item(out, LatexDirectiveKind::UsePackage, false, cmd, opt, (a1, "", ""));
            return Some(next);
        }
        "part" | "chapter" | "section" | "sectiontitle" | "subsection" | "subsubsection"
        | "paragraph" | "subparagraph"
            if at_start =>
        {
            let starred = cmd == "sectiontitle" || bytes.get(after) == Some(&b'*');
            let p = after + usize::from(bytes.get(after) == Some(&b'*'));
            let (opt, raw, next) = read_opt_and_brace(text, p)?;
            push_item(out, LatexDirectiveKind::Section, starred, cmd, opt, (&clean_tex_inline_text(raw), "", ""));
            return Some(next);
        }
        "label" => {
            let (s, e, next) = read_balanced_braces(bytes, after)?;
            push_item(out, LatexDirectiveKind::Label, false, cmd, "", (text[s..e].trim(), "", ""));
            return Some(next);
        }
        "bibliography" | "addbibresource" => {
            let (s, e, next) = read_balanced_braces(bytes, after)?;
            push_item(out, LatexDirectiveKind::BibResource, false, cmd, "", (&text[s..e], "", ""));
            return Some(next);
        }
        "input" | "include" if is_preamble && at_start => {
            let (s, e, next) = read_balanced_braces(bytes, after)?;
            push_item(out, LatexDirectiveKind::InputFile, false, cmd, "", (&text[s..e], "", ""));
            return Some(next);
        }
        "title" | "author" | "date" if at_start => {
            let (opt, raw, next) = read_opt_and_brace(text, after)?;
            push_item(out, LatexDirectiveKind::Frontmatter, false, cmd, opt, (&clean_tex_inline_text(raw), "", ""));
            return Some(next);
        }
        _ => {}
    }
    if is_preamble {
        if let Some(next) = try_scan_preamble_style(text, cmd, after, out) {
            return Some(next);
        }
    }
    if cmd == "newif" {
        let (if_cmd, next) = read_cmd_at(text, skip_hspace(bytes, after))?;
        if let Some(c) = if_cmd.strip_prefix("if").filter(|c| !c.is_empty()) {
            push_item(out, LatexDirectiveKind::NewIf, false, "newif", "", (c, "", ""));
            return Some(next);
        }
    } else if let Some(c) = cmd.strip_suffix("true").filter(|&c| !c.is_empty() && c != "if") {
        push_item(out, LatexDirectiveKind::ToggleIf, false, cmd, "", (c, "true", ""));
    } else if let Some(c) = cmd.strip_suffix("false").filter(|&c| !c.is_empty() && c != "if") {
        push_item(out, LatexDirectiveKind::ToggleIf, false, cmd, "", (c, "false", ""));
    }
    None
}

fn try_scan_preamble_style(
    text: &str,
    cmd: &str,
    after: usize,
    out: &mut Vec<LatexDirectiveItem>,
) -> Option<usize> {
    let bytes = text.as_bytes();
    match cmd {
        "setmainfont" | "setsansfont" | "setmonofont" => {
            let (opt, f, next) = read_opt_and_brace(text, after)?;
            push_item(out, LatexDirectiveKind::SetFont, false, cmd, opt, (f.trim(), "", ""));
            Some(next)
        }
        "renewcommand" => {
            let (s1, e1, a1) = read_balanced_braces(bytes, after)?;
            (text[s1..e1].trim() == "\\familydefault").then_some(())?;
            let (s2, e2, a2) = read_balanced_braces(bytes, a1)?;
            let target = text[s2..e2].trim().trim_start_matches('\\');
            matches!(target, "sfdefault" | "rmdefault" | "ttdefault").then(|| {
                push_item(out, LatexDirectiveKind::FamilyDefault, false, cmd, "", (target, "", ""));
                a2
            })
        }
        "setstretch" | "linespread" => {
            let (s, e, next) = read_balanced_braces(bytes, after)?;
            push_item(out, LatexDirectiveKind::SetStretch, false, cmd, "", (text[s..e].trim(), "", ""));
            Some(next)
        }
        "setlength" => {
            let (s1, e1, a1) = read_balanced_braces(bytes, after)?;
            let param = text[s1..e1].trim().trim_start_matches('\\');
            matches!(param, "parindent" | "parskip").then_some(())?;
            let (s2, e2, a2) = read_balanced_braces(bytes, a1)?;
            push_item(out, LatexDirectiveKind::SetLength, false, cmd, "", (param, text[s2..e2].trim(), ""));
            Some(a2)
        }
        "definecolor" => {
            let (s1, e1, a1) = read_balanced_braces(bytes, after)?;
            let (s2, e2, a2) = read_balanced_braces(bytes, a1)?;
            let (s3, e3, a3) = read_balanced_braces(bytes, a2)?;
            push_item(out, LatexDirectiveKind::DefineColor, false, cmd, "", (text[s1..e1].trim(), text[s2..e2].trim(), text[s3..e3].trim()));
            Some(a3)
        }
        _ => None,
    }
}

pub fn analyze_macro_template(active: &str, body_placeholder: &str) -> MacroTemplateAnalysis {
    let shows_body = !body_placeholder.is_empty() && active.contains(body_placeholder);
    let ph_pos = if shows_body { active.find(body_placeholder).unwrap_or(active.len()) } else { 0 };
    let bytes = active.as_bytes();
    let (mut color_name, mut prefix_label, mut vspace_list, mut heading_level, mut i) =
        (String::new(), String::new(), Vec::new(), 0u32, 0usize);
    while i < bytes.len() {
        let Some((cmd, after)) = read_control_word(active, i) else { i += 1; continue; };
        let p = after + usize::from(bytes.get(after) == Some(&b'*'));
        if matches!(cmd, "color" | "textcolor") && color_name.is_empty() {
            if let Some((s, e, next)) = read_balanced_braces(bytes, after) { color_name = active[s..e].to_string(); i = next; continue; }
        } else if cmd == "textbf" && shows_body && prefix_label.is_empty() && i < ph_pos {
            if let Some((s, e, next)) = read_balanced_braces(bytes, after) { prefix_label = active[s..e].to_string(); i = next; continue; }
        } else if cmd == "vspace" {
            if let Some((s, e, next)) = read_balanced_braces(bytes, p) { vspace_list.push(active[s..e].trim().to_string()); i = next; continue; }
        } else if shows_body && heading_level == 0 && bytes.get(skip_ascii_ws(bytes, p)) == Some(&b'{') {
            heading_level = match cmd { "part" | "chapter" | "section" | "sectiontitle" => 1, "subsection" => 2, "subsubsection" => 3, "paragraph" => 4, _ => 0 };
        }
        i = after;
    }
    MacroTemplateAnalysis { shows_body, heading_level, color_name, prefix_label, vspace_args: vspace_list.join(",") }
}

pub fn normalize_display_math(raw: &str, env_name: &str) -> NormalizedDisplayMath {
    let bytes = raw.as_bytes();
    let (mut explicit_tag, mut stripped, mut i) = (String::new(), String::with_capacity(raw.len()), 0usize);
    while i < bytes.len() {
        if let Some((cmd, after)) = read_control_word(raw, i) {
            let p = after + usize::from(bytes.get(after) == Some(&b'*'));
            if cmd == "tag" {
                if let Some((s, e, next)) = read_balanced_braces(bytes, p) {
                    if explicit_tag.is_empty() { explicit_tag = raw[s..e].to_string(); }
                    i = next; continue;
                }
            } else if cmd == "label" {
                if let Some((_, _, next)) = read_balanced_braces(bytes, after) { i = next; continue; }
            } else if matches!(cmd, "nonumber" | "notag") { i = after; continue; }
        }
        if let Some(ch) = raw[i..].chars().next() { stripped.push(ch); i += ch.len_utf8(); } else { break; }
    }
    let mut s = stripped.trim().to_string();
    let base = env_name.replace('*', "");
    if matches!(base.as_str(), "align" | "flalign" | "alignat") && !s.contains("\\begin{aligned}") && (s.contains('&') || s.contains("\\\\")) {
        s = format!("\\begin{{aligned}}\n{s}\n\\end{{aligned}}");
    } else if matches!(base.as_str(), "gather" | "multline") && !s.contains("\\begin{gathered}") && s.contains("\\\\") {
        s = format!("\\begin{{gathered}}\n{s}\n\\end{{gathered}}");
    }
    NormalizedDisplayMath { cleaned_latex: s, explicit_tag }
}
