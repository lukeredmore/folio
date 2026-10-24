#!/usr/bin/env python3
"""
Fetches and updates the upstream GitHub Flavored Markdown (cmark-gfm) parser C sources
and official Markdown specification test suites (GFM spec.txt/extensions.txt + CommonMark spec.json).

Usage:
    ./tools/update_markdown_spec.py
    ./tools/update_markdown_spec.py --cmark-gfm-ref 0.29.0.gfm.13 --commonmark-version 0.31.2
"""

import argparse
import hashlib
import io
import json
import re
import shutil
import tarfile
import urllib.request
from pathlib import Path


DEFAULT_CMARK_GFM_REF = "0.29.0.gfm.13"
DEFAULT_CMARK_GFM_SHA256 = "5abc61798ebd9de5660bc076443c07abad2b8d15dbc11094a3a79644b8ad243a"
DEFAULT_COMMONMARK_VERSION = "0.31.2"
DEFAULT_COMMONMARK_SHA256 = "d431b29d97b6f73e69d547109cf5081578fac931e72afe95639ebe766c1b2a20"

CONFIG_H_CONTENT = """\
#ifndef CMARK_CONFIG_H
#define CMARK_CONFIG_H

#ifdef __cplusplus
extern "C" {
#endif

#define HAVE_STDBOOL_H 1
#include <stdbool.h>

#define HAVE___BUILTIN_EXPECT 1
#define HAVE___ATTRIBUTE__ 1

#ifdef HAVE___ATTRIBUTE__
  #define CMARK_ATTRIBUTE(list) __attribute__ (list)
#else
  #define CMARK_ATTRIBUTE(list)
#endif

#ifndef CMARK_INLINE
  #if defined(_MSC_VER) && !defined(__cplusplus)
    #define CMARK_INLINE __inline
  #else
    #define CMARK_INLINE inline
  #endif
#endif

#ifdef __cplusplus
}
#endif

#endif
"""

CMARK_GFM_EXPORT_H_CONTENT = """\
#ifndef CMARK_GFM_EXPORT_H
#define CMARK_GFM_EXPORT_H

#define CMARK_GFM_EXPORT
#define CMARK_GFM_NO_EXPORT

#endif
"""

CMARK_GFM_EXTENSIONS_EXPORT_H_CONTENT = """\
#ifndef CMARK_GFM_EXTENSIONS_EXPORT_H
#define CMARK_GFM_EXTENSIONS_EXPORT_H

#define CMARK_GFM_EXTENSIONS_EXPORT
#define CMARK_GFM_EXTENSIONS_NO_EXPORT

#endif
"""

CMARK_GFM_BUILD_BAZEL = """\
load("@rules_cc//cc:defs.bzl", "cc_library")

package(default_visibility = ["//visibility:public"])

cc_library(
    name = "cmark_gfm",
    srcs = glob(
        [
            "src/*.c",
            "src/*.inc",
            "extensions/*.c",
        ],
        exclude = ["src/main.c"],
    ),
    hdrs = glob([
        "src/*.h",
        "extensions/*.h",
    ]),
    copts = [
        "-std=c99",
        "-DCMARK_GFM_STATIC_DEFINE",
        "-DCMARK_GFM_EXTENSIONS_STATIC_DEFINE",
        "-Wno-unused-parameter",
    ],
    includes = [
        "extensions",
        "src",
    ],
)
"""

MARKDOWN_SPEC_BUILD_BAZEL = """\
package(default_visibility = ["//visibility:public"])

exports_files([
    "gfm_spec.txt",
    "gfm_spec.json",
    "gfm_extensions.txt",
    "gfm_extensions.json",
    "commonmark_spec.json",
    "spec_manifest.json",
])

filegroup(
    name = "all_spec_files",
    srcs = [
        "commonmark_spec.json",
        "gfm_extensions.json",
        "gfm_extensions.txt",
        "gfm_spec.json",
        "gfm_spec.txt",
        "spec_manifest.json",
    ],
)
"""


def parse_spec_txt(spec_text: str):
    """
    Exact upstream test extractor from github/cmark-gfm/test/spec_tests.py (`get_tests`).
    Extracts every ```... example ... ``` block into structured JSON test definitions.
    """
    line_number = 0
    start_line = 0
    end_line = 0
    example_number = 0
    markdown_lines = []
    html_lines = []
    state = 0  # 0 regular text, 1 markdown example, 2 html output
    extensions = []
    headertext = ""
    tests = []

    header_re = re.compile(r"#+ ")
    fence_prefix = "`" * 32

    for line in spec_text.splitlines(keepends=True):
        line_number += 1
        stripped = line.strip()
        if stripped.startswith(fence_prefix + " example"):
            state = 1
            extensions = stripped[len(fence_prefix + " example") :].split()
        elif stripped == fence_prefix:
            state = 0
            example_number += 1
            end_line = line_number
            if "disabled" not in extensions:
                tests.append(
                    {
                        "markdown": "".join(markdown_lines).replace("→", "\t"),
                        "html": "".join(html_lines).replace("→", "\t"),
                        "example": example_number,
                        "start_line": start_line,
                        "end_line": end_line,
                        "section": headertext,
                        "extensions": extensions,
                    }
                )
            start_line = 0
            markdown_lines = []
            html_lines = []
        elif stripped == ".":
            state = 2
        elif state == 1:
            if start_line == 0:
                start_line = line_number - 1
            markdown_lines.append(line)
        elif state == 2:
            html_lines.append(line)
        elif state == 0 and header_re.match(line):
            headertext = header_re.sub("", line).strip()

    return tests


