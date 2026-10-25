use super::inline_scan::{make_span, scan_range, InlineScanCtx};
use super::scanner::{read_balanced_braces, read_bracket_group, skip_hspace};
use super::types::{LatexInlineSpan, LatexInlineSpanKind};

fn is_cite_cmd(s: &str) -> bool {
    matches!(
        s,
        "cite" | "citep" | "citet" | "parencite" | "textcite" | "autocite"
    )
}

fn is_ref_cmd(s: &str) -> bool {
    matches!(s, "eqref" | "autoref" | "cref" | "Cref" | "ref" | "pageref")
}

fn is_hidden_meta_brace_cmd(s: &str) -> bool {
    matches!(
        s,
        "label" | "bibliography" | "bibliographystyle" | "addbibresource" | "nocite"
    )
}

fn is_hidden_meta_bare_cmd(s: &str) -> bool {
    matches!(
        s,
        "centering" | "noindent" | "newpage" | "clearpage" | "tableofcontents"
    )
}

fn is_style_cmd(s: &str) -> bool {
    matches!(
        s,
        "textbf"
            | "textit"
            | "emph"
            | "underline"
            | "texttt"
            | "textsc"
            | "footnote"
            | "textrm"
            | "textsf"
    )
}

pub(super) fn try_scan_control_word(
    ctx: &InlineScanCtx<'_>,
    i: usize,
    cmd: &str,
    after_cmd: usize,
    end: usize,
    out: &mut Vec<LatexInlineSpan>,
) -> Option<usize> {
    if let Some(next_i) = try_scan_cite_or_ref(ctx, i, cmd, after_cmd, end, out) {
        return Some(next_i);
    }
    if let Some(next_i) = try_scan_link_or_style(ctx, i, cmd, after_cmd, end, out) {
        return Some(next_i);
    }
    try_scan_symbol_or_macro(ctx, i, cmd, after_cmd, end, out)
}

fn try_scan_cite_or_ref(
    ctx: &InlineScanCtx<'_>,
    i: usize,
    cmd: &str,
    after_cmd: usize,
    end: usize,
    out: &mut Vec<LatexInlineSpan>,
) -> Option<usize> {
    let text = ctx.text;
    let bytes = ctx.bytes;
    let u16 = ctx.u16;
    if is_cite_cmd(cmd) {
        let mut p = after_cmd;
        if p < end && bytes[p] == b'*' {
            p += 1;
        }
        while let Some((_, _, after_b)) = read_bracket_group(&bytes[..end], p) {
            p = after_b;
        }
        if let Some((k_start, k_end, after_brace)) = read_balanced_braces(&bytes[..end], p) {
            out.push(make_span(
                u16,
                LatexInlineSpanKind::Cite,
                (i, after_brace),
                (i, k_start),
                (k_start, k_end),
                (k_end, after_brace),
                (cmd, &text[k_start..k_end]),
            ));
            return Some(after_brace);
        }
    } else if is_ref_cmd(cmd) {
        if let Some((k_start, k_end, after_brace)) = read_balanced_braces(&bytes[..end], after_cmd)
        {
            out.push(make_span(
                u16,
                LatexInlineSpanKind::Ref,
                (i, after_brace),
                (i, k_start),
                (k_start, k_end),
                (k_end, after_brace),
                (cmd, &text[k_start..k_end]),
            ));
            return Some(after_brace);
        }
    } else if is_hidden_meta_brace_cmd(cmd) {
        if let Some((k_start, k_end, after_brace)) = read_balanced_braces(&bytes[..end], after_cmd)
        {
            out.push(make_span(
                u16,
                LatexInlineSpanKind::HiddenMeta,
                (i, after_brace),
                (i, after_brace),
                (k_start, k_end),
                (after_brace, after_brace),
                (cmd, &text[k_start..k_end]),
            ));
            return Some(after_brace);
        }
    } else if is_hidden_meta_bare_cmd(cmd) {
        let p = skip_hspace(&bytes[..end], after_cmd);
        out.push(make_span(
            u16,
            LatexInlineSpanKind::HiddenMeta,
            (i, p),
            (i, p),
            (i, i),
            (p, p),
            (cmd, ""),
        ));
        return Some(p);
    }
    None
}

