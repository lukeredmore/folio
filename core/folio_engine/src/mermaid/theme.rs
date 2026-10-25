use std::{borrow::Cow, sync::OnceLock};

use merman::{
    Engine, MermaidConfig, Renderer, SvgEnvironment, SvgRequest,
    svg::{
        CssOverridePolicy, DeterministicTextMeasurer, HostTheme, HostThemePreset, LayoutOptions,
        MeasurementProfileId, Presentation, RenderError, SvgDebugOptions, SvgOutputPolicy,
        SvgPipeline, SvgPipelinePreset, SvgPostprocessContext, SvgPostprocessor, SvgRenderOptions,
        TextMeasurementPolicy, TextMeasurementProfile, TextMeasurementProfileIdentity, TextStyle,
        ThemeRole, sanitize_svg_id,
    },
};

const FONT_FAMILY: &str =
    r#"-apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", Arial, sans-serif"#;

#[derive(Debug, Clone, Copy)]
pub(super) struct FolioMermaidColors {
    pub(super) canvas: &'static str,
    pub(super) surface: &'static str,
    pub(super) surface_alt: &'static str,
    pub(super) text: &'static str,
    pub(super) subtle_text: &'static str,
    pub(super) border: &'static str,
    pub(super) line: &'static str,
    pub(super) edge_label_bg: &'static str,
}

pub(super) const fn theme_colors(is_dark: bool) -> FolioMermaidColors {
    if is_dark {
        FolioMermaidColors {
            canvas: "#161922", surface: "#232838", surface_alt: "#283352", text: "#E8ECF4",
            subtle_text: "#B8C4DC", border: "#4B6BFB", line: "#8B9BB8", edge_label_bg: "#1A1E29",
        }
    } else {
        FolioMermaidColors {
            canvas: "#FFFFFF", surface: "#F4F6FB", surface_alt: "#E6ECFA", text: "#1B2234",
            subtle_text: "#4B5672", border: "#3B5BDB", line: "#52607A", edge_label_bg: "#FFFFFF",
        }
    }
}

const DARK_ROLES: &[(ThemeRole, &str)] = &[
    (ThemeRole::Canvas, "#161922"), (ThemeRole::Surface, "#232838"),
    (ThemeRole::SurfaceAlt, "#283352"), (ThemeRole::SurfaceMuted, "#1C202B"),
    (ThemeRole::Text, "#E8ECF4"), (ThemeRole::SubtleText, "#B8C4DC"),
    (ThemeRole::Border, "#4B6BFB"), (ThemeRole::Line, "#8B9BB8"),
    (ThemeRole::EdgeLabelBackground, "#1A1E29"), (ThemeRole::ClusterBackground, "#191D28"),
    (ThemeRole::ClusterBorder, "#36405A"), (ThemeRole::NoteBackground, "#283352"),
    (ThemeRole::NoteBorder, "#4B6BFB"), (ThemeRole::NoteText, "#E8ECF4"),
    (ThemeRole::ActorBackground, "#232838"), (ThemeRole::ActorBorder, "#4B6BFB"),
    (ThemeRole::ActorText, "#E8ECF4"), (ThemeRole::ActivationBackground, "#283352"),
    (ThemeRole::ActivationBorder, "#5E81F4"), (ThemeRole::Error, "#F87171"),
    (ThemeRole::Warning, "#FBBF24"), (ThemeRole::Success, "#34D399"),
];

const DARK_PALETTE: &[&str] = &[
    "#5E81F4", "#38BDF8", "#34D399", "#FBBF24", "#F87171", "#A78BFA", "#F472B6", "#FB923C",
    "#60A5FA", "#4ADE80", "#FACC15", "#C084FC",
];

