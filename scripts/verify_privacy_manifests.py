#!/usr/bin/env python3
"""Validate source and built-bundle privacy manifests."""

from __future__ import annotations

import argparse
import plistlib
from pathlib import Path


EXPECTED = {
    "iphone": {
        "NSPrivacyAccessedAPICategoryDiskSpace": {"E174.1"},
        "NSPrivacyAccessedAPICategoryUserDefaults": {"CA92.1"},
    },
    "watch": {
        "NSPrivacyAccessedAPICategoryDiskSpace": {"85F4.1", "E174.1"},
        "NSPrivacyAccessedAPICategoryFileTimestamp": {"C617.1"},
    },
}


def load_manifest(path: Path) -> dict:
    if not path.is_file():
        raise SystemExit(f"Privacy manifest is missing: {path}")
    with path.open("rb") as stream:
        return plistlib.load(stream)


def validate(path: Path, target: str) -> None:
    manifest = load_manifest(path)
    declarations = {}
    for entry in manifest.get("NSPrivacyAccessedAPITypes", []):
        category = entry.get("NSPrivacyAccessedAPIType")
        reasons = set(entry.get("NSPrivacyAccessedAPITypeReasons", []))
        if category:
            declarations[category] = reasons

    if declarations != EXPECTED[target]:
        raise SystemExit(
            f"Unexpected Required Reason API declarations in {path}: "
            f"expected {EXPECTED[target]}, found {declarations}"
        )
    if manifest.get("NSPrivacyTracking") is not False:
        raise SystemExit(f"NSPrivacyTracking must be false in {path}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--iphone", type=Path, required=True)
    parser.add_argument("--watch", type=Path, required=True)
    args = parser.parse_args()
    validate(args.iphone, "iphone")
    validate(args.watch, "watch")
    print(f"Validated privacy manifests: {args.iphone}, {args.watch}")


if __name__ == "__main__":
    main()
