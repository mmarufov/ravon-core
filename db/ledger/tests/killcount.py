"""Count the backends this suite actually kills, per test.

"Crash injection" is only a claim if something counts the crashes. Every kill
in the suite goes through `test_crash_atomicity.kill()`, which calls `record()`
after `pg_terminate_backend(pid, 5000)` has returned true, so a kill is counted
only once PostgreSQL has confirmed the backend is gone.

The summary line is printed at the end of every run:

    KILL-TESTS 7 of 85; total kills 18

The first number is how many tests killed at least one backend, the second is
how many tests ran, the third is the total number of backends killed. Run with
`-rA` or read the lines below the summary for the per-test breakdown.

This counts calls into the harness, not log lines. An independent cross-check
is the server log: with default logging every kill writes one "terminating
connection due to administrator command" line, and the two counts should agree.
"""

from __future__ import annotations

import os
from collections import Counter

KILLS: Counter[str] = Counter()
RAN: set[str] = set()


def _current_test() -> str:
    # PYTEST_CURRENT_TEST is "path::name (call)"; strip the phase suffix.
    return os.environ.get("PYTEST_CURRENT_TEST", "<outside a test>").rsplit(" (", 1)[0]


def record() -> None:
    KILLS[_current_test()] += 1


def pytest_runtest_logreport(report) -> None:
    if report.when == "call":
        RAN.add(report.nodeid)


def pytest_terminal_summary(terminalreporter) -> None:
    killing = {n: c for n, c in KILLS.items() if c}
    terminalreporter.write_line(
        f"KILL-TESTS {len(killing)} of {len(RAN)}; total kills {sum(killing.values())}")
    for nodeid, count in sorted(killing.items()):
        terminalreporter.write_line(f"  {count:3d} {nodeid}")
