# Findings

Things that surprised me while building this, including the ones where I was
wrong. Negative results are kept rather than tidied away.

---

## 1. A deferred constraint trigger runs as the *session* user, not as the function that caused it

`ledger_post` is `SECURITY DEFINER`, so everything it does runs with the owner's
privileges. I assumed that covered the triggers it fires. It does — for the
immediate ones.

It does not for the deferred one, because a `DEFERRABLE INITIALLY DEFERRED`
constraint trigger fires at **COMMIT**, which is outside the function's execution
context entirely. It runs as whoever owns the session.

The symptom was that the least-privilege application role could not post at all:

```
ERROR:  permission denied for sequence ledger_deferred_check_seq
```

Fail-closed, so not a soundness hole — an unbalanced transaction still could not
commit. But it made the ledger unusable by the exact role it was designed for,
and the error named a diagnostic sequence rather than anything to do with
balance, so the cause was not obvious from the message.

The fix was to make the four trigger functions `SECURITY DEFINER` as well. That
turns out to be the better posture anyway: the invariant now runs with the
owner's privileges no matter who is committing, so **it cannot be disabled by
taking privileges away from the caller**.

`test_the_invariant_still_holds_for_the_service_role` is the regression test —
it posts an unbalanced transaction *as the service role* and requires
`UNBALANCED_TRANSACTION` rather than a permission error.

## 2. Fixing that introduced a security bug, and a test caught it rather than review

PostgreSQL grants `EXECUTE` on new functions to `PUBLIC` by default. Adding
`SECURITY DEFINER` to five functions in §1 therefore handed `PUBLIC` the right to
execute five `SECURITY DEFINER` functions — the exact finding shape CLAUDE.md
records from this project's earlier security reports.

For the four trigger functions the practical blast radius was nil, because
PostgreSQL refuses to call a trigger function directly. But
`ledger_deferred_check_count()` and `ledger_verify_balances()` are ordinary
functions, and the latter returns account ids and balances. Any role in the
database could have read it.

What is worth recording is *how* it was caught. I did not write a test for
"`ledger_apply_balance_delta` is not PUBLIC-executable" — I would never have
thought to. `test_no_ledger_function_is_executable_by_public` asserts the
**class**: no `SECURITY DEFINER` function in the schema is executable by
`PUBLIC`, discovered by querying `pg_proc`. It failed the moment the five
functions changed, naming them. `test_every_security_definer_function_pins_its_search_path`
is the same pattern for the other classic `SECURITY DEFINER` mistake.

Class-level tests over the catalog catch the thing you forgot. Instance-level
tests only catch the thing you remembered.

## 3. The state machine spent its first runs doing almost nothing, and passed

The first working version of `test_stateful.py` passed in 0.8 seconds. That
should have been suspicious and initially wasn't.

Measured, **18 of 32 examples produced zero ledger entries**. The cause: the
`authorize` rule draws from three bundles (consumer, merchant, courier), all of
which start empty, so nothing could happen until Hypothesis drew all three
opener rules first. Short sequences almost never did.

`@initialize` fixed that half. The other half was worse. **Hypothesis does not
weight rules** — it picks among applicable ones, and rules that consume fewer
random bits get picked far more often. Instrumenting every rule with a counter
showed a wildly skewed distribution:

```
rule:open_consumer=136    rule:chargeback=0
rule:attempt_to_overdraw_a_payable=67    rule:courier_payout=0
rule:authorize=11                        rule:replay_a_prior_operation=0
```

30% of all steps went to opening consumers. Three rules never fired once in 460
steps. The suite was green the entire time.

Two fixes: cap the cheap rules with `@precondition` on a per-run counter so their
probability mass moves elsewhere, and cap `authorize` too — it was creating
orders faster than the other rules could operate on them (212 authorizes against
38 captures, so refunds, which need a capture, almost never ran). After both:

```
3,415 invariant checks · 1,019 postings · 476 rejected operations · every rule fired
```

The lasting lesson is in `WORK` and the floor assertions at the bottom of
`test_stateful.py`. **A stateful property suite that degenerates into no-op runs
still passes, and passing for that reason is worse than failing**, because it
reports confidence it has not earned. The counters are now part of the test.

`test_order_lifecycle.py` exists for the same reason from the other direction:
the rarest operations are covered deterministically, so coverage does not depend
on Hypothesis's mood.

## 4. TRUNCATE does not fire row-level DELETE triggers

The immutability trigger on `ledger_entries` does not protect against `TRUNCATE`.
Row-level triggers simply do not fire for it. The only thing standing between a
misconfigured role and an erased ledger is the explicit `REVOKE TRUNCATE`.

This is documented PostgreSQL behaviour, not a bug, but it undercuts the "belt
and braces" framing: for `TRUNCATE` there is only the belt. I kept it as a test
(`test_truncate_bypasses_the_row_level_trigger`) rather than a comment, so that
if PostgreSQL ever changes it, the test fails and the `REVOKE` can be relaxed.

Same reasoning applies to the test harness, which uses `TRUNCATE` to reset
between examples — precisely because the immutability trigger would block
`DELETE`.

## 5. Deferred triggers fire in the order their events were queued

A transaction with exactly one entry raises `DEGENERATE_TRANSACTION` (fewer than
two entries), not `UNBALANCED_TRANSACTION`, even though it is also unbalanced.
Both checks are deferred, and the `ledger_transactions` row was inserted before
the `ledger_entries` row, so its event is first in the queue.

This cost me a confused half hour writing a test that asserted the wrong error.
The test now uses two unbalanced legs and says why in a comment.

## 6. `ledger_post` returning successfully does not mean the posting was valid

