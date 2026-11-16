use std::ops::Range;

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

        let sel_bounds = selected_utf16_range
            .and_then(|(loc, len)| (len > 0).then(|| (loc, loc.saturating_add(len))));

        let mut characters = 0usize;
        let mut characters_without_spaces = 0usize;
        let mut sel_byte_start = None;
        let mut sel_byte_end = None;

        for (byte_idx, ch) in text.char_indices() {
            if let Some((sel_loc, sel_end)) = sel_bounds {
                if characters == sel_loc {
                    sel_byte_start = Some(byte_idx);
                }
                if characters == sel_end {
                    sel_byte_end = Some(byte_idx);
                }
            }
            characters += ch.len_utf16();
            if !ch.is_whitespace() {
                characters_without_spaces += 1;
            }
        }
        if let Some((_, sel_end)) = sel_bounds {
            if characters == sel_end {
                sel_byte_end = Some(text.len());
            }
        }

        let (lines, words, reading_time_seconds) = compute_line_and_word_totals(text);
        let mut selected_words = 0usize;
        let mut selected_characters = 0usize;
        if let Some((sel_loc, sel_end)) = sel_bounds {
            if sel_end <= characters {
                selected_characters = sel_end - sel_loc;
                if let (Some(bs), Some(be)) = (sel_byte_start, sel_byte_end) {
                    selected_words = count_words_in_str(&text[bs..be]);
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

    pub fn compute_utf8(text: &str, selected_byte_range: Option<Range<usize>>) -> Self {
        if text.is_empty() {
            return Self {
                lines: 1,
                ..Default::default()
            };
        }

        let mut characters = 0usize;
        let mut characters_without_spaces = 0usize;
        for ch in text.chars() {
            characters += ch.len_utf16();
            if !ch.is_whitespace() {
                characters_without_spaces += 1;
            }
        }

        let (lines, words, reading_time_seconds) = compute_line_and_word_totals(text);
        let mut selected_words = 0usize;
        let mut selected_characters = 0usize;

        if let Some(range) = selected_byte_range {
            let start = snap_left(text, range.start);
            let end = snap_left(text, range.end).max(start);
            if start < end {
                let sel_slice = &text[start..end];
                selected_characters = sel_slice.chars().map(char::len_utf16).sum();
                selected_words = count_words_in_str(sel_slice);
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

fn snap_left(text: &str, offset: usize) -> usize {
    let mut idx = offset.min(text.len());
    while idx > 0 && !text.is_char_boundary(idx) {
        idx -= 1;
    }
    idx
}

fn compute_line_and_word_totals(text: &str) -> (usize, usize, usize) {
    let mut line_count = text.lines().count();
    if text.ends_with('\n') {
        line_count += 1;
    }
    let lines = line_count.max(1);
    let words = count_words_in_str(text);
    let reading_time_seconds = (((words as f64) / 225.0) * 60.0).max(0.0) as usize;
    (lines, words, reading_time_seconds)
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
