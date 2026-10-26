pub mod directives;
pub mod inline_scan;
pub mod line_classify;

use biblatex::{Bibliography, ChunksExt, RawBibliography};

pub use directives::{analyze_macro_template, normalize_display_math, scan_latex_directives};
pub use inline_scan::scan_latex_inlines;
pub use line_classify::classify_latex_line;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u32)]
pub enum LatexInlineSpanKind {
    InlineMath = 1,
    Cite = 2,
    Ref = 3,
    HiddenMeta = 4,
    Href = 5,
    Url = 6,
    SizeGroup = 7,
    ColorGroup = 8,
    StyleCmd = 9,
    LogoCmd = 10,
    TextBackslash = 11,
    ProseMacroCandidate = 12,
    TexQuote = 13,
    EscapedChar = 14,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LatexInlineSpan {
    pub kind: LatexInlineSpanKind,
    pub full_loc: usize,
    pub full_len: usize,
    pub open_loc: usize,
    pub open_len: usize,
    pub inner_loc: usize,
    pub inner_len: usize,
    pub close_loc: usize,
    pub close_len: usize,
    pub cmd: String,
    pub arg: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u32)]
pub enum LatexDirectiveKind {
    DocumentClass = 1,
    UsePackage = 2,
    Section = 3,
    Label = 4,
    BibResource = 5,
    InputFile = 6,
    Frontmatter = 7,
    SetFont = 8,
    FamilyDefault = 9,
    SetStretch = 10,
    SetLength = 11,
    DefineColor = 12,
    NewIf = 13,
    ToggleIf = 14,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LatexDirectiveItem {
    pub kind: LatexDirectiveKind,
    pub starred: bool,
    pub cmd: String,
    pub opt_arg: String,
    pub arg1: String,
    pub arg2: String,
    pub arg3: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u32)]
pub enum LatexLineKind {
    None = 0,
    TableRule = 1,
    Item = 2,
    IncludeGraphics = 3,
    Caption = 4,
    MacroBlockOpen = 5,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LatexLineClassification {
    pub kind: LatexLineKind,
    pub has_opt_arg: bool,
    pub open_loc: usize,
    pub open_len: usize,
    pub opt_loc: usize,
    pub opt_len: usize,
    pub space_loc: usize,
    pub space_len: usize,
    pub body_loc: usize,
    pub body_len: usize,
    pub close_loc: usize,
    pub close_len: usize,
    pub cmd: String,
    pub opt_arg: String,
    pub arg1: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MacroTemplateAnalysis {
    pub shows_body: bool,
    pub heading_level: u32,
    pub color_name: String,
    pub prefix_label: String,
    pub vspace_args: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NormalizedDisplayMath {
    pub cleaned_latex: String,
    pub explicit_tag: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BibEntryData {
    pub key: String,
    pub entry_type: String,
    pub author: String,
    pub year: String,
    pub title: String,
    pub utf16_loc: usize,
}

pub fn parse_bibtex_entries(content: &str) -> Vec<BibEntryData> {
    let u16 = build_byte_to_utf16_table(content);
    let Ok(raw) = RawBibliography::parse(content) else {
        return Vec::new();
    };
    let resolved = Bibliography::from_raw(raw.clone()).ok();
    raw.entries
        .iter()
        .map(|raw_entry| {
            let entry_type = raw_entry.v.kind.v.to_ascii_lowercase();
            let key = raw_entry.v.key.v.trim().to_string();
            let (mut author, mut year, mut title) = (String::new(), String::new(), String::new());
            if let Some(entry) = resolved.as_ref().and_then(|b| b.get(&key)) {
                if let Some(c) = entry.fields.get("author").or_else(|| entry.fields.get("editor")) {
                    author = clean_tex_inline_text(&c.format_verbatim());
                }
                if let Some(c) = entry.fields.get("year").or_else(|| entry.fields.get("date")) {
                    year = c.format_verbatim().chars().take(4).collect();
                }
                if let Some(c) = entry.fields.get("title") {
                    title = clean_tex_inline_text(&c.format_verbatim());
                }
            }
            BibEntryData {
                key,
                entry_type,
                author,
                year,
                title,
                utf16_loc: u16[raw_entry.span.start.min(content.len())],
            }
        })
        .collect()
}

pub fn build_byte_to_utf16_table(text: &str) -> Vec<usize> {
    let mut table = vec![0usize; text.len() + 1];
    let mut u16_pos = 0usize;
    for (byte_idx, ch) in text.char_indices() {
        for b in 0..ch.len_utf8() {
            table[byte_idx + b] = u16_pos;
        }
        u16_pos += ch.len_utf16();
    }
    table[text.len()] = u16_pos;
    table
}

pub fn skip_hspace(bytes: &[u8], mut pos: usize) -> usize {
    while pos < bytes.len() && matches!(bytes[pos], b' ' | b'\t') {
        pos += 1;
    }
    pos
}

pub fn skip_ascii_ws(bytes: &[u8], mut pos: usize) -> usize {
    while pos < bytes.len() && bytes[pos].is_ascii_whitespace() {
        pos += 1;
    }
    pos
}

pub fn read_control_word(text: &str, slash: usize) -> Option<(&str, usize)> {
    let bytes = text.as_bytes();
    if slash >= bytes.len() || bytes[slash] != b'\\' {
        return None;
    }
    let mut end = slash + 1;
    while end < bytes.len() && bytes[end].is_ascii_alphabetic() {
        end += 1;
    }
    (end > slash + 1).then(|| (&text[(slash + 1)..end], end))
}

pub fn read_balanced_braces(bytes: &[u8], open: usize) -> Option<(usize, usize, usize)> {
    if open >= bytes.len() || bytes[open] != b'{' {
        return None;
    }
    let (mut depth, mut i) = (1usize, open + 1);
    while i < bytes.len() {
        if bytes[i] == b'\\' {
            i += 2;
            continue;
        }
        if bytes[i] == b'{' {
            depth += 1;
        } else if bytes[i] == b'}' {
            depth -= 1;
            if depth == 0 {
                return Some((open + 1, i, i + 1));
            }
        }
        i += 1;
    }
    None
}

pub fn read_bracket_group(bytes: &[u8], open: usize) -> Option<(usize, usize, usize)> {
    if open >= bytes.len() || bytes[open] != b'[' {
        return None;
    }
    let mut i = open + 1;
    while i < bytes.len() {
        if bytes[i] == b'\\' {
            i += 2;
            continue;
        }
        if bytes[i] == b']' {
            return Some((open + 1, i, i + 1));
        }
        i += 1;
    }
    None
}

pub fn clean_tex_inline_text(raw: &str) -> String {
    let mut s = raw.to_string();
    for w in ["\\textbf{", "\\textit{", "\\emph{", "\\texttt{", "\\textsc{", "\\underline{"] {
        while let Some(pos) = s.find(w) {
            s.replace_range(pos..(pos + w.len()), "");
            if let Some(last) = s.rfind('}') {
                s.remove(last);
            }
        }
    }
    for (pat, rep) in [
        ("\\LaTeX{}", "LaTeX"), ("\\LaTeX", "LaTeX"), ("\\TeX{}", "TeX"), ("\\TeX", "TeX"),
        ("\\&", "&"), ("\\%", "%"), ("\\_", "_"), ("\\#", "#"), ("\\$", "$"),
        ("~", " "), ("---", "—"), ("--", "–"), ("``", "“"), ("''", "”"),
    ] {
        s = s.replace(pat, rep);
    }
    s.trim().to_string()
}
