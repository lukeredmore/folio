#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct DocumentStats {
    pub words: usize,
    pub lines: usize,
    pub characters: usize,
    pub characters_without_spaces: usize,
    pub selected_words: usize,
    pub selected_characters: usize,
    pub reading_time_seconds: usize,
}

impl DocumentStats {
    pub fn reading_time_string(&self) -> String {
        if self.reading_time_seconds == 0 {
            "0 sec".to_string()
        } else if self.reading_time_seconds < 60 {
            "< 1 min".to_string()
        } else {
            let minutes = ((self.words as f64) / 225.0).ceil() as usize;
            format!("{} min", minutes)
        }
    }

    pub fn compute(text: &str, selected_utf16_range: Option<(usize, usize)>) -> Self {
        if text.is_empty() {
            return Self {
                lines: 1,
                ..Default::default()
            };
        }

        let utf16_units: Vec<u16> = text.encode_utf16().collect();
        let characters = utf16_units.len();
        let characters_without_spaces = text.chars().filter(|c| !c.is_whitespace()).count();

        let mut line_count = text.lines().count();
        if text.ends_with('\n') {
            line_count += 1;
        }
        let lines = line_count.max(1);

        let words = count_words_in_str(text);
        let reading_time_seconds = (((words as f64) / 225.0) * 60.0).max(0.0) as usize;

        let mut selected_words = 0;
        let mut selected_characters = 0;

        if let Some((sel_loc, sel_len)) = selected_utf16_range {
            if sel_len > 0 && sel_loc.saturating_add(sel_len) <= characters {
                selected_characters = sel_len;
                let slice = &utf16_units[sel_loc..sel_loc + sel_len];
                if let Ok(sel_str) = String::from_utf16(slice) {
                    selected_words = count_words_in_str(&sel_str);
                }
            }
        }

        Self {
            words,
            lines,
            characters,
            characters_without_spaces,
            selected_words,
            selected_characters,
            reading_time_seconds,
        }
    }
}

fn count_words_in_str(s: &str) -> usize {
    let mut count = 0;
    let mut in_word = false;
    for ch in s.chars() {
        let is_word_char =
            ch.is_alphanumeric() || (in_word && (ch == '\'' || ch == '’' || ch == '-'));
        if is_word_char {
            if !in_word {
                in_word = true;
                count += 1;
            }
        } else {
            in_word = false;
        }
    }
    count
}
