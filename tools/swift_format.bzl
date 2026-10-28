"""A test that runs `swift-format lint --strict` on `srcs`, so results cache on the sources and config."""

load("@bazel_skylib//lib:shell.bzl", "shell")

def _swift_format_test_impl(ctx):
    xcode_config = ctx.attr._xcode_config[apple_common.XcodeVersionConfig]
    files = [ctx.file.config] + ctx.files.srcs
    script = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.write(
        output = script,
        is_executable = True,
        # Runfiles are symlinks, which swift-format skips without --follow-symlinks. The Xcode version
        # is part of the script so a new swift-format reruns the test.
        content = "\n".join([
            "#!/bin/bash",
            "# Xcode {}".format(xcode_config.xcode_version()),
            "exec /usr/bin/xcrun swift-format lint --strict --parallel --follow-symlinks --configuration {config} {srcs}".format(
                config = shell.quote(ctx.file.config.short_path),
                srcs = " ".join([shell.quote(f.short_path) for f in ctx.files.srcs]),
            ),
            "",
        ]),
    )
    return [
        DefaultInfo(executable = script, runfiles = ctx.runfiles(files = files)),
        RunEnvironmentInfo(environment = apple_common.apple_host_system_env(xcode_config)),
    ]

swift_format_test = rule(
    implementation = _swift_format_test_impl,
    attrs = {
        "config": attr.label(allow_single_file = True, mandatory = True),
        "srcs": attr.label_list(allow_files = [".swift"], mandatory = True),
        "_xcode_config": attr.label(
            default = configuration_field(fragment = "apple", name = "xcode_config_label"),
        ),
    },
    fragments = ["apple"],
    test = True,
)
