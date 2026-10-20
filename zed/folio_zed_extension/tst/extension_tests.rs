use folio_zed_extension::{
    extract_zed_outline_symbols, EXTENSION_TOML, LANGUAGE_CONFIG_TOML, OUTLINE_SCM,
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
