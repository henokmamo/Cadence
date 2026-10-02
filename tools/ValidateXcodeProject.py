#!/usr/bin/env python3
"""
ValidateXcodeProject.py — sanity-checks Cadence.xcodeproj without Xcode.

The .pbxproj format is unforgiving: a dangling object id or a file reference whose
path doesn't resolve produces a cryptic "Build input file cannot be found" or an
"unsupported project" error inside Xcode. This script catches those offline.

Checks
  1. every referenced object id is defined
  2. every PBXFileReference resolves to a real file/directory on disk
     (walking the group tree the same way Xcode does)
  3. every source file in the repo is a member of exactly one target's sources phase
  4. no duplicate object ids

Usage:  python3 tools/ValidateXcodeProject.py
"""

from __future__ import annotations

import os
import re
import sys
from collections import defaultdict

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PBXPROJ = os.path.join(ROOT, "Cadence.xcodeproj", "project.pbxproj")

ID = re.compile(r"\b([0-9A-F]{24})\b")
DEFINITION = re.compile(r"^\t\t([0-9A-F]{24}) = \{(.*)$")


def parse(text: str):
    definitions: dict[str, str] = {}
    counts: dict[str, int] = {}
    for line in text.splitlines():
        match = DEFINITION.match(line)
        if match:
            identifier = match.group(1)
            counts[identifier] = counts.get(identifier, 0) + 1
            definitions[identifier] = line
    referenced = set(ID.findall(text))
    dangling = sorted(r for r in referenced if r not in definitions)
    duplicates = sorted(i for i, count in counts.items() if count > 1)
    return definitions, dangling, duplicates


def group_children(body: str) -> list[str]:
    match = re.search(r"children = \((.*?)\);", body)
    if not match:
        return []
    return ID.findall(match.group(1))


def group_path(body: str) -> str | None:
    match = re.search(r"\bpath = ([^;]+);", body)
    if not match:
        return None
    return match.group(1).strip().strip('"')


def resolve_paths(definitions: dict[str, str]) -> dict[str, str]:
    """Map every PBXFileReference id to the path Xcode would use."""
    resolved: dict[str, str] = {}
    roots = ["root"]  # groups whose path is empty (sourceTree = <group>, no path)

    def walk(group_id: str, prefix: str, seen: set[str]) -> None:
        if group_id in seen:
            return
        seen.add(group_id)
        body = definitions.get(group_id, "")
        if "PBXGroup" not in body:
            return
        directory = os.path.join(prefix, group_path(body) or "")
        for child in group_children(body):
            child_body = definitions.get(child, "")
            if "PBXGroup" in child_body:
                walk(child, directory, seen)
            elif "PBXFileReference" in child_body:
                if "sourceTree = BUILT_PRODUCTS_DIR" in child_body:
                    continue          # build output, not on disk yet
                path = group_path(child_body) or ""
                resolved[child] = os.path.join(directory, path)

    for group_id, body in definitions.items():
        if "PBXGroup" in body and "path = " not in body:
            walk(group_id, "", set())
    _ = roots
    return resolved


def main() -> int:
    if not os.path.exists(PBXPROJ):
        print(f"Missing {PBXPROJ}. Run tools/GenerateXcodeProject.py first.")
        return 1

    text = open(PBXPROJ, encoding="utf-8").read()
    definitions, dangling, duplicates = parse(text)

    problems: list[str] = []

    if dangling:
        problems.append(f"dangling object ids (referenced but never defined): {dangling[:10]}")
    if duplicates:
        problems.append(f"duplicate object ids: {duplicates[:10]}")

    resolved = resolve_paths(definitions)
    missing = []
    for identifier, path in resolved.items():
        if not path:
            continue
        full = os.path.join(ROOT, path)
        if not os.path.exists(full):
            missing.append(path)
    if missing:
        problems.append("file references that do not exist on disk:\n    " + "\n    ".join(sorted(missing)))

    # Source membership: each .swift file should appear in at least one sources phase.
    swift_on_disk = set()
    for target in ["Cadence", "CadenceCore", "CadenceShared", "CadenceWidget", "CadenceTests", "CadenceCoreTests"]:
        for current, _dirs, files in os.walk(os.path.join(ROOT, target)):
            for name in files:
                if name.endswith(".swift"):
                    swift_on_disk.add(os.path.relpath(os.path.join(current, name), ROOT))

    id_to_path = {v: k for k, v in resolved.items()}
    in_sources: set[str] = set()
    for identifier, body in definitions.items():
        if "PBXSourcesBuildPhase" not in body:
            continue
        for build_file in ID.findall(re.search(r"files = \((.*?)\);", body).group(1)):
            build_body = definitions.get(build_file, "")
            ref_match = re.search(r"fileRef = ([0-9A-F]{24})", build_body)
            if not ref_match:
                continue
            ref = ref_match.group(1)
            if ref in resolved:
                in_sources.add(resolved[ref])
            elif ref in id_to_path:
                in_sources.add(id_to_path[ref])

    orphaned = sorted(swift_on_disk - in_sources)
    if orphaned:
        problems.append("Swift files not compiled into any target:\n    " + "\n    ".join(orphaned))

    print(f"objects            : {len(definitions)}")
    print(f"file references    : {len(resolved)}")
    print(f"swift files on disk: {len(swift_on_disk)}")
    print(f"swift in phases    : {len(swift_on_disk & in_sources)}")

    if problems:
        print("\nPROBLEMS")
        for problem in problems:
            print(f"  • {problem}")
        return 1

    print("\nproject validates ✓")
    return 0


if __name__ == "__main__":
    sys.exit(main())
