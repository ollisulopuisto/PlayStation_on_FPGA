#!/usr/bin/env python3
"""Regression test for the sta-summary -> seed-selection flow used by the
Pocket build workflow: check_sta.setup_slacks parses synthetic Quartus
summaries, pick_best_seed chooses among fabricated fit-artifact dirs.

Run: python3 tools/pocket/test_pick_best_seed.py  (exit 0 = pass)
"""
from __future__ import annotations

import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import check_sta  # noqa: E402

PICK = Path(__file__).resolve().parent / "pick_best_seed.py"


def summary(*sections: tuple[str, list[tuple[str, float]]]) -> str:
    out = []
    for title, rows in sections:
        out.append(f"+-- {title} " + "-" * 40)
        for clock, slack in rows:
            out.append(f"; {clock} ; {slack:+.3f} ;")
    return "\n".join(out) + "\n"


def make_fit(root: Path, name: str, seed: int | None, text: str | None, rbf: bool = True) -> Path:
    d = root / name
    d.mkdir(parents=True)
    if seed is not None:
        (d / "seed.txt").write_text(f"{seed}\n")
    if text is not None:
        (d / "ap_core.sta.summary").write_text(text)
    if rbf:
        (d / "ap_core.rbf").write_bytes(b"\x00fake-rbf")
    return d


def run_pick(fits: Path) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, str(PICK), str(fits)], capture_output=True, text=True
    )


def main() -> int:
    checks = 0

    def ok(cond: bool, label: str) -> None:
        nonlocal checks
        checks += 1
        if not cond:
            print(f"FAIL: {label}")
            sys.exit(1)

    # Parser: setup section only, hold section ignored.
    text = summary(
        ("Setup Summary", [("clk_sys", 0.341), ("clk_vid", 1.002)]),
        ("Hold Summary", [("clk_sys", -2.500)]),
    )
    slacks = check_sta.setup_slacks(_write(text))
    ok(len(slacks) == 2, "hold section not misread as setup")
    ok(min(v for _, v in slacks) == 0.341, "worst setup slack parsed")

    with tempfile.TemporaryDirectory() as tmp:
        fits = Path(tmp) / "fits"

        # Two closing seeds: higher slack wins even with a higher seed number.
        make_fit(fits, "fit-1", 1, summary(("Setup Summary", [("clk", 0.100)])))
        make_fit(fits, "fit-2", 2, summary(("Setup Summary", [("clk", 0.341)])))
        r = run_pick(fits)
        ok(r.returncode == 0, f"closing seeds select: rc={r.returncode} {r.stderr}")
        ok("best_seed=2" in r.stdout, "highest slack seed selected")

        # A negative-slack seed must not win over a closing one.
        make_fit(fits, "fit-3", 3, summary(("Setup Summary", [("clk", -0.050)])))
        r = run_pick(fits)
        ok(r.returncode == 0 and "best_seed=2" in r.stdout, "negative slack excluded")

        # No closing seed -> exit 1.
        with tempfile.TemporaryDirectory() as tmp2:
            fits2 = Path(tmp2) / "fits"
            make_fit(fits2, "fit-1", 1, summary(("Setup Summary", [("clk", -0.050)])))
            make_fit(fits2, "fit-2", 2, summary(("Setup Summary", [("clk", -1.200)])))
            r = run_pick(fits2)
            ok(r.returncode == 1, "no closing seed exits 1")

        # Unparseable summary is skipped, other closing seed still wins.
        make_fit(fits, "fit-4", 4, "garbage\n")
        r = run_pick(fits)
        ok(r.returncode == 0 and "best_seed=2" in r.stdout, "unparseable skipped")

        # Missing rbf disqualifies.
        with tempfile.TemporaryDirectory() as tmp3:
            fits3 = Path(tmp3) / "fits"
            make_fit(fits3, "fit-1", 1, summary(("Setup Summary", [("clk", 5.000)])), rbf=False)
            make_fit(fits3, "fit-2", 2, summary(("Setup Summary", [("clk", 0.010)])))
            r = run_pick(fits3)
            ok(r.returncode == 0 and "best_seed=2" in r.stdout, "missing rbf disqualified")

    print(f"ok - {checks} checks passed")
    return 0


def _write(text: str) -> Path:
    fh = tempfile.NamedTemporaryFile("w", suffix=".summary", delete=False)
    fh.write(text)
    fh.close()
    return Path(fh.name)


if __name__ == "__main__":
    sys.exit(main())
