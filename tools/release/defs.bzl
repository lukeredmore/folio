"""Release stamping and packaging rules for Folio.

Dev builds use fixed values. `--config=release` sets //tools/release:release, which makes these
rules read the STABLE_FOLIO_* keys that tools/release/workspace_status.sh writes.
"""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")

_RELEASE_FLAG = "//tools/release:release"
_SIGNING_IDENTITY_FLAG = "@build_bazel_rules_apple//apple/build_settings:signing_certificate_name"

# Reads one key from the stable status file. Defined in each action script that needs it.
_STAMP_FUNCTION = """
stamp() { /usr/bin/awk -v key="$1" '$1 == key { print $2; exit }' "$status_file"; }
"""

def _is_release(ctx):
    return ctx.attr._release[BuildSettingInfo].value

def _folio_info_plist_impl(ctx):
    out = ctx.actions.declare_file(ctx.label.name + ".plist")
    release = _is_release(ctx)
    inputs = [ctx.file.cargo_toml]
    args = ctx.actions.args()
    args.add_all([out, ctx.file.cargo_toml, ctx.attr.short_version])
    if release:
        inputs.append(ctx.info_file)
        args.add(ctx.info_file)
    ctx.actions.run_shell(
        inputs = inputs,
        outputs = [out],
        arguments = [args],
        mnemonic = "FolioInfoPlist",
        progress_message = "Stamping Info.plist values for %{label}",
        command = """
set -euo pipefail
out="$1"
cargo_toml="$2"
short_version="$3"
status_file="${4:-}"
""" + _STAMP_FUNCTION + """
engine_version="$(/usr/bin/awk -F'"' '/^version[[:space:]]*=/ { print $2; exit }' "$cargo_toml")"
if [[ -z "$engine_version" ]]; then
  echo "error: no version in $cargo_toml" >&2
  exit 1
fi
build_number=1
commit_sha=dev
channel=dev
icon=AppIcon-Dev
if [[ -n "$status_file" ]]; then
  build_number="$(stamp STABLE_FOLIO_BUILD_NUMBER)"
  commit_sha="$(stamp STABLE_FOLIO_COMMIT_SHA)"
  stamped_version="$(stamp STABLE_FOLIO_VERSION)"
  short_version="${stamped_version:-$short_version}"
  channel=release
  icon=AppIcon
  if [[ ! "$build_number" =~ ^[0-9]+$ || -z "$commit_sha" ]]; then
    echo "error: release builds need tools/release/workspace_status.sh; use --config=release" >&2
    exit 1
  fi
fi
/usr/bin/plutil -create xml1 "$out"
/usr/bin/plutil -insert CFBundleIconFile -string "$icon" "$out"
/usr/bin/plutil -insert CFBundleShortVersionString -string "$short_version" "$out"
/usr/bin/plutil -insert CFBundleVersion -string "$build_number" "$out"
/usr/bin/plutil -insert FolioBuildChannel -string "$channel" "$out"
/usr/bin/plutil -insert FolioCommitSHA -string "$commit_sha" "$out"
/usr/bin/plutil -insert FolioEngineVersion -string "$engine_version" "$out"
""",
    )
    return [DefaultInfo(files = depset([out]))]

folio_info_plist = rule(
    implementation = _folio_info_plist_impl,
    doc = "Writes the Info.plist keys that differ between dev and release builds of Folio.app.",
    attrs = {
        "cargo_toml": attr.label(
            allow_single_file = True,
            mandatory = True,
            doc = "Cargo.toml whose package version becomes FolioEngineVersion.",
        ),
        "short_version": attr.string(
            mandatory = True,
            doc = "CFBundleShortVersionString. FOLIO_VERSION overrides it in release builds.",
        ),
        "_release": attr.label(default = _RELEASE_FLAG),
    },
)

