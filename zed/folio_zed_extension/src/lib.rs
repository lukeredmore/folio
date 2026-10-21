#![deny(warnings)]

use std::fs;
use std::io;
use std::path::Path;

use folio_engine::markdown::{analyze_markdown_document, OutlineHeadingItem};

pub const EXTENSION_ID: &str = "folio-markdown-outline";
pub const EXTENSION_TOML: &str = include_str!("../extension.toml");
pub const LANGUAGE_CONFIG_TOML: &str = include_str!("../languages/markdown/config.toml");
pub const OUTLINE_SCM: &str = include_str!("../languages/markdown/outline.scm");

/// Ensures the built-in Folio Markdown extension (`folio-markdown-outline`) is materialized
/// inside Zed's `extensions/installed` directory so it is loaded out of the box without
/// requiring any network download or manual installation.
///
/// Returns `Ok(true)` if any extension file was created or updated on disk.
pub fn ensure_builtin_extension_installed(installed_extensions_dir: &Path) -> io::Result<bool> {
    let ext_root = installed_extensions_dir.join(EXTENSION_ID);
    let lang_dir = ext_root.join("languages").join("markdown");
    fs::create_dir_all(&lang_dir)?;

    let files = [
        (ext_root.join("extension.toml"), EXTENSION_TOML),
        (lang_dir.join("config.toml"), LANGUAGE_CONFIG_TOML),
        (lang_dir.join("outline.scm"), OUTLINE_SCM),
    ];

    let mut updated = false;
    for (path, expected_contents) in files {
        let matches_existing = fs::read_to_string(&path)
            .map(|existing| existing == expected_contents)
            .unwrap_or(false);
        if !matches_existing {
            fs::write(&path, expected_contents.as_bytes())?;
            updated = true;
        }
    }

    Ok(updated)
}

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
