use super::{
    build_byte_to_utf16_table, read_balanced_braces, read_bracket_group, read_control_word,
    skip_hspace, LatexInlineSpan, LatexInlineSpanKind,
};

const SIZE_CMDS: &[&str] = &[
    "Huge",
    "huge",
    "LARGE",
    "Large",
    "large",
    "normalsize",
    "small",
    "footnotesize",
    "scriptsize",
    "tiny",
];

fn make_span(
    u16: &[usize],
    kind: LatexInlineSpanKind,
    full: (usize, usize),
    open: (usize, usize),
    inner: (usize, usize),
    close: (usize, usize),
    cmd_arg: (&str, &str),
) -> LatexInlineSpan {
    LatexInlineSpan {
        kind,
        full_loc: u16[full.0],
        full_len: u16[full.1].saturating_sub(u16[full.0]),
        open_loc: u16[open.0],
        open_len: u16[open.1].saturating_sub(u16[open.0]),
        inner_loc: u16[inner.0],
        inner_len: u16[inner.1].saturating_sub(u16[inner.0]),
        close_loc: u16[close.0],
        close_len: u16[close.1].saturating_sub(u16[close.0]),
        cmd: cmd_arg.0.to_string(),
        arg: cmd_arg.1.to_string(),
    }
}

struct InlineScanCtx<'a> {
    text: &'a str,
    bytes: &'a [u8],
    u16: &'a [usize],
}

pub fn scan_latex_inlines(text: &str) -> Vec<LatexInlineSpan> {
    let bytes = text.as_bytes();
    let u16 = build_byte_to_utf16_table(text);
    let ctx = InlineScanCtx {
        text,
        bytes,
        u16: &u16,
    };
    let mut out = Vec::new();
    scan_range(&ctx, 0, bytes.len(), &mut out);
    out
}

fn scan_range(ctx: &InlineScanCtx<'_>, start: usize, end: usize, out: &mut Vec<LatexInlineSpan>) {
    let mut i = start;
    while i < end {
        let b = ctx.bytes[i];
        if b == b'$' {
            if let Some(next_i) = try_scan_dollar(ctx, i, end, out) {
                i = next_i;
                continue;
            }
        } else if b == b'{' {
            if let Some(next_i) = try_scan_braced(ctx, i, end, out) {
                i = next_i;
                continue;
            }
        } else if (b == b'`' || b == b'\'') && i + 1 < end && ctx.bytes[i + 1] == b {
            out.push(make_span(
                ctx.u16,
                LatexInlineSpanKind::TexQuote,
                (i, i + 2),
                (i, i + 2),
                (i, i),
                (i, i),
                (if b == b'`' { "``" } else { "''" }, ""),
            ));
            i += 2;
            continue;
        } else if b == b'\\' {
            if let Some(next_i) = try_scan_backslash(ctx, i, end, out) {
                i = next_i;
                continue;
            }
        }
        i += 1;
    }
}

fn try_scan_dollar(
    ctx: &InlineScanCtx<'_>,
    i: usize,
    end: usize,
    out: &mut Vec<LatexInlineSpan>,
) -> Option<usize> {
    let bytes = ctx.bytes;
    if (i > 0 && matches!(bytes[i - 1], b'\\' | b'$')) || bytes.get(i + 1) == Some(&b'$') {
        return None;
    }
    let mut j = i + 1;
    while j < end && !ends_paragraph(bytes, j, end) {
        if bytes[j] == b'$'
            && !matches!(bytes[j - 1], b'\\' | b'$')
            && bytes.get(j + 1) != Some(&b'$')
        {
            return (j > i + 1).then(|| {
                out.push(make_span(
                    ctx.u16,
                    LatexInlineSpanKind::InlineMath,
                    (i, j + 1),
                    (i, i + 1),
                    (i + 1, j),
                    (j, j + 1),
                    ("$", &ctx.text[(i + 1)..j]),
                ));
                j + 1
            });
        }
        j += 1;
    }
    None
}