fn try_scan_link_or_style(
    ctx: &InlineScanCtx<'_>,
    i: usize,
    cmd: &str,
    after_cmd: usize,
    end: usize,
    out: &mut Vec<LatexInlineSpan>,
) -> Option<usize> {
    let text = ctx.text;
    let bytes = ctx.bytes;
    let u16 = ctx.u16;
    if cmd == "href" {
        if let Some((u_start, u_end, after_u)) = read_balanced_braces(&bytes[..end], after_cmd) {
            if let Some((t_start, t_end, after_t)) = read_balanced_braces(&bytes[..end], after_u) {
                out.push(make_span(
                    u16,
                    LatexInlineSpanKind::Href,
                    (i, after_t),
                    (i, t_start),
                    (t_start, t_end),
                    (t_end, after_t),
                    ("href", &text[u_start..u_end]),
                ));
                scan_range(ctx, t_start, t_end, out);
                return Some(after_t);
            }
        }
    } else if cmd == "url" {
        if let Some((u_start, u_end, after_u)) = read_balanced_braces(&bytes[..end], after_cmd) {
            out.push(make_span(
                u16,
                LatexInlineSpanKind::Url,
                (i, after_u),
                (i, u_start),
                (u_start, u_end),
                (u_end, after_u),
                ("url", &text[u_start..u_end]),
            ));
            return Some(after_u);
        }
    } else if cmd == "textcolor" {
        if let Some((c_start, c_end, after_c)) = read_balanced_braces(&bytes[..end], after_cmd) {
            if let Some((t_start, t_end, after_t)) = read_balanced_braces(&bytes[..end], after_c) {
                out.push(make_span(
                    u16,
                    LatexInlineSpanKind::ColorGroup,
                    (i, after_t),
                    (i, t_start),
                    (t_start, t_end),
                    (t_end, after_t),
                    ("textcolor", &text[c_start..c_end]),
                ));
                scan_range(ctx, t_start, t_end, out);
                return Some(after_t);
            }
        }
    } else if is_style_cmd(cmd) {
        if let Some((t_start, t_end, after_t)) = read_balanced_braces(&bytes[..end], after_cmd) {
            out.push(make_span(
                u16,
                LatexInlineSpanKind::StyleCmd,
                (i, after_t),
                (i, t_start),
                (t_start, t_end),
                (t_end, after_t),
                (cmd, ""),
            ));
            scan_range(ctx, t_start, t_end, out);
            return Some(after_t);
        }
    }
    None
}

fn try_scan_symbol_or_macro(
    ctx: &InlineScanCtx<'_>,
    i: usize,
    cmd: &str,
    after_cmd: usize,
    end: usize,
    out: &mut Vec<LatexInlineSpan>,
) -> Option<usize> {
    let bytes = ctx.bytes;
    let u16 = ctx.u16;
    if matches!(cmd, "LaTeX" | "TeX" | "today") {
        let mut p = after_cmd;
        let mut close_range = (after_cmd, after_cmd);
        if p + 1 < end && bytes[p] == b'{' && bytes[p + 1] == b'}' {
            close_range = (p, p + 2);
            p += 2;
        }
        out.push(make_span(
            u16,
            LatexInlineSpanKind::LogoCmd,
            (i, p),
            (i, i + 1),
            (i + 1, after_cmd),
            close_range,
            (cmd, ""),
        ));
        return Some(p);
    } else if cmd == "textbackslash" {
        let mut p = after_cmd;
        if p + 1 < end && bytes[p] == b'{' && bytes[p + 1] == b'}' {
            p += 2;
        } else {
            p = skip_hspace(&bytes[..end], p);
        }
        out.push(make_span(
            u16,
            LatexInlineSpanKind::TextBackslash,
            (i, p),
            (i + 1, p),
            (i, i + 1),
            (p, p),
            (cmd, ""),
        ));
        return Some(p);
    } else if after_cmd + 1 < end && bytes[after_cmd] == b'{' && bytes[after_cmd + 1] == b'}' {
        out.push(make_span(
            u16,
            LatexInlineSpanKind::ProseMacroCandidate,
            (i, after_cmd + 2),
            (i, after_cmd + 2),
            (i + 1, after_cmd),
            (after_cmd, after_cmd + 2),
            (cmd, ""),
        ));
        return Some(after_cmd + 2);
    } else if after_cmd >= end || bytes[after_cmd] != b'{' {
        out.push(make_span(
            u16,
            LatexInlineSpanKind::ProseMacroCandidate,
            (i, after_cmd),
            (i, after_cmd),
            (i + 1, after_cmd),
            (after_cmd, after_cmd),
            (cmd, ""),
        ));
        return Some(after_cmd);
    }
    Some(after_cmd)
}
