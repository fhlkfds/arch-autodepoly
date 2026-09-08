#!/usr/bin/env python3
"""Report Stow targets that do not resolve to their tracked source file."""

import argparse
import json
import os
import subprocess


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True)
    parser.add_argument("--home", required=True)
    parser.add_argument("packages", nargs="+")
    return parser.parse_args()


def blocking_ancestor(target: str, home: str) -> str | None:
    """Return a symlink or non-directory ancestor that Stow cannot replace."""
    current = os.path.dirname(target)
    while current != home and current.startswith(f"{home}{os.sep}"):
        if os.path.lexists(current):
            if os.path.islink(current) or not os.path.isdir(current):
                return current
        current = os.path.dirname(current)
    return None


def main() -> None:
    args = parse_args()
    entries = []

    for package in args.packages:
        result = subprocess.run(
            ["git", "ls-files", package],
            cwd=args.repo,
            check=True,
            text=True,
            capture_output=True,
        )
        prefix = f"{package}/"
        for tracked_path in result.stdout.splitlines():
            if not tracked_path.startswith(prefix):
                continue
            relative = tracked_path[len(prefix) :]
            # GNU Stow's built-in ignore rules skip Git administrative files.
            if os.path.basename(relative) == ".gitignore":
                continue
            source = os.path.join(args.repo, tracked_path)
            target = os.path.join(args.home, relative)
            exists = os.path.lexists(target)
            resolves_to_source = exists and os.path.realpath(target) == source
            entries.append(
                {
                    "package": package,
                    "relative": relative,
                    "source": source,
                    "target": target,
                    "exists": exists,
                    "resolves_to_source": resolves_to_source,
                }
            )

    needs_changes = [entry for entry in entries if not entry["resolves_to_source"]]
    conflicts_by_target = {}
    for entry in needs_changes:
        ancestor = blocking_ancestor(entry["target"], args.home)
        conflict = entry if entry["exists"] and ancestor is None else None
        if ancestor is not None:
            conflict = {
                "package": entry["package"],
                "relative": os.path.relpath(ancestor, args.home),
                "source": "",
                "target": ancestor,
                "exists": True,
                "resolves_to_source": False,
            }
        if conflict is not None:
            conflicts_by_target[conflict["target"]] = conflict
    conflicts = list(conflicts_by_target.values())
    packages_needing_change = sorted(
        {entry["package"] for entry in needs_changes}
    )
    print(
        json.dumps(
            {
                "entries": entries,
                "needs_changes": needs_changes,
                "conflicts": conflicts,
                "packages_needing_change": packages_needing_change,
            },
            separators=(",", ":"),
        )
    )


if __name__ == "__main__":
    main()