/// True when `bytes[j]` is a line break that a blank line follows, which ends a TeX paragraph
/// and so any inline math. A single line break, inside a multi-line macro call, does not.
fn ends_paragraph(bytes: &[u8], j: usize, end: usize) -> bool {
    if bytes[j] != b'\n' {
        return false;
    }
    let mut k = j + 1;
    while k < end && matches!(bytes[k], b' ' | b'\t' | b'\r') {
        k += 1;
    }
    k >= end || bytes[k] == b'\n'
}

fn try_scan_braced(
    ctx: &InlineScanCtx<'_>,
    i: usize,
    end: usize,
    out: &mut Vec<LatexInlineSpan>,
) -> Option<usize> {
    let bytes = ctx.bytes;
    (bytes.get(i + 1) == Some(&b'\\')).then_some(())?;
    let (_, close_b, after_close) = read_balanced_braces(&bytes[..end], i)?;
    let (cmd, after_cmd) = read_control_word(ctx.text, i + 1)?;
    if SIZE_CMDS.contains(&cmd) {
        let (mut p, mut opt_color) = (skip_hspace(bytes, after_cmd), "");
        if let Some(("color", after_c_cmd)) = read_control_word(ctx.text, p) {
            if let Some((cs, ce, after_c)) = read_balanced_braces(&bytes[..end], after_c_cmd) {
                opt_color = &ctx.text[cs..ce];
                p = skip_hspace(bytes, after_c);
            }
        }
        if p <= close_b {
            out.push(make_span(
                ctx.u16,
                LatexInlineSpanKind::SizeGroup,
                (i, after_close),
                (i, p),
                (p, close_b),
                (close_b, after_close),
                (cmd, opt_color),
            ));
            scan_range(ctx, p, close_b, out);
            return Some(after_close);
        }
    } else if cmd == "color" {
        let (cs, ce, after_c) = read_balanced_braces(&bytes[..end], after_cmd)?;
        let mut p = skip_hspace(bytes, after_c);
        if let Some((nc, after_n)) = read_control_word(ctx.text, p) {
            if SIZE_CMDS.contains(&nc) {
                p = skip_hspace(bytes, after_n);
            }
        }
        if p <= close_b {
            out.push(make_span(
                ctx.u16,
                LatexInlineSpanKind::ColorGroup,
                (i, after_close),
                (i, p),
                (p, close_b),
                (close_b, after_close),
                ("color", &ctx.text[cs..ce]),
            ));
            scan_range(ctx, p, close_b, out);
            return Some(after_close);
        }
    }
    None
}

fn try_scan_backslash(
    ctx: &InlineScanCtx<'_>,
    i: usize,
    end: usize,
    out: &mut Vec<LatexInlineSpan>,
) -> Option<usize> {
    let bytes = ctx.bytes;
    let next_b = *bytes.get(i + 1)?;
    if next_b == b'(' {
        let mut j = i + 2;
        while j + 1 < end {
            if bytes[j] == b'\\' && bytes[j + 1] == b')' {
                if j > i + 2 {
                    out.push(make_span(
                        ctx.u16,
                        LatexInlineSpanKind::InlineMath,
                        (i, j + 2),
                        (i, i + 2),
                        (i + 2, j),
                        (j, j + 2),
                        ("\\(", &ctx.text[(i + 2)..j]),
                    ));
                }
                return Some(j + 2);
            }
            j += 1;
        }
        return Some(i + 2);
    }
    if next_b == b'\\' {
        let (mut p, mut arg_str) = (i + 2, "");
        if let Some((bs, be, after_b)) = read_bracket_group(&bytes[..end], p) {
            arg_str = &ctx.text[bs..be];
            p = after_b;
        }
        out.push(make_span(
            ctx.u16,
            LatexInlineSpanKind::HiddenMeta,
            (i, p),
            (i, p),
            (i, i),
            (i, i),
            ("\\\\", arg_str),
        ));
        return Some(p);
    }
    if matches!(next_b, b'&' | b'%' | b'$' | b'#' | b'_' | b'{' | b'}') {
        out.push(make_span(
            ctx.u16,
            LatexInlineSpanKind::EscapedChar,
            (i, i + 2),
            (i, i + 1),
            (i + 1, i + 2),
            (i + 2, i + 2),
            (&ctx.text[(i + 1)..(i + 2)], ""),
        ));
        return Some(i + 2);
    }
    let (cmd, after_cmd) = read_control_word(ctx.text, i)?;
    try_scan_cmd(ctx, i, cmd, after_cmd, end, out)
}

