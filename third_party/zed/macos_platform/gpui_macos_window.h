#ifndef GPUI_MACOS_WINDOW_H
#define GPUI_MACOS_WINDOW_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct CGpuiRgba {
    float r;
    float g;
    float b;
    float a;
} CGpuiRgba;

typedef struct CGpuiTheme {
    bool is_dark;
    float base_font_size;
    float max_write_width;
    CGpuiRgba editor_bg;
    CGpuiRgba text_fg;
    CGpuiRgba heading_fg;
    CGpuiRgba secondary_fg;
    CGpuiRgba link_fg;
    CGpuiRgba code_bg;
    CGpuiRgba inline_code_fg;
} CGpuiTheme;

typedef struct CGpuiFoldSpan {
    size_t byte_start;
    size_t byte_end;
    bool collapse_completely;
} CGpuiFoldSpan;

// kind:
// 0 = HeadingRule, 1 = BlockquoteBar, 2 = CodeFenceHeader,
// 3 = CodeFenceRow, 4 = DisplayMathCard, 5 = HorizontalRule,
// 6 = TableRow, 7 = InlineCodePill
typedef struct CGpuiBlockDecoration {
    uint32_t kind;
    size_t byte_start;
    size_t byte_end;
    uint32_t level;
    bool is_active;
    float dim_factor;
    CGpuiRgba accent_rgba;
    const char* label_text;
} CGpuiBlockDecoration;

// kind:
// 0 = ShapedGlyphRun, 1 = RuleQuad, 2 = RadicalStroke
typedef struct CGpuiMathPrimitive {
    uint32_t kind;
    float x;
    float y;
    float width;
    float height;
    float font_size;
    float line_width;
    bool italic;
    bool bold;
    bool serif;
    const char* text;
} CGpuiMathPrimitive;

typedef struct CGpuiMathCanvas {
    size_t byte_start;
    size_t byte_end;
    bool is_display;
    float width;
    float ascent;
    float descent;
    const CGpuiMathPrimitive* primitives;
    size_t primitives_len;
} CGpuiMathCanvas;

typedef struct CGpuiRenderFrame {
    CGpuiTheme theme;
    const CGpuiFoldSpan* folds;
    size_t folds_len;
    const CGpuiBlockDecoration* blocks;
    size_t blocks_len;
    const CGpuiMathCanvas* math_canvases;
    size_t math_canvases_len;
} CGpuiRenderFrame;

typedef void (*CGpuiRenderCallback)(void* cb_ctx, const CGpuiRenderFrame* frame);

typedef void (*CGpuiEvaluateFn)(
    void* user_data,
    const char* text_utf8,
    size_t sel_byte_start,
    size_t sel_byte_end,
    bool is_dark,
    CGpuiRenderCallback render_callback,
    void* cb_ctx
);

typedef char* (*CGpuiNewlineFn)(
    void* user_data,
    const char* text_utf8,
    size_t cursor_byte_offset,
    size_t* out_new_cursor_byte
);

typedef char* (*CGpuiSetFenceLangFn)(
    void* user_data,
    const char* text_utf8,
    size_t fence_start_byte_offset,
    const char* new_lang_utf8
);

typedef void (*CGpuiFreeStringFn)(char* ptr);

void gpui_macos_run_window(
    void* user_data,
    const char* initial_text_utf8,
    CGpuiEvaluateFn evaluate_fn,
    CGpuiNewlineFn newline_fn,
    CGpuiSetFenceLangFn set_fence_lang_fn,
    CGpuiFreeStringFn free_string_fn
);

#ifdef __cplusplus
}
#endif

#endif // GPUI_MACOS_WINDOW_H
