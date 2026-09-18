# Ravon double-entry ledger

A money ledger whose correctness is enforced by PostgreSQL rather than by
application code. Debits equal credits because a deferred constraint trigger
refuses to let COMMIT finish otherwise — not because a service remembered to
check.

Everything asserted below is asserted by a named test in `tests/`. The right-hand
column of each table is the test that fails if the claim stops being true.

---

## Run it

```bash
# 1. a database (Postgres 16, matching CI)
docker run --rm -e POSTGRES_PASSWORD=ledger -p 5433:5432 postgres:16

# 2. the schema and the tests
cd db/ledger
python3 -m venv .venv && .venv/bin/pip install -r tests/requirements.txt
.venv/bin/python -m pytest tests
```

The suite creates and drops its own database, so it needs a superuser connection
but leaves nothing behind. To point it somewhere else:

```bash
LEDGER_DSN=postgresql://user:pw@host:5432/postgres .venv/bin/python -m pytest tests
```

Without Docker, any Postgres 16+ works — including a throwaway cluster:

```bash
initdb -D /tmp/pg16 -U postgres --auth=trust
pg_ctl -D /tmp/pg16 -o "-p 5433" -l /tmp/pg16.log start
```

Applying the schema on its own:

```bash
psql -v ON_ERROR_STOP=1 -h 127.0.0.1 -p 5433 -U postgres -d ledger -f schema.sql
```

`ON_ERROR_STOP=1` is not optional — without it psql exits 0 after a failed
statement and you get a half-applied schema.

---

## What is in here

| File | |
|---|---|
| `schema.sql` | tables, the six invariants, `ledger_post`, the payout saga. Plain SQL, no extensions |
| `tests/` | pytest + Hypothesis, talking to a real database |
| `HANDOFF-for-kotlin.md` | the contract the Kotlin service wraps |
| `FINDINGS.md` | what surprised me, including the things that did not work |

---

## The invariants

### 1. Balanced at COMMIT

A `CREATE CONSTRAINT TRIGGER ... DEFERRABLE INITIALLY DEFERRED` on
`ledger_entries` re-checks, for each transaction touched, that
`SUM(debits) = SUM(credits)`.

Deferral is the design, not an optimisation. A double-entry posting is
unbalanced between its first leg and its last, so an immediate check would
reject every legal posting and force the balance logic back into application
code — exactly what this schema exists to avoid. Deferring it to COMMIT means
both legs insert freely and the transaction is judged as a whole.

| Claim | Test |
|---|---|
| A balanced posting commits | `test_balanced_posting_commits` |
| An unbalanced posting is rejected and leaves nothing | `test_unbalanced_posting_is_rejected` |
| The check really runs at COMMIT, not at INSERT | `test_the_check_is_deferred_to_commit_not_run_at_insert` |
| A caller can promote it to IMMEDIATE to fail earlier | `test_forcing_the_constraint_immediate_moves_the_error_earlier` |
| A transaction with no entries is not vacuously balanced | `test_transaction_with_no_entries_is_rejected` |
| It still fires for a least-privilege service role | `test_the_invariant_still_holds_for_the_service_role` |

### 2. One currency per transaction

Checked by the same deferred trigger. Currency lives on every entry row, not
only on the account, so a mixed-currency transaction is detectable from the
entries alone — including one whose minor units happen to cancel out.

| Claim | Test |
|---|---|
| Two currencies in one transaction are rejected | `test_mixed_currency_transaction_is_rejected` |
| A leg's currency must match its account's | `test_entry_currency_must_match_its_account` |

### 3. Entries are immutable

`REVOKE UPDATE, DELETE` from the application role, **and** a `BEFORE UPDATE OR
DELETE` trigger that raises unconditionally. Belt and braces, because roles get
misconfigured and triggers do not. Corrections are reversing entries.

| Claim | Test |
|---|---|
| UPDATE/DELETE fail even for the table owner | `test_history_cannot_be_mutated_even_by_the_owner` |
| The service role cannot write any ledger table | `test_service_role_cannot_write_any_ledger_table_directly` |
| Corrections work as reversing entries, and history only grows | `test_corrections_are_reversing_entries` |
| TRUNCATE bypasses the trigger — which is why it is revoked | `test_truncate_bypasses_the_row_level_trigger` |

### 4. No negative balances

