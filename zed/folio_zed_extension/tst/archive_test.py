"""Checks the packaged folio-markdown-outline.tar.gz that ships to Zed."""

import re
import sys
import tarfile
import unittest

REQUIRED_FILES = (
    "extension.toml",
    "extension.wasm",
    "languages/markdown/config.toml",
    "languages/markdown/outline.scm",
)
VERSION_PATTERN = re.compile(r'^version\s*=\s*"(\d+)\.(\d+)\.(\d+)"', re.MULTILINE)


class ArchiveTest(unittest.TestCase):
    archive_path = ""
    source_manifest_path = ""

    def setUp(self):
        self.archive = tarfile.open(self.archive_path, "r:gz")
        self.addCleanup(self.archive.close)
        self.files = {
            member.name.removeprefix("./"): member
            for member in self.archive.getmembers()
            if member.isfile()
        }

    def read(self, name):
        return self.archive.extractfile(self.files[name]).read()

    def test_contains_exactly_the_required_files(self):
        self.assertEqual(sorted(self.files), sorted(REQUIRED_FILES))

    def test_wasm_is_a_zed_extension_component(self):
        wasm = self.read("extension.wasm")
        self.assertTrue(wasm.startswith(b"\x00asm"), "extension.wasm has no WebAssembly header")
        self.assertIn(b"zed:api-version", wasm, "extension.wasm has no zed:api-version section")

    def test_manifest_keeps_the_source_major_and_minor_version(self):
        with open(self.source_manifest_path, encoding="utf-8") as source:
            source_version = VERSION_PATTERN.search(source.read())
        packaged_version = VERSION_PATTERN.search(self.read("extension.toml").decode("utf-8"))
        self.assertIsNotNone(source_version)
        self.assertIsNotNone(packaged_version, "packaged extension.toml has no X.Y.Z version")
        self.assertEqual(packaged_version.group(1, 2), source_version.group(1, 2))


if __name__ == "__main__":
    ArchiveTest.archive_path, ArchiveTest.source_manifest_path = sys.argv[1:3]
    unittest.main(argv=sys.argv[:1])
