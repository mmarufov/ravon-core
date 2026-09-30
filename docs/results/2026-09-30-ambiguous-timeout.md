# Results: payouts when the provider's reply is lost (2026-09-30)

**Simulated.** Fake provider, logical clock, real `db/ledger/schema.sql`. No real
provider or money.

| | |
|---|---|
| Pre-registration | `db/temporal_payout/PREREGISTRATION-ambiguity.md`, committed in `40cb959fb1451d46a42b46934287d934ed6ca418` (2026-09-30 12:38 -0700) before `ambiguity_matrix.py` existed |
| Code SHA measured | `73c2ddad12e0b3bd9155c2a560d77141e423bebe` (clean tree) |
| Date | 2026-09-30T19:55:16Z |
| Machine | Apple M5 Pro, macOS 27.0.1, arm64; PostgreSQL 16.15 over its Unix socket; Python 3.12.13; Temporal CLI 1.9.1 |

`LEDGER_DSN="postgresql://postgres@/postgres?host=/tmp/pgstripe&port=5455"` for every command.

## The matrix, 200 seeds

```bash
cd db/temporal_payout
python ambiguity_matrix.py --seeds 200 --check --out matrix200.md --json matrix200.json
```

Exit 0 (the pre-registered gate passed), 35 s wall. Raw counts:
`docs/results/2026-09-30-ambiguity-matrix-200.json`. Output, verbatim:

Simulated. 200 seeds per cell, TTL 10 ticks, horizon 40 ticks, status calls time out with p=0.2.

Each cell: double / orphaned / phantom / stuck, out of 200 runs. **wrong** = double or orphaned or phantom.

| fault mode | `fresh_key` | `same_key` | `fail_on_timeout` | `status_first` |
|---|---|---|---|---|
| `none` (control) | 0 / 0 / 0 / 0 (**wrong 0**) | 0 / 0 / 0 / 0 (**wrong 0**) | 0 / 0 / 0 / 0 (**wrong 0**) | 0 / 0 / 0 / 0 (**wrong 0**) |
| `commit_then_timeout` | 200 / 0 / 0 / 0 (**wrong 200**) | 0 / 0 / 0 / 0 (**wrong 0**) | 0 / 200 / 0 / 0 (**wrong 200**) | 0 / 0 / 0 / 0 (**wrong 0**) |
| `timeout_before_commit` | 0 / 0 / 0 / 0 (**wrong 0**) | 0 / 0 / 0 / 0 (**wrong 0**) | 0 / 0 / 0 / 0 (**wrong 0**) | 0 / 0 / 0 / 0 (**wrong 0**) |
| `async_pending_then_paid` | 200 / 0 / 0 / 0 (**wrong 200**) | 0 / 0 / 0 / 78 (**wrong 0**) | 0 / 200 / 0 / 0 (**wrong 200**) | 0 / 0 / 0 / 78 (**wrong 0**) |
| `async_pending_then_failed` | 0 / 0 / 0 / 0 (**wrong 0**) | 0 / 0 / 0 / 67 (**wrong 0**) | 0 / 0 / 0 / 0 (**wrong 0**) | 0 / 0 / 0 / 68 (**wrong 0**) |
| `returned_after_delay` | 0 / 0 / 0 / 0 (**wrong 0**) | 0 / 0 / 0 / 0 (**wrong 0**) | 0 / 0 / 0 / 0 (**wrong 0**) | 0 / 0 / 0 / 0 (**wrong 0**) |
| `key_expiry` | 200 / 0 / 0 / 0 (**wrong 200**) | 200 / 0 / 0 / 0 (**wrong 200**) | 0 / 200 / 0 / 0 (**wrong 200**) | 0 / 0 / 0 / 0 (**wrong 0**) |

Summed over the 6 fault modes (1200 runs per strategy):

| strategy | double | orphaned | phantom | wrong (any) | stuck |
|---|---|---|---|---|---|
| `fresh_key` | 600 | 0 | 0 | **600** | 0 |
| `same_key` | 200 | 0 | 0 | **200** | 145 |
| `fail_on_timeout` | 0 | 600 | 0 | **600** | 0 |
| `status_first` | 0 | 0 | 0 | **0** | 146 |

`ledger_verify_balances()` after all runs: 0 mismatches. Elapsed 34.9 s.

Every prediction in the pre-registration held, cell for cell. There were no
deviations from the pre-registered design.

Headline (pre-registered): wrong-money runs over the 6 fault modes, fail on
timeout (today's hand-built `resume(NULL)`) **600 of 1,200** vs status first
**0 of 1,200**. Fresh request id: 600 of 1,200. Same request id (today's
Temporal behaviour): 200 of 1,200, all of them under `key_expiry`.

The 0-or-200 cells are determined by the fault definitions. The seeds vary
amounts, delays and status timeouts (147,994 status calls across the run, each
timing out with p = 0.2); they are not a frequency estimate.

CI size: `python ambiguity_matrix.py --seeds 10 --check` gave exit 0 in 3.5 s:
wrong 30 / 10 / 30 / 0 (fresh / same / fail / status first) out of 60 each.

## Tests

```bash
cd db/temporal_payout && python -m pytest
```

44 passed in 44.59 s (17 existing + 27 in `tests/test_ambiguous_timeout.py`).

`python compare.py --repeat 1 --timeout-sensitivity 0`: exit 0, every row
identical pass/fail, 0 failures (14/14, 2/2, 15/15). The `after_begin` row's text now
names the verdict.

```bash
cd db/ledger && PYTHONPATH=tools python -m pytest tests -p no:cacheprovider -s -p pg_killcount --expect-kills 7:18
```

85 passed in 11.65 s; both kill counters report 7 of 85 tests, 18 kills. The
state machine now reports `invariant_checks=3854`, `posts=1019`,
`rejections=205` (was 3415 / 1019 / 476). Why they moved: FINDINGS §14. Changing
a single string literal in the same rule, with no change in behaviour, gave
3767 / 994 / 407, which shows the counts follow the test's code.

## Mutation checks

Each mutation was applied alone, `pytest tests/test_ambiguous_timeout.py` was
run, and the source was restored:

| mutation | result |
|---|---|
| `ledger_payout_fail` accepts a NULL verdict | 3 failed, 24 passed |
| `ledger_payout_resume` fails a pending/unknown payout as `not_found` without being told | 2 failed, 25 passed |
| provider ignores key expiry | 1 failed, 26 passed |
| resolver fails a payout on `not_found` instead of resubmitting | 1 failed, 26 passed |
| posted payout accepts `declined` | 2 failed, 25 passed |
| submit activity re-raises the timeout instead of asking status | 1 failed, 26 passed |

(An earlier attempt at the last four was invalid: my mutation helper restored an
uncommitted `provider.py` from git, so those runs failed on import. They were
redone after committing.)