def _zed_extension_manifest_impl(ctx):
    out = ctx.actions.declare_file(ctx.label.name + "/extension.toml")
    release = _is_release(ctx)
    inputs = [ctx.file.src]
    args = ctx.actions.args()
    args.add_all([out, ctx.file.src])
    if release:
        inputs.append(ctx.info_file)
        args.add(ctx.info_file)
    ctx.actions.run_shell(
        inputs = inputs,
        outputs = [out],
        arguments = [args],
        mnemonic = "ZedExtensionManifest",
        progress_message = "Stamping extension.toml for %{label}",
        command = """
set -euo pipefail
out="$1"
src="$2"
status_file="${3:-}"
""" + _STAMP_FUNCTION + """
if [[ -z "$status_file" ]]; then
  /bin/cp "$src" "$out"
  exit 0
fi
build_number="$(stamp STABLE_FOLIO_BUILD_NUMBER)"
if [[ ! "$build_number" =~ ^[0-9]+$ ]]; then
  echo "error: release builds need tools/release/workspace_status.sh; use --config=release" >&2
  exit 1
fi
/usr/bin/awk -v build="$build_number" '
  !done && /^version[[:space:]]*=/ {
    match($0, /"[^"]+"/)
    n = split(substr($0, RSTART + 1, RLENGTH - 2), part, ".")
    if (n != 3) { print "error: extension.toml version must be X.Y.Z" > "/dev/stderr"; exit 1 }
    print "version = \\"" part[1] "." part[2] "." build "\\""
    done = 1
    next
  }
  { print }
  END { if (!done) { print "error: extension.toml has no version" > "/dev/stderr"; exit 1 } }
' "$src" > "$out"
""",
    )
    return [DefaultInfo(files = depset([out]))]

zed_extension_manifest = rule(
    implementation = _zed_extension_manifest_impl,
    doc = "Copies extension.toml. Release builds set the patch version to the build number.",
    attrs = {
        "src": attr.label(allow_single_file = [".toml"], mandatory = True),
        "_release": attr.label(default = _RELEASE_FLAG),
    },
)

def _folio_dmg_impl(ctx):
    apps = [f for f in ctx.attr.app[DefaultInfo].files.to_list() if f.basename.endswith(".app")]
    if len(apps) != 1:
        fail("expected one .app bundle in %s, found %s" % (ctx.attr.app.label, apps))
    out = ctx.actions.declare_file(ctx.attr.out)
    identity = ctx.attr._signing_identity[BuildSettingInfo].value
    ctx.actions.run_shell(
        inputs = apps,
        outputs = [out],
        arguments = [apps[0].path, out.path, ctx.attr.volume_name, identity],
        mnemonic = "FolioDmg",
        progress_message = "Creating %{output}",
        # hdiutil and codesign need the host disk image and keychain services.
        execution_requirements = {
            "local": "1",
            "no-remote": "1",
            "no-sandbox": "1",
            "requires-darwin": "",
        },
        command = """
set -euo pipefail
app="$1"
out="$2"
volume_name="$3"
identity="$4"
stage="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/folio-dmg.XXXXXX")"
trap '/bin/rm -rf "$stage"' EXIT
/bin/cp -R "$app" "$stage/"
/bin/chmod -R u+w "$stage"
/bin/ln -s /Applications "$stage/Applications"
/usr/bin/hdiutil create -quiet -volname "$volume_name" -srcfolder "$stage" -ov -format UDZO "$out"
if [[ -n "$identity" && "$identity" != "-" ]]; then
  /usr/bin/codesign --force --timestamp --sign "$identity" "$out"
fi
""",
    )
    return [DefaultInfo(files = depset([out]))]

folio_dmg = rule(
    implementation = _folio_dmg_impl,
    doc = """Packages a .app bundle into a compressed DMG with an /Applications link.

The DMG is signed with the rules_apple signing identity when one is set. hdiutil is not hermetic,
so the action runs locally without the sandbox.
""",
    attrs = {
        "app": attr.label(mandatory = True, doc = "A macos_application target."),
        "out": attr.string(mandatory = True, doc = "The DMG file name."),
        "volume_name": attr.string(mandatory = True),
        "_signing_identity": attr.label(default = _SIGNING_IDENTITY_FLAG),
    },
)

