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

#ifdef __cplusplus
}
#endif

#endif // FOLIO_ENGINE_H
