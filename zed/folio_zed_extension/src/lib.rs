#![deny(warnings)]

use folio_engine::markdown::{analyze_markdown_document, OutlineHeadingItem};

pub const EXTENSION_TOML: &str = include_str!("../extension.toml");
pub const LANGUAGE_CONFIG_TOML: &str = include_str!("../languages/markdown/config.toml");
pub const OUTLINE_SCM: &str = include_str!("../languages/markdown/outline.scm");

/// Represents an entry in Zed's native Outline Panel (`outline_panel::OutlineItem`)
/// populated by the Folio Markdown extension.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ZedOutlineSymbol {
    pub depth: usize,
    pub context_marker: String,
    pub text: String,
    pub byte_offset: usize,
    pub row: usize,
}

impl From<OutlineHeadingItem> for ZedOutlineSymbol {
    fn from(h: OutlineHeadingItem) -> Self {
        Self {
            depth: h.level,
            context_marker: "#".repeat(h.level),
            text: h.title,
            byte_offset: h.byte_offset,
            row: h.line_number.saturating_sub(1),
        }
    }
}

/// Computes Zed Outline Panel symbols (`@context` + `@name`) for a Markdown buffer.
pub fn extract_zed_outline_symbols(markdown_text: &str) -> Vec<ZedOutlineSymbol> {
    let analysis = analyze_markdown_document(markdown_text, 0, true, false);
    analysis
        .headings
        .into_iter()
        .map(ZedOutlineSymbol::from)
        .collect()
}
