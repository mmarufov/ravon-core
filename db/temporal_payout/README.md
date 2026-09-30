# The payout saga, a second time, on Temporal

A comparison, not a migration. `db/ledger/` is untouched: same `schema.sql`, same
`ledger_api.py`, same idempotency key. This directory adds a Temporal workflow that drives
the same four SQL steps, and a harness that runs both implementations through one crash
matrix.

```
create pending  ->  call the provider  ->  mark submitted  ->  post entries
```

## Run it

```bash
# PostgreSQL on 5433, as in db/ledger/README.md, and the Temporal CLI
brew install temporal

cd db/temporal_payout
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
.venv/bin/python -m pytest              # Temporal side, starts its own dev server on :7239
.venv/bin/python compare.py --repeat 3  # both sides, one table
```

Everything runs against a local `temporal server start-dev`. Nothing here has been run
against a production Temporal cluster. CI does the same on every push: the
`temporal-payout` job installs Temporal CLI 1.9.1, runs this pytest suite, and runs
`compare.py --repeat 1 --timeout-sensitivity 0`, which exits non-zero if any row of
the matrix fails.

## What is in here

| File | |
|---|---|
| `workflow.py` | the saga's step order. There is no resume function |
| `activities.py` | one activity per step, each a single call into `ledger_api.Ledger` |
| `worker.py` | the long-running process the hand-built version does not have |
| `provider.py` | a fake payout provider in its own database: an idempotency-key cache with an optional TTL, permanent payout records, `status(request_id)`, and the lost-reply fault modes |
| `faults.py` | crash injection inside the worker: SIGKILL, SIGSTOP, or kill the PG backend |
| `tests/` | the seven hand-built crash points plus the worker-only ones |
| `compare.py` | runs both suites, prints the matrix, lines of code, dependencies, surface |
| `resolver.py` | the status-first recovery sweeper the hand-built saga lacked |
| `ambiguity_matrix.py` | 4 strategies for a lost provider reply x 6 fault modes, simulated. Design fixed in `PREREGISTRATION-ambiguity.md` |

## How the crash points map

| Hand-built | Temporal |
|---|---|
| `during_begin`, `during_post`: kill the PostgreSQL backend before COMMIT | the same kill, inside the activity |
| `after_begin`, `after_provider_call`, `after_mark_submitted`: the driver stops | SIGKILL the worker at the next activity's entry, after the previous step is in history |
| `after_post`: resume three more times | submit the same workflow id three more times |
| `never` | `never` |
| (no worker) | SIGKILL the worker after a step's COMMIT, before Temporal is told, once per step |
| stale resumer posts after another finished | SIGSTOP a worker at `post`, let a second worker finish, SIGCONT |

## The result in one line

Every step that commits and then loses its worker runs again. Temporal cannot prevent
that, so each activity is safe to repeat only because of something in PostgreSQL:
`ON CONFLICT (request_id)`, the idempotent state transitions, and the `'payout:' || id`
ledger key. A per-attempt key breaks that: `test_negative_control_a_per_attempt_ledger_key_posts_twice`
posts the same payout under `payout:<id>:attempt:<n>` twice and gets two ledger
transactions, where `payout:<id>` replays. That control runs against the ledger directly.
Nobody has run the Temporal `worker_kill_mid_post` and zombie tests with a per-attempt key
swapped into the activity, so "those two would fail" is an inference from it, not a
measurement.

## When the provider's reply is lost

Everything above is about the platform's own process dying. The harder case is
the provider's reply going missing: the request timed out, and the money may
have moved, may be pending, or may never have been seen. Both "retry" and "give
up" can be wrong there, and until this section neither implementation modelled
it. The hand-built `resume(NULL)` failed the payout on the assumption that no ref
meant "never received". Temporal retried the same request id forever, which is
safe only because the fake provider never forgot a key.

**What changed**

- `db/ledger/schema.sql`: a payout state `unknown`, and a verdict type
  `declined | not_found | returned`. `ledger_payout_fail` requires a verdict, and
  a CHECK makes a failed row without one impossible. A posted payout only fails
  as `returned`, which posts the reversal. `ledger_payout_resume` refuses to fail
  a `pending` or `unknown` payout without a ref or a verdict
  (`PAYOUT_VERDICT_REQUIRED`). A timeout is not a verdict, so "fail on a guess"
  cannot be expressed without writing the guess down.
- `activities.py`: on a timeout the submit activity marks the payout `unknown`,
  asks `status(request_id)`, and branches. `paid` goes on to post, `pending` is
  polled by the workflow, `failed` fails with the provider's verdict, and
  `not_found` is resubmitted under the same request id.
