use folio_engine::theme::RgbaColor;

/// A half-open UTF-8 byte range (`[start, end)`) matching Zed's WIT `common.range` record.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Range {
    pub start: u32,
    pub end: u32,
}

impl From<std::ops::Range<u32>> for Range {
    fn from(value: std::ops::Range<u32>) -> Self {
        Self {
            start: value.start,
            end: value.end,
        }
    }
}

impl From<std::ops::Range<usize>> for Range {
    fn from(value: std::ops::Range<usize>) -> Self {
        Self {
            start: value.start as u32,
            end: value.end as u32,
        }
    }
}

/// A styled highlight for a UTF-8 byte range in an editor buffer (`editor.text-highlight`).
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct TextHighlight {
    pub range: Range,
    pub color: Option<u32>,
    pub background_color: Option<u32>,
    pub font_weight: Option<u16>,
    pub italic: bool,
    pub underline: bool,
    pub strikethrough: bool,
    pub fade_out: bool,
}

/// A background highlight for an inclusive 0-based buffer row range (`editor.row-highlight`).
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct RowHighlight {
    pub start_row: u32,
    pub end_row: u32,
    pub color: u32,
    pub should_autoscroll: bool,
}

/// Dynamic text and row highlights computed for an editor buffer (`editor.editor-highlights`).
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct EditorHighlights {
    pub text_highlights: Vec<TextHighlight>,
    pub row_highlights: Vec<RowHighlight>,
}

/// A 2D rectangle primitive for extension-rendered editor decorations (`editor.canvas-quad`).
#[derive(Debug, Clone, PartialEq, Default)]
pub struct CanvasQuad {
    pub x: f32,
    pub y: f32,
    pub width: f32,
    pub height: f32,
    pub background_color: u32,
    pub border_color: u32,
    pub border_width: f32,
    pub corner_radius: f32,
}

/// A 2D styled text run primitive for extension-rendered editor decorations (`editor.canvas-glyph-run`).
#[derive(Debug, Clone, PartialEq, Default)]
pub struct CanvasGlyphRun {
    pub x: f32,
    pub y: f32,
    pub text: String,
    pub color: u32,
    pub font_size: f32,
    pub font_weight: Option<u16>,
    pub italic: bool,
    pub monospace: bool,
}

/// An optional buffer edit triggered when a canvas decoration is clicked (`editor.canvas-text-replacement`).
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct CanvasTextReplacement {
    pub range: Range,
    pub replacement_text: String,
}

/// A declarative 2D canvas element composed of quads and glyph runs (`editor.canvas-element`).
#[derive(Debug, Clone, PartialEq, Default)]
pub struct CanvasElement {
    pub width: f32,
    pub height: f32,
    pub quads: Vec<CanvasQuad>,
    pub glyph_runs: Vec<CanvasGlyphRun>,
    pub click_replacement: Option<CanvasTextReplacement>,
}

/// An inline fold decoration that collapses a UTF-8 byte range into a placeholder or canvas (`editor.inline-fold-decoration`).
#[derive(Debug, Clone, PartialEq, Default)]
pub struct InlineFoldDecoration {
    pub range: Range,
    pub placeholder_text: String,
    pub render_canvas: Option<CanvasElement>,
}

/// A custom block decoration anchored above or below a UTF-8 byte offset (`editor.block-decoration`).
#[derive(Debug, Clone, PartialEq, Default)]
pub struct BlockDecoration {
    pub anchor_offset: u32,
    pub above: bool,
    pub height_rows: u8,
    pub content: CanvasElement,
}

/// Inline fold and block decorations computed for an editor buffer (`editor.editor-decorations`).
#[derive(Debug, Clone, PartialEq, Default)]
pub struct EditorDecorations {
    pub inline_folds: Vec<InlineFoldDecoration>,
    pub blocks: Vec<BlockDecoration>,
}

/// Packs normalized `0.0..=1.0` RGBA channels into `0xRRGGBBAA`.
pub fn pack_rgba(r: f32, g: f32, b: f32, a: f32) -> u32 {
    let rb = (r.clamp(0.0, 1.0) * 255.0).round() as u32;
    let gb = (g.clamp(0.0, 1.0) * 255.0).round() as u32;
    let bb = (b.clamp(0.0, 1.0) * 255.0).round() as u32;
    let ab = (a.clamp(0.0, 1.0) * 255.0).round() as u32;
    (rb << 24) | (gb << 16) | (bb << 8) | ab
}

/// Packs a Folio `RgbaColor` into `0xRRGGBBAA`.
pub fn pack_engine_rgba(c: RgbaColor) -> u32 {
    pack_rgba(c.r as f32, c.g as f32, c.b as f32, c.a as f32)
}

/// Converts a UTF-8 byte offset in `text` to a 0-based line/row index.
pub fn byte_offset_to_row(text: &str, byte_offset: usize) -> u32 {
    let clamped = byte_offset.min(text.len());
    text.as_bytes()[..clamped]
        .iter()
        .filter(|&&b| b == b'\n')
        .count() as u32
}
