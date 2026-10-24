#![deny(warnings)]

use folio_zed_extension::dispatch_preview_command;

#[cfg(target_arch = "wasm32")]
#[unsafe(link_section = "zed:api-version")]
pub static ZED_API_VERSION: [u8; 6] = [0, 0, 0, 8, 0, 0];

#[cfg(target_os = "wasi")]
mod wasi_ext {
    unsafe extern "C" {
        static mut errno: i32;
        pub static mut __wasilibc_cwd: *mut std::ffi::c_char;
    }

    pub fn init_cwd() {
        unsafe {
            chdir(std::ptr::null());
            if let Ok(pwd) = std::env::var("PWD") {
                if let Ok(c_str) = std::ffi::CString::new(pwd) {
                    __wasilibc_cwd = c_str.into_raw().cast();
                }
            }
        }
    }

    #[unsafe(no_mangle)]
    pub unsafe extern "C" fn chdir(_raw_path: *const std::ffi::c_char) -> i32 {
        unsafe {
            errno = 58;
        }
        -1
    }
}

#[unsafe(export_name = "init-extension")]
pub extern "C" fn __init_extension() {
    #[cfg(target_os = "wasi")]
    wasi_ext::init_cwd();
}

wit_bindgen::generate!({
    skip: ["init-extension"],
    path: "./wit",
});

use zed::extension::dap::TaskTemplate;

struct FolioWasmComponent;

export!(FolioWasmComponent);

impl Guest for FolioWasmComponent {
    fn language_server_command(
        _language_server_id: String,
        _worktree: &Worktree,
    ) -> Result<Command, String> {
        Err("`language_server_command` not implemented".to_string())
    }

    fn language_server_initialization_options(
        _language_server_id: String,
        _worktree: &Worktree,
    ) -> Result<Option<String>, String> {
        Ok(None)
    }

    fn language_server_workspace_configuration(
        _language_server_id: String,
        _worktree: &Worktree,
    ) -> Result<Option<String>, String> {
        Ok(None)
    }

    fn language_server_initialization_options_schema(
        _language_server_id: String,
        _worktree: &Worktree,
    ) -> Option<String> {
        None
    }

    fn language_server_workspace_configuration_schema(
        _language_server_id: String,
        _worktree: &Worktree,
    ) -> Option<String> {
        None
    }

    fn language_server_additional_initialization_options(
        _language_server_id: String,
        _target_language_server_id: String,
        _worktree: &Worktree,
    ) -> Result<Option<String>, String> {
        Ok(None)
    }

    fn language_server_additional_workspace_configuration(
        _language_server_id: String,
        _target_language_server_id: String,
        _worktree: &Worktree,
    ) -> Result<Option<String>, String> {
        Ok(None)
    }

    fn labels_for_completions(
        _language_server_id: String,
        _completions: Vec<Completion>,
    ) -> Result<Vec<Option<CodeLabel>>, String> {
        Ok(Vec::new())
    }

    fn labels_for_symbols(
        _language_server_id: String,
        _symbols: Vec<Symbol>,
    ) -> Result<Vec<Option<CodeLabel>>, String> {
        Ok(Vec::new())
    }

    fn complete_slash_command_argument(
        _command: SlashCommand,
        _args: Vec<String>,
    ) -> Result<Vec<SlashCommandArgumentCompletion>, String> {
        Ok(Vec::new())
    }

    fn run_slash_command(
        command: SlashCommand,
        args: Vec<String>,
        _worktree: Option<&Worktree>,
    ) -> Result<SlashCommandOutput, String> {
        let text = dispatch_preview_command(&command.name, &args)?;
        Ok(SlashCommandOutput {
            text,
            sections: Vec::new(),
        })
    }

    fn context_server_command(
        _context_server_id: String,
        _project: &Project,
    ) -> Result<Command, String> {
        Err("`context_server_command` not implemented".to_string())
    }

    fn context_server_configuration(
        _context_server_id: String,
        _project: &Project,
    ) -> Result<Option<ContextServerConfiguration>, String> {
        Ok(None)
    }

    fn suggest_docs_packages(_provider: String) -> Result<Vec<String>, String> {
        Ok(Vec::new())
    }

    fn index_docs(
        _provider: String,
        _package: String,
        _database: &KeyValueStore,
    ) -> Result<(), String> {
        Ok(())
    }

    fn get_dap_binary(
        _adapter_name: String,
        _config: DebugTaskDefinition,
        _user_installed_path: Option<String>,
        _worktree: &Worktree,
    ) -> Result<DebugAdapterBinary, String> {
        Err("`get_dap_binary` not implemented".to_string())
    }

    fn dap_request_kind(
        _adapter_name: String,
        _config: String,
    ) -> Result<StartDebuggingRequestArgumentsRequest, String> {
        Err("`dap_request_kind` not implemented".to_string())
    }

    fn dap_config_to_scenario(_config: DebugConfig) -> Result<DebugScenario, String> {
        Err("`dap_config_to_scenario` not implemented".to_string())
    }

    fn dap_locator_create_scenario(
        _locator_name: String,
        _build_task: TaskTemplate,
        _resolved_label: String,
        _debug_adapter_name: String,
    ) -> Option<DebugScenario> {
        None
    }

    fn run_dap_locator(
        _locator_name: String,
        _build_task: TaskTemplate,
    ) -> Result<DebugRequest, String> {
        Err("`run_dap_locator` not implemented".to_string())
    }

    fn editor_highlights_for_buffer(
        _language_name: String,
        _text: String,
        _cursor_offset: u32,
    ) -> Result<EditorHighlights, String> {
        Ok(EditorHighlights {
            text_highlights: Vec::new(),
            row_highlights: Vec::new(),
        })
    }

    fn editor_decorations_for_buffer(
        _language_name: String,
        _text: String,
        _cursor_offset: u32,
    ) -> Result<EditorDecorations, String> {
        Ok(EditorDecorations {
            inline_folds: Vec::new(),
            blocks: Vec::new(),
        })
    }
}
