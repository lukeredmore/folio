#![deny(warnings)]

use folio_zed_extension::dispatch_preview_command;
use zed_extension_api as zed;

struct FolioWasmExtension;

impl zed::Extension for FolioWasmExtension {
    fn new() -> Self {
        Self
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
        _language_name: String,
        _text: String,
        _cursor_offset: u32,
    ) -> zed::Result<zed::EditorHighlights> {
        Ok(zed::EditorHighlights {
            text_highlights: Vec::new(),
            row_highlights: Vec::new(),
        })
    }

    fn editor_decorations_for_buffer(
        &mut self,
        _language_name: String,
        _text: String,
        _cursor_offset: u32,
    ) -> zed::Result<zed::EditorDecorations> {
        Ok(zed::EditorDecorations {
            inline_folds: Vec::new(),
            blocks: Vec::new(),
        })
    }
}

zed::register_extension!(FolioWasmExtension);