fn try_scan_cmd(
    ctx: &InlineScanCtx<'_>,
    i: usize,
    cmd: &str,
    after: usize,
    end: usize,
    out: &mut Vec<LatexInlineSpan>,
) -> Option<usize> {
    let bytes = &ctx.bytes[..end];
    if let Some(next) = scan_argument_cmd(ctx, bytes, (i, cmd, after), out) {
        return Some(next);
    }
    if let Some(next) = scan_bare_cmd(ctx, bytes, (i, cmd, after), out) {
        return Some(next);
    }
    Some(scan_prose_macro_candidate(ctx, bytes, (i, cmd, after), out))
}

/// Builds a span for `\cmd{arg}`: the braces are the delimiters and `arg` is the content.
fn braced_span(
    ctx: &InlineScanCtx<'_>,
    kind: LatexInlineSpanKind,
    open: usize,
    (ks, ke, next): (usize, usize, usize),
    payload: (&str, &str),
) -> LatexInlineSpan {
    make_span(
        ctx.u16,
        kind,
        (open, next),
        (open, ks),
        (ks, ke),
        (ke, next),
        payload,
    )
}

/// Commands that take a braced argument. Returns `None` when `cmd` is not one of
/// them or its argument is malformed, so the caller can treat it as a plain macro.
fn scan_argument_cmd(
    ctx: &InlineScanCtx<'_>,
    bytes: &[u8],
    (i, cmd, after): (usize, &str, usize),
    out: &mut Vec<LatexInlineSpan>,
) -> Option<usize> {
    use LatexInlineSpanKind as K;
    let text = ctx.text;
    match cmd {
        "cite" | "citep" | "citet" | "parencite" | "textcite" | "autocite" => {
            let mut p = after + usize::from(bytes.get(after) == Some(&b'*'));
            while let Some((_, _, next)) = read_bracket_group(bytes, p) {
                p = next;
            }
            let arg @ (ks, ke, next) = read_balanced_braces(bytes, p)?;
            out.push(braced_span(ctx, K::Cite, i, arg, (cmd, &text[ks..ke])));
            Some(next)
        }
        "eqref" | "autoref" | "cref" | "Cref" | "ref" | "pageref" => {
            let arg @ (ks, ke, next) = read_balanced_braces(bytes, after)?;
            out.push(braced_span(ctx, K::Ref, i, arg, (cmd, &text[ks..ke])));
            Some(next)
        }
        "label" | "bibliography" | "bibliographystyle" | "addbibresource" | "nocite" | "index" => {
            let (ks, ke, next) = read_balanced_braces(bytes, after)?;
            out.push(make_span(
                ctx.u16,
                K::HiddenMeta,
                (i, next),
                (i, next),
                (ks, ke),
                (next, next),
                (cmd, &text[ks..ke]),
            ));
            Some(next)
        }
        "href" | "textcolor" => {
            let (s1, e1, a1) = read_balanced_braces(bytes, after)?;
            let arg @ (s2, e2, a2) = read_balanced_braces(bytes, a1)?;
            let kind = if cmd == "href" {
                K::Href
            } else {
                K::ColorGroup
            };
            out.push(braced_span(ctx, kind, i, arg, (cmd, &text[s1..e1])));
            scan_range(ctx, s2, e2, out);
            Some(a2)
        }
        "url" => {
            let arg @ (us, ue, next) = read_balanced_braces(bytes, after)?;
            out.push(braced_span(ctx, K::Url, i, arg, ("url", &text[us..ue])));
            Some(next)
        }
        "textbf" | "textit" | "emph" | "underline" | "texttt" | "textsc" | "footnote"
        | "textrm" | "textsf" => {
            let arg @ (ts, te, next) = read_balanced_braces(bytes, after)?;
            out.push(braced_span(ctx, K::StyleCmd, i, arg, (cmd, "")));
            scan_range(ctx, ts, te, out);
            Some(next)
        }
        _ => None,
    }
}

