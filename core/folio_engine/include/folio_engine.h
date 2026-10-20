#ifndef FOLIO_ENGINE_H
#define FOLIO_ENGINE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ============================================================================
// 1. Document Statistics
// ============================================================================

typedef struct OTDocumentStats {
    size_t words;
    size_t lines;
    size_t characters;
    size_t characters_without_spaces;
    size_t selected_words;
    size_t selected_characters;
    size_t reading_time_seconds;
} OTDocumentStats;

OTDocumentStats ot_engine_compute_stats(
    const char* text_utf8,
    bool has_selection,
    size_t sel_utf16_loc,
    size_t sel_utf16_len
);

// ============================================================================
// 2. 2D LaTeX Math Parser & Box Layout Engine
// ============================================================================

typedef enum OTMathFontStyle {
    OT_MATH_FONT_ITALIC_VARIABLE = 0,
    OT_MATH_FONT_ROMAN_UPRIGHT = 1,
    OT_MATH_FONT_BOLD_UPRIGHT = 2,
    OT_MATH_FONT_CALLIGRAPHIC = 3,
    OT_MATH_FONT_BLACKBOARD_BOLD = 4,
    OT_MATH_FONT_MONOSPACE = 5,
    OT_MATH_FONT_OPERATOR_SYMBOL = 6,
    OT_MATH_FONT_BIG_OPERATOR = 7
} OTMathFontStyle;

typedef enum OTMathCmdKind {
    OT_MATH_CMD_TEXT = 0,
    OT_MATH_CMD_RULE = 1,
    OT_MATH_CMD_RADICAL = 2,
    OT_MATH_CMD_DELIMITER = 3
} OTMathCmdKind;

typedef struct OTMathDrawCmd {
    uint32_t kind;        // OTMathCmdKind
    uint32_t font_style;  // OTMathFontStyle
    double x;             // Relative to layout box left
    double y;             // Relative to layout box baseline (+y is downward in flipped view)
    double width;
    double height;
    double font_size;
    double thickness;
    char* text;           // UTF-8 string (glyph run for TEXT, delimiter symbol for DELIMITER)
} OTMathDrawCmd;

typedef struct OTMathLayoutResult {
    double width;
    double ascent;
    double descent;
    OTMathDrawCmd* commands;
    size_t command_count;
} OTMathLayoutResult;

OTMathLayoutResult* ot_engine_layout_latex(
    const char* latex_utf8,
    double base_font_size,
    bool is_display_style
);

void ot_engine_free_math_layout(OTMathLayoutResult* result);

char* ot_engine_plain_text_latex(const char* latex_utf8);
void ot_engine_free_string(char* str);

// ============================================================================
// 3. Smart List Newline Continuation
// ============================================================================

typedef enum OTNewlineActionKind {
    OT_NEWLINE_DEFAULT = 0,
    OT_NEWLINE_CLEAR_EMPTY_LIST_LINE = 1,
    OT_NEWLINE_INSERT_PREFIX = 2
} OTNewlineActionKind;

typedef struct OTNewlineAction {
    uint32_t kind; // OTNewlineActionKind
    char* prefix;  // Non-null when kind == OT_NEWLINE_INSERT_PREFIX
} OTNewlineAction;

OTNewlineAction ot_engine_newline_continuation(const char* line_up_to_cursor_utf8);
void ot_engine_free_newline_action(OTNewlineAction action);

// ============================================================================
// 4. Theme Palette & Language Accent Colors
// ============================================================================

typedef struct OTRgbaColor {
    double r;
    double g;
    double b;
    double a;
} OTRgbaColor;

typedef struct OTThemeMetrics {
    bool is_dark;
    double base_font_size;
    double max_write_width;
    OTRgbaColor editor_bg;
    OTRgbaColor sidebar_bg;
    OTRgbaColor text_fg;
    OTRgbaColor heading_fg;
    OTRgbaColor secondary_text_fg;
    OTRgbaColor link_fg;
    OTRgbaColor code_bg;
    OTRgbaColor inline_code_fg;
    OTRgbaColor markdown_token_fg;
    OTRgbaColor blockquote_fg;
} OTThemeMetrics;

// theme_id: 0=Daylight, 1=Midnight, 2=Parchment, 3=Editorial, 4=Classic, 5=Modernist
OTThemeMetrics ot_engine_theme_metrics(uint32_t theme_id);

OTRgbaColor ot_engine_language_accent_color(const char* language_utf8, bool is_dark);

// ============================================================================
// 5. CommonMark + GFM Spec Parser & AST / HTML Renderer (cmark-gfm)
// ============================================================================

typedef enum OTMarkdownBlockKind {
    OT_MD_BLOCK_HEADING = 1,
    OT_MD_BLOCK_CODE_BLOCK = 2,
    OT_MD_BLOCK_THEMATIC_BREAK = 3,
    OT_MD_BLOCK_BLOCK_QUOTE = 4,
    OT_MD_BLOCK_LIST_ITEM = 5,
    OT_MD_BLOCK_TABLE = 6,
    OT_MD_BLOCK_HTML_BLOCK = 7,
    OT_MD_BLOCK_PARAGRAPH = 8
} OTMarkdownBlockKind;

