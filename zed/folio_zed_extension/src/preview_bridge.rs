use crate::keystroke_controller::{
    evaluate_markdown_keystroke, KeystrokeDecision, KeystrokeInput,
};
use crate::markdown_formatting::cycle_code_block_language;
use crate::math_canvas::{
    build_gpui_math_canvas, GpuiMathCanvasDescriptor, GpuiMathPrimitive,
};
use crate::text_navigation::{
    extract_html_attr, percent_decode_str, surrounding_code_span_delimiters,
};
use folio_engine::mermaid::{normalize_svg_markup, render_mermaid_to_svg};

pub fn dispatch_preview_command(command: &str, args: &[String]) -> Result<String, String> {
    match command {
        "normalize_svg" => {
            let raw = args.first().map(String::as_str).unwrap_or("");
            if let Some((svg, w, h)) = normalize_svg_markup(raw) {
                Ok(format!("1\t{}\t{}\n{}", w.to_bits(), h.to_bits(), svg))
            } else {
                Ok("0".to_string())
            }
        }
        "render_mermaid_svg" => {
            let src = args.first().map(String::as_str).unwrap_or("");
            let is_dark = args.get(1).is_some_and(|s| s == "1" || s == "true");
            let rendered = render_mermaid_to_svg(src, is_dark);
            if rendered.svg.is_empty() {
                Ok("0".to_string())
            } else {
                Ok(format!(
                    "1\t{}\t{}\n{}",
                    rendered.width.to_bits(),
                    rendered.height.to_bits(),
                    rendered.svg
                ))
            }
        }
        "build_math_canvas" => {
            let latex = args.first().map(String::as_str).unwrap_or("");
            let font_size = args
                .get(1)
                .and_then(|s| s.parse::<f32>().ok())
                .unwrap_or(16.0);
            let display_mode = args.get(2).is_some_and(|s| s == "1" || s == "true");
            let desc = build_gpui_math_canvas(latex, font_size, display_mode);
            Ok(encode_math_canvas(&desc))
        }
        "evaluate_keystroke" => handle_evaluate_keystroke(args),
        "surrounding_code_span_delimiters" => {
            let src = args.first().map(String::as_str).unwrap_or("");
            let start = args.get(1).and_then(|s| s.parse::<usize>().ok()).unwrap_or(0);
            let end = args.get(2).and_then(|s| s.parse::<usize>().ok()).unwrap_or(0);
            if let Some((open, close)) = surrounding_code_span_delimiters(src, &(start..end)) {
                Ok(format!(
                    "1\t{}\t{}\t{}\t{}",
                    open.start, open.end, close.start, close.end
                ))
            } else {
                Ok("0".to_string())
            }
        }
        "cycle_code_block_language" => {
            let src = args.first().map(String::as_str).unwrap_or("");
            let start = args.get(1).and_then(|s| s.parse::<usize>().ok()).unwrap_or(0);
            let end = args.get(2).and_then(|s| s.parse::<usize>().ok()).unwrap_or(0);
            let lang = args.get(3).map(String::as_str).unwrap_or("");
            if let Some((range, repl)) = cycle_code_block_language(src, start..end, lang) {
                Ok(format!("1\t{}\t{}\n{}", range.start, range.end, repl))
            } else {
                Ok("0".to_string())
            }
        }
        "extract_html_attr" => {
            let tag = args.first().map(String::as_str).unwrap_or("");
            let attr = args.get(1).map(String::as_str).unwrap_or("");
            if let Some(val) = extract_html_attr(tag, attr) {
                Ok(format!("1\n{}", val))
            } else {
                Ok("0".to_string())
            }
        }
        "percent_decode" => {
            let input = args.first().map(String::as_str).unwrap_or("");
            Ok(percent_decode_str(input))
        }
        other => Err(format!("Unsupported Folio preview command: {other}")),
    }
}

