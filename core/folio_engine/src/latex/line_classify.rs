use super::scanner::{
    build_byte_to_utf16_table, read_balanced_braces, read_bracket_group, read_control_word,
    skip_ascii_ws, skip_hspace,
};
use super::types::{LatexLineClassification, LatexLineKind};

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
    if start >= bytes.len() || bytes[start] != b'\\' {
        return empty_classification();
    }
    let Some((cmd, after_cmd)) = read_control_word(line, start) else {
        return empty_classification();
    };
    let u16 = build_byte_to_utf16_table(line);

    if matches!(cmd, "hline" | "toprule" | "midrule" | "bottomrule") {
        let p = skip_hspace(bytes, after_cmd);
        if p == bytes.len() {
            return LatexLineClassification {
                kind: LatexLineKind::TableRule,
                cmd: cmd.to_string(),
                ..empty_classification()
            };
        }
    } else if cmd == "cline" {
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
    } else if cmd == "item" {
        return classify_item_line(line, bytes, &u16, start, after_cmd);
    } else if cmd == "includegraphics" {
        if let Some(res) = classify_includegraphics_line(line, bytes, &u16, start, after_cmd) {
            return res;
        }
    } else if cmd == "caption" {
        if let Some(res) = classify_caption_line(line, bytes, &u16, start, after_cmd) {
            return res;
        }
    }

    classify_macro_block_open(line, bytes, &u16, cmd, after_cmd)
}

fn classify_item_line(
    line: &str,
    bytes: &[u8],
    u16: &[usize],
    start: usize,
    after_cmd: usize,
) -> LatexLineClassification {
    let mut p = after_cmd;
    let mut has_opt_arg = false;
    let mut opt_range = (p, p);
    let mut opt_str = String::new();
    if let Some((o_s, o_e, after_o)) = read_bracket_group(bytes, p) {
        has_opt_arg = true;
        opt_range = (o_s, o_e);
        opt_str = line[o_s..o_e].to_string();
        p = after_o;
    }
    let after_space = skip_hspace(bytes, p);
    if after_space > p || after_space == bytes.len() {
        let body_end = bytes.len();
        return LatexLineClassification {
            kind: LatexLineKind::Item,
            has_opt_arg,
            open_loc: u16[start],
            open_len: u16[after_cmd].saturating_sub(u16[start]),
            opt_loc: u16[opt_range.0],
            opt_len: u16[opt_range.1].saturating_sub(u16[opt_range.0]),
            space_loc: u16[p],
            space_len: u16[after_space].saturating_sub(u16[p]),
            body_loc: u16[after_space],
            body_len: u16[body_end].saturating_sub(u16[after_space]),
            close_loc: u16[body_end],
            close_len: 0,
            cmd: "item".to_string(),
            opt_arg: opt_str,
            arg1: line[after_space..body_end].to_string(),
        };
    }
    empty_classification()
}

fn classify_includegraphics_line(
    line: &str,
    bytes: &[u8],
    u16: &[usize],
    start: usize,
    after_cmd: usize,
) -> Option<LatexLineClassification> {
    let mut p = after_cmd;
    let mut has_opt = false;
    let mut opt_range = (p, p);
    let mut opt_str = String::new();
    if let Some((o_s, o_e, after_o)) = read_bracket_group(bytes, p) {
        has_opt = true;
        opt_range = (o_s, o_e);
        opt_str = line[o_s..o_e].to_string();
        p = after_o;
    }
    let (s, e, after_b) = read_balanced_braces(bytes, p)?;
    if skip_hspace(bytes, after_b) != bytes.len() {
        return None;
    }
    Some(LatexLineClassification {
        kind: LatexLineKind::IncludeGraphics,
        has_opt_arg: has_opt,
        open_loc: u16[start],
        open_len: u16[s].saturating_sub(u16[start]),
        opt_loc: u16[opt_range.0],
        opt_len: u16[opt_range.1].saturating_sub(u16[opt_range.0]),
        space_loc: 0,
        space_len: 0,
        body_loc: u16[s],
        body_len: u16[e].saturating_sub(u16[s]),
        close_loc: u16[e],
        close_len: u16[after_b].saturating_sub(u16[e]),
        cmd: "includegraphics".to_string(),
        opt_arg: opt_str,
        arg1: line[s..e].to_string(),
    })
}

fn classify_caption_line(
    line: &str,
    bytes: &[u8],
    u16: &[usize],
    start: usize,
    after_cmd: usize,
) -> Option<LatexLineClassification> {
    let mut p = after_cmd;
    if p < bytes.len() && bytes[p] == b'*' {
        p += 1;
    }
    if p >= bytes.len() || bytes[p] != b'{' {
        return None;
    }
    let trimmed_end = line.trim_end_matches([' ', '\t']).len();
    if trimmed_end <= p + 1 || bytes[trimmed_end - 1] != b'}' {
        return None;
    }
    let inner_start = p + 1;
    let close_brace = trimmed_end - 1;
    Some(LatexLineClassification {
        kind: LatexLineKind::Caption,
        has_opt_arg: false,
        open_loc: u16[start],
        open_len: u16[inner_start].saturating_sub(u16[start]),
        opt_loc: 0,
        opt_len: 0,
        space_loc: 0,
        space_len: 0,
        body_loc: u16[inner_start],
        body_len: u16[close_brace].saturating_sub(u16[inner_start]),
        close_loc: u16[close_brace],
        close_len: u16[trimmed_end].saturating_sub(u16[close_brace]),
        cmd: "caption".to_string(),
        opt_arg: String::new(),
        arg1: line[inner_start..close_brace].to_string(),
    })
}

fn classify_macro_block_open(
    line: &str,
    bytes: &[u8],
    u16: &[usize],
    cmd: &str,
    after_cmd: usize,
) -> LatexLineClassification {
    let mut p = after_cmd;
    if p < bytes.len() && bytes[p] == b'*' {
        p += 1;
    }
    let mut has_opt = false;
    let mut opt_range = (p, p);
    let mut opt_str = String::new();
    if let Some((o_s, o_e, after_o)) = read_bracket_group(bytes, p) {
        has_opt = true;
        opt_range = (o_s, o_e);
        opt_str = line[o_s..o_e].to_string();
        p = after_o;
    }
    p = skip_ascii_ws(bytes, p);
    if p < bytes.len() && bytes[p] == b'{' {
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
            has_opt_arg: has_opt,
            open_loc: 0,
            open_len: u16[p + 1],
            opt_loc: u16[opt_range.0],
            opt_len: u16[opt_range.1].saturating_sub(u16[opt_range.0]),
            space_loc: 0,
            space_len: 0,
            body_loc,
            body_len,
            close_loc,
            close_len,
            cmd: cmd.to_string(),
            opt_arg: opt_str,
            arg1,
        };
    }
    empty_classification()
}
