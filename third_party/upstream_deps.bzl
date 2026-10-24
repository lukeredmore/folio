"""Bazel module extension for fetching upstream cmark-gfm C sources and Markdown spec test fixtures."""

CMARK_GFM_REF = "0.29.0.gfm.13"
CMARK_GFM_URL = "https://github.com/github/cmark-gfm/archive/{}.tar.gz".format(CMARK_GFM_REF)
CMARK_GFM_SHA256 = "5abc61798ebd9de5660bc076443c07abad2b8d15dbc11094a3a79644b8ad243a"

COMMONMARK_VERSION = "0.31.2"
COMMONMARK_URL = "https://spec.commonmark.org/{}/spec.json".format(COMMONMARK_VERSION)
COMMONMARK_SHA256 = "d431b29d97b6f73e69d547109cf5081578fac931e72afe95639ebe766c1b2a20"

def _cmark_gfm_repo_impl(ctx):
    script = ctx.path(Label("//tools:update_markdown_spec.py"))
    ctx.download(
        url = CMARK_GFM_URL,
        output = "cmark_gfm.tar.gz",
        sha256 = CMARK_GFM_SHA256,
    )
    res = ctx.execute([
        "python3",
        str(script),
        "--cmark-gfm-ref",
        CMARK_GFM_REF,
        "--cmark-tar",
        "cmark_gfm.tar.gz",
        "--output-cmark-dir",
        ".",
        "--output-spec-dir",
        "none",
    ])
    if res.return_code != 0:
        fail("Failed to extract cmark-gfm sources:\n{}\n{}".format(res.stdout, res.stderr))

cmark_gfm_repository = repository_rule(
    implementation = _cmark_gfm_repo_impl,
    attrs = {},
)

def _markdown_spec_repo_impl(ctx):
    script = ctx.path(Label("//tools:update_markdown_spec.py"))
    ctx.download(
        url = CMARK_GFM_URL,
        output = "cmark_gfm.tar.gz",
        sha256 = CMARK_GFM_SHA256,
    )
    ctx.download(
        url = COMMONMARK_URL,
        output = "commonmark_spec_raw.json",
        sha256 = COMMONMARK_SHA256,
    )
    res = ctx.execute([
        "python3",
        str(script),
        "--cmark-gfm-ref",
        CMARK_GFM_REF,
        "--commonmark-version",
        COMMONMARK_VERSION,
        "--cmark-tar",
        "cmark_gfm.tar.gz",
        "--commonmark-json",
        "commonmark_spec_raw.json",
        "--output-cmark-dir",
        "none",
        "--output-spec-dir",
        ".",
    ])
    if res.return_code != 0:
        fail("Failed to generate markdown_spec fixtures:\n{}\n{}".format(res.stdout, res.stderr))

markdown_spec_repository = repository_rule(
    implementation = _markdown_spec_repo_impl,
    attrs = {},
)

def _upstream_deps_impl(_module_ctx):
    cmark_gfm_repository(name = "cmark_gfm")
    markdown_spec_repository(name = "markdown_spec")

upstream_deps = module_extension(
    implementation = _upstream_deps_impl,
)