fn handle_evaluate_keystroke(args: &[String]) -> Result<String, String> {
    let source = args.first().map(String::as_str).unwrap_or("");
    let sel_start = args.get(1).and_then(|s| s.parse::<usize>().ok()).unwrap_or(0);
    let sel_end = args.get(2).and_then(|s| s.parse::<usize>().ok()).unwrap_or(0);
    let head = args.get(3).and_then(|s| s.parse::<usize>().ok()).unwrap_or(0);
    let tail = args.get(4).and_then(|s| s.parse::<usize>().ok()).unwrap_or(0);
    let key = args.get(5).map(String::as_str).unwrap_or("");
    let flags = args.get(6).and_then(|s| s.parse::<u32>().ok()).unwrap_or(0);
    let input = KeystrokeInput {
        key,
        platform: (flags & 1) != 0,
        control: (flags & 2) != 0,
        alt: (flags & 4) != 0,
        shift: (flags & 8) != 0,
        function: (flags & 16) != 0,
    };
    let decision = evaluate_markdown_keystroke(source, sel_start..sel_end, head, tail, &input);
    Ok(encode_keystroke_decision(&decision))
}

pub fn encode_keystroke_decision(decision: &KeystrokeDecision) -> String {
    match decision {
        KeystrokeDecision::Unhandled => "0".to_string(),
        KeystrokeDecision::HandledNoOp => "1".to_string(),
        KeystrokeDecision::TogglePrettyMode => "2".to_string(),
        KeystrokeDecision::ClipboardCut(r) => format!("3\t{}\t{}", r.start, r.end),
        KeystrokeDecision::ClipboardPaste(r) => format!("4\t{}\t{}", r.start, r.end),
        KeystrokeDecision::SelectRange(r) => format!("5\t{}\t{}", r.start, r.end),
        KeystrokeDecision::SourceEdit {
            edit_range,
            replacement,
            post_selection,
        } => {
            if let Some(ps) = post_selection {
                format!(
                    "6\t{}\t{}\t1\t{}\t{}\n{}",
                    edit_range.start, edit_range.end, ps.start, ps.end, replacement
                )
            } else {
                format!(
                    "6\t{}\t{}\t0\t0\t0\n{}",
                    edit_range.start, edit_range.end, replacement
                )
            }
        }
    }
}

pub fn encode_math_canvas(desc: &GpuiMathCanvasDescriptor) -> String {
    let mut out = format!(
        "{}\t{}\t{}\t{}\n",
        desc.width.to_bits(),
        desc.ascent.to_bits(),
        desc.descent.to_bits(),
        desc.primitives.len()
    );
    for prim in &desc.primitives {
        match prim {
            GpuiMathPrimitive::ShapedGlyphRun {
                text,
                origin_x,
                baseline_y,
                font_size,
                italic,
                bold,
                serif,
            } => {
                let clean = text.replace(['\n', '\r'], " ");
                out.push_str(&format!(
                    "G\t{}\t{}\t{}\t{}\t{}\t{}\t{}\n",
                    origin_x.to_bits(),
                    baseline_y.to_bits(),
                    font_size.to_bits(),
                    u8::from(*italic),
                    u8::from(*bold),
                    u8::from(*serif),
                    clean
                ));
            }
            GpuiMathPrimitive::RuleQuad {
                x,
                y,
                width,
                height,
            } => {
                out.push_str(&format!(
                    "R\t{}\t{}\t{}\t{}\n",
                    x.to_bits(),
                    y.to_bits(),
                    width.to_bits(),
                    height.to_bits()
                ));
            }
            GpuiMathPrimitive::RadicalStroke {
                x,
                top_y,
                bottom_y,
                hook_width,
                radicand_width,
                line_width,
            } => {
                out.push_str(&format!(
                    "S\t{}\t{}\t{}\t{}\t{}\t{}\n",
                    x.to_bits(),
                    top_y.to_bits(),
                    bottom_y.to_bits(),
                    hook_width.to_bits(),
                    radicand_width.to_bits(),
                    line_width.to_bits()
                ));
            }
        }
    }
    out.push_str(&desc.plain_text_accessibility);
    out
}