def _opt_transition_impl(_settings, _attr):
    return {"//command_line_option:compilation_mode": "opt"}

_opt_transition = transition(
    implementation = _opt_transition_impl,
    inputs = [],
    outputs = ["//command_line_option:compilation_mode"],
)

def _opt_files_impl(ctx):
    files = depset(transitive = [src[DefaultInfo].files for src in ctx.attr.srcs])
    return [DefaultInfo(files = files, runfiles = ctx.runfiles(transitive_files = files))]

opt_files = rule(
    implementation = _opt_files_impl,
    doc = "Builds srcs with -c opt, whatever the command-line compilation mode.",
    attrs = {
        "srcs": attr.label_list(cfg = _opt_transition, mandatory = True),
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
    },
)

_SourceFilesInfo = provider(
    doc = "Main-repository source files that a target depends on.",
    fields = {"files": "depset of File"},
)

def _attr_targets(value):
    if type(value) == "list":
        return value
    if type(value) == "dict":
        return list(value.keys()) + list(value.values())
    return [value]

def _source_files_aspect_impl(_target, ctx):
    direct = []
    transitive = []
    for name in dir(ctx.rule.attr):
        # Implicit attributes hold toolchains and tools, not product inputs.
        if name.startswith("_"):
            continue
        for dep in _attr_targets(getattr(ctx.rule.attr, name)):
            if type(dep) != "Target":
                continue
            if _SourceFilesInfo in dep:
                transitive.append(dep[_SourceFilesInfo].files)
            elif dep.label.workspace_name == "":
                # Aspects do not run on source file labels, so collect their files here.
                direct.extend([f for f in dep[DefaultInfo].files.to_list() if f.is_source])
    return [_SourceFilesInfo(files = depset(direct, transitive = transitive))]

_source_files_aspect = aspect(
    implementation = _source_files_aspect_impl,
    attr_aspects = ["*"],
    doc = "Collects main-repository source files from non-implicit attributes.",
)

def _input_hash_impl(ctx):
    files = depset(
        ctx.files.extra_srcs,
        transitive = [ctx.attr.target[_SourceFilesInfo].files],
    ).to_list()
    files = sorted({f.path: f for f in files}.values(), key = lambda f: f.path)
    file_list = ctx.actions.declare_file(ctx.label.name + ".files")
    ctx.actions.write(file_list, "".join([f.path + "\n" for f in files]))
    out = ctx.actions.declare_file(ctx.label.name + ".sha256")
    ctx.actions.run_shell(
        inputs = files + [file_list],
        outputs = [out],
        arguments = [file_list.path, out.path],
        mnemonic = "InputHash",
        progress_message = "Hashing source inputs of %{label}",
        command = """
set -euo pipefail
/usr/bin/tr '\\n' '\\0' < "$1" | /usr/bin/xargs -0 /usr/bin/shasum -a 256 | /usr/bin/shasum -a 256 | /usr/bin/cut -d ' ' -f 1 > "$2"
""",
    )
    return [DefaultInfo(files = depset([out]))]

input_hash = rule(
    implementation = _input_hash_impl,
    doc = """Writes a SHA-256 of every main-repository source file that `target` depends on.

CI compares it with the hash in the latest release and reuses that release's DMG when they match.
Then a change that does not touch the app does not publish a new app build number.
""",
    attrs = {
        "extra_srcs": attr.label_list(
            allow_files = True,
            doc = "Files that affect the build but are not in the target graph, such as MODULE.bazel.lock.",
        ),
        "target": attr.label(aspects = [_source_files_aspect], mandatory = True),
    },
)