// Bitflags for OTMarkdownBlockSpan.flags:
// bit 0 (1): is_fenced (for CODE_BLOCK)
// bit 1 (2): is_setext (for HEADING)
// bit 2 (4): is_ordered (for LIST_ITEM)
// bit 3 (8): is_task (for LIST_ITEM)
// bit 4 (16): task_checked (for LIST_ITEM)
typedef struct OTMarkdownBlockSpan {
    uint32_t kind;          // OTMarkdownBlockKind
    uint32_t start_line;    // 1-based line number
    uint32_t start_column;  // 1-based UTF-8 column
    uint32_t end_line;      // 1-based line number
    uint32_t end_column;    // 1-based UTF-8 column
    uint32_t level;         // heading level (1..6), blockquote depth, or ordered list item number
    uint32_t flags;         // bitflags
    char* info;             // fence language, heading plain text, or table alignments ("lcrn")
} OTMarkdownBlockSpan;

typedef enum OTMarkdownInlineKind {
    OT_MD_INLINE_EMPH = 1,
    OT_MD_INLINE_STRONG = 2,
    OT_MD_INLINE_CODE = 3,
    OT_MD_INLINE_STRIKETHROUGH = 4,
    OT_MD_INLINE_LINK = 5,
    OT_MD_INLINE_IMAGE = 6,
    OT_MD_INLINE_HTML_INLINE = 7
} OTMarkdownInlineKind;

typedef struct OTMarkdownInlineSpan {
    uint32_t kind;          // OTMarkdownInlineKind
    uint32_t start_line;    // 1-based line number
    uint32_t start_column;  // 1-based UTF-8 column
    uint32_t end_line;      // 1-based line number
    uint32_t end_column;    // 1-based UTF-8 column
    char* url;              // Resolved link/image URL (including reference links)
    char* literal;          // Code/text literal or link label
} OTMarkdownInlineSpan;

typedef struct OTMarkdownAstResult {
    OTMarkdownBlockSpan* blocks;
    size_t block_count;
    OTMarkdownInlineSpan* inlines;
    size_t inline_count;
} OTMarkdownAstResult;

// Renders Markdown to HTML using the upstream cmark-gfm specification parser.
// Pass NULL for extensions_space_separated_utf8 to use default GFM extensions
// ("table strikethrough autolink tagfilter tasklist"), or "" for pure CommonMark.
// Free the returned string with ot_engine_free_string().
char* ot_engine_render_markdown_html(
    const char* markdown_utf8,
    const char* extensions_space_separated_utf8
);

// Parses Markdown into a CommonMark + GFM AST using cmark-gfm and returns all block
// and inline spans (including resolved reference links and indented code blocks).
// Free the returned result with ot_engine_free_markdown_ast().
OTMarkdownAstResult* ot_engine_parse_markdown_ast(const char* markdown_utf8);
void ot_engine_free_markdown_ast(OTMarkdownAstResult* result);

// ============================================================================
// 6. Markdown Source Reflow (paragraph hard-wrap)
// ============================================================================

typedef struct OTParagraphReflow {
    bool found;
    uint32_t start_line;   // 1-based, inclusive
    uint32_t end_line;     // 1-based, inclusive
    char* replacement;     // Non-null when found; replaces lines start_line...end_line
} OTParagraphReflow;

// Rewraps the paragraph that contains the 1-based `line` to `width` columns.
// Free the returned value with ot_engine_free_paragraph_reflow().
OTParagraphReflow ot_engine_reflow_paragraph_at_line(const char* markdown_utf8, uint32_t line, uint32_t width);
void ot_engine_free_paragraph_reflow(OTParagraphReflow result);

// Rewraps every paragraph in the document to `width` columns.
// Free the returned string with ot_engine_free_string().
char* ot_engine_reflow_markdown(const char* markdown_utf8, uint32_t width);

// ============================================================================
// 7. Mermaid Diagram & SVG Renderer
// ============================================================================

typedef struct OTMermaidRenderResult {
    char* svg;
    double width;
    double height;
} OTMermaidRenderResult;

// Renders a Mermaid diagram source string into a standalone SVG with intrinsic dimensions.
// Free the returned result with ot_engine_free_mermaid_result().
OTMermaidRenderResult* ot_engine_render_mermaid_svg(
    const char* mermaid_utf8,
    bool is_dark
);

// Validates and normalizes an inline or fenced <svg>...</svg> string and extracts its dimensions.
// Returns NULL if the input does not contain valid <svg>...</svg> markup.
// Free the returned result with ot_engine_free_mermaid_result().
OTMermaidRenderResult* ot_engine_normalize_svg(const char* svg_utf8);

void ot_engine_free_mermaid_result(OTMermaidRenderResult* result);

// ============================================================================
// 8. Shared Cursor-Aware Markdown Editing Transformations
// ============================================================================

typedef struct OTCursorEditResult {
    char* text;
    size_t cursor_byte;
} OTCursorEditResult;

OTCursorEditResult ot_engine_apply_newline_at_cursor(const char* markdown_utf8, size_t cursor_byte);
OTCursorEditResult ot_engine_toggle_symmetric_delimiter(
    const char* markdown_utf8,
    size_t cursor_byte,
    const char* delimiter_utf8
);
OTCursorEditResult ot_engine_set_heading_level_at_cursor(
    const char* markdown_utf8,
    size_t cursor_byte,
    uint8_t level
);
OTCursorEditResult ot_engine_toggle_task_checkbox_at_cursor(
    const char* markdown_utf8,
    size_t cursor_byte
);
void ot_engine_free_cursor_edit(OTCursorEditResult result);

#ifdef __cplusplus
}
#endif

#endif // FOLIO_ENGINE_H