Enforced by the statement-level trigger that maintains the balance cache, so an
over-refund or over-payout fails atomically with the entries that caused it.
`allow_negative` is per account: escrow, wallets and payables are hard floors at
zero; clearing and revenue accounts may legitimately go negative.

"Negative" means the *natural* balance, not the signed one. A consumer wallet is
a liability funded by credits, so a healthy wallet has a negative signed balance.

| Claim | Test |
|---|---|
| Over-refunding an order is rejected | `test_over_refund_is_rejected` |
| Refunding exactly the balance is allowed | `test_refund_of_exactly_the_balance_is_allowed` |
| Over-paying a courier is rejected | `test_a_payout_larger_than_the_balance_is_refused` |
| `allow_negative` accounts really may go negative | `test_allow_negative_accounts_may_go_negative` |
| The check uses the natural sign, not the signed sum | `test_negative_balance_check_uses_the_natural_sign` |
| A posting that dips and recovers within itself is fine | `test_a_posting_that_dips_and_recovers_within_itself_is_allowed` |

### 5. The cache equals the truth

`ledger_verify_balances()` returns one row per account whose cached balance
disagrees with the sum of its entries. Empty means consistent. The tests call it
after every operation; in production it belongs in a scheduled job.

| Claim | Test |
|---|---|
| It is empty after normal use | `test_verify_balances_is_clean_after_normal_use` |
| It actually detects a deliberately corrupted cache | `test_verify_balances_actually_detects_a_corrupted_cache` |
| The cache cannot be written around | `test_balance_cache_cannot_be_written_around` |

The second row matters more than the first: without it, the function could
return nothing at all and every other test would still pass.

### 6. Idempotent posting

`ledger_post(idempotency_key, fingerprint, …)` implements DoorDash's published
contract: same key and same fingerprint replays the original transaction; same
key with a different fingerprint is a 409. Concurrent callers serialise via
`INSERT ... ON CONFLICT DO NOTHING` followed by `SELECT ... FOR UPDATE`.

| Claim | Test |
|---|---|
| Replay returns the original transaction | `test_replay_with_same_fingerprint_returns_the_original` |
| Replay moves no money, however many times | `test_replay_is_a_no_op_not_a_second_posting` |
| A different body under the same key is a 409 | `test_same_key_different_fingerprint_is_a_409` |
| Eight concurrent identical posts write exactly once | `test_concurrent_identical_posts_write_exactly_once` |
| Concurrent conflicting posts: one wins, the rest get 409 | `test_concurrent_posts_with_conflicting_fingerprints` |
| A loser blocks until the winner commits, then replays it | `test_the_loser_blocks_until_the_winner_commits` |
| If the winner aborts, the key is free again | `test_a_losers_replay_survives_the_winner_rolling_back` |

---

## Integer money

Minor units in `BIGINT`, currency on every row, `CHECK (amount_minor > 0)` with
direction carrying the sign. There is no `float`, `double precision`, `numeric`
or `money` column anywhere in the schema, and
`test_no_floating_point_columns_anywhere` fails if one appears.

Fee splitting is integer too. `ledger_split_minor(total, bps[])` returns one
share per weight plus a trailing remainder; the remainder posts to
`platform_rounding`.

| Claim | Test |
|---|---|
| A split always sums back to the original (property test) | `test_a_split_always_sums_back_to_the_original` |
| The remainder is exactly what flooring lost | `test_the_remainder_is_exactly_what_flooring_lost` |
| Settling an order conserves every minor unit (property test) | `test_settling_an_order_conserves_every_minor_unit` |
| Omitting the remainder makes the posting fail by exactly that much | `test_the_remainder_really_does_land_in_rounding` |
| Weights must sum to 100% | `test_weights_must_sum_to_one_hundred_percent` |

---

## Randomised operations

`tests/test_stateful.py` is a Hypothesis `RuleBasedStateMachine`. It drives the
ledger through arbitrary interleavings of open account · authorize · capture ·
tip · promo credit · wallet spend · adjust · partial refund · full refund ·
chargeback · chargeback reversal · settle · courier payout · payout failure ·
payout reversal · replay-any-prior-operation, plus three operations that **must**
be rejected (over-refund, overdrawn payable, unbalanced posting).

The oracle is a plain `dict[account_id, int]`. Every rule applies its effect to
both PostgreSQL and the dict. After **every** rule, six things are re-checked in
one query:

