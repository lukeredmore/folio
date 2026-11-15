//! Checks that the shipped `extension.wasm` is a component that Zed can load.

use std::path::PathBuf;

const WASM_COMPONENT_HEADER: &[u8; 8] = b"\0asm\x0d\x00\x01\x00";
const COMPONENT_EXPORT_SECTION_ID: u8 = 11;

fn extension_wasm() -> Vec<u8> {
    let path =
        PathBuf::from(std::env::var("EXTENSION_WASM").expect("EXTENSION_WASM is set by Bazel"));
    std::fs::read(&path).unwrap_or_else(|err| panic!("read {}: {err}", path.display()))
}

fn read_uleb128(bytes: &[u8], pos: &mut usize) -> usize {
    let mut value = 0usize;
    let mut shift = 0u32;
    loop {
        let byte = bytes[*pos];
        *pos += 1;
        value |= usize::from(byte & 0x7f) << shift;
        if byte & 0x80 == 0 {
            return value;
        }
        shift += 7;
    }
}

fn component_exports(bytes: &[u8]) -> Vec<String> {
    assert!(
        bytes.starts_with(WASM_COMPONENT_HEADER),
        "expected WASI Preview 2 component header"
    );
    let mut pos = WASM_COMPONENT_HEADER.len();
    let mut exports = Vec::new();
    while pos < bytes.len() {
        let section_id = bytes[pos];
        pos += 1;
        let section_len = read_uleb128(bytes, &mut pos);
        let section = &bytes[pos..pos + section_len];
        pos += section_len;
        if section_id != COMPONENT_EXPORT_SECTION_ID {
            continue;
        }
        let mut sec_pos = 0usize;
        let count = read_uleb128(section, &mut sec_pos);
        for _ in 0..count {
            let _name_discriminant = section[sec_pos];
            sec_pos += 1;
            let name_len = read_uleb128(section, &mut sec_pos);
            let name = std::str::from_utf8(&section[sec_pos..sec_pos + name_len])
                .expect("valid UTF-8 component export name");
            sec_pos += name_len;
            exports.push(name.to_string());
            let sort = section[sec_pos];
            sec_pos += 1;
            if sort == 0 {
                sec_pos += 1;
            }
            let _sort_idx = read_uleb128(section, &mut sec_pos);
            let has_type_desc = section[sec_pos];
            sec_pos += 1;
            if has_type_desc != 0 {
                break;
            }
        }
    }
    exports
}

#[test]
fn artifact_is_a_webassembly_binary() {
    assert!(extension_wasm().starts_with(b"\0asm"));
}

#[test]
fn artifact_declares_the_zed_api_version() {
    let bytes = extension_wasm();
    let marker = b"zed:api-version";
    assert!(bytes.windows(marker.len()).any(|window| window == marker));
}

#[test]
fn artifact_exports_zed_editor_and_slash_command_symbols() {
    let bytes = extension_wasm();
    let exports = component_exports(&bytes);
    for required in [
        "init-extension",
        "run-slash-command",
        "editor-highlights-for-buffer",
        "editor-decorations-for-buffer",
    ] {
        assert!(
            exports.iter().any(|export| export == required),
            "expected component export `{required}` in {exports:?}"
        );
        let marker = required.as_bytes();
        assert!(bytes.windows(marker.len()).any(|window| window == marker));
    }
}
