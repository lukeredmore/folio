#![deny(warnings)]

use folio_zed_extension::{dispatch_preview_command, FolioZedExtension};
use zed_extension_api as zed;

struct FolioWasmExtension {
    extension: FolioZedExtension,
}

impl zed::Extension for FolioWasmExtension {
    fn new() -> Self {
        Self {
            extension: FolioZedExtension::new(),
        }
    }

    fn run_slash_command(
        &self,
        command: zed::SlashCommand,
        args: Vec<String>,
        _worktree: Option<&zed::Worktree>,
    ) -> zed::Result<zed::SlashCommandOutput> {
        let text = dispatch_preview_command(&command.name, &args)?;
        Ok(zed::SlashCommandOutput {
            text,
            sections: Vec::new(),
        })
    }

    fn editor_highlights_for_buffer(
        &mut self,
        language_name: String,
        text: String,
        cursor_offset: u32,
    ) -> zed::Result<zed::EditorHighlights> {
        let highlights =
            self.extension
                .editor_highlights_for_buffer(language_name, text, cursor_offset)?;
        Ok(into_zed_highlights(highlights))
    }

    fn editor_decorations_for_buffer(
        &mut self,
        language_name: String,
        text: String,
        cursor_offset: u32,
    ) -> zed::Result<zed::EditorDecorations> {
        let decorations =
            self.extension
                .editor_decorations_for_buffer(language_name, text, cursor_offset)?;
        Ok(into_zed_decorations(decorations))
    }
}

fn into_zed_range(range: folio_zed_extension::Range) -> zed::Range {
    zed::Range {
        start: range.start,
        end: range.end,
    }
}

fn into_zed_text_highlight(highlight: folio_zed_extension::TextHighlight) -> zed::TextHighlight {
    zed::TextHighlight {
        range: into_zed_range(highlight.range),
        color: highlight.color,
        background_color: highlight.background_color,
        font_weight: highlight.font_weight,
        italic: highlight.italic,
        underline: highlight.underline,
        strikethrough: highlight.strikethrough,
        fade_out: highlight.fade_out,
    }
}

fn into_zed_row_highlight(highlight: folio_zed_extension::RowHighlight) -> zed::RowHighlight {
    zed::RowHighlight {
        start_row: highlight.start_row,
        end_row: highlight.end_row,
        color: highlight.color,
        should_autoscroll: highlight.should_autoscroll,
    }
}

fn into_zed_highlights(highlights: folio_zed_extension::EditorHighlights) -> zed::EditorHighlights {
    zed::EditorHighlights {
        text_highlights: highlights
            .text_highlights
            .into_iter()
            .map(into_zed_text_highlight)
            .collect(),
        row_highlights: highlights
            .row_highlights
            .into_iter()
            .map(into_zed_row_highlight)
            .collect(),
    }
}

fn into_zed_canvas_quad(quad: folio_zed_extension::CanvasQuad) -> zed::CanvasQuad {
    zed::CanvasQuad {
        x: quad.x,
        y: quad.y,
        width: quad.width,
        height: quad.height,
        background_color: quad.background_color,
        border_color: quad.border_color,
        border_width: quad.border_width,
        corner_radius: quad.corner_radius,
    }
}

fn into_zed_canvas_glyph_run(
    glyph_run: folio_zed_extension::CanvasGlyphRun,
) -> zed::CanvasGlyphRun {
    zed::CanvasGlyphRun {
        x: glyph_run.x,
        y: glyph_run.y,
        text: glyph_run.text,
        color: glyph_run.color,
        font_size: glyph_run.font_size,
        font_weight: glyph_run.font_weight,
        italic: glyph_run.italic,
        monospace: glyph_run.monospace,
    }
}

fn into_zed_canvas_text_replacement(
    replacement: folio_zed_extension::CanvasTextReplacement,
) -> zed::CanvasTextReplacement {
    zed::CanvasTextReplacement {
        range: into_zed_range(replacement.range),
        replacement_text: replacement.replacement_text,
    }
}

fn into_zed_canvas_element(canvas: folio_zed_extension::CanvasElement) -> zed::CanvasElement {
    zed::CanvasElement {
        width: canvas.width,
        height: canvas.height,
        quads: canvas.quads.into_iter().map(into_zed_canvas_quad).collect(),
        glyph_runs: canvas
            .glyph_runs
            .into_iter()
            .map(into_zed_canvas_glyph_run)
            .collect(),
        click_replacement: canvas
            .click_replacement
            .map(into_zed_canvas_text_replacement),
    }
}

fn into_zed_inline_fold(
    fold: folio_zed_extension::InlineFoldDecoration,
) -> zed::InlineFoldDecoration {
    zed::InlineFoldDecoration {
        range: into_zed_range(fold.range),
        placeholder_text: fold.placeholder_text,
        render_canvas: fold.render_canvas.map(into_zed_canvas_element),
    }
}

fn into_zed_block_decoration(block: folio_zed_extension::BlockDecoration) -> zed::BlockDecoration {
    zed::BlockDecoration {
        anchor_offset: block.anchor_offset,
        above: block.above,
        height_rows: block.height_rows,
        content: into_zed_canvas_element(block.content),
    }
}

fn into_zed_decorations(
    decorations: folio_zed_extension::EditorDecorations,
) -> zed::EditorDecorations {
    zed::EditorDecorations {
        inline_folds: decorations
            .inline_folds
            .into_iter()
            .map(into_zed_inline_fold)
            .collect(),
        blocks: decorations
            .blocks
            .into_iter()
            .map(into_zed_block_decoration)
            .collect(),
    }
}

zed::register_extension!(FolioWasmExtension);
