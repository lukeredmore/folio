"""Bazel repository rule and Bzlmod extension for importing Zed and applying the Folio GPUI Mod patch."""

_ZED_BUILD_FILE = """\
load("@rules_rust//rust:defs.bzl", "rust_binary", "rust_library", "rust_test")

package(default_visibility = ["//visibility:public"])

rust_library(
    name = "gpui",
    srcs = ["crates/gpui/src/lib.rs"],
    crate_name = "gpui",
    edition = "2021",
    deps = [
        "@//third_party/zed:gpui_macos_platform",
    ],
)

rust_library(
    name = "editor",
    srcs = [
        "crates/editor/src/display_map.rs",
        "crates/editor/src/editor.rs",
        "crates/editor/src/element.rs",
        "crates/editor/src/lib.rs",
    ],
    crate_name = "editor",
    edition = "2021",
    deps = [
        ":gpui",
    ],
)

rust_library(
    name = "markdown_preview",
    srcs = [
        "crates/markdown_preview/src/lib.rs",
    ],
    crate_name = "markdown_preview",
    edition = "2021",
    deps = [
        ":editor",
        ":gpui",
        "@//core/folio_engine",
        "@//zed/folio_zed_extension",
        "@//zed/folio_zed_mod",
    ],
)

rust_binary(
    name = "zed_with_folio_mod",
    srcs = ["crates/zed/src/main.rs"],
    edition = "2021",
    deps = [
        ":editor",
        ":gpui",
        ":markdown_preview",
        "@//core/folio_engine",
        "@//zed/folio_zed_extension",
        "@//zed/folio_zed_mod",
    ],
)
"""

def _zed_upstream_repo_impl(ctx):
    if ctx.attr.archive_url:
        ctx.download_and_extract(
            url = ctx.attr.archive_url,
            sha256 = ctx.attr.archive_sha256,
            stripPrefix = ctx.attr.strip_prefix,
        )
    else:
        for seed_label in ctx.attr.seed_files:
            seed_path = ctx.path(seed_label)
            rel_idx = str(seed_path).find("upstream_seed/")
            if rel_idx != -1:
                rel_path = str(seed_path)[rel_idx + len("upstream_seed/"):]
                ctx.file(rel_path, ctx.read(seed_path))

    for patch_label in ctx.attr.patches:
        res = ctx.execute(["patch", "-p1", "-i", str(ctx.path(patch_label))])
        if res.return_code != 0:
            fail("Failed to apply Zed patch {}: {}\n{}".format(patch_label, res.stdout, res.stderr))

    ctx.file("BUILD.bazel", _ZED_BUILD_FILE)

zed_upstream_repository = repository_rule(
    implementation = _zed_upstream_repo_impl,
    attrs = {
        "archive_url": attr.string(default = ""),
        "archive_sha256": attr.string(default = ""),
        "strip_prefix": attr.string(default = ""),
        "seed_files": attr.label_list(allow_files = True),
        "patches": attr.label_list(allow_files = True),
    },
    doc = "Imports Zed source tree into Bazel and applies the Folio GPUI live-markdown mod patches.",
)

def _zed_ext_impl(module_ctx):
    zed_upstream_repository(
        name = "zed_upstream",
        seed_files = [
            Label("//third_party/zed:upstream_seed/crates/gpui/src/lib.rs"),
            Label("//third_party/zed:upstream_seed/crates/editor/src/display_map.rs"),
            Label("//third_party/zed:upstream_seed/crates/editor/src/editor.rs"),
            Label("//third_party/zed:upstream_seed/crates/editor/src/element.rs"),
            Label("//third_party/zed:upstream_seed/crates/editor/src/lib.rs"),
            Label("//third_party/zed:upstream_seed/crates/markdown_preview/src/lib.rs"),
            Label("//third_party/zed:upstream_seed/crates/zed/src/main.rs"),
        ],
        patches = [
            Label("//third_party/zed:patches/0001-folio-live-markdown-mod.patch"),
        ],
    )

zed_ext = module_extension(
    implementation = _zed_ext_impl,
)

