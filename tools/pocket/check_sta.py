#!/usr/bin/env python3
"""Report the worst setup slack from a Quartus .sta.summary and fail on negative slack.

Usage: python3 tools/pocket/check_sta.py output_files

Prints one line per parsed clock ("<clock>: <slack> ns") and a final
"worst setup slack: <value> ns" line. Exit codes:
  0  at least one setup slack parsed, all non-negative
  1  at least one negative setup slack
  2  no setup slack could be parsed (format unknown; says so loudly)

The Quartus summary layout has changed between versions, so this parses
tolerantly: inside sections whose heading mentions "Setup", every table row
"; <clock> ; <float> ;" contributes its first float as a slack value. The raw
reports should accompany any decision; this script is a convenience check.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path


ROW = re.compile(r"^\s*;\s*(?P<clock>[^;]+?)\s*;\s*(?P<slack>[-+]?[0-9]+\.[0-9]+)\s*;")


def setup_slacks(summary: Path) -> list[tuple[str, float]]:
    """Parse (clock, slack) pairs from the Setup sections of a .sta.summary."""
    setup = False
    slacks: list[tuple[str, float]] = []
    for line in summary.read_text(errors="replace").splitlines():
        heading = re.sub(r"[;+|]", " ", line).strip().lower()
        if "summary" in heading or "model" in heading:
            setup = "setup" in heading
        match = ROW.match(line)
        if match and setup:
            slacks.append((match.group("clock"), float(match.group("slack"))))
    return slacks


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    out = Path(sys.argv[1])
    summary = out / "ap_core.sta.summary"
    if not summary.is_file():
        print(f"ERROR: {summary} not found")
        return 2
    slacks = setup_slacks(summary)
    if not slacks:
        print("NO SETUP SLACK PARSED - check output_files/ap_core.sta.summary by hand")
        return 2
    worst = min(value for _, value in slacks)
    for clock, value in slacks:
        print(f"{clock}: {value:+.3f} ns")
    print(f"worst setup slack: {worst:+.3f} ns")
    return 0 if worst >= 0 else 1


if __name__ == "__main__":
    sys.exit(main())
