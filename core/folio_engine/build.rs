use std::env;
use std::fs;
use std::path::PathBuf;
use std::process::Command;

fn main() {
    let manifest_dir = PathBuf::from(env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR"));
    let cmark_root = manifest_dir.join("../../third_party/cmark_gfm");
    let src_dir = cmark_root.join("src");
    let ext_dir = cmark_root.join("extensions");
    if !src_dir.exists() {
        return;
    }

    println!("cargo:rerun-if-changed={}", src_dir.display());
    println!("cargo:rerun-if-changed={}", ext_dir.display());

    let out_dir = PathBuf::from(env::var("OUT_DIR").expect("OUT_DIR"));
    let mut obj_files = Vec::new();

    for dir in [&src_dir, &ext_dir] {
        let entries = fs::read_dir(dir).expect("Failed to read cmark_gfm directory");
        for entry in entries.flatten() {
            let path = entry.path();
            if path.extension().and_then(|s| s.to_str()) != Some("c") {
                continue;
            }
            if path.file_name().and_then(|s| s.to_str()) == Some("main.c") {
                continue;
            }
            let stem = path
                .file_stem()
                .and_then(|s| s.to_str())
                .expect("valid C file stem");
            let obj_path = out_dir.join(format!("cmark_{stem}.o"));
            let status = Command::new("cc")
                .args([
                    "-std=c99",
                    "-O2",
                    "-DCMARK_GFM_STATIC_DEFINE",
                    "-DCMARK_GFM_EXTENSIONS_STATIC_DEFINE",
                    "-Wno-unused-parameter",
                    "-I",
                ])
                .arg(&src_dir)
                .arg("-I")
                .arg(&ext_dir)
                .arg("-c")
                .arg(&path)
                .arg("-o")
                .arg(&obj_path)
                .status()
                .expect("Failed to invoke cc for cmark_gfm");
            assert!(status.success(), "cc failed compiling {}", path.display());
            obj_files.push(obj_path);
        }
    }

    let lib_path = out_dir.join("libcmark_gfm_cargo.a");
    let _ = fs::remove_file(&lib_path);
    let status = Command::new("ar")
        .arg("rcs")
        .arg(&lib_path)
        .args(&obj_files)
        .status()
        .expect("Failed to invoke ar for libcmark_gfm_cargo.a");
    assert!(status.success(), "ar failed creating libcmark_gfm_cargo.a");

    println!("cargo:rustc-link-search=native={}", out_dir.display());
    println!("cargo:rustc-link-lib=static=cmark_gfm_cargo");
}
