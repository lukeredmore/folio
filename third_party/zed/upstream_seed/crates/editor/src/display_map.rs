//! Zed `DisplayMap` and `FoldMap` (`crates/editor/src/display_map.rs`).

use std::ops::Range;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FoldCrease {
    pub byte_range: Range<usize>,
    pub placeholder: String,
    pub collapsed: bool,
}

#[derive(Default, Debug, Clone)]
pub struct DisplayMap {
    pub folds: Vec<FoldCrease>,
}

impl DisplayMap {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn clear_folds(&mut self) {
        self.folds.clear();
    }

    pub fn insert_fold(&mut self, byte_range: Range<usize>, placeholder: String, collapsed: bool) {
        self.folds.push(FoldCrease {
            byte_range,
            placeholder,
            collapsed,
        });
    }

    /// Renders visible display text after applying active fold creases.
    pub fn render_visible_text(&self, raw_buffer: &str) -> String {
        if self.folds.is_empty() {
            return raw_buffer.to_string();
        }
        let mut sorted = self.folds.clone();
        sorted.sort_by_key(|f| f.byte_range.start);

        let mut out = String::with_capacity(raw_buffer.len());
        let mut cursor = 0;
        for fold in sorted {
            if fold.byte_range.start >= cursor && fold.byte_range.end <= raw_buffer.len() {
                out.push_str(&raw_buffer[cursor..fold.byte_range.start]);
                if !fold.collapsed {
                    out.push_str(&fold.placeholder);
                }
                cursor = fold.byte_range.end;
            }
        }
        if cursor < raw_buffer.len() {
            out.push_str(&raw_buffer[cursor..]);
        }
        out
    }
}
