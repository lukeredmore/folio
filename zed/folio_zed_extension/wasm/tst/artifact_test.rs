//! Checks that the shipped `extension.wasm` is a component that Zed can load.

use std::path::PathBuf;

fn extension_wasm() -> Vec<u8> {
    let path =
        PathBuf::from(std::env::var("EXTENSION_WASM").expect("EXTENSION_WASM is set by Bazel"));
    std::fs::read(&path).unwrap_or_else(|err| panic!("read {}: {err}", path.display()))
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
