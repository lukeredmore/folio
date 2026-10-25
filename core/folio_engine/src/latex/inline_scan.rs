use super::inline_scan_cmds::try_scan_control_word;
use super::scanner::{
    build_byte_to_utf16_table, read_balanced_braces, read_bracket_group, read_control_word,
    skip_hspace,
};
use super::types::{LatexInlineSpan, LatexInlineSpanKind};

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

pub(super) fn is_size_cmd(s: &str) -> bool {
    SIZE_CMDS.contains(&s)
}

pub(super) fn make_span(
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

pub(super) struct InlineScanCtx<'a> {
    pub text: &'a str,
    pub bytes: &'a [u8],
    pub u16: &'a [usize],
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

pub(super) fn scan_range(
    ctx: &InlineScanCtx<'_>,
    start: usize,
    end: usize,
    out: &mut Vec<LatexInlineSpan>,
) {
    let mut i = start;
    while i < end {
        let b = ctx.bytes[i];
        if b == b'$' {
            if let Some(next_i) = try_scan_dollar_math(ctx, i, end, out) {
                i = next_i;
                continue;
            }
            i += 1;
            continue;
        }
        if b == b'{' {
            if let Some(next_i) = try_scan_braced_group(ctx, i, end, out) {
                i = next_i;
                continue;
            }
            i += 1;
            continue;
        }
        if (b == b'`' || b == b'\'') && i + 1 < end && ctx.bytes[i + 1] == b {
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
        }
        if b == b'\\' {
            if let Some(next_i) = try_scan_backslash(ctx, i, end, out) {
                i = next_i;
                continue;
            }
        }
        i += 1;
    }
}

fn try_scan_dollar_math(
    ctx: &InlineScanCtx<'_>,
    i: usize,
    end: usize,
    out: &mut Vec<LatexInlineSpan>,
) -> Option<usize> {
    let bytes = ctx.bytes;
    if (i > 0 && (bytes[i - 1] == b'\\' || bytes[i - 1] == b'$'))
        || (i + 1 < end && bytes[i + 1] == b'$')
    {
        return None;
    }
    let mut j = i + 1;
    while j < end && bytes[j] != b'\n' {
        if bytes[j] == b'$'
            && bytes[j - 1] != b'\\'
            && bytes[j - 1] != b'$'
            && (j + 1 >= end || bytes[j + 1] != b'$')
        {
            if j > i + 1 {
                out.push(make_span(
                    ctx.u16,
                    LatexInlineSpanKind::InlineMath,
                    (i, j + 1),
                    (i, i + 1),
                    (i + 1, j),
                    (j, j + 1),
                    ("$", &ctx.text[(i + 1)..j]),
                ));
                return Some(j + 1);
            }
            return None;
        }
        j += 1;
    }
    None
}

fn try_scan_braced_group(
    ctx: &InlineScanCtx<'_>,
    i: usize,
    end: usize,
    out: &mut Vec<LatexInlineSpan>,
) -> Option<usize> {
    let bytes = ctx.bytes;
    if i + 1 >= end || bytes[i + 1] != b'\\' {
        return None;
    }
    let (_, close_brace, after_close) = read_balanced_braces(&bytes[..end], i)?;
    let (cmd, after_cmd) = read_control_word(ctx.text, i + 1)?;
    if is_size_cmd(cmd) {
        let mut p = skip_hspace(bytes, after_cmd);
        let mut opt_color = "";
        if let Some(("color", after_color_cmd)) = read_control_word(ctx.text, p) {
            if let Some((c_start, c_end, after_c)) =
                read_balanced_braces(&bytes[..end], after_color_cmd)
            {
                opt_color = &ctx.text[c_start..c_end];
                p = skip_hspace(bytes, after_c);
            }
        }
        if p <= close_brace {
            out.push(make_span(
                ctx.u16,
                LatexInlineSpanKind::SizeGroup,
                (i, after_close),
                (i, p),
                (p, close_brace),
                (close_brace, after_close),
                (cmd, opt_color),
            ));
            scan_range(ctx, p, close_brace, out);
            return Some(after_close);
        }
    } else if cmd == "color" {
        if let Some((c_start, c_end, after_c)) = read_balanced_braces(&bytes[..end], after_cmd) {
            let color_name = &ctx.text[c_start..c_end];
            let mut p = skip_hspace(bytes, after_c);
            if let Some((next_cmd, after_next)) = read_control_word(ctx.text, p) {
                if is_size_cmd(next_cmd) {
                    p = skip_hspace(bytes, after_next);
                }
            }
            if p <= close_brace {
                out.push(make_span(
                    ctx.u16,
                    LatexInlineSpanKind::ColorGroup,
                    (i, after_close),
                    (i, p),
                    (p, close_brace),
                    (close_brace, after_close),
                    ("color", color_name),
                ));
                scan_range(ctx, p, close_brace, out);
                return Some(after_close);
            }
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
    if i + 1 >= end {
        return None;
    }
    let next_b = bytes[i + 1];
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
        let mut p = i + 2;
        let mut arg_str = "";
        if let Some((b_start, b_end, after_b)) = read_bracket_group(&bytes[..end], p) {
            arg_str = &ctx.text[b_start..b_end];
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
    try_scan_control_word(ctx, i, cmd, after_cmd, end, out)
}
