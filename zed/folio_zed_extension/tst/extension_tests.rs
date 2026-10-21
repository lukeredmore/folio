use std::fs;
use std::time::{SystemTime, UNIX_EPOCH};

use folio_zed_extension::{
    ensure_builtin_extension_installed, extract_zed_outline_symbols, EXTENSION_ID, EXTENSION_TOML,
    LANGUAGE_CONFIG_TOML, OUTLINE_SCM,
};

#[test]
fn test_zed_extension_manifest_and_outline_queries_are_valid() {
    assert!(EXTENSION_TOML.contains("id = \"folio-markdown-outline\""));
    assert!(LANGUAGE_CONFIG_TOML.contains("grammar = \"markdown\""));
    assert!(OUTLINE_SCM.contains("(atx_heading"));
    assert!(OUTLINE_SCM.contains("@item"));
    assert!(OUTLINE_SCM.contains("@name"));
    assert!(OUTLINE_SCM.contains("@context"));
}

#[test]
fn test_ensure_builtin_extension_installed_is_idempotent() {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let temp_dir = std::env::temp_dir().join(format!("folio_zed_ext_test_{nanos}"));
    let installed_dir = temp_dir.join("installed");

    let first_install = ensure_builtin_extension_installed(&installed_dir)
        .expect("initial built-in extension install should succeed");
    assert!(first_install);

    let ext_dir = installed_dir.join(EXTENSION_ID);
    assert_eq!(
        fs::read_to_string(ext_dir.join("extension.toml")).unwrap(),
        EXTENSION_TOML
    );
    assert_eq!(
        fs::read_to_string(ext_dir.join("languages/markdown/config.toml")).unwrap(),
        LANGUAGE_CONFIG_TOML
    );
    assert_eq!(
        fs::read_to_string(ext_dir.join("languages/markdown/outline.scm")).unwrap(),
        OUTLINE_SCM
    );

    let second_install = ensure_builtin_extension_installed(&installed_dir)
        .expect("idempotent built-in extension check should succeed");
    assert!(!second_install);

    let _ = fs::remove_dir_all(&temp_dir);
}

#[test]
fn test_extract_zed_outline_symbols() {
    let doc = "# Top Title\n\n## Section A\n\n### Subsection A.1\n";
    let symbols = extract_zed_outline_symbols(doc);
    assert_eq!(symbols.len(), 3);
    assert_eq!(symbols[0].depth, 1);
    assert_eq!(symbols[0].context_marker, "#");
    assert_eq!(symbols[0].text, "Top Title");
    assert_eq!(symbols[1].depth, 2);
    assert_eq!(symbols[1].context_marker, "##");
    assert_eq!(symbols[1].text, "Section A");
    assert_eq!(symbols[2].depth, 3);
    assert_eq!(symbols[2].text, "Subsection A.1");
}
