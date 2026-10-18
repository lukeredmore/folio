//! Zed `EditorElement` GPUI layout and paint pipeline (`crates/editor/src/element.rs`).

use crate::editor::Editor;
use gpui::WindowScene;

pub struct EditorElement;

impl EditorElement {
    pub fn prepaint(editor: &mut Editor) {
        editor.display_map.clear_folds();
    }

    pub fn paint(_editor: &Editor, _scene: &mut WindowScene) {
        // Default upstream paint pass
    }
}