/// Commands that take no argument. Returns `None` when `cmd` is not one of them.
fn scan_bare_cmd(
    ctx: &InlineScanCtx<'_>,
    bytes: &[u8],
    (i, cmd, after): (usize, &str, usize),
    out: &mut Vec<LatexInlineSpan>,
) -> Option<usize> {
    use LatexInlineSpanKind as K;
    let empty_braces = bytes.get(after..after + 2) == Some(b"{}");
    let (kind, p, layout) = match cmd {
        "centering" | "noindent" | "newpage" | "clearpage" | "tableofcontents" => {
            let p = skip_hspace(bytes, after);
            (K::HiddenMeta, p, [(i, p), (i, i), (p, p)])
        }
        "LaTeX" | "TeX" | "today" => {
            let p = after + if empty_braces { 2 } else { 0 };
            (K::LogoCmd, p, [(i, i + 1), (i + 1, after), (after, p)])
        }
        "textbackslash" => {
            let p = if empty_braces {
                after + 2
            } else {
                skip_hspace(bytes, after)
            };
            (K::TextBackslash, p, [(i + 1, p), (i, i + 1), (p, p)])
        }
        _ => return None,
    };
    let [open, content, close] = layout;
    out.push(make_span(
        ctx.u16,
        kind,
        (i, p),
        open,
        content,
        close,
        (cmd, ""),
    ));
    Some(p)
}

/// Maximum braced arguments a `\newcommand` macro can take.
const MAX_MACRO_GROUPS: usize = 9;

/// Returns the end of the `[...]` and `{...}` groups that directly follow `start`, with no
/// space between them. At most one bracket group is read, and only before the brace groups.
fn adjacent_argument_groups_end(bytes: &[u8], start: usize) -> usize {
    let mut p = start;
    if let Some((_, _, next)) = read_bracket_group(bytes, p) {
        p = next;
    }
    for _ in 0..MAX_MACRO_GROUPS {
        let Some((_, _, next)) = read_balanced_braces(bytes, p) else {
            break;
        };
        p = next;
    }
    p
}

/// Records an unknown `\cmd` or `\cmd*` as a possible user macro. `cmd` in the span includes
/// a trailing `*`. The full range also covers the `[...]` and `{...}` groups that directly
/// follow the name, which are the close range. Swift reads the arguments that the document's
/// definition takes, so this returns the offset after the name and the groups' contents are
/// still scanned for nested spans. `\cmd{}` is the exception: it consumes the empty group.
fn scan_prose_macro_candidate(
    ctx: &InlineScanCtx<'_>,
    bytes: &[u8],
    (i, _, after): (usize, &str, usize),
    out: &mut Vec<LatexInlineSpan>,
) -> usize {
    let kind = LatexInlineSpanKind::ProseMacroCandidate;
    let name_end = after + usize::from(bytes.get(after) == Some(&b'*'));
    let name = &ctx.text[(i + 1)..name_end];
    if bytes.get(name_end..name_end + 2) == Some(b"{}") {
        let full = (i, name_end + 2);
        out.push(make_span(
            ctx.u16,
            kind,
            full,
            full,
            (i + 1, name_end),
            (name_end, name_end + 2),
            (name, ""),
        ));
        return name_end + 2;
    }
    let groups_end = adjacent_argument_groups_end(bytes, name_end);
    out.push(make_span(
        ctx.u16,
        kind,
        (i, groups_end),
        (i, name_end),
        (i + 1, name_end),
        (name_end, groups_end),
        (name, ""),
    ));
    name_end
}
