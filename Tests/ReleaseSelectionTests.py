#!/usr/bin/env python3

import importlib.util
import pathlib
import unittest


SCRIPT_PATH = pathlib.Path(__file__).parents[1] / "script" / "select_previous_release.py"
SPEC = importlib.util.spec_from_file_location("select_previous_release", SCRIPT_PATH)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def release(
    tag: str,
    published_at: str,
    *assets: str,
    draft: bool = False,
    prerelease: bool = False,
) -> dict:
    return {
        "tag_name": tag,
        "published_at": published_at,
        "draft": draft,
        "prerelease": prerelease,
        "assets": [{"name": name} for name in assets],
    }


class PreviousReleaseSelectionTests(unittest.TestCase):
    def test_uses_latest_published_archive_instead_of_unreleased_tag(self) -> None:
        releases = [
            release("v1.0.0", "2026-08-21T04:23:45Z"),
            release(
                "v0.1.44",
                "2026-05-27T01:22:16Z",
                "Limits-v0.1.44-macOS-arm64.zip",
            ),
        ]

        self.assertEqual(
            MODULE.select_previous_release(releases, "v1.0.1"),
            {
                "tag": "v0.1.44",
                "asset": "Limits-v0.1.44-macOS-arm64.zip",
            },
        )

    def test_skips_current_draft_prerelease_and_release_without_archive(self) -> None:
        releases = [
            release(
                "v1.1.0",
                "2026-08-28T12:00:00Z",
                "Limits-v1.1.0-macOS-arm64.zip",
                draft=True,
            ),
            release(
                "v1.0.2-beta",
                "2026-08-28T11:00:00Z",
                "Limits-v1.0.2-macOS-arm64.zip",
                prerelease=True,
            ),
            release(
                "v1.0.1",
                "2026-08-28T10:00:00Z",
                "Limits-v1.0.1-macOS-arm64.zip",
            ),
            release("v1.0.0", "2026-08-27T10:00:00Z", "source.zip"),
            release(
                "v0.1.44",
                "2026-05-27T01:22:16Z",
                "Limits-v0.1.44-macOS-arm64.zip",
            ),
        ]

        selection = MODULE.select_previous_release(releases, "v1.0.1")

        self.assertEqual(selection["tag"], "v0.1.44")

    def test_requires_a_published_mac_archive(self) -> None:
        with self.assertRaisesRegex(ValueError, "signed macOS archive"):
            MODULE.select_previous_release([], "v1.0.1")


if __name__ == "__main__":
    unittest.main()
