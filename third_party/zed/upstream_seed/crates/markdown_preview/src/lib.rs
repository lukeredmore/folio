//! Zed `markdown_preview` crate (`crates/markdown_preview/src/lib.rs`).

use editor::Editor;
use gpui::WindowScene;
use std::ops::Range;

pub struct MarkdownPreviewView {
    pub active_editor: Editor,
    pub selection: Range<usize>,
}

impl MarkdownPreviewView {
    pub fn new(editor: Editor) -> Self {
        Self {
            active_editor: editor,
            selection: 0..0,
        }
    }

    pub fn set_selection(&mut self, selection: Range<usize>) {
        self.selection = selection;
    }
}

pub struct MarkdownPreviewElement;

impl MarkdownPreviewElement {
    pub fn prepaint(_view: &mut MarkdownPreviewView) {}

    pub fn paint(_view: &MarkdownPreviewView, _scene: &mut WindowScene) {}
}
