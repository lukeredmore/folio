use super::scanner::{
    clean_tex_inline_text, find_unescaped_percent_byte, read_balanced_braces, read_bracket_group,
    read_control_word_with_at, skip_ascii_ws, skip_hspace,
};
use super::types::{LatexDirectiveItem, LatexDirectiveKind};

fn push_item(
    out: &mut Vec<LatexDirectiveItem>,
    kind: LatexDirectiveKind,
    starred: bool,
    cmd: &str,
    opt_arg: &str,
    args: (&str, &str, &str),
) {
    out.push(LatexDirectiveItem {
        kind,
        starred,
        cmd: cmd.to_string(),
        opt_arg: opt_arg.to_string(),
        arg1: args.0.to_string(),
        arg2: args.1.to_string(),
        arg3: args.2.to_string(),
    });
}

fn read_opt_and_brace(text: &str, pos: usize) -> Option<(&str, &str, usize)> {
    let bytes = text.as_bytes();
    let mut p = pos;
    let mut opt = "";
    if let Some((o_s, o_e, after_o)) = read_bracket_group(bytes, p) {
        opt = &text[o_s..o_e];
        p = after_o;
    }
    let (a_s, a_e, after_a) = read_balanced_braces(bytes, p)?;
    Some((opt, &text[a_s..a_e], after_a))
}

pub fn scan_latex_directives(line: &str, is_preamble: bool) -> Vec<LatexDirectiveItem> {
    let uncommented = match find_unescaped_percent_byte(line) {
        Some(idx) => &line[..idx],
        None => line,
    };
    let bytes = uncommented.as_bytes();
    let first_non_ws = skip_ascii_ws(bytes, 0);
    let trimmed = uncommented.trim();
    let mut out = Vec::new();

    if is_preamble {
        if trimmed == "\\onehalfspacing" {
            push_item(
                &mut out,
                LatexDirectiveKind::SetStretch,
                false,
                "onehalfspacing",
                "",
                ("1.25", "", ""),
            );
        } else if trimmed == "\\doublespacing" {
            push_item(
                &mut out,
                LatexDirectiveKind::SetStretch,
                false,
                "doublespacing",
                "",
                ("1.65", "", ""),
            );
        } else if trimmed == "\\singlespacing" {
            push_item(
                &mut out,
                LatexDirectiveKind::SetStretch,
                false,
                "singlespacing",
                "",
                ("1.0", "", ""),
            );
        }
    }

    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] != b'\\' {
            i += 1;
            continue;
        }
        let Some((cmd, after_cmd)) = read_control_word_with_at(uncommented, i) else {
            i += 1;
            continue;
        };
        let at_line_start = i == first_non_ws;
        if let Some(next_i) =
            try_scan_directive_cmd(uncommented, cmd, after_cmd, at_line_start, is_preamble, &mut out)
        {
            i = next_i;
        } else {
            i = after_cmd;
        }
    }
    out
}

fn try_scan_directive_cmd(
    text: &str,
    cmd: &str,
    after_cmd: usize,
    at_line_start: bool,
    is_preamble: bool,
    out: &mut Vec<LatexDirectiveItem>,
) -> Option<usize> {
    let bytes = text.as_bytes();
    if cmd == "documentclass" {
        let (opt, arg1, next_i) = read_opt_and_brace(text, after_cmd)?;
        push_item(out, LatexDirectiveKind::DocumentClass, false, cmd, opt, (arg1, "", ""));
        return Some(next_i);
    }
    if is_preamble && cmd == "usepackage" {
        let (opt, arg1, next_i) = read_opt_and_brace(text, after_cmd)?;
        push_item(out, LatexDirectiveKind::UsePackage, false, cmd, opt, (arg1, "", ""));
        return Some(next_i);
    }
    if at_line_start
        && matches!(
            cmd,
            "part"
                | "chapter"
                | "section"
                | "sectiontitle"
                | "subsection"
                | "subsubsection"
                | "paragraph"
                | "subparagraph"
        )
    {
        let mut p = after_cmd;
        let mut starred = cmd == "sectiontitle";
        if p < bytes.len() && bytes[p] == b'*' {
            starred = true;
            p += 1;
        }
        let (opt, raw_title, next_i) = read_opt_and_brace(text, p)?;
        let clean = clean_tex_inline_text(raw_title);
        push_item(out, LatexDirectiveKind::Section, starred, cmd, opt, (&clean, "", ""));
        return Some(next_i);
    }
    if cmd == "label" {
        let (s, e, next_i) = read_balanced_braces(bytes, after_cmd)?;
        push_item(out, LatexDirectiveKind::Label, false, cmd, "", (text[s..e].trim(), "", ""));
        return Some(next_i);
    }
    if matches!(cmd, "bibliography" | "addbibresource") {
        let (s, e, next_i) = read_balanced_braces(bytes, after_cmd)?;
        push_item(out, LatexDirectiveKind::BibResource, false, cmd, "", (&text[s..e], "", ""));
        return Some(next_i);
    }
    if is_preamble && at_line_start && matches!(cmd, "input" | "include") {
        let (s, e, next_i) = read_balanced_braces(bytes, after_cmd)?;
        push_item(out, LatexDirectiveKind::InputFile, false, cmd, "", (&text[s..e], "", ""));
        return Some(next_i);
    }
    if at_line_start && matches!(cmd, "title" | "author" | "date") {
        let (opt, raw_val, next_i) = read_opt_and_brace(text, after_cmd)?;
        let clean = clean_tex_inline_text(raw_val);
        push_item(out, LatexDirectiveKind::Frontmatter, false, cmd, opt, (&clean, "", ""));
        return Some(next_i);
    }
    if let Some(next_i) = try_scan_preamble_style_cmd(text, cmd, after_cmd, is_preamble, out) {
        return Some(next_i);
    }
    try_scan_cond_cmd(text, cmd, after_cmd, out)
}

