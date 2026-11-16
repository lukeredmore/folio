use std::collections::BTreeMap;
use std::fs;
use std::path::PathBuf;

const CURSOR_MARKER: &str = "ˇ";

pub fn load_spec_json() -> String {
    let mut candidates = vec![
        PathBuf::from("tst/specs/editor_behaviors.json"),
        PathBuf::from("../../tst/specs/editor_behaviors.json"),
    ];
    if let Ok(test_srcdir) = std::env::var("TEST_SRCDIR") {
        let srcdir = PathBuf::from(&test_srcdir);
        if let Ok(entries) = fs::read_dir(&srcdir) {
            for entry in entries.flatten() {
                candidates.push(entry.path().join("tst/specs/editor_behaviors.json"));
            }
        }
    }
    for candidate in &candidates {
        if candidate.exists() {
            return fs::read_to_string(candidate).expect("Failed to read editor_behaviors.json");
        }
    }
    panic!("Could not locate tst/specs/editor_behaviors.json");
}

pub fn split_cursor(annotated: &str) -> (String, usize) {
    let pos = annotated
        .find(CURSOR_MARKER)
        .unwrap_or_else(|| panic!("Missing cursor marker {CURSOR_MARKER:?} in {annotated:?}"));
    let mut clean = String::with_capacity(annotated.len() - CURSOR_MARKER.len());
    clean.push_str(&annotated[..pos]);
    clean.push_str(&annotated[pos + CURSOR_MARKER.len()..]);
    (clean, pos)
}

pub fn join_cursor(text: &str, cursor_byte: usize) -> String {
    let mut out = String::with_capacity(text.len() + CURSOR_MARKER.len());
    out.push_str(&text[..cursor_byte]);
    out.push_str(CURSOR_MARKER);
    out.push_str(&text[cursor_byte..]);
    out
}

pub fn parse_flat_objects_in_section(
    json: &str,
    section_key: &str,
) -> Vec<BTreeMap<String, String>> {
    let array_slice = find_section_array_slice(json, section_key);
    let mut objects = Vec::new();
    let mut cur_start = None;
    let mut in_str = false;
    let mut prev_backslash = false;
    for (idx, ch) in array_slice.char_indices() {
        if in_str {
            if ch == '"' && !prev_backslash {
                in_str = false;
            }
            prev_backslash = ch == '\\' && !prev_backslash;
            continue;
        }
        match ch {
            '"' => in_str = true,
            '{' => cur_start = Some(idx + 1),
            '}' => {
                if let Some(start) = cur_start.take() {
                    objects.push(parse_kv_fields(&array_slice[start..idx]));
                }
            }
            _ => {}
        }
    }
    objects
}

fn find_section_array_slice<'a>(json: &'a str, section_key: &str) -> &'a str {
    let needle = format!("\"{section_key}\"");
    let start = json.find(&needle).expect("Missing section in spec JSON");
    let bracket_open = json[start..].find('[').expect("Missing '[' in spec JSON") + start;
    let mut depth = 0i32;
    let mut in_str = false;
    let mut prev_backslash = false;
    for (idx, ch) in json[bracket_open..].char_indices() {
        if in_str {
            if ch == '"' && !prev_backslash {
                in_str = false;
            }
            prev_backslash = ch == '\\' && !prev_backslash;
            continue;
        }
        match ch {
            '"' => in_str = true,
            '[' => depth += 1,
            ']' => {
                depth -= 1;
                if depth == 0 {
                    return &json[bracket_open + 1..bracket_open + idx];
                }
            }
            _ => {}
        }
    }
    panic!("Unclosed '[' for section {section_key}");
}

fn parse_kv_fields(obj_body: &str) -> BTreeMap<String, String> {
    let mut map = BTreeMap::new();
    for raw_line in obj_body.lines() {
        let line = raw_line.trim().trim_end_matches(',');
        if line.is_empty() {
            continue;
        }
        if let Some((key_part, val_part)) = line.split_once(':') {
            let key = key_part.trim().trim_matches('"').to_string();
            let val_trimmed = val_part.trim();
            let val = if val_trimmed.starts_with('"') && val_trimmed.ends_with('"') {
                unescape_json_str(&val_trimmed[1..val_trimmed.len() - 1])
            } else {
                val_trimmed.to_string()
            };
            map.insert(key, val);
        }
    }
    map
}

fn unescape_json_str(raw: &str) -> String {
    let mut out = String::new();
    let mut chars = raw.chars();
    while let Some(ch) = chars.next() {
        if ch == '\\' {
            match chars.next() {
                Some('n') => out.push('\n'),
                Some('r') => out.push('\r'),
                Some('t') => out.push('\t'),
                Some('"') => out.push('"'),
                Some('\\') => out.push('\\'),
                Some(other) => {
                    out.push('\\');
                    out.push(other);
                }
                None => out.push('\\'),
            }
        } else {
            out.push(ch);
        }
    }
    out
}
