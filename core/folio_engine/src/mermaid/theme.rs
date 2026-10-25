use std::sync::OnceLock;

use merman::{
    Engine, MermaidConfig, Renderer, SvgEnvironment, SvgRequest,
    svg::{
        CssOverridePolicy, HostTheme, HostThemePreset, LayoutOptions, Presentation, SvgDebugOptions,
        SvgOutputPolicy, SvgPipeline, SvgPipelinePreset, SvgRenderOptions, ThemeRole,
        sanitize_svg_id,
    },
};

const FONT_FAMILY: &str =
    r#"-apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", Arial, sans-serif"#;

const DARK_ROLES: &[(ThemeRole, &str)] = &[
    (ThemeRole::Canvas, "#161922"),
    (ThemeRole::Surface, "#232838"),
    (ThemeRole::SurfaceAlt, "#283352"),
    (ThemeRole::SurfaceMuted, "#1C202B"),
    (ThemeRole::Text, "#E8ECF4"),
    (ThemeRole::SubtleText, "#B8C4DC"),
    (ThemeRole::Border, "#4B6BFB"),
    (ThemeRole::Line, "#7C8AA5"),
    (ThemeRole::EdgeLabelBackground, "#1A1E29"),
    (ThemeRole::ClusterBackground, "#191D28"),
    (ThemeRole::ClusterBorder, "#36405A"),
    (ThemeRole::NoteBackground, "#283352"),
    (ThemeRole::NoteBorder, "#4B6BFB"),
    (ThemeRole::NoteText, "#E8ECF4"),
    (ThemeRole::ActorBackground, "#232838"),
    (ThemeRole::ActorBorder, "#4B6BFB"),
    (ThemeRole::ActorText, "#E8ECF4"),
    (ThemeRole::ActivationBackground, "#283352"),
    (ThemeRole::ActivationBorder, "#5E81F4"),
    (ThemeRole::Error, "#F87171"),
    (ThemeRole::Warning, "#FBBF24"),
    (ThemeRole::Success, "#34D399"),
];

const DARK_PALETTE: &[&str] = &[
    "#5E81F4", "#38BDF8", "#34D399", "#FBBF24", "#F87171", "#A78BFA", "#F472B6", "#FB923C",
    "#60A5FA", "#4ADE80", "#FACC15", "#C084FC",
];

const LIGHT_ROLES: &[(ThemeRole, &str)] = &[
    (ThemeRole::Canvas, "#FFFFFF"),
    (ThemeRole::Surface, "#F4F6FB"),
    (ThemeRole::SurfaceAlt, "#E6ECFA"),
    (ThemeRole::SurfaceMuted, "#EEF2F8"),
    (ThemeRole::Text, "#1B2234"),
    (ThemeRole::SubtleText, "#4B5672"),
    (ThemeRole::Border, "#3B5BDB"),
    (ThemeRole::Line, "#5C6B8A"),
    (ThemeRole::EdgeLabelBackground, "#FFFFFF"),
    (ThemeRole::ClusterBackground, "#F3F5FA"),
    (ThemeRole::ClusterBorder, "#C5D0E6"),
    (ThemeRole::NoteBackground, "#FFF9DB"),
    (ThemeRole::NoteBorder, "#F08C00"),
    (ThemeRole::NoteText, "#2B2110"),
    (ThemeRole::ActorBackground, "#F4F6FB"),
    (ThemeRole::ActorBorder, "#3B5BDB"),
    (ThemeRole::ActorText, "#1B2234"),
    (ThemeRole::ActivationBackground, "#E6ECFA"),
    (ThemeRole::ActivationBorder, "#3B5BDB"),
    (ThemeRole::Error, "#E03131"),
    (ThemeRole::Warning, "#F08C00"),
    (ThemeRole::Success, "#0CA678"),
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
    if is_dark {
        "#E8ECF4"
    } else {
        "#1B2234"
    }
}

fn build_renderer(is_dark: bool) -> FolioMermaidRenderer {
    let theme = build_host_theme(is_dark);
    let resolved = Presentation::new().with_theme(theme).resolve();
    let mut flowchart_config = MermaidConfig::empty_object();
    flowchart_config.set_value("flowchart.wrappingWidth", 200.into());
    let engine = resolved
        .materialize_engine(Engine::new())
        .with_site_config(flowchart_config);
    let renderer = Renderer::new().with_engine(engine);

    let diagram_id = if is_dark {
        "folio-mermaid-dark"
    } else {
        "folio-mermaid-light"
    };
    let options = SvgRenderOptions {
        diagram_id: Some(sanitize_svg_id(diagram_id)),
        ..Default::default()
    };

    let svg_request = SvgRequest {
        environment: SvgEnvironment::deterministic(),
        layout: LayoutOptions::headless_svg_defaults(),
        options,
        debug: SvgDebugOptions::default(),
        pipeline: Some(build_svg_pipeline(is_dark)),
        presentation: resolved.render_policy(),
    };

    FolioMermaidRenderer {
        renderer,
        svg_request,
    }
}

fn build_host_theme(is_dark: bool) -> HostTheme {
    let preset = if is_dark {
        HostThemePreset::EditorDark
    } else {
        HostThemePreset::EditorLight
    };
    let (roles, palette) = if is_dark {
        (DARK_ROLES, DARK_PALETTE)
    } else {
        (LIGHT_ROLES, LIGHT_PALETTE)
    };

    let mut theme = HostTheme::from_preset(preset);
    if let Ok(updated) = theme.clone().try_with_font_family(FONT_FAMILY) {
        theme = updated;
    }
    if let Ok(updated) = theme.clone().try_with_font_size("14px") {
        theme = updated;
    }
    for &(role, color) in roles {
        if let Ok(updated) = theme.clone().try_with_role(role, color) {
            theme = updated;
        }
    }
    if let Ok(updated) = theme.clone().try_with_series_palette(palette.iter().copied()) {
        theme = updated;
    }
    theme
}

fn build_svg_pipeline(is_dark: bool) -> SvgPipeline {
    let note_text = if is_dark { "#E8ECF4" } else { "#2B2110" };
    let scoped_css = format!(
        "g.node > rect.basic.label-container {{ rx: 6px; ry: 6px; }} \
         g > circle.pieOuterCircle {{ fill: none !important; }} \
         path.edge {{ fill: none !important; }} \
         g.noteText > text, g.noteText > text > tspan {{ fill: {note_text} !important; }}"
    );

    SvgOutputPolicy {
        preset: SvgPipelinePreset::ResvgSafe,
        css_override_policy: CssOverridePolicy::StripExistingImportant,
        root_background_color: None,
        drop_native_duplicate_fallbacks: true,
        scoped_css: Some(scoped_css),
    }
    .pipeline()
}
