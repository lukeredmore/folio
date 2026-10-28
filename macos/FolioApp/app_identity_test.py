"""Checks the identity keys in the built Folio.app Info.plist.

A dev build must never use the release bundle ID: it would share the installed
app's preferences, state, and file-type registration.
"""

import plistlib
import sys
import unittest
from pathlib import Path


class AppIdentityTest(unittest.TestCase):
    channel = ""
    bundle_id = ""
    bundle_name = ""
    handler_rank = ""
    release_bundle_id = ""
    app_path = Path()

    def setUp(self):
        plist_path = self.app_path / "Contents" / "Info.plist"
        self.assertTrue(plist_path.is_file(), f"no Info.plist at {plist_path}")
        with plist_path.open("rb") as plist_file:
            self.info = plistlib.load(plist_file)

    def test_identity_matches_the_build_configuration(self):
        self.assertEqual(self.info.get("CFBundleIdentifier"), self.bundle_id)
        self.assertEqual(self.info.get("CFBundleName"), self.bundle_name)
        self.assertEqual(self.info.get("CFBundleDisplayName"), self.bundle_name)
        self.assertEqual(self.info.get("FolioBuildChannel"), self.channel)

    def test_dev_build_does_not_use_the_release_bundle_id(self):
        if self.channel != "dev":
            self.skipTest("release build")
        self.assertNotEqual(
            self.info.get("CFBundleIdentifier"),
            self.release_bundle_id,
            "the dev build uses the release bundle ID",
        )

    def test_document_types_use_the_expected_handler_rank(self):
        document_types = self.info.get("CFBundleDocumentTypes", [])
        self.assertTrue(document_types, "no CFBundleDocumentTypes")
        for index, document_type in enumerate(document_types):
            with self.subTest(document_type=index):
                self.assertEqual(document_type.get("LSHandlerRank"), self.handler_rank)


if __name__ == "__main__":
    (
        AppIdentityTest.channel,
        AppIdentityTest.bundle_id,
        AppIdentityTest.bundle_name,
        AppIdentityTest.handler_rank,
        AppIdentityTest.release_bundle_id,
        *bundle_paths,
    ) = sys.argv[1:]
    AppIdentityTest.app_path = next(Path(path) for path in bundle_paths if path.endswith(".app"))
    unittest.main(argv=sys.argv[:1])
