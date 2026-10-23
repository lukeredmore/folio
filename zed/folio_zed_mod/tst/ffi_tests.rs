use std::ffi::{CStr, CString};

use folio_zed_mod::ffi::{
    folio_zed_mod_build_math_canvas, folio_zed_mod_free_math_canvas,
    folio_zed_mod_free_newline_result, folio_zed_mod_free_string, folio_zed_mod_free_svg_result,
    folio_zed_mod_normalize_svg, folio_zed_mod_on_editor_newline,
    folio_zed_mod_render_mermaid_svg, folio_zed_mod_set_code_fence_language,
};

#[test]
fn test_ffi_svg_and_mermaid_roundtrip() {
    let raw_svg = CString::new("<svg viewBox=\"0 0 120 60\"><rect width=\"120\" height=\"60\"/></svg>").unwrap();
    unsafe {
        let res = folio_zed_mod_normalize_svg(raw_svg.as_ptr());
        assert!(!res.is_null());
        let svg_str = CStr::from_ptr((*res).svg).to_str().unwrap();
        assert!(svg_str.contains("<svg"));
        assert_eq!((*res).width, 120.0);
        assert_eq!((*res).height, 60.0);
        folio_zed_mod_free_svg_result(res);
    }

    let mermaid_src = CString::new("flowchart TD\n    A[Start] --> B[End]").unwrap();
    unsafe {
        let res = folio_zed_mod_render_mermaid_svg(mermaid_src.as_ptr(), false);
        assert!(!res.is_null());
        let svg_str = CStr::from_ptr((*res).svg).to_str().unwrap();
        assert!(svg_str.contains("<svg"));
        assert!((*res).width > 0.0);
        assert!((*res).height > 0.0);
        folio_zed_mod_free_svg_result(res);
    }
}

#[test]
fn test_ffi_math_canvas_and_newline_and_fence_language() {
    let latex = CString::new("\\frac{a}{b} + \\sqrt{x}").unwrap();
    unsafe {
        let canvas = folio_zed_mod_build_math_canvas(latex.as_ptr(), 16.0, true);
        assert!(!canvas.is_null());
        assert!((*canvas).width > 0.0);
        assert!((*canvas).primitive_count > 0);
        let fallback = CStr::from_ptr((*canvas).plain_text_fallback).to_str().unwrap();
        assert!(!fallback.is_empty());
        folio_zed_mod_free_math_canvas(canvas);
    }

    let task_line = CString::new("- [x] Ship decoupled moddable Zed").unwrap();
    unsafe {
        let newline = folio_zed_mod_on_editor_newline(task_line.as_ptr());
        assert_eq!(newline.kind, 2);
        assert!(!newline.prefix.is_null());
        let prefix = CStr::from_ptr(newline.prefix).to_str().unwrap();
        assert_eq!(prefix, "- [ ] ");
        folio_zed_mod_free_newline_result(newline);
    }

    let empty_list = CString::new("- ").unwrap();
    unsafe {
        let newline = folio_zed_mod_on_editor_newline(empty_list.as_ptr());
        assert_eq!(newline.kind, 1);
        assert!(newline.prefix.is_null());
        folio_zed_mod_free_newline_result(newline);
    }

    let fence = CString::new("```python\nprint(1)\n```\n").unwrap();
    let lang = CString::new("rust").unwrap();
    unsafe {
        let updated_ptr = folio_zed_mod_set_code_fence_language(fence.as_ptr(), 0, lang.as_ptr());
        assert!(!updated_ptr.is_null());
        let updated = CStr::from_ptr(updated_ptr).to_str().unwrap();
        assert_eq!(updated, "```rust\nprint(1)\n```\n");
        folio_zed_mod_free_string(updated_ptr);
    }
}
