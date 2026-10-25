use super::scanner::{
    build_byte_to_utf16_table, clean_tex_inline_text, read_balanced_braces, skip_ascii_ws,
};
use super::types::BibEntryData;

pub fn parse_bibtex_entries(content: &str) -> Vec<BibEntryData> {
    let bytes = content.as_bytes();
    let u16 = build_byte_to_utf16_table(content);
    let mut headers: Vec<(usize, String, String, usize)> = Vec::new();
    let mut i = 0;

    while i < bytes.len() {
        if bytes[i] == b'@' {
            let type_start = i + 1;
            let mut type_end = type_start;
            while type_end < bytes.len() && bytes[type_end].is_ascii_alphabetic() {
                type_end += 1;
            }
            if type_end > type_start {
                let p = skip_ascii_ws(bytes, type_end);
                if p < bytes.len() && bytes[p] == b'{' {
                    let key_start = skip_ascii_ws(bytes, p + 1);
                    let mut key_end = key_start;
                    while key_end < bytes.len()
                        && bytes[key_end] != b','
                        && !bytes[key_end].is_ascii_whitespace()
                        && bytes[key_end] != b'}'
                    {
                        key_end += 1;
                    }
                    let after_key = skip_ascii_ws(bytes, key_end);
                    if key_end > key_start && after_key < bytes.len() && bytes[after_key] == b',' {
                        let entry_type = content[type_start..type_end].to_ascii_lowercase();
                        let key = content[key_start..key_end].trim().to_string();
                        headers.push((i, entry_type, key, after_key + 1));
                        i = after_key + 1;
                        continue;
                    }
                }
            }
        }
        i += 1;
    }

    let mut out = Vec::new();
    for (idx, (at_byte, entry_type, key, body_start)) in headers.iter().enumerate() {
        if matches!(entry_type.as_str(), "comment" | "preamble" | "string") {
            continue;
        }
        let body_end = if idx + 1 < headers.len() {
            headers[idx + 1].0
        } else {
            bytes.len()
        };
        let (author, year, title) = parse_bib_fields(&content[*body_start..body_end]);
        out.push(BibEntryData {
            key: key.clone(),
            entry_type: entry_type.clone(),
            author,
            year,
            title,
            utf16_loc: u16[*at_byte],
        });
    }
    out
}

fn parse_bib_fields(block: &str) -> (String, String, String) {
    let bytes = block.as_bytes();
    let mut author = String::new();
    let mut year = String::new();
    let mut title = String::new();
    let mut i = 0;

    while i < bytes.len() {
        let line_start = skip_ascii_ws(bytes, i);
        if line_start >= bytes.len() {
            break;
        }
        let mut name_end = line_start;
        while name_end < bytes.len()
            && (bytes[name_end].is_ascii_alphabetic() || bytes[name_end] == b'_')
        {
            name_end += 1;
        }
        if name_end > line_start {
            let eq_pos = skip_ascii_ws(bytes, name_end);
            if eq_pos < bytes.len() && bytes[eq_pos] == b'=' {
                let val_pos = skip_ascii_ws(bytes, eq_pos + 1);
                if let Some((raw_val, after_val)) = read_bib_field_value(block, val_pos) {
                    let field_name = block[line_start..name_end].to_ascii_lowercase();
                    let val = clean_tex_inline_text(raw_val);
                    match field_name.as_str() {
                        "author" | "editor" => {
                            if author.is_empty() || field_name == "author" {
                                author = val;
                            }
                        }
                        "year" | "date" => {
                            if year.is_empty() {
                                year = val.chars().take(4).collect();
                            }
                        }
                        "title" => {
                            title = val;
                        }
                        _ => {}
                    }
                    i = after_val;
                    continue;
                }
            }
        }
        while i < bytes.len() && bytes[i] != b'\n' {
            i += 1;
        }
        if i < bytes.len() {
            i += 1;
        }
    }
    (author, year, title)
}

fn read_bib_field_value(block: &str, val_pos: usize) -> Option<(&str, usize)> {
    let bytes = block.as_bytes();
    if val_pos >= bytes.len() {
        return None;
    }
    if bytes[val_pos] == b'{' {
        let (s, e, after_b) = read_balanced_braces(bytes, val_pos)?;
        return Some((&block[s..e], after_b));
    }
    if bytes[val_pos] == b'"' {
        let mut j = val_pos + 1;
        while j < bytes.len() {
            if bytes[j] == b'\\' {
                j += 2;
                continue;
            }
            if bytes[j] == b'"' {
                return Some((&block[(val_pos + 1)..j], j + 1));
            }
            j += 1;
        }
        return None;
    }
    if bytes[val_pos].is_ascii_digit() {
        let mut j = val_pos;
        while j < bytes.len() && bytes[j].is_ascii_digit() {
            j += 1;
        }
        return Some((&block[val_pos..j], j));
    }
    None
}