def download_bytes(url: str) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": "Folio-Spec-Updater/1.0"})
    with urllib.request.urlopen(req, timeout=60) as resp:
        return resp.read()


def parse_version_from_cmake(cmake_text: str):
    def get_var(name: str, default: str = "0") -> str:
        m = re.search(rf"set\({name}\s+(\d+)\)", cmake_text)
        return m.group(1) if m else default

    major = int(get_var("PROJECT_VERSION_MAJOR", "0"))
    minor = int(get_var("PROJECT_VERSION_MINOR", "29"))
    patch = int(get_var("PROJECT_VERSION_PATCH", "0"))
    gfm = int(get_var("PROJECT_VERSION_GFM", "13"))
    return major, minor, patch, gfm


def make_version_h(major: int, minor: int, patch: int, gfm: int) -> str:
    return f"""\
#ifndef CMARK_GFM_VERSION_H
#define CMARK_GFM_VERSION_H

#define CMARK_GFM_VERSION (({major} << 24) | ({minor} << 16) | ({patch} << 8) | {gfm})
#define CMARK_GFM_VERSION_STRING "{major}.{minor}.{patch}.gfm.{gfm}"

#endif
"""


def main():
    repo_root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description="Update upstream cmark-gfm and Markdown spec fixtures.")
    parser.add_argument(
        "--cmark-gfm-ref",
        default=DEFAULT_CMARK_GFM_REF,
        help=f"Git tag or commit ref in github/cmark-gfm (default: {DEFAULT_CMARK_GFM_REF})",
    )
    parser.add_argument(
        "--commonmark-version",
        default=DEFAULT_COMMONMARK_VERSION,
        help=f"CommonMark spec version from spec.commonmark.org (default: {DEFAULT_COMMONMARK_VERSION})",
    )
    parser.add_argument(
        "--cmark-tar",
        default="",
        help="Optional local path to pre-downloaded cmark-gfm tar.gz archive",
    )
    parser.add_argument(
        "--commonmark-json",
        default="",
        help="Optional local path to pre-downloaded CommonMark spec.json",
    )
    parser.add_argument(
        "--output-cmark-dir",
        default=str(repo_root / "third_party" / "cmark_gfm"),
        help="Output directory for cmark-gfm C sources (pass 'none' to skip)",
    )
    parser.add_argument(
        "--output-spec-dir",
        default=str(repo_root / "third_party" / "markdown_spec"),
        help="Output directory for Markdown spec fixtures (pass 'none' to skip)",
    )
    args = parser.parse_args()

    cmark_dir = None if args.output_cmark_dir == "none" else Path(args.output_cmark_dir)
    spec_dir = None if args.output_spec_dir == "none" else Path(args.output_spec_dir)

    cmark_tar_url = f"https://github.com/github/cmark-gfm/archive/{args.cmark_gfm_ref}.tar.gz"
    commonmark_json_url = f"https://spec.commonmark.org/{args.commonmark_version}/spec.json"

    if args.cmark_tar:
        cmark_tar_bytes = Path(args.cmark_tar).read_bytes()
    else:
        print(f"[1/4] Downloading cmark-gfm ({args.cmark_gfm_ref}) from {cmark_tar_url} ...")
        cmark_tar_bytes = download_bytes(cmark_tar_url)
    cmark_tar_sha256 = hashlib.sha256(cmark_tar_bytes).hexdigest()
    if args.cmark_gfm_ref == DEFAULT_CMARK_GFM_REF and cmark_tar_sha256 != DEFAULT_CMARK_GFM_SHA256:
        raise RuntimeError(
            f"SHA-256 mismatch for {cmark_tar_url}: expected {DEFAULT_CMARK_GFM_SHA256}, got {cmark_tar_sha256}"
        )

    commonmark_json_bytes = b"[]"
    commonmark_json_sha256 = ""
    commonmark_tests = []
    if spec_dir is not None:
        if args.commonmark_json:
            commonmark_json_bytes = Path(args.commonmark_json).read_bytes()
        else:
            print(f"[2/4] Downloading CommonMark {args.commonmark_version} spec.json from {commonmark_json_url} ...")
            commonmark_json_bytes = download_bytes(commonmark_json_url)
        commonmark_json_sha256 = hashlib.sha256(commonmark_json_bytes).hexdigest()
        if args.commonmark_version == DEFAULT_COMMONMARK_VERSION and commonmark_json_sha256 != DEFAULT_COMMONMARK_SHA256:
            raise RuntimeError(
                f"SHA-256 mismatch for {commonmark_json_url}: expected {DEFAULT_COMMONMARK_SHA256}, got {commonmark_json_sha256}"
            )
        commonmark_tests = json.loads(commonmark_json_bytes.decode("utf-8"))

    if cmark_dir is not None:
        (cmark_dir / "src").mkdir(parents=True, exist_ok=True)
        (cmark_dir / "extensions").mkdir(parents=True, exist_ok=True)
    if spec_dir is not None:
        spec_dir.mkdir(parents=True, exist_ok=True)

    cmake_root_text = ""
    gfm_spec_txt = ""
    gfm_extensions_txt = ""

    with tarfile.open(fileobj=io.BytesIO(cmark_tar_bytes), mode="r:gz") as tf:
        for member in tf.getmembers():
            if not member.isfile():
                continue
            parts = Path(member.name).parts
            if len(parts) < 2:
                continue
            rel = Path(*parts[1:])
            rel_str = rel.as_posix()

            data = tf.extractfile(member).read()
            if rel_str == "CMakeLists.txt":
                cmake_root_text = data.decode("utf-8")
            elif cmark_dir is not None and rel_str == "COPYING":
                (cmark_dir / "COPYING").write_bytes(data)
            elif cmark_dir is not None and rel.parts[0] == "src" and rel.suffix in (".c", ".h", ".inc") and rel.name != "main.c":
                (cmark_dir / rel).write_bytes(data)
            elif cmark_dir is not None and rel.parts[0] == "extensions" and rel.suffix in (".c", ".h"):
                (cmark_dir / rel).write_bytes(data)
            elif rel_str == "test/spec.txt":
                gfm_spec_txt = data.decode("utf-8")
            elif rel_str == "test/extensions.txt":
                gfm_extensions_txt = data.decode("utf-8")

    major, minor, patch, gfm = parse_version_from_cmake(cmake_root_text)
    if cmark_dir is not None:
        (cmark_dir / "src" / "config.h").write_text(CONFIG_H_CONTENT, encoding="utf-8")
        (cmark_dir / "src" / "cmark-gfm_version.h").write_text(
            make_version_h(major, minor, patch, gfm), encoding="utf-8"
        )
        (cmark_dir / "src" / "cmark-gfm_export.h").write_text(CMARK_GFM_EXPORT_H_CONTENT, encoding="utf-8")
        (cmark_dir / "extensions" / "cmark-gfm-extensions_export.h").write_text(
            CMARK_GFM_EXTENSIONS_EXPORT_H_CONTENT, encoding="utf-8"
        )
        (cmark_dir / "BUILD.bazel").write_text(CMARK_GFM_BUILD_BAZEL, encoding="utf-8")

    if spec_dir is not None:
        gfm_spec_tests = parse_spec_txt(gfm_spec_txt)
        gfm_ext_tests = parse_spec_txt(gfm_extensions_txt)

        (spec_dir / "gfm_spec.txt").write_text(gfm_spec_txt, encoding="utf-8")
        (spec_dir / "gfm_extensions.txt").write_text(gfm_extensions_txt, encoding="utf-8")
        (spec_dir / "gfm_spec.json").write_text(
            json.dumps(gfm_spec_tests, indent=2, ensure_ascii=False) + "\n",
            encoding="utf-8",
        )
        (spec_dir / "gfm_extensions.json").write_text(
            json.dumps(gfm_ext_tests, indent=2, ensure_ascii=False) + "\n",
            encoding="utf-8",
        )
        (spec_dir / "commonmark_spec.json").write_bytes(commonmark_json_bytes)
        (spec_dir / "BUILD.bazel").write_text(MARKDOWN_SPEC_BUILD_BAZEL, encoding="utf-8")

        manifest = {
            "cmark_gfm": {
                "ref": args.cmark_gfm_ref,
                "version": f"{major}.{minor}.{patch}.gfm.{gfm}",
                "archive_url": cmark_tar_url,
                "archive_sha256": cmark_tar_sha256,
                "gfm_spec_test_count": len(gfm_spec_tests),
                "gfm_extensions_test_count": len(gfm_ext_tests),
            },
            "commonmark": {
                "version": args.commonmark_version,
                "spec_json_url": commonmark_json_url,
                "spec_json_sha256": commonmark_json_sha256,
                "test_count": len(commonmark_tests),
            },
        }
        (spec_dir / "spec_manifest.json").write_text(
            json.dumps(manifest, indent=2) + "\n",
            encoding="utf-8",
        )


if __name__ == "__main__":
    main()
