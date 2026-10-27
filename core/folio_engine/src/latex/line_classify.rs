use super::{
    build_byte_to_utf16_table, read_balanced_braces, read_bracket_group, read_control_word,
    skip_ascii_ws, skip_hspace, LatexLineClassification, LatexLineKind,
};

fn empty_classification() -> LatexLineClassification {
    LatexLineClassification {
        kind: LatexLineKind::None,
        has_opt_arg: false,
        open_loc: 0,
        open_len: 0,
        opt_loc: 0,
        opt_len: 0,
        space_loc: 0,
        space_len: 0,
        body_loc: 0,
        body_len: 0,
        close_loc: 0,
        close_len: 0,
        cmd: String::new(),
        opt_arg: String::new(),
        arg1: String::new(),
    }
}

pub fn classify_latex_line(line: &str) -> LatexLineClassification {
    let bytes = line.as_bytes();
    let start = skip_hspace(bytes, 0);
    let Some((cmd, after_cmd)) = read_control_word(line, start) else {
        return empty_classification();
    };
    let u16 = build_byte_to_utf16_table(line);
    match cmd {
        "hline" | "toprule" | "midrule" | "bottomrule"
            if skip_hspace(bytes, after_cmd) == bytes.len() =>
        {
            return LatexLineClassification {
                kind: LatexLineKind::TableRule,
                cmd: cmd.to_string(),
                ..empty_classification()
            };
        }
        "cline" => {
            if let Some((s, e, after_b)) = read_balanced_braces(bytes, after_cmd) {
                if skip_hspace(bytes, after_b) == bytes.len() {
                    return LatexLineClassification {
                        kind: LatexLineKind::TableRule,
                        cmd: "cline".to_string(),
                        arg1: line[s..e].to_string(),
                        ..empty_classification()
                    };
                }
            }
        }
        "item" => return classify_item(line, bytes, &u16, start, after_cmd),
        "includegraphics" => {
            if let Some(res) = classify_graphics(line, bytes, &u16, start, after_cmd) {
                return res;
            }
        }
        "caption" => {
            if let Some(res) = classify_caption(line, bytes, &u16, start, after_cmd) {
                return res;
            }
        }
        _ => {}
    }
    classify_macro_open(line, bytes, &u16, cmd, after_cmd)
}

fn read_opt(line: &str, bytes: &[u8], pos: usize) -> (bool, (usize, usize), String, usize) {
    if let Some((os, oe, after_o)) = read_bracket_group(bytes, pos) {
        (true, (os, oe), line[os..oe].to_string(), after_o)
    } else {
        (false, (pos, pos), String::new(), pos)
    }
}

fn classify_item(
    line: &str,
    bytes: &[u8],
    u16: &[usize],
    start: usize,
    after_cmd: usize,
) -> LatexLineClassification {
    let (has_opt_arg, opt_r, opt_arg, p) = read_opt(line, bytes, after_cmd);
    let after_sp = skip_hspace(bytes, p);
    if after_sp > p || after_sp == bytes.len() {
        let end = bytes.len();
        return LatexLineClassification {
            kind: LatexLineKind::Item,
            has_opt_arg,
            open_loc: u16[start],
            open_len: u16[after_cmd].saturating_sub(u16[start]),
            opt_loc: u16[opt_r.0],
            opt_len: u16[opt_r.1].saturating_sub(u16[opt_r.0]),
            space_loc: u16[p],
            space_len: u16[after_sp].saturating_sub(u16[p]),
            body_loc: u16[after_sp],
            body_len: u16[end].saturating_sub(u16[after_sp]),
            close_loc: u16[end],
            close_len: 0,
            cmd: "item".to_string(),
            opt_arg,
            arg1: line[after_sp..end].to_string(),
        };
    }
    empty_classification()
}

fn classify_graphics(
    line: &str,
    bytes: &[u8],
    u16: &[usize],
    start: usize,
    after_cmd: usize,
) -> Option<LatexLineClassification> {
    let (has_opt_arg, opt_r, opt_arg, p) = read_opt(line, bytes, after_cmd);
    let (s, e, after_b) = read_balanced_braces(bytes, p)?;
    (skip_hspace(bytes, after_b) == bytes.len()).then(|| LatexLineClassification {
        kind: LatexLineKind::IncludeGraphics,
        has_opt_arg,
        open_loc: u16[start],
        open_len: u16[s].saturating_sub(u16[start]),
        opt_loc: u16[opt_r.0],
        opt_len: u16[opt_r.1].saturating_sub(u16[opt_r.0]),
        body_loc: u16[s],
        body_len: u16[e].saturating_sub(u16[s]),
        close_loc: u16[e],
        close_len: u16[after_b].saturating_sub(u16[e]),
        cmd: "includegraphics".to_string(),
        opt_arg,
        arg1: line[s..e].to_string(),
        ..empty_classification()
    })
}

fn classify_caption(
    line: &str,
    bytes: &[u8],
    u16: &[usize],
    start: usize,
    after_cmd: usize,
) -> Option<LatexLineClassification> {
    let p = after_cmd + usize::from(bytes.get(after_cmd) == Some(&b'*'));
    let trimmed_end = line.trim_end_matches([' ', '\t']).len();
    (bytes.get(p) == Some(&b'{') && trimmed_end > p + 1 && bytes[trimmed_end - 1] == b'}').then(
        || {
            let (inner_s, close_b) = (p + 1, trimmed_end - 1);
            LatexLineClassification {
                kind: LatexLineKind::Caption,
                open_loc: u16[start],
                open_len: u16[inner_s].saturating_sub(u16[start]),
                body_loc: u16[inner_s],
                body_len: u16[close_b].saturating_sub(u16[inner_s]),
                close_loc: u16[close_b],
                close_len: u16[trimmed_end].saturating_sub(u16[close_b]),
                cmd: "caption".to_string(),
                arg1: line[inner_s..close_b].to_string(),
                ..empty_classification()
            }
        },
    )
}

fn classify_macro_open(
    line: &str,
    bytes: &[u8],
    u16: &[usize],
    cmd: &str,
    after_cmd: usize,
) -> LatexLineClassification {
    let p0 = after_cmd + usize::from(bytes.get(after_cmd) == Some(&b'*'));
    let (has_opt_arg, opt_r, opt_arg, p1) = read_opt(line, bytes, p0);
    let p = skip_ascii_ws(bytes, p1);
    if bytes.get(p) == Some(&b'{') {
        let (body_loc, body_len, close_loc, close_len, arg1) =
            if let Some((s, e, after_b)) = read_balanced_braces(bytes, p) {
                (
                    u16[s],
                    u16[e].saturating_sub(u16[s]),
                    u16[e],
                    u16[after_b].saturating_sub(u16[e]),
                    line[s..e].to_string(),
                )
            } else {
                (u16[p + 1], 0, 0, 0, String::new())
            };
        return LatexLineClassification {
            kind: LatexLineKind::MacroBlockOpen,
            has_opt_arg,
            open_len: u16[p + 1],
            opt_loc: u16[opt_r.0],
            opt_len: u16[opt_r.1].saturating_sub(u16[opt_r.0]),
            body_loc,
            body_len,
            close_loc,
            close_len,
            cmd: cmd.to_string(),
            opt_arg,
            arg1,
            ..empty_classification()
        };
    }
    empty_classification()
}