- `resolver.py`: the same decision for the hand-built saga, as a sweeper. With
  it, the `after_begin` row resolves to posted (asks, hears `not_found`,
  resubmits) instead of failed.

**The matrix (simulated).** Four strategies for the timeout, six fault modes
plus a control, 200 seeds, paired across strategies. Provider key TTL is 10 ticks,
the horizon is 40 ticks, and every status call times out with p = 0.2. The
design, including predictions, was committed in 40cb959 before
`ambiguity_matrix.py` existed.

```bash
python ambiguity_matrix.py --seeds 200 --check    # 35 s; CI runs --seeds 10 --check
```

Each cell: double / orphaned / phantom / stuck, out of 200.

| fault mode | fresh request id | same request id | fail on timeout | status first |
|---|---|---|---|---|
| none (control) | 0 / 0 / 0 / 0 | 0 / 0 / 0 / 0 | 0 / 0 / 0 / 0 | 0 / 0 / 0 / 0 |
| commit, then timeout | **200** / 0 / 0 / 0 | 0 / 0 / 0 / 0 | 0 / **200** / 0 / 0 | 0 / 0 / 0 / 0 |
| timeout before commit | 0 / 0 / 0 / 0 | 0 / 0 / 0 / 0 | 0 / 0 / 0 / 0 | 0 / 0 / 0 / 0 |
| pending, later paid | **200** / 0 / 0 / 0 | 0 / 0 / 0 / 78 | 0 / **200** / 0 / 0 | 0 / 0 / 0 / 78 |
| pending, later failed | 0 / 0 / 0 / 0 | 0 / 0 / 0 / 67 | 0 / 0 / 0 / 0 | 0 / 0 / 0 / 68 |
| returned after a delay | 0 / 0 / 0 / 0 | 0 / 0 / 0 / 0 | 0 / 0 / 0 / 0 | 0 / 0 / 0 / 0 |
| key expired before the retry | **200** / 0 / 0 / 0 | **200** / 0 / 0 / 0 | 0 / **200** / 0 / 0 | 0 / 0 / 0 / 0 |
| **wrong money, all 6 modes** | **600 / 1,200** | **200 / 1,200** | **600 / 1,200** | **0 / 1,200** |

*double*: the provider paid 2 or more times. *orphaned*: the provider paid, and
the ledger says failed. *phantom*: the ledger says posted, and the provider paid
nothing (0 everywhere). *stuck*: not terminal at the horizon.

**How to read it**

- **A same-key retry is safe while the provider still holds the key.** It was 0
  wrong in five of six modes. It pays twice only when the retry comes after the
  key has expired, and there it paid twice in all 200 runs. Stripe keeps
  idempotency keys for at least 24 hours, so this is about retries after long
  outages or backlogs, not about ordinary retries.
- **Status first was 0 wrong in all 1,200 runs.** It pays for that with
  **stuck** payouts: 146, all in the two pending modes, where the provider had not
  decided by the horizon. Those payouts are `submitted`: the ledger has not
  recorded the money as paid, nobody was paid twice, and the next sweep picks
  them up. A same-key retry
  is stuck in the same runs, for the same reason.
- **The wrong-money cells are 0 or 200, never in between.** Given the fault
  definitions, the outcome of each strategy in each mode is decided by
  construction. The seeds vary the amounts, the delays and the status timeouts
  (147,994 status calls in total, each timing out with p = 0.2), and they show the
  result does not depend on them. They are not a sample of real-world failure
  frequencies. This table states where each strategy fails, and CI keeps it
  true. It does not estimate how often it happens.
- **What status first assumes and cannot check.** `status()` reads records
  that outlive the idempotency key, and a request reported `not_found` can no
  longer land. The fake provider makes both true. A real provider has to offer a
  lookup by client reference, and the resolver only sweeps payouts older than
  the provider's request deadline.

**Not modelled:** a provider that declines a retry although the first attempt
paid, webhooks, more than one payout in flight per
courier, and a status endpoint that is itself wrong.

Tests: `tests/test_ambiguous_timeout.py`, 27 tests, including two negative
controls. A fresh request id per attempt must come out double under the same
detector, and a per-attempt ledger key must post twice. Six deliberate
mutations were each caught by at least one test: fail accepting a null verdict,
resume guessing `not_found`, a provider that never expires keys, a resolver
that fails on `not_found`, a posted payout accepting `declined`, and an activity
that retries blind on a timeout. Numbers, commands and SHAs:
`docs/results/2026-09-30-ambiguous-timeout.md`.