The direct consequence of deferral, and the thing most likely to trip up the
Kotlin service. The function returns a transaction id happily; `COMMIT` is where
`UNBALANCED_TRANSACTION` is raised.

That is not a wart — it is what makes the two-leg insert possible at all — but it
inverts the usual assumption that a DAO call returning means the write is good.
It is called out prominently in `HANDOFF-for-kotlin.md` §3, along with the
`SET CONSTRAINTS ... IMMEDIATE` escape hatch for callers who would rather fail
early.

## 7. Proving a trigger did *not* fire needs a non-transactional side channel

"The deferred check never ran" is central to the crash-atomicity claim, and it is
not directly observable: after killing a backend mid-transaction, everything the
transaction touched is gone — including any evidence the trigger might have left
in a table.

The way out is that **`nextval()` is not transactional**. It survives rollback.
The trigger bumps `ledger_deferred_check_seq`, and the crash tests compare the
counter across the aborted transaction: unchanged means it never ran.

Two things worth noting. First, this only works because the counter is *not*
rolled back, which is normally the annoying property of sequences. Second, an
assertion that a counter did not move is worthless if the counter never moves at
all, so `test_the_fire_counter_is_not_vacuous` commits a real posting and
requires the counter to advance by exactly one per inserted row.

## 8. PostgreSQL does not promise left-to-right evaluation of an `OR` chain

The entry-validation predicate in `ledger_post` originally read:

```sql
WHERE ... OR (e->>'amount_minor') !~ '^[0-9]+$'
      OR (e->>'amount_minor')::bigint <= 0
```

with the regex intended to guard the cast. The planner is free to evaluate those
in either order, so `{"amount_minor": "abc"}` could raise a raw `22P02` instead
of the structured `INVALID_ENTRY` — an error the service has no case for, from a
predicate written specifically to produce one it does.

The validation is now entirely cast-free: everything is checked as text by
regex, including the uuid shape and a length bound that keeps the value inside
`bigint`. `test_malformed_entries_are_structured_errors_not_cast_failures`
covers six shapes of junk.

## 9. "Refunded ≤ captured" is only half enforced by the database, and I could not close the gap cheaply

The database structurally guarantees that **outflows for an order never exceed
inflows for that order**: everything the order receives is credited to a
per-order `order_escrow` account with `allow_negative = false`, and refunds
debit it. Over-refunding is therefore impossible in the strong sense — no code
path, no privilege level.

It does *not* guarantee the narrower "you cannot refund more than you captured",
because escrow is funded at authorization rather than at capture. An order that
was authorized and never captured could, as far as the schema is concerned, be
refunded.

Making that structural needs the refund path to draw from an account funded only
by captures — a per-order clearing account, doubling the account count per order,
or a global clearing account with `allow_negative = false`, which is wrong
because a real clearing account does legitimately go negative between payout and
settlement.

I left it as service policy, and the state machine asserts it holds across every
interleaving it generates (`per_order` in the invariant query,
`test_refunded_never_exceeds_captured_for_the_order` as a readable version). But
it is an assertion about the harness's behaviour as much as the schema's, and it
would be dishonest to list it next to the invariants that are genuinely
unbypassable.

## 10. `ON CONFLICT DO NOTHING` blocks on a concurrent uncommitted row

This is what makes the idempotency race work, and it is easy to assume the
opposite. When a second caller inserts a duplicate key while the first
transaction is still open, `ON CONFLICT DO NOTHING` does not skip immediately —
it waits for the first transaction to finish, then re-checks. If the first
committed, the second sees no row returned and finds the committed transaction;
if the first aborted, the second's insert succeeds.

Both branches are tested (`test_the_loser_blocks_until_the_winner_commits`,
`test_a_losers_replay_survives_the_winner_rolling_back`), including asserting
that the loser really is *blocked* rather than merely slow.

The catch: this reasoning depends on READ COMMITTED. At REPEATABLE READ the
winner's committed row is invisible to the loser's snapshot even though the
unique index rejected the insert, leaving a state that looks impossible. That
branch raises `IDEMPOTENCY_RACE_RETRY` rather than pretending it cannot happen.

## 11. The cache-consistency function would have been vacuously true

`ledger_balances` is maintained by a trigger on `ledger_entries`, so entries
cannot be written around it, so `ledger_verify_balances()` can never find a
mismatch through any normal path. Every test calling it after every operation
proves nothing about the function — an implementation of `SELECT` over an empty
set would pass all of them.

`test_verify_balances_actually_detects_a_corrupted_cache` corrupts the cache by
exactly 7 minor units and requires the function to name the account and the
drift. Without it, invariant 5 is untested.

## 12. Cost of the design, honestly

* The balance trigger is `FOR EACH STATEMENT` with a transition table, so a
  posting costs one extra aggregate and one upsert regardless of leg count.
  Cheap.
* The deferred balance trigger is `FOR EACH ROW` — constraint triggers must be —
  so an N-leg posting re-runs the same `SUM ... GROUP BY transaction_id`
  aggregate N times at commit. For the 2–7 leg postings here that is cheaper
  than the bookkeeping needed to deduplicate, but it is O(N²) in legs and would
  need revisiting for a posting with hundreds of legs (a bulk payout run, say).
* `ledger_post` does two validation passes over the jsonb before touching a
  table. Deliberate: a structured 422 is worth more than the microseconds.

## 13. Versions

Developed against PostgreSQL 17.10 and verified against **PostgreSQL 16.15**,
which is what CI runs. `schema.sql` applies clean and the whole suite passes on
both.
Nothing in the schema needs anything newer than PostgreSQL 14 (`pg_terminate_backend`
with a timeout, used only by the crash tests, is the highest floor;
`gen_random_uuid()` needs 13, transition tables need 10).
