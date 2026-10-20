use folio_engine::markdown::render_gfm_to_html;
use folio_engine::reflow::{reflow_markdown, reflow_paragraph_at_line};

fn assert_same_render(before: &str, after: &str) {
    let norm = |s: &str| {
        render_gfm_to_html(s)
            .split_whitespace()
            .collect::<Vec<_>>()
            .join(" ")
    };
    assert_eq!(
        norm(before),
        norm(after),
        "\nbefore:\n{before}\nafter:\n{after}"
    );
}

fn max_line(s: &str) -> usize {
    s.lines().map(|l| l.chars().count()).max().unwrap_or(0)
}

#[test]
fn rewraps_plain_paragraph_to_width() {
    let md = "one two three four five six seven eight nine ten eleven twelve\nthirteen";
    let out = reflow_markdown(md, 20);
    assert!(max_line(&out) <= 20, "{out}");
    assert_eq!(
        out,
        "one two three four\nfive six seven eight\nnine ten eleven\ntwelve thirteen"
    );
    assert_same_render(md, &out);
}

#[test]
fn joins_short_lines() {
    let md = "a\nb\nc\n\nnext";
    assert_eq!(reflow_markdown(md, 80), "a b c\n\nnext");
}

#[test]
fn keeps_list_item_indentation() {
    let md = "- North Bed: a raised bed with drip irrigation, and a trellis for climbing\n  beans that depends on morning sun.\n- second item";
    let out = reflow_markdown(md, 40);
    for l in out.lines().filter(|l| !l.starts_with("- ")) {
        assert!(l.starts_with("  "), "{out}");
    }
    assert!(max_line(&out) <= 40, "{out}");
    assert_same_render(md, &out);
}

#[test]
fn keeps_ordered_and_nested_blockquote_prefixes() {
    let md = "> 10. alpha beta gamma delta epsilon zeta eta theta iota kappa lambda\n> mu nu";
    let out = reflow_markdown(md, 30);
    for l in out.lines().skip(1) {
        assert!(l.starts_with(">    "), "{out}");
    }
    assert_same_render(md, &out);
}

#[test]
fn never_splits_inline_code_links_or_math() {
    let md = "Watering schedule that runs the `herb timer program` of [Garden Helper Tool](https://example.com/a_b) and $a + b = c$ and **bold w** done";
    let out = reflow_markdown(md, 12);
    assert!(out.contains("`herb timer program`"), "{out}");
    assert!(
        out.contains("[Garden Helper Tool](https://example.com/a_b)"),
        "{out}"
    );
    assert!(out.contains("$a + b = c$"), "{out}");
    assert!(out.contains("**bold w**"), "{out}");
    assert_same_render(md, &out);
}

#[test]
fn preserves_hard_breaks() {
    let md = "first line  \nsecond line\\\nthird line";
    let out = reflow_markdown(md, 80);
    assert_eq!(out, "first line  \nsecond line\\\nthird line");
    assert_same_render(md, &out);
}

#[test]
fn never_starts_line_with_block_syntax() {
    let md = "aaaa bbbb - cccc 1. dddd # eeee > ffff --- gggg";
    for w in 4..20 {
        let out = reflow_markdown(md, w);
        assert_same_render(md, &out);
    }
}

#[test]
fn leaves_code_blocks_headings_and_tables_alone() {
    let md = "# A very long heading that goes past the width\n\n```\ncode line that is very long indeed\n```\n\n| a | b |\n|---|---|\n| c | d |";
    assert_eq!(reflow_markdown(md, 10), md);
}

#[test]
fn skips_link_reference_definitions() {
    let md = "[ref]: https://example.com\ntext that follows";
    assert_same_render(md, &reflow_markdown(md, 5));
}

#[test]
fn reflow_paragraph_at_line_targets_one_paragraph() {
    let md = "a\nb\n\nc\nd";
    let r = reflow_paragraph_at_line(md, 5, 80).unwrap();
    assert_eq!(
        (r.start_line, r.end_line, r.replacement.as_str()),
        (4, 5, "c d")
    );
    assert!(reflow_paragraph_at_line(md, 3, 80).is_none());
}

#[test]
fn task_list_continuation_stays_in_item() {
    let md = "- [ ] alpha beta gamma delta epsilon zeta eta theta iota kappa\n- [x] done";
    let out = reflow_markdown(md, 25);
    assert_same_render(md, &out);
}

#[test]
fn wrapped_list_section_from_bug_report() {
    let md = "- [North Bed](beds/north.md): a raised bed with drip irrigation, and a trellis for climbing\n  beans that depends on morning sun. The trellis supports the peas in spring and the\n  `pole-beans` rotation in summer. The drip line runs from the rain barrel to every corner of the bed.\n- [Herb Spiral](beds/herb-spiral.md): the basil, thyme, and oregano plantings near the back door and the\n  watering schedule that runs the `herb-timer` program of\n  [GardenHelper](https://example.com). The schedule runs every morning with\n  the profile `GardenHelperWatering-<season>`, or `GardenHelperWatering-<custom-schedule-name>` for a\n  custom plan, without spaces in the name.";
    let out = reflow_markdown(md, 80);
    assert!(max_line(&out) <= 80, "{out}");
    assert_same_render(md, &out);
    assert_eq!(reflow_markdown(&out, 80), out, "reflow must be idempotent");
}
