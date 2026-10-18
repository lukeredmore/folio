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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_zed_extension_manifest_and_outline_queries_are_valid() {
        assert!(EXTENSION_TOML.contains("id = \"folio-markdown-outline\""));
        assert!(LANGUAGE_CONFIG_TOML.contains("grammar = \"markdown\""));
        assert!(OUTLINE_SCM.contains("(atx_heading"));
        assert!(OUTLINE_SCM.contains("@item"));
        assert!(OUTLINE_SCM.contains("@name"));
        assert!(OUTLINE_SCM.contains("@context"));
    }

    #[test]
    fn test_extract_zed_outline_symbols() {
        let doc = "# Top Title\n\n## Section A\n\n### Subsection A.1\n";
        let symbols = extract_zed_outline_symbols(doc);
        assert_eq!(symbols.len(), 3);
        assert_eq!(symbols[0].depth, 1);
        assert_eq!(symbols[0].context_marker, "#");
        assert_eq!(symbols[0].text, "Top Title");
        assert_eq!(symbols[1].depth, 2);
        assert_eq!(symbols[1].context_marker, "##");
        assert_eq!(symbols[1].text, "Section A");
        assert_eq!(symbols[2].depth, 3);
        assert_eq!(symbols[2].text, "Subsection A.1");
    }
}
