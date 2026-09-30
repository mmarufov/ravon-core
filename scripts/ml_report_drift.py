#!/usr/bin/env python3
"""Check that a regenerated `ml/reports/metrics.json` matches the committed one.

    python -m ravon_ml.cli                  # (in ml/) rewrites reports/metrics.json
    python3 scripts/ml_report_drift.py      # compares it against git HEAD
    python3 scripts/ml_report_drift.py OLD NEW
    python3 scripts/ml_report_drift.py --self-test

## Why

Every number in `ml/README.md` and `ml/FINDINGS.md` is quoted from the committed
`metrics.json`. The test suite checks that the methods behave; it does not check that
the committed report is still what the code produces. A change to a feature, a split
or a default that moves CRPS would pass all 79 tests and leave the README quoting a
number the code no longer computes. This fails the build when that happens.

## Why not bitwise

The report is not bitwise reproducible, and a gate that pretended it was would be
flaky. Regenerated in a fresh venv from ml/requirements-lock.txt, on the machine that
produced the committed file, 78 of 690 float leaves differed, by 1.2e-16 to 1.75e-13
relative: summation order in the last bits. The largest was a mean bias near zero, where
cancellation magnifies last-bit noise. So:

  * structure, strings, booleans, nulls and integers must match exactly
    (row counts, day counts, seeds, false-alarm counts are integers)
  * NaN matches NaN
  * floats match if |a - b| <= RTOL * max(|a|, |b|)
  * where one side is exactly 0.0, relative difference is undefined, so the other
    side must be within ATOL of zero instead

RTOL = 1e-6 sits more than six orders of magnitude above the measured drift and two below the
fourth significant figure, which is the precision every number in the docs is quoted
at. The tolerance is relative everywhere else on purpose: the report holds p-values
near 1e-246, and any absolute tolerance would wave through a change in them.

The script prints the largest relative difference it saw, so each CI log records the
measurement the tolerance is justified by.
"""
from __future__ import annotations

import json
import math
import pathlib
import subprocess
import sys
from typing import Any, Iterator

RTOL = 1e-6
ATOL = 1e-12
REPORT = "ml/reports/metrics.json"


def leaves(a: Any, b: Any, path: str = "") -> Iterator[tuple[str, Any, Any]]:
    """Pairs of leaves at the same path. A structural mismatch is yielded as a leaf."""
    if isinstance(a, dict) and isinstance(b, dict):
        for key in sorted(set(a) | set(b)):
            if key not in a or key not in b:
                yield f"{path}.{key}", a.get(key, "<missing>"), b.get(key, "<missing>")
            else:
                yield from leaves(a[key], b[key], f"{path}.{key}")
    elif isinstance(a, list) and isinstance(b, list):
        if len(a) != len(b):
            yield f"{path}[len]", len(a), len(b)
        for i, (x, y) in enumerate(zip(a, b)):
            yield from leaves(x, y, f"{path}[{i}]")
    else:
        yield path, a, b


def compare(old: Any, new: Any) -> tuple[list[str], float, int]:
    """(mismatches, largest relative float difference, float leaves compared)."""
    mismatches: list[str] = []
    worst, floats = 0.0, 0
    for path, a, b in leaves(old, new):
        if isinstance(a, float) and isinstance(b, float):
            floats += 1
            if math.isnan(a) or math.isnan(b):
                if not (math.isnan(a) and math.isnan(b)):
                    mismatches.append(f"{path}: {a!r} -> {b!r}")
                continue
            if a == b:
                continue
            scale = max(abs(a), abs(b))
            rel = abs(a - b) / scale if math.isfinite(scale) else math.inf
            worst = max(worst, rel if min(abs(a), abs(b)) else 0.0)
            allowed = ATOL if min(abs(a), abs(b)) == 0.0 else RTOL * scale
            if abs(a - b) > allowed:
                mismatches.append(f"{path}: {a!r} -> {b!r} (relative {rel:.2e})")
        elif type(a) is not type(b) or a != b:
            mismatches.append(f"{path}: {a!r} -> {b!r}")
    return mismatches, worst, floats


def committed() -> Any:
    out = subprocess.run(["git", "show", f"HEAD:{REPORT}"], capture_output=True, text=True)
    if out.returncode != 0:
        print(f"error: cannot read {REPORT} at HEAD: {out.stderr.strip()}", file=sys.stderr)
        raise SystemExit(2)
    return json.loads(out.stdout)


def self_test() -> int:
    base = {"n": 13857, "crps": 16.42249384461309, "p": 1.6e-246, "zero": 0.0,
            "nan": math.nan, "label": "well dispersed", "rows": [1.0, 2.0]}

    def variant(**changes: Any) -> dict:
        return {**base, **changes}

    cases = [
        ("identical", variant(), True),
        ("last-bit drift", variant(crps=16.42249384461309 * (1 + 3.5e-15)), True),
        ("noise around zero", variant(zero=1e-17), True),
        ("NaN stays NaN", variant(nan=math.nan), True),
        ("CRPS moved 2e-6", variant(crps=16.42249384461309 * (1 + 2e-6)), False),
        ("CRPS moved in the 4th figure", variant(crps=16.43), False),
        ("tiny p-value moved 1e-3", variant(p=1.6016e-246), False),
        ("NaN became a number", variant(nan=0.5), False),
        ("integer count changed", variant(n=13858), False),
        ("int became float", variant(n=13857.0), False),
        ("string changed", variant(label="over-dispersed"), False),
        ("list grew", variant(rows=[1.0, 2.0, 3.0]), False),
        ("key removed", {k: v for k, v in base.items() if k != "crps"}, False),
    ]
    failed = 0
    for name, new, should_pass in cases:
        passed = not compare(base, new)[0]
        ok = passed == should_pass
        failed += not ok
        print(f"  {'ok  ' if ok else 'FAIL'} {name}: {'accepted' if passed else 'rejected'}")
    print(f"\n{len(cases) - failed}/{len(cases)} self-test cases behaved")
    return 1 if failed else 0


def main(argv: list[str]) -> int:
    if argv == ["--self-test"]:
        return self_test()
    if len(argv) == 2:
        old = json.loads(pathlib.Path(argv[0]).read_text())
        new = json.loads(pathlib.Path(argv[1]).read_text())
    elif not argv:
        old, new = committed(), json.loads(pathlib.Path(REPORT).read_text())
    else:
        print(__doc__.split("## Why")[0], file=sys.stderr)
        return 2

    mismatches, worst, floats = compare(old, new)
    print(f"ml report drift: {floats} float leaves, largest relative difference "
          f"{worst:.2e}, tolerance {RTOL:g} relative ({ATOL:g} absolute against an exact 0.0)")
    for line in mismatches:
        print(f"  DRIFT {line}")
    if mismatches:
        print(f"\n{len(mismatches)} leaves drifted. The committed report no longer matches "
              f"the code: regenerate it with `python -m ravon_ml.cli` and update the docs "
              f"that quote it.", file=sys.stderr)
        return 1
    print("0 drift")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
