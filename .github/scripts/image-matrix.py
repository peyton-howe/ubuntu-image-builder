#!/usr/bin/env python3
"""Print a GitHub Actions matrix for stock Ubuntu image builds.

Boards, releases, and flavors come from configs/ so a new
configs/boards/<name>.sh is built without editing the workflow.
A board is included for a release or flavor only when its config lists
that name in COMPATIBLE_SUITES / COMPATIBLE_FLAVORS. An empty list means
every release or flavor.
"""

from __future__ import annotations

import json
import os
import pathlib
import subprocess
import sys


def names(directory: pathlib.Path) -> list[str]:
    return sorted(path.stem for path in directory.glob("*.sh"))


def sourced_array(board_file: pathlib.Path, array: str) -> list[str] | None:
    script = f"""
source "{board_file}"
if declare -p {array} >/dev/null 2>&1; then
    printf '%s\\n' "${{{array}[@]}}"
else
    printf '__UNSET__\\n'
fi
"""
    out = subprocess.check_output(["bash", "-c", script], text=True)
    lines = [line.strip() for line in out.splitlines() if line.strip()]
    if lines == ["__UNSET__"]:
        return None
    return lines


def select(requested: str, available: list[str], label: str) -> list[str]:
    # "both" is the flavor input for desktop and server. A release list is
    # comma-separated so a pull request can build stonking and resolute
    # without also building every file under configs/releases.
    if requested == "all" or (requested == "both" and label == "flavor"):
        return available
    chosen: list[str] = []
    for part in requested.split(","):
        name = part.strip()
        if name and name not in chosen:
            chosen.append(name)
    missing = [name for name in chosen if name not in available]
    if not chosen or missing:
        bad = ", ".join(missing) if missing else requested
        print(f"error: unknown {label} {bad!r}; have {', '.join(available)}", file=sys.stderr)
        sys.exit(1)
    return chosen


def main() -> None:
    root = pathlib.Path(__file__).resolve().parents[2]
    os.chdir(root)

    boards = names(root / "configs" / "boards")
    releases = names(root / "configs" / "releases")
    flavors = names(root / "configs" / "flavors")
    if not boards or not releases or not flavors:
        print("error: configs/boards, configs/releases, or configs/flavors is empty", file=sys.stderr)
        sys.exit(1)

    want_board = select(os.environ.get("BOARD", "all"), boards, "board")
    want_release = select(os.environ.get("RELEASE", "stonking,resolute"), releases, "release")
    want_flavor = select(os.environ.get("FLAVOR", "both"), flavors, "flavor")

    include = []
    for board in want_board:
        board_file = root / "configs" / "boards" / f"{board}.sh"
        allowed_releases = sourced_array(board_file, "COMPATIBLE_SUITES")
        allowed_flavors = sourced_array(board_file, "COMPATIBLE_FLAVORS")
        for release in want_release:
            if allowed_releases is not None and release not in allowed_releases:
                continue
            for flavor in want_flavor:
                if allowed_flavors is not None and flavor not in allowed_flavors:
                    continue
                include.append({"board": board, "release": release, "flavor": flavor})

    if not include:
        print(
            "error: matrix is empty "
            f"(BOARD={os.environ.get('BOARD', 'all')} "
            f"RELEASE={os.environ.get('RELEASE', 'stonking,resolute')} "
            f"FLAVOR={os.environ.get('FLAVOR', 'both')})",
            file=sys.stderr,
        )
        sys.exit(1)

    # images: one row per board. rootfs: the release/flavor pairs those rows
    # share, so the ISO is downloaded once per pair.
    kind = os.environ.get("MATRIX_KIND", "images")
    if kind == "rootfs":
        payload = []
        seen: set[tuple[str, str]] = set()
        for row in include:
            key = (row["release"], row["flavor"])
            if key in seen:
                continue
            seen.add(key)
            payload.append({"release": row["release"], "flavor": row["flavor"]})
    elif kind == "images":
        payload = include
    else:
        print(f"error: unknown MATRIX_KIND {kind!r}; use images or rootfs", file=sys.stderr)
        sys.exit(1)

    json.dump(payload, sys.stdout, separators=(",", ":"))
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
