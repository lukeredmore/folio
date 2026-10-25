use super::scanner::{read_balanced_braces, read_control_word, skip_ascii_ws};
use super::types::{MacroTemplateAnalysis, NormalizedDisplayMath};

fn section_level(cmd: &str) -> u32 {
    match cmd {
        "part" | "chapter" | "section" | "sectiontitle" => 1,
        "subsection" => 2,
        "subsubsection" => 3,
        "paragraph" => 4,
        _ => 5,
    }
}

pub fn analyze_macro_template(active: &str, body_placeholder: &str) -> MacroTemplateAnalysis {
    let shows_body = !body_placeholder.is_empty() && active.contains(body_placeholder);
    let placeholder_pos = if shows_body {
        active.find(body_placeholder).unwrap_or(active.len())
    } else {
        0
    };
    let bytes = active.as_bytes();
    let mut color_name = String::new();
    let mut prefix_label = String::new();
    let mut vspace_list = Vec::new();
    let mut heading_level = 0u32;

    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] != b'\\' {
            i += 1;
            continue;
        }
        let Some((cmd, after_cmd)) = read_control_word(active, i) else {
            i += 1;
            continue;
        };
        if matches!(cmd, "color" | "textcolor") && color_name.is_empty() {
            if let Some((s, e, after_b)) = read_balanced_braces(bytes, after_cmd) {
                color_name = active[s..e].to_string();
                i = after_b;
                continue;
            }
        } else if cmd == "textbf" && shows_body && prefix_label.is_empty() && i < placeholder_pos {
            if let Some((s, e, after_b)) = read_balanced_braces(bytes, after_cmd) {
                prefix_label = active[s..e].to_string();
                i = after_b;
                continue;
            }
        } else if cmd == "vspace" {
            let mut p = after_cmd;
            if p < bytes.len() && bytes[p] == b'*' {
                p += 1;
            }
            if let Some((s, e, after_b)) = read_balanced_braces(bytes, p) {
                vspace_list.push(active[s..e].trim().to_string());
                i = after_b;
                continue;
            }
        } else if shows_body
            && heading_level == 0
            && matches!(
                cmd,
                "part" | "chapter" | "section" | "subsection" | "subsubsection"
            )
        {
            let mut p = after_cmd;
            if p < bytes.len() && bytes[p] == b'*' {
                p += 1;
            }
            p = skip_ascii_ws(bytes, p);
            if p < bytes.len() && bytes[p] == b'{' {
                heading_level = section_level(cmd);
            }
        }
        i = after_cmd;
    }

    MacroTemplateAnalysis {
        shows_body,
        heading_level,
        color_name,
        prefix_label,
        vspace_args: vspace_list.join(","),
    }
}

pub fn normalize_display_math(raw: &str, env_name: &str) -> NormalizedDisplayMath {
    let bytes = raw.as_bytes();
    let mut explicit_tag = String::new();
    let mut stripped = String::with_capacity(raw.len());
    let mut i = 0;

    while i < bytes.len() {
        if bytes[i] == b'\\' {
            if let Some((cmd, after_cmd)) = read_control_word(raw, i) {
                if cmd == "tag" {
                    let mut p = after_cmd;
                    if p < bytes.len() && bytes[p] == b'*' {
                        p += 1;
                    }
                    if let Some((s, e, after_b)) = read_balanced_braces(bytes, p) {
                        if explicit_tag.is_empty() {
                            explicit_tag = raw[s..e].to_string();
                        }
                        i = after_b;
                        continue;
                    }
                } else if cmd == "label" {
                    if let Some((_, _, after_b)) = read_balanced_braces(bytes, after_cmd) {
                        i = after_b;
                        continue;
                    }
                } else if matches!(cmd, "nonumber" | "notag") {
                    i = after_cmd;
                    continue;
                }
            }
        }
        if let Some(ch) = raw[i..].chars().next() {
            stripped.push(ch);
            i += ch.len_utf8();
        } else {
            break;
        }
    }

    let mut s = stripped.trim().to_string();
    let base_env = env_name.replace('*', "");
    if matches!(base_env.as_str(), "align" | "flalign" | "alignat")
        && !s.contains("\\begin{aligned}")
        && (s.contains('&') || s.contains("\\\\"))
    {
        s = format!("\\begin{{aligned}}\n{s}\n\\end{{aligned}}");
    } else if matches!(base_env.as_str(), "gather" | "multline")
        && !s.contains("\\begin{gathered}")
        && s.contains("\\\\")
    {
        s = format!("\\begin{{gathered}}\n{s}\n\\end{{gathered}}");
    }

    NormalizedDisplayMath {
        cleaned_latex: s,
        explicit_tag,
    }
}
