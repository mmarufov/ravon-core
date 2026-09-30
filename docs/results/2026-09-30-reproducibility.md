# Results: README, kill count, libm, Temporal CI (2026-09-30)

Every number below was produced by the command next to it, on the tree named
here. Nothing was typed in by hand.

| | |
|---|---|
| Code SHA | `8ebc63fb107d64df35df59474a8582e12bf05967` (clean tree) |
| Date | 2026-09-30T19:35:04Z |
| Machine | Apple M5 Pro, macOS 27.0.1, arm64 |
| PostgreSQL | 16.15 (Homebrew), local throwaway cluster on port 5455 |
| Python | 3.12.13; psycopg 3.3.6, pytest 9.1.1, hypothesis 6.168.3, temporalio 1.33.0 |
| JDK | OpenJDK 25.0.2 |
| Temporal CLI | 1.9.1 (Server 1.32.0) |

`LEDGER_DSN=postgresql://postgres@127.0.0.1:5455/postgres` for every Python command.

## Ledger suite and kill count

```bash
cd db/ledger
PYTHONPATH=tools python -m pytest tests -p no:cacheprovider -s \
    -p pg_killcount --kill-report --expect-kills 7:18
```

| measurement | value |
|---|---|
| tests | 85 passed in 11.38 s |
| state machine, default settings (derandomised) | `invariant_checks=3415`, `posts=1019`, `rejections=476` |
| tests that kill a PostgreSQL backend | **7 of 85**, by both counters: `KILL-TESTS 7 of 85; total kills 18` (harness side, `tests/killcount.py`) and `pg-killcount: 7 of 85 tests killed a backend; 18 kills in total` (server side, `tools/pg_killcount.py`) |
| backends killed | **18** (5 atomicity tests: 1+1+1+1+12; 2 saga points: `during_begin`, `during_post`) |

The server-side count is read from `pg_stat_database.sessions_killed`, not
from the test code, so it is independent of the harness counter. The other five saga "crash points" stop the driver and kill nothing.

```bash
LEDGER_MAX_EXAMPLES=100 HYPOTHESIS_PROFILE=ci python -m pytest tests -p no:cacheprovider   # x3
```

85 passed in 10.64 s, 10.34 s, 10.64 s. All 15 full-suite runs on this machine
today (both settings, 18b41ad and 8ebc63f, same test code) ranged 10.34 s to
13.87 s with a median of 11.97 s. Hence "~12 s" in `db/ledger/README.md`.

Kill counter self-test, including the negative controls (a normal disconnect
counts 0; a wrong `--expect-kills` fails the session):

```bash
PYTHONPATH=tools python -m pytest tools -p pytester -p no:cacheprovider
```

3 passed in 1.46 s. Mutation check (run on 18b41ad, before the module was
renamed from `killcount` to `pg_killcount`): with `sessions_killed()` forced to
return 0, the same command gives 3 failed.

## libm disagreement (Kotlin)

```bash
cd services
./gradlew :dispatch:test --tests 'dev.ravon.dispatch.LibmDisagreementTest' --rerun-tasks --no-daemon -i
```

600 bearings from `SwiftRandom(1)`, drawn as `MarketplaceSimulator.randomPoint`
draws them (a radial draw, then the bearing), compared bitwise against the
platform libm:

| implementation | disagreeing inputs |
|---|---|
| `Math.sin` or `Math.cos` | 122 / 600 = **20.3%** |
| `Math.sin` alone | 69 / 600 = 11.5% |
| `StrictMath.sin` or `StrictMath.cos` | 54 / 600 = 9.0% |

Drawing 600 consecutive bearings with no radial draw gives 111 / 65 / 52
instead (18.5% / 10.8% / 8.7%); the first version of the test did that and
failed, which is how the draw order was found.

Negative controls in the same test class: libm against itself gives 0; a
one-ULP perturbation (`Math.nextUp`) is caught on 600 of 600.

The 109 on seed 1, re-measured by editing the source, running
`./gradlew :dispatch:test --tests 'dev.ravon.dispatch.DispatchBaselineTest'`,
and restoring the source:

| change | result |
|---|---|
| `EPOCH_SECONDS` set to the Unix value 1,700,000,000 | 435 mismatches, first `seed 1 / greedy ordersAssigned: expected 110, got 109` |
| `Libm` sin/cos/log/atan2 routed through `java.lang.Math` | 91 mismatches, seed 1 untouched, `ordersAssigned` off by one on seeds 4, 6, 9 |
| the same through `StrictMath` | 87 mismatches, same seeds |

So the 109 is the epoch bug, not libm. `Libm.kt` and `DispatchClock.kt` now
say so.

Kotlin suite: `./gradlew :dispatch:test :server:test --no-daemon` gives 39
tests, 0 failed (36 before, plus the 3 in `LibmDisagreementTest`).

All of this is macOS libm. Linux glibc is not measured.

## Temporal payout suite and crash matrix

```bash
cd db/temporal_payout
python -m pytest                    # 17 passed in 42.31 s, 43 s wall
python compare.py --repeat 1        # exit 0, 72 s wall
```

compare.py: every row identical pass/fail, 0 failures; `test_payout_saga.py`
14/14, hand-built worker points 2/2, Temporal 15/15. The 7 shared crash
points: hand-built 0.73 s, Temporal 16.41 s.

These two steps are the `temporal-payout` CI job, about 115 s locally
(43 s + 72 s).

## Follow-ups on the same day

**CI on 8ebc63f** (run 36767085492): all 10 jobs green, including
`LibmDisagreementTest` on `macos-15` and the new `temporal-payout` job. That
job's two test steps took 46 s (pytest) and 82 s (`compare.py --repeat 1`),
3 min 1 s for the whole job including container start. To bring the matrix step
down, CI now passes `--timeout-sensitivity 0`, which skips the extra Temporal
run at a 1 s activity timeout. Locally that made `compare.py --repeat 1` 47 s
instead of 72 s (exit 0, same matrix, 0 failures).

**A bug in `pg_killcount` found by a stale database.** After a run aborted by
macOS ephemeral-port exhaustion ("Can't assign requested address", a local TCP
problem, not a test failure), the next run reported `7 of 85 tests killed a
backend; 0 kills in total`. The aborted run had left `ravon_ledger_test` behind
holding 18 kills. The counter read "before" ahead of fixture setup, and the
session fixture then dropped and recreated that database, resetting its
statistics row, so the first test came out at -17. The fix reads "before" after
fixture setup. `test_a_stale_database_from_an_earlier_run_does_not_leak_into_the_count`
pre-seeds 5 kills into the scratch database and recreates it in a session
fixture. With the fix: 4 passed. With the old ordering: 1 failed, 3 passed.
Local runs from here on use the Unix socket
(`postgresql://postgres@/postgres?host=/tmp/pgstripe&port=5455`) to avoid the
port exhaustion.
