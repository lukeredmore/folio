use std::env;
use std::fs;
use std::path::PathBuf;
use std::process::Command;

fn main() {
    let manifest_dir = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap());
    let cmark_root = manifest_dir.join("../../third_party/cmark_gfm");
    let src_dir = cmark_root.join("src");
    let ext_dir = cmark_root.join("extensions");
    if !src_dir.exists() {
        return;
    }

    let out_dir = PathBuf::from(env::var("OUT_DIR").unwrap());
    let mut obj_files = Vec::new();

    for dir in [&src_dir, &ext_dir] {
        if let Ok(entries) = fs::read_dir(dir) {
            for entry in entries.flatten() {
                let path = entry.path();
                if path.extension().and_then(|s| s.to_str()) != Some("c") {
                    continue;
                }
                if path.file_name().and_then(|s| s.to_str()) == Some("main.c") {
                    continue;
                }
                println!("cargo:rerun-if-changed={}", path.display());
                let stem = path.file_stem().unwrap().to_string_lossy();
                let obj = out_dir.join(format!("cmark_{stem}.o"));
                let status = Command::new("cc")
                    .arg("-c")
                    .arg("-O2")
                    .arg("-std=c99")
                    .arg("-DCMARK_GFM_STATIC_DEFINE")
                    .arg("-DCMARK_GFM_EXTENSIONS_STATIC_DEFINE")
                    .arg("-Wno-unused-parameter")
                    .arg("-I")
                    .arg(&src_dir)
                    .arg("-I")
                    .arg(&ext_dir)
                    .arg(&path)
                    .arg("-o")
                    .arg(&obj)
                    .status()
                    .expect("failed to invoke cc for cmark_gfm");
                assert!(status.success(), "cc failed on {}", path.display());
                obj_files.push(obj);
            }
        }
    }

    let lib_path = out_dir.join("libcmark_gfm_cargo.a");
    let _ = fs::remove_file(&lib_path);
    let status = Command::new("ar")
        .arg("rcs")
        .arg(&lib_path)
        .args(&obj_files)
        .status()
        .expect("failed to invoke ar for cmark_gfm");
    assert!(status.success(), "ar failed creating libcmark_gfm_cargo.a");

    println!("cargo:rustc-link-search=native={}", out_dir.display());
    println!("cargo:rustc-link-lib=static=cmark_gfm_cargo");
}
