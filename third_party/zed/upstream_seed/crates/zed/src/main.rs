use editor::{Editor, EditorElement};
use gpui::WindowScene;

fn main() {
    let mut ed = Editor::new("# Zed Editor\n");
    let mut scene = WindowScene::new();
    EditorElement::prepaint(&mut ed);
    EditorElement::paint(&ed, &mut scene);
    println!("Zed initialized: {}", ed.display_map.render_visible_text(&ed.buffer_text));
}