const LIGHT_ROLES: &[(ThemeRole, &str)] = &[
    (ThemeRole::Canvas, "#FFFFFF"), (ThemeRole::Surface, "#F4F6FB"),
    (ThemeRole::SurfaceAlt, "#E6ECFA"), (ThemeRole::SurfaceMuted, "#EEF2F8"),
    (ThemeRole::Text, "#1B2234"), (ThemeRole::SubtleText, "#4B5672"),
    (ThemeRole::Border, "#3B5BDB"), (ThemeRole::Line, "#52607A"),
    (ThemeRole::EdgeLabelBackground, "#FFFFFF"), (ThemeRole::ClusterBackground, "#F3F5FA"),
    (ThemeRole::ClusterBorder, "#C5D0E6"), (ThemeRole::NoteBackground, "#FFF9DB"),
    (ThemeRole::NoteBorder, "#F08C00"), (ThemeRole::NoteText, "#2B2110"),
    (ThemeRole::ActorBackground, "#F4F6FB"), (ThemeRole::ActorBorder, "#3B5BDB"),
    (ThemeRole::ActorText, "#1B2234"), (ThemeRole::ActivationBackground, "#E6ECFA"),
    (ThemeRole::ActivationBorder, "#3B5BDB"), (ThemeRole::Error, "#E03131"),
    (ThemeRole::Warning, "#F08C00"), (ThemeRole::Success, "#0CA678"),
];

const LIGHT_PALETTE: &[&str] = &[
    "#3B5BDB", "#0CA678", "#F08C00", "#7950F2", "#1098AD", "#E64980", "#D9480F", "#2B8A3E",
    "#1971C2", "#099268", "#E67700", "#862E9C",
];

pub(super) struct FolioMermaidRenderer {
    pub(super) renderer: Renderer,
    pub(super) svg_request: SvgRequest,
}

pub(super) fn folio_mermaid_renderer(is_dark: bool) -> &'static FolioMermaidRenderer {
    static LIGHT_RENDERER: OnceLock<FolioMermaidRenderer> = OnceLock::new();
    static DARK_RENDERER: OnceLock<FolioMermaidRenderer> = OnceLock::new();
    if is_dark {
        DARK_RENDERER.get_or_init(|| build_renderer(true))
    } else {
        LIGHT_RENDERER.get_or_init(|| build_renderer(false))
    }
}

pub(super) const fn fallback_text_color(is_dark: bool) -> &'static str {
    theme_colors(is_dark).text
}

fn build_renderer(is_dark: bool) -> FolioMermaidRenderer {
    let resolved = Presentation::new().with_theme(build_host_theme(is_dark)).resolve();
    let mut site_config = MermaidConfig::empty_object();
    site_config.set_value("look", "classic".into());
    site_config.set_value("flowchart.wrappingWidth", 220.into());
    site_config.set_value("sequence.messageMargin", 42.into());
    let engine = resolved.materialize_engine(Engine::new()).with_site_config(site_config);
    let diagram_id = if is_dark { "folio-mermaid-dark" } else { "folio-mermaid-light" };
    let svg_request = SvgRequest {
        environment: build_svg_environment(),
        layout: LayoutOptions::headless_svg_defaults(),
        options: SvgRenderOptions {
            diagram_id: Some(sanitize_svg_id(diagram_id)),
            ..Default::default()
        },
        debug: SvgDebugOptions::default(),
        pipeline: Some(build_svg_pipeline()),
        presentation: resolved.render_policy(),
    };
    FolioMermaidRenderer { renderer: Renderer::new().with_engine(engine), svg_request }
}

fn build_svg_environment() -> SvgEnvironment {
    let mut env = SvgEnvironment::deterministic();
    if let (Ok(id), true) = (MeasurementProfileId::new("folio.sf-pro"), true) {
        if let Ok(identity) = TextMeasurementProfileIdentity::new(id, "v1") {
            let measurer =
                DeterministicTextMeasurer::default().with_width_callback(sf_pro_text_width_px);
            let policy = TextMeasurementPolicy::uniform(TextMeasurementProfile::new(identity, measurer));
            env = env.with_text_measurement_policy(policy);
        }
    }
    env
}

