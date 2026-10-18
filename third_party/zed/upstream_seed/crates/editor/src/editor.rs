//! Zed `Editor` buffer and cursor state (`crates/editor/src/editor.rs`).

use crate::display_map::DisplayMap;
use std::ops::Range;

pub struct Editor {
    pub buffer_text: String,
    pub selection: Range<usize>,
    pub display_map: DisplayMap,
}

impl Editor {
    pub fn new(buffer_text: impl Into<String>) -> Self {
        Self {
            buffer_text: buffer_text.into(),
            selection: 0..0,
            display_map: DisplayMap::new(),
        }
    }

    pub fn set_selection(&mut self, selection: Range<usize>) {
        self.selection = selection;
    }

    pub fn insert_newline(&mut self) {
        let pos = self.selection.end.min(self.buffer_text.len());
        self.buffer_text.insert(pos, '\n');
        let new_pos = pos + 1;
        self.selection = new_pos..new_pos;
    }
}