* global conservation — `SUM(signed)` over all entries is 0
* every transaction sums to zero
* no transaction spans two currencies
* `ledger_verify_balances()` is empty
* every cached balance equals the model
* per order, `refunded ≤ captured`

A representative run: **3,415 invariant checks, 1,019 postings, 476 rejected
operations across 166 examples.** The test asserts floors on those counters,
because a stateful suite whose bundles never fill still passes, and passing for
that reason is worse than failing — see FINDINGS §3.

`tests/test_order_lifecycle.py` complements it: one order walked through every
operation with exact expected balances, so the rare operations are covered on
every run rather than when Hypothesis feels like it.

---

## Crash injection

Not `ROLLBACK`. The crash tests call `pg_terminate_backend()` on their own
connection, so the database sees what it would see if the machine lost power
mid-posting.

**Transaction atomicity** — kill a backend after the first leg and before the
second:

| Claim | Test |
|---|---|
| No partial posting survives; the transaction is simply absent | `test_a_crash_between_the_two_legs_leaves_no_partial_posting` |
| The deferred trigger never fired | same test, via `ledger_deferred_check_count()` |
| …and that counter is not vacuous | `test_the_fire_counter_is_not_vacuous` |
| A complete-but-uncommitted posting is lost too | `test_a_crash_after_a_complete_valid_posting_still_loses_it` |
| The balance cache is exactly where it was | `test_a_crash_leaves_the_balance_cache_exactly_where_it_was` |
| A crashed attempt frees its own idempotency key | `test_a_crash_frees_the_idempotency_key_it_had_claimed` |
| Crashing at any point in a run of postings loses only the last | `test_crashing_at_any_point_in_a_run_of_postings_loses_only_the_last` |

"The deferred trigger never fired" is observable because the trigger bumps a
**sequence**, and `nextval()` is not transactional — it survives rollback. Without
that, the evidence would roll back along with everything else and there would be
no way to tell "never ran" from "ran and left no trace".

**Saga resumability** — a payout is create pending → call provider → mark
submitted → post entries. The backend is killed at *every* boundary, the resume
path runs, and the result must always be exactly one ledger effect:

`test_payout_survives_a_crash_at_every_step_boundary` is parametrised over
`during_begin`, `after_begin`, `after_provider_call`, `after_mark_submitted`,
`during_post`, `after_post`, and a no-crash control.

---

## Reproducibility and runtime

Hypothesis runs with `derandomize=True`, so a given commit explores the same
sequences on every machine and a CI failure reproduces locally with nothing to
copy across — the equivalent of the SplitMix64 seeding the Swift property tests
in this repo use. `print_blob=True` means a failure also prints a
`@reproduce_failure` blob that replays the exact failing case.

There is deliberately no seed environment variable: Hypothesis exposes no seed
argument on `run_state_machine_as_test`, so such a knob could only have turned
`derandomize` *off*, making runs less reproducible while appearing to do the
opposite. The two dials below are the real ones.

Runtime dials, and the trade-off:

| Variable | Default | Effect |
|---|---|---|
| `LEDGER_MAX_EXAMPLES` | 120 (CI uses 100) | linear in wall-clock; more interleavings explored |
| `LEDGER_STEP_COUNT` | 40 | longer sequences reach deeper states — settlement after several refunds, say — but each example costs proportionally more |
| `HYPOTHESIS_PROFILE` | `ci` | `dev` turns off `derandomize` and keeps a local example database, so repeated runs explore new ground and remember past failures |

Measured: the full suite (85 tests) runs in **~11 s against PostgreSQL 16** with
CI settings on an M-series laptop. The `ledger-invariants` CI job is sized to stay well under a
minute; `LEDGER_MAX_EXAMPLES=100` is the dial to turn if it stops doing so. The
honest trade-off is that the state machine finds interleaving bugs in proportion
to how long it is allowed to run, and a one-minute budget is a compromise, not a
proof.

---

## Not in scope

No payment-processor integration, no real money movement, no Kotlin, and no
`SECURITY DEFINER` RPC exposed to iOS clients. The ledger is reached only through
the service tier — `test_untrusted_client_role_cannot_execute_the_posting_api`
and `test_no_ledger_function_is_executable_by_public` fail if that ever stops
being true.
