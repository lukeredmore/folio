#[derive(Debug, Clone, Copy, PartialEq)]
pub struct RgbaColor {
    pub r: f64,
    pub g: f64,
    pub b: f64,
    pub a: f64,
}

impl RgbaColor {
    pub const fn new(r: f64, g: f64, b: f64, a: f64) -> Self {
        Self { r, g, b, a }
    }

    pub const fn with_alpha(self, a: f64) -> Self {
        Self {
            r: self.r,
            g: self.g,
            b: self.b,
            a,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u32)]
pub enum ThemeId {
    Daylight = 0,
    Midnight = 1,
    Parchment = 2,
    Editorial = 3,
    Classic = 4,
    Modernist = 5,
}

impl ThemeId {
    pub fn from_u32(val: u32) -> Self {
        match val {
            0 => Self::Daylight,
            1 => Self::Midnight,
            2 => Self::Parchment,
            3 => Self::Editorial,
            4 => Self::Classic,
            5 => Self::Modernist,
            _ => Self::Daylight,
        }
    }

    pub fn name(&self) -> &'static str {
        match self {
            Self::Daylight => "Daylight",
            Self::Midnight => "Midnight",
            Self::Parchment => "Parchment",
            Self::Editorial => "Editorial",
            Self::Classic => "Classic",
            Self::Modernist => "Modernist",
        }
    }

