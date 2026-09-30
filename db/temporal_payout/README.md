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
`compare.py --repeat 1`, which exits non-zero if any row of the matrix fails.

## What is in here

| File | |
|---|---|
| `workflow.py` | the saga's step order. There is no resume function |
| `activities.py` | one activity per step, each a single call into `ledger_api.Ledger` |
| `worker.py` | the long-running process the hand-built version does not have |
| `provider.py` | a fake payout provider, idempotent on `request_id`, in its own database |
| `faults.py` | crash injection inside the worker: SIGKILL, SIGSTOP, or kill the PG backend |
| `tests/` | the seven hand-built crash points plus the worker-only ones |
| `compare.py` | runs both suites, prints the matrix, lines of code, dependencies, surface |

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
ledger key. Swap the post activity for one that uses a per-attempt key and
`worker_kill_mid_post` and the zombie test both fail with two ledger transactions.
