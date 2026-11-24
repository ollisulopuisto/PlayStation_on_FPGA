#!/usr/bin/env python3
"""Pick the fitter seed whose compile closed timing with the best worst-setup-slack.

Usage: python3 tools/pocket/pick_best_seed.py <fits-dir>

<fits-dir> holds one subdirectory per compiled seed (downloaded fit artifacts).
A subdirectory competes when it has:
  - seed.txt              (one integer, the fitter seed)
  - ap_core.sta.summary   (parsed with check_sta's tolerant setup parser)
  - ap_core.rbf           (the bitstream to package)
and a parseable, non-negative worst setup slack.

Prints "best_seed=<n>", "best_dir=<path>" and "best_slack=<ns>" and, when
GITHUB_OUTPUT is set, appends the same keys there. Exit codes:
  0  a closing seed was selected
  1  no seed closed timing (every candidate is listed with its slack)
  2  usage error / fits dir missing
"""
from __future__ import annotations

import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from check_sta import setup_slacks  # noqa: E402


def candidates(fits: Path) -> list[tuple[float, int, Path]]:
    out: list[tuple[float, int, Path]] = []
    for d in sorted(fits.iterdir()):
        if not d.is_dir():
            continue
        seed_file = d / "seed.txt"
        summary = d / "ap_core.sta.summary"
        rbf = d / "ap_core.rbf"
        if not (seed_file.is_file() and summary.is_file() and rbf.is_file()):
            continue
        try:
            seed = int(seed_file.read_text().strip())
        except ValueError:
            continue
        slacks = setup_slacks(summary)
        if not slacks:
            print(f"seed {seed}: no setup slack parsed, not eligible", file=sys.stderr)
            continue
        worst = min(value for _, value in slacks)
        print(f"seed {seed}: worst setup slack {worst:+.3f} ns", file=sys.stderr)
        if worst >= 0:
            out.append((worst, seed, d))
    return out


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    fits = Path(sys.argv[1])
    if not fits.is_dir():
        print(f"ERROR: {fits} not found", file=sys.stderr)
        return 2
    closing = candidates(fits)
    if not closing:
        print("No seed closed timing; inspect the fit artifacts.", file=sys.stderr)
        return 1
    # Highest worst-slack wins; ties go to the lower seed for determinism.
    closing.sort(key=lambda item: (-item[0], item[1]))
    slack, seed, path = closing[0]
    lines = [f"best_seed={seed}", f"best_dir={path}", f"best_slack={slack:+.3f}"]
    for line in lines:
        print(line)
    github_output = os.environ.get("GITHUB_OUTPUT")
    if github_output:
        with open(github_output, "a") as fh:
            for line in lines:
                fh.write(line + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
