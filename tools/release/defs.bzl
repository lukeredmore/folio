"""Release stamping and packaging rules for Folio.

Dev builds use fixed values. `--config=release` sets //tools/release:release, which makes these
rules read the STABLE_FOLIO_* keys that tools/release/workspace_status.sh writes.
"""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")

_RELEASE_FLAG = "//tools/release:release"

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
