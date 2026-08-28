#!/usr/bin/env python3
"""Select the newest published Limits release that can be used for update testing."""

from __future__ import annotations

import json
import re
import sys
from collections.abc import Iterable
from typing import Any


ARCHIVE_NAME = re.compile(r"^Limits-v[0-9]+(?:\.[0-9]+){1,2}-macOS-arm64\.zip$")


def select_previous_release(releases: Iterable[dict[str, Any]], current_tag: str) -> dict[str, str]:
    candidates: list[tuple[str, str, str]] = []
    for release in releases:
        tag = release.get("tag_name")
        published_at = release.get("published_at")
        if (
            not isinstance(tag, str)
            or tag == current_tag
            or not isinstance(published_at, str)
            or release.get("draft") is True
            or release.get("prerelease") is True
        ):
            continue

        archive = next(
            (
                asset.get("name")
                for asset in release.get("assets", [])
                if isinstance(asset, dict)
                and isinstance(asset.get("name"), str)
                and ARCHIVE_NAME.fullmatch(asset["name"])
            ),
            None,
        )
        if archive is not None:
            candidates.append((published_at, tag, archive))

    if not candidates:
        raise ValueError("No earlier published release contains a signed macOS archive.")

    _, tag, archive = max(candidates)
    return {"tag": tag, "asset": archive}


def main() -> int:
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} CURRENT_TAG", file=sys.stderr)
        return 2

    try:
        releases = json.load(sys.stdin)
        if not isinstance(releases, list):
            raise ValueError("GitHub releases response must be a JSON array.")
        selection = select_previous_release(releases, sys.argv[1])
    except (json.JSONDecodeError, ValueError) as error:
        print(error, file=sys.stderr)
        return 1

    json.dump(selection, sys.stdout, separators=(",", ":"))
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