fn try_scan_preamble_style_cmd(
    text: &str,
    cmd: &str,
    after_cmd: usize,
    is_preamble: bool,
    out: &mut Vec<LatexDirectiveItem>,
) -> Option<usize> {
    if !is_preamble {
        return None;
    }
    let bytes = text.as_bytes();
    if matches!(cmd, "setmainfont" | "setsansfont" | "setmonofont") {
        let (opt, font_name, next_i) = read_opt_and_brace(text, after_cmd)?;
        push_item(out, LatexDirectiveKind::SetFont, false, cmd, opt, (font_name.trim(), "", ""));
        return Some(next_i);
    }
    if cmd == "renewcommand" {
        let (s1, e1, after1) = read_balanced_braces(bytes, after_cmd)?;
        if text[s1..e1].trim() == "\\familydefault" {
            let (s2, e2, after2) = read_balanced_braces(bytes, after1)?;
            let target = text[s2..e2].trim().trim_start_matches('\\');
            if matches!(target, "sfdefault" | "rmdefault" | "ttdefault") {
                push_item(out, LatexDirectiveKind::FamilyDefault, false, cmd, "", (target, "", ""));
                return Some(after2);
            }
        }
    }
    if matches!(cmd, "setstretch" | "linespread") {
        let (s, e, next_i) = read_balanced_braces(bytes, after_cmd)?;
        push_item(out, LatexDirectiveKind::SetStretch, false, cmd, "", (text[s..e].trim(), "", ""));
        return Some(next_i);
    }
    if cmd == "setlength" {
        let (s1, e1, after1) = read_balanced_braces(bytes, after_cmd)?;
        let param = text[s1..e1].trim().trim_start_matches('\\');
        if matches!(param, "parindent" | "parskip") {
            let (s2, e2, after2) = read_balanced_braces(bytes, after1)?;
            push_item(out, LatexDirectiveKind::SetLength, false, cmd, "", (param, text[s2..e2].trim(), ""));
            return Some(after2);
        }
    }
    if cmd == "definecolor" {
        let (s1, e1, after1) = read_balanced_braces(bytes, after_cmd)?;
        let (s2, e2, after2) = read_balanced_braces(bytes, after1)?;
        let (s3, e3, after3) = read_balanced_braces(bytes, after2)?;
        push_item(
            out,
            LatexDirectiveKind::DefineColor,
            false,
            cmd,
            "",
            (text[s1..e1].trim(), text[s2..e2].trim(), text[s3..e3].trim()),
        );
        return Some(after3);
    }
    None
}

fn try_scan_cond_cmd(
    text: &str,
    cmd: &str,
    after_cmd: usize,
    out: &mut Vec<LatexDirectiveItem>,
) -> Option<usize> {
    let bytes = text.as_bytes();
    if cmd == "newif" {
        let p = skip_hspace(bytes, after_cmd);
        let (if_cmd, next_i) = read_control_word_with_at(text, p)?;
        if let Some(cond_name) = if_cmd.strip_prefix("if") {
            if !cond_name.is_empty() {
                push_item(out, LatexDirectiveKind::NewIf, false, "newif", "", (cond_name, "", ""));
                return Some(next_i);
            }
        }
    }
    if let Some(cond_name) = cmd.strip_suffix("true") {
        if !cond_name.is_empty() && cond_name != "if" {
            push_item(out, LatexDirectiveKind::ToggleIf, false, cmd, "", (cond_name, "true", ""));
        }
    } else if let Some(cond_name) = cmd.strip_suffix("false") {
        if !cond_name.is_empty() && cond_name != "if" {
            push_item(out, LatexDirectiveKind::ToggleIf, false, cmd, "", (cond_name, "false", ""));
        }
    }
    None
}
