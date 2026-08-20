#!/usr/bin/env python3
"""Verify that every shipped localization implements the same string contract."""

from __future__ import annotations

import collections
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
RESOURCE_ROOT = ROOT / "Sources" / "LimitsShared" / "Resources"
LINE = re.compile(r'^"(?P<key>[^"]+)"\s*=\s*"(?P<value>(?:[^"\\]|\\.)*)";$')
PLACEHOLDER = re.compile(r'%(?!%)(?:\d+\$)?[@dDuUxXfFeEgGcCsSpaA]')


def load(path: pathlib.Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("//") or line.startswith("/*"):
            continue
        match = LINE.fullmatch(line)
        if match is None:
            raise ValueError(f"{path}:{number}: unsupported .strings line")
        key = match.group("key")
        if key in values:
            raise ValueError(f"{path}:{number}: duplicate key {key}")
        values[key] = match.group("value")
    return values


def placeholders(value: str) -> collections.Counter[str]:
    return collections.Counter(PLACEHOLDER.findall(value))


def main() -> int:
    paths = sorted(RESOURCE_ROOT.glob("*.lproj/Localizable.strings"))
    if not paths:
        raise ValueError("No Localizable.strings files found")
    catalogs = {path.parent.name.removesuffix(".lproj"): load(path) for path in paths}
    baseline_name = "en"
    baseline = catalogs[baseline_name]
    failures: list[str] = []

    for language, catalog in catalogs.items():
        missing = sorted(set(baseline) - set(catalog))
        extra = sorted(set(catalog) - set(baseline))
        if missing:
            failures.append(f"{language}: missing keys: {', '.join(missing)}")
        if extra:
            failures.append(f"{language}: extra keys: {', '.join(extra)}")
        for key in sorted(set(baseline) & set(catalog)):
            expected = placeholders(baseline[key])
            actual = placeholders(catalog[key])
            if actual != expected:
                failures.append(f"{language}:{key}: placeholders {dict(actual)} != {dict(expected)}")

    if failures:
        print("\n".join(failures), file=sys.stderr)
        return 1
    print(f"localizations verified: {len(catalogs)} languages, {len(baseline)} keys")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ValueError as error:
        print(error, file=sys.stderr)
        raise SystemExit(1)