    pub fn all() -> &'static [ThemeId; 6] {
        &[
            Self::Daylight,
            Self::Midnight,
            Self::Parchment,
            Self::Editorial,
            Self::Classic,
            Self::Modernist,
        ]
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ThemeMetrics {
    pub id: ThemeId,
    pub is_dark: bool,
    pub base_font_size: f64,
    pub max_write_width: f64,
    pub editor_bg: RgbaColor,
    pub sidebar_bg: RgbaColor,
    pub text_fg: RgbaColor,
    pub heading_fg: RgbaColor,
    pub secondary_text_fg: RgbaColor,
    pub link_fg: RgbaColor,
    pub code_bg: RgbaColor,
    pub inline_code_fg: RgbaColor,
    pub markdown_token_fg: RgbaColor,
    pub blockquote_fg: RgbaColor,
}

impl ThemeMetrics {
    pub fn for_theme(theme: ThemeId) -> Self {
        let is_dark = matches!(theme, ThemeId::Midnight);

        let editor_bg = match theme {
            ThemeId::Daylight => RgbaColor::new(1.0, 1.0, 1.0, 1.0),
            ThemeId::Midnight => RgbaColor::new(0.212, 0.231, 0.251, 1.0),
            ThemeId::Parchment => RgbaColor::new(0.953, 0.949, 0.933, 1.0),
            ThemeId::Editorial => RgbaColor::new(1.0, 1.0, 1.0, 1.0),
            ThemeId::Classic => RgbaColor::new(0.996, 0.996, 0.996, 1.0),
            ThemeId::Modernist => RgbaColor::new(0.988, 0.988, 0.988, 1.0),
        };

        let sidebar_bg = match theme {
            ThemeId::Daylight => RgbaColor::new(0.980, 0.980, 0.980, 1.0),
            ThemeId::Midnight => RgbaColor::new(0.180, 0.188, 0.200, 1.0),
            ThemeId::Parchment => RgbaColor::new(0.922, 0.918, 0.898, 1.0),
            ThemeId::Editorial => RgbaColor::new(0.976, 0.976, 0.976, 1.0),
            ThemeId::Classic => RgbaColor::new(0.969, 0.969, 0.969, 1.0),
            ThemeId::Modernist => RgbaColor::new(0.953, 0.953, 0.953, 1.0),
        };

        let text_fg = match theme {
            ThemeId::Daylight => RgbaColor::new(0.20, 0.20, 0.20, 1.0),
            ThemeId::Midnight => RgbaColor::new(0.722, 0.749, 0.776, 1.0),
            ThemeId::Parchment => RgbaColor::new(0.122, 0.035, 0.035, 1.0),
            ThemeId::Editorial => RgbaColor::new(0.20, 0.20, 0.20, 1.0),
            ThemeId::Classic => RgbaColor::new(0.20, 0.20, 0.20, 1.0),
            ThemeId::Modernist => RgbaColor::new(0.067, 0.067, 0.067, 1.0),
        };

        let heading_fg = match theme {
            ThemeId::Midnight => RgbaColor::new(0.871, 0.871, 0.871, 1.0),
            ThemeId::Parchment => RgbaColor::new(0.122, 0.035, 0.035, 1.0),
            _ => RgbaColor::new(0.067, 0.067, 0.067, 1.0),
        };

        let secondary_text_fg = match theme {
            ThemeId::Midnight => RgbaColor::new(0.54, 0.57, 0.60, 1.0),
            ThemeId::Parchment => RgbaColor::new(0.267, 0.267, 0.267, 1.0),
            _ => RgbaColor::new(0.467, 0.467, 0.467, 1.0),
        };

        let link_fg = match theme {
            ThemeId::Daylight => RgbaColor::new(0.255, 0.514, 0.769, 1.0),
            ThemeId::Midnight => RgbaColor::new(0.878, 0.698, 0.494, 1.0),
            ThemeId::Parchment => RgbaColor::new(0.024, 0.333, 0.533, 1.0),
            ThemeId::Editorial => RgbaColor::new(0.0, 0.463, 0.875, 1.0),
            ThemeId::Classic => RgbaColor::new(0.165, 0.416, 0.659, 1.0),
            ThemeId::Modernist => RgbaColor::new(0.15, 0.35, 0.60, 1.0),
        };

        let code_bg = match theme {
            ThemeId::Daylight => RgbaColor::new(0.973, 0.973, 0.973, 1.0),
            ThemeId::Midnight => RgbaColor::new(0.157, 0.173, 0.192, 1.0),
            ThemeId::Parchment => RgbaColor::new(0.902, 0.898, 0.878, 1.0),
            ThemeId::Editorial => RgbaColor::new(0.965, 0.965, 0.965, 1.0),
            ThemeId::Classic => RgbaColor::new(0.975, 0.975, 0.975, 1.0),
            ThemeId::Modernist => RgbaColor::new(0.955, 0.955, 0.955, 1.0),
        };

        let inline_code_fg = match theme {
            ThemeId::Daylight => RgbaColor::new(0.83, 0.18, 0.30, 1.0),
            ThemeId::Midnight => RgbaColor::new(0.596, 0.765, 0.475, 1.0),
            ThemeId::Parchment => RgbaColor::new(0.45, 0.15, 0.15, 1.0),
            _ => RgbaColor::new(0.75, 0.22, 0.28, 1.0),
        };

        let markdown_token_fg = match theme {
            ThemeId::Midnight => RgbaColor::new(0.47, 0.53, 0.60, 1.0),
            _ => RgbaColor::new(0.58, 0.62, 0.67, 1.0),
        };

        let blockquote_fg = match theme {
            ThemeId::Daylight => RgbaColor::new(0.467, 0.467, 0.467, 1.0),
            ThemeId::Midnight => RgbaColor::new(0.60, 0.63, 0.66, 1.0),
            _ => secondary_text_fg,
        };

        let base_font_size = match theme {
            ThemeId::Daylight | ThemeId::Midnight | ThemeId::Parchment | ThemeId::Modernist => 16.0,
            ThemeId::Editorial => 17.5,
            ThemeId::Classic => 18.0,
        };

        let max_write_width = match theme {
            ThemeId::Daylight | ThemeId::Midnight => 860.0,
            ThemeId::Parchment => 760.0,
            ThemeId::Editorial => 840.0,
            ThemeId::Classic => 920.0,
            ThemeId::Modernist => 880.0,
        };

        Self {
            id: theme,
            is_dark,
            base_font_size,
            max_write_width,
            editor_bg,
            sidebar_bg,
            text_fg,
            heading_fg,
            secondary_text_fg,
            link_fg,
            code_bg,
            inline_code_fg,
            markdown_token_fg,
            blockquote_fg,
        }
    }
}

pub fn language_accent_color(raw_lang: &str, is_dark: bool) -> RgbaColor {
    match raw_lang.trim().to_ascii_lowercase().as_str() {
        "swift" => RgbaColor::new(0.94, 0.32, 0.22, 1.0),
        "python" | "py" => RgbaColor::new(0.22, 0.46, 0.67, 1.0),
        "javascript" | "js" | "jsx" => {
            if is_dark {
                RgbaColor::new(0.95, 0.82, 0.22, 1.0)
            } else {
                RgbaColor::new(0.78, 0.58, 0.04, 1.0)
            }
        }
        "typescript" | "ts" | "tsx" => RgbaColor::new(0.19, 0.47, 0.78, 1.0),
        "rust" | "rs" => RgbaColor::new(0.85, 0.45, 0.24, 1.0),
        "go" | "golang" => RgbaColor::new(0.0, 0.68, 0.85, 1.0),
        "c" | "h" | "cpp" | "c++" | "hpp" | "objc" | "objective-c" => {
            RgbaColor::new(0.58, 0.28, 0.78, 1.0)
        }
        "json" | "jsonc" | "yaml" | "yml" | "toml" => RgbaColor::new(0.20, 0.65, 0.45, 1.0),
        "bash" | "sh" | "zsh" | "shell" => RgbaColor::new(0.26, 0.68, 0.34, 1.0),
        "html" | "xml" | "svg" | "css" | "scss" => RgbaColor::new(0.86, 0.30, 0.42, 1.0),
        "sql" => RgbaColor::new(0.28, 0.52, 0.88, 1.0),
        _ => {
            if is_dark {
                RgbaColor::new(1.0, 1.0, 1.0, 0.65)
            } else {
                RgbaColor::new(0.0, 0.0, 0.0, 0.55)
            }
        }
    }
}
