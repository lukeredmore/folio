use opentype_engine::theme::{RgbaColor, ThemeId, ThemeMetrics};

/// Zed's native appearance mode (Light or Dark) that the WYSIWYG Markdown editor respects.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ZedAppearanceMode {
    Light,
    Dark,
}

impl ZedAppearanceMode {
    pub fn from_is_dark(is_dark: bool) -> Self {
        if is_dark {
            Self::Dark
        } else {
            Self::Light
        }
    }

    pub fn is_dark(self) -> bool {
        matches!(self, Self::Dark)
    }
}

/// Synchronized colors and typography metrics derived from Zed's active appearance mode.
#[derive(Debug, Clone, PartialEq)]
pub struct ZedThemeOverrides {
    pub appearance: ZedAppearanceMode,
    pub is_dark: bool,
    pub base_font_size: f32,
    pub max_write_width: f32,
    pub line_spacing: f32,
    pub editor_background: RgbaColor,
    pub text_color: RgbaColor,
    pub heading_color: RgbaColor,
    pub secondary_text_color: RgbaColor,
    pub link_color: RgbaColor,
    pub code_background: RgbaColor,
    pub inline_code_color: RgbaColor,
}

impl ZedThemeOverrides {
    pub fn for_appearance(is_dark: bool) -> Self {
        let appearance = ZedAppearanceMode::from_is_dark(is_dark);
        let m = ThemeMetrics::for_theme(if is_dark {
            ThemeId::Midnight
        } else {
            ThemeId::Daylight
        });
        Self {
            appearance,
            is_dark: m.is_dark,
            base_font_size: m.base_font_size as f32,
            max_write_width: m.max_write_width as f32,
            line_spacing: 6.0,
            editor_background: m.editor_bg,
            text_color: m.text_fg,
            heading_color: m.heading_fg,
            secondary_text_color: m.secondary_text_fg,
            link_color: m.link_fg,
            code_background: m.code_bg,
            inline_code_color: m.inline_code_fg,
        }
    }
}