fn sf_pro_text_width_px(text: &str, style: &TextStyle) -> f64 {
    if text.is_empty() {
        return 0.0;
    }
    let weight_scale = match style.font_weight.as_deref().map(str::trim) {
        Some("bold" | "600" | "700" | "800" | "900") => 1.07,
        _ => 1.0,
    };
    let em_sum: f64 = text
        .chars()
        .map(|ch| match ch {
            ' ' | '\u{00A0}' => 0.34,
            'i' | 'l' | 'j' | 't' | 'f' | 'r' | 'I' => 0.38,
            'm' | 'w' => 0.86,
            'a'..='z' => 0.56,
            'M' | 'W' => 0.92,
            'A'..='Z' => 0.70,
            '0'..='9' => 0.60,
            '.' | ',' | ':' | ';' | '!' | '|' | '\'' => 0.30,
            '(' | ')' | '[' | ']' | '{' | '}' | '/' | '-' | '_' => 0.42,
            _ => 0.66,
        })
        .sum();
    em_sum * style.font_size.max(1.0) * weight_scale + 6.0
}

fn build_host_theme(is_dark: bool) -> HostTheme {
    let (preset, roles, palette) = if is_dark {
        (HostThemePreset::EditorDark, DARK_ROLES, DARK_PALETTE)
    } else {
        (HostThemePreset::EditorLight, LIGHT_ROLES, LIGHT_PALETTE)
    };
    let mut theme = HostTheme::from_preset(preset);
    if let Ok(t) = theme.clone().try_with_font_family(FONT_FAMILY) { theme = t; }
    if let Ok(t) = theme.clone().try_with_font_size("14px") { theme = t; }
    for &(role, color) in roles {
        if let Ok(t) = theme.clone().try_with_role(role, color) { theme = t; }
    }
    if let Ok(t) = theme.clone().try_with_series_palette(palette.iter().copied()) { theme = t; }
    theme
}

struct ClassMemberAlignPostprocessor;

impl SvgPostprocessor for ClassMemberAlignPostprocessor {
    fn name(&self) -> &'static str {
        "folio-class-member-align"
    }

    fn process<'a>(
        &self,
        svg: Cow<'a, str>,
        _context: &SvgPostprocessContext<'_>,
    ) -> Result<Cow<'a, str>, RenderError> {
        let mut owned = svg.into_owned();
        for marker in [r#"<g class="members-group"#, r#"<g class="methods-group"#] {
            let mut from = 0;
            while let Some(rel) = owned[from..].find(marker) {
                let start = from + rel;
                let end = find_matching_g_end(&owned, start).unwrap_or(owned.len());
                let slice = &owned[start..end];
                if slice.contains("<foreignObject ") && !slice.contains(r#"<foreignObject text-anchor="start" "#) {
                    let replaced = slice.replace("<foreignObject ", r#"<foreignObject text-anchor="start" "#);
                    from = start + replaced.len();
                    owned.replace_range(start..end, &replaced);
                } else {
                    from = end;
                }
            }
        }
        Ok(Cow::Owned(owned))
    }
}

fn find_matching_g_end(svg: &str, start: usize) -> Option<usize> {
    let mut depth = 0usize;
    let mut i = start;
    while let Some(lt) = svg[i..].find('<') {
        let pos = i + lt;
        let rest = &svg[pos..];
        if rest.starts_with("<g ") || rest.starts_with("<g>") {
            let gt = rest.find('>')?;
            if !rest[..=gt].ends_with("/>") {
                depth += 1;
            } else if depth == 0 {
                return Some(pos + gt + 1);
            }
            i = pos + gt + 1;
        } else if rest.starts_with("</g>") {
            depth = depth.saturating_sub(1);
            i = pos + 4;
            if depth == 0 {
                return Some(i);
            }
        } else {
            i = pos + 1;
        }
    }
    None
}

fn build_svg_pipeline() -> SvgPipeline {
    SvgOutputPolicy {
        preset: SvgPipelinePreset::ResvgSafe,
        css_override_policy: CssOverridePolicy::StripExistingImportant,
        root_background_color: None,
        drop_native_duplicate_fallbacks: true,
        scoped_css: None,
    }
    .pipeline()
    .with_postprocessor(ClassMemberAlignPostprocessor)
}
