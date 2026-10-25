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
