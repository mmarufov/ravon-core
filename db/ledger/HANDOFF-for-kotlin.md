# Handoff: wrapping the ledger from the Kotlin service

This is the contract the ledger presents to the service tier. Phase 2 of the
Kotlin extraction wraps *this*; it does not reimplement it.

**The one rule:** the service calls `ledger_post(...)`. It never writes
`ledger_entries`, `ledger_transactions` or `ledger_balances` directly. Not
because that would be impolite — because the application role has no privilege
to do it, and an immutability trigger rejects it even if the role were
misconfigured. The whole value of putting the balance invariant in PostgreSQL is
that no service bug can bypass it, and a service that writes entries directly
throws that away.

---

## 1. Schema

Apply `db/ledger/schema.sql` to the database as a migration, as the owner role.
It is idempotent in the roles it creates but not in the objects it creates, so
it runs once.

| Table | Purpose |
|---|---|
| `ledger_accounts` | `id`, `kind`, `owner_id` (null for platform accounts), `currency CHAR(3)`, `allow_negative` |
| `ledger_transactions` | `id`, `business_event_type`, `business_event_id`, `idempotency_key UNIQUE`, `request_fingerprint`, `created_at` |
| `ledger_entries` | `id`, `transaction_id`, `account_id`, `direction` (`debit`/`credit`), `amount_minor BIGINT > 0`, `currency CHAR(3)`, `created_at` |
| `ledger_balances` | `account_id PK`, `balance_minor BIGINT` — a cache, maintained by trigger inside the same transaction as the entries |
| `ledger_payouts` | saga journal; see §6 |

`ledger_account_kind` values: `consumer_wallet`, `merchant_payable`,
`courier_payable`, `order_escrow`, `platform_revenue`, `platform_rounding`,
`promo_expense`, `chargeback_loss`, `psp_clearing`, `order_receivable`.

### Signed vs natural balances

`ledger_balances.balance_minor` uses one uniform convention: **debit positive,
credit negative**. That is what makes `SUM(signed)` over the whole ledger exactly
zero.

It is *not* what you show a user. A consumer wallet is a liability funded by
credits, so a wallet with 25.00 in it has `balance_minor = -2500`. Multiply by
`ledger_normal_sign(kind)` to get the natural balance, or read the
`ledger_account_balances` view, which has both:

```sql
SELECT natural_minor FROM ledger_account_balances WHERE account_id = $1;
```

Do not hand `balance_minor` to a serializer. That is the single most likely way
for this schema to produce a wrong number in an app.

---

## 2. `ledger_post` — the only write path

```sql
ledger_post(
  p_idempotency_key     text,     -- required, unique across the ledger
  p_request_fingerprint text,     -- required, hash of the request body
  p_business_event_type text,     -- 'authorize' | 'capture' | 'refund' | ...
  p_business_event_id   uuid,     -- the order / payout / dispute this is about
  p_entries             jsonb     -- >= 2 legs
) RETURNS (transaction_id uuid, replayed boolean)
```

Each leg:

```json
{"account_id": "…uuid…", "direction": "debit", "amount_minor": 12345, "currency": "TJS"}
```

`amount_minor` is an integer in minor units and must be **> 0**. Direction
carries the sign; there are no negative amounts. There are no floating-point
columns anywhere in this schema and there must be none in the Kotlin DTOs
either — use `Long`, never `Double` or `Float`, and never `BigDecimal` for
storage. A test (`test_no_floating_point_columns_anywhere`) fails if a float
column ever appears.

### Idempotency

| Call | Result |
|---|---|
| new key | writes; returns `(id, replayed = false)` |
| same key, same fingerprint | writes nothing; returns `(original_id, replayed = true)` |
| same key, different fingerprint | raises `IDEMPOTENCY_KEY_CONFLICT` → **HTTP 409** |
| concurrent callers, same key | exactly one writes; the others block until it commits, then replay its result |

Map `replayed = true` to `200 OK` with the original resource, not `201`.

`ledger_post` **requires READ COMMITTED**, the PostgreSQL default. Under
REPEATABLE READ or SERIALIZABLE a concurrent winner's row is invisible to the
loser even though the unique index rejected its insert; that case raises
`IDEMPOTENCY_RACE_RETRY` (503) and the whole transaction should be retried. If
the Kotlin service sets a non-default isolation level globally, it must handle
that reason as retryable.

---

## 3. The thing most likely to surprise you

**A successful return from `ledger_post` does not mean the posting was valid.**

The balance check is a `DEFERRABLE INITIALLY DEFERRED` constraint trigger. It
runs at **COMMIT**. That is deliberate — it is what lets both legs of a posting
insert inside one transaction without a transient unbalanced state being
rejected — but it means:

```kotlin
val result = ledgerPost(...)   // returns fine
tx.commit()                    // <-- UNBALANCED_TRANSACTION can be raised HERE
```

So:

* Wrap `commit()` in the same error translation as the call itself. A
  `P0001` at commit is a domain error, not an infrastructure error.
* Never treat "the DAO returned" as "the money moved". Only a successful commit
  means that.
* If you would rather fail early — for instance to return a clean 422 without
  unwinding other work — promote the constraint first:

  ```sql
  SET CONSTRAINTS ledger_entries_balanced_at_commit IMMEDIATE;
  ```

  after which `ledger_post` itself raises. This is tested
  (`test_forcing_the_constraint_immediate_moves_the_error_earlier`).

---

## 4. Error codes

Every error follows the repo's existing RPC convention from
`.context/migrations/13_*.sql`: **SQLSTATE `P0001`** with a jsonb `DETAIL`
carrying `reason` and `http_status`, plus context fields.

```
ERROR:  negative_balance_not_allowed
DETAIL: {"reason": "NEGATIVE_BALANCE_NOT_ALLOWED", "http_status": 409,
         "account_id": "…", "account_kind": "order_escrow",
         "attempted_balance_minor": -1}
```

Parse `DETAIL` as JSON and switch on `reason`. Do not match on the message text.

| `reason` | HTTP | Meaning |
|---|---|---|
| `IDEMPOTENCY_KEY_CONFLICT` | 409 | key reused with different money |
| `NEGATIVE_BALANCE_NOT_ALLOWED` | 409 | over-refund, over-payout, over-spend |
| `PAYOUT_NOT_SUBMITTED` | 409 | posting before the provider accepted |
| `PAYOUT_ALREADY_FAILED` | 409 | payout is terminal |
| `UNBALANCED_TRANSACTION` | 422 | debits ≠ credits — **a bug in the caller**, log loudly |
| `MIXED_CURRENCY_TRANSACTION` | 422 | one transaction spans two currencies |
| `CURRENCY_MISMATCH_ACCOUNT` | 422 | leg currency ≠ account currency |
| `DEGENERATE_TRANSACTION` | 422 | transaction committed with < 2 entries |
| `INVALID_ENTRY` | 422 | malformed leg |
| `INVALID_ENTRY_SET` | 422 | not an array, or fewer than two legs |
| `INVALID_IDEMPOTENCY_KEY` / `INVALID_FINGERPRINT` | 422 | missing required argument |
| `INVALID_AMOUNT` | 422 | amount ≤ 0 |
| `INVALID_CURRENCY` | 422 | not `^[A-Z]{3}$` |
| `INVALID_SPLIT_TOTAL` / `INVALID_SPLIT_WEIGHTS` | 422 | bad arguments to `ledger_split_minor` |
| `UNKNOWN_ACCOUNT` | 404 | no such account |
| `PAYOUT_NOT_FOUND` | 404 | no such payout |
| `IDEMPOTENCY_RACE_RETRY` / `ACCOUNT_RACE_RETRY` / `PAYOUT_RACE_RETRY` | 503 | **retryable**; re-run the whole transaction |
| `LEDGER_IMMUTABLE` | 500 | something tried to UPDATE or DELETE history |

`UNBALANCED_TRANSACTION` and `LEDGER_IMMUTABLE` should never reach a user. If
either appears in production logs, the service has a bug that the database
caught.

---

## 5. Splitting money

```sql
SELECT ledger_split_minor(12501, ARRAY[7000, 2000, 1000]);
-- {8750,2500,1250,1}
```

Weights are basis points and must sum to 10000. The return array has **one more
element than the weights**: the trailing element is the remainder that flooring
lost. Post it to `platform_rounding`. Do not drop it and do not give it to
whoever happens to be first in the list — either would make the settlement
unbalanced by a few minor units and the commit would fail anyway.

Do this in SQL rather than in Kotlin. The whole point of integer minor units is
lost the moment a `Double` enters the calculation.

---

## 6. Payouts: the saga

A payout has a step the database cannot roll back — the call to the payment
provider — so it is a saga, not a transaction:

```
ledger_payout_begin(request_id, payee_account, cash_account, amount, currency)
        -> state 'pending', no ledger effect
   [call the provider]
ledger_payout_mark_submitted(payout_id, provider_ref)
        -> state 'submitted', still no ledger effect
ledger_payout_post(payout_id)
        -> state 'posted', debits the payable, credits clearing
```

Failure handling:

* `ledger_payout_fail(payout_id, reason)` — if not yet posted, marks it failed
  with no ledger effect; if already posted, writes a **reversing transaction**.
* `ledger_payout_resume(payout_id, provider_ref)` — the recovery path. Pass the
  ref if the provider confirms it saw the request, `NULL` if it never did.

The ledger effect is keyed `payout:<payout_id>`, so `ledger_payout_post` can run
any number of times and land exactly once. That is what makes the saga safe to
resume after a crash at any boundary — which is tested by killing the backend at
each of them (`test_payout_saga.py`).

**The service may own this state machine instead of these functions.** If it
does, it must keep the idempotency key derivation identical —
`"payout:" + payoutId` and `"payout-reversal:" + payoutId` — or a Kotlin-side
retry and a SQL-side retry will each post their own transaction.

---

## 7. What the service must and must not do

**Must**

* Call `ledger_post` for every money movement, with an idempotency key derived
  from the request, not from a clock or a random.
* Translate `commit()` failures as domain errors (§3).
* Treat `*_RACE_RETRY` as retryable and everything else as terminal.
* Read balances through `ledger_account_balances.natural_minor`.
* Connect as `ravon_ledger_app`, never as the owner.

**Must not**

* Write `ledger_entries`, `ledger_transactions` or `ledger_balances` directly.
* `UPDATE` or `DELETE` any ledger row. Corrections are reversing entries.
* Recompute balances in Kotlin and write them back. The cache is trigger-
  maintained; `ledger_verify_balances()` proves it matches.
* Grant any ledger function to `anon` or `authenticated`. The ledger is reached
  only through the service tier — there is no iOS-facing RPC here, and
  `test_privileges.py` fails if one appears.
* Use floating point for money anywhere in the path.

**Should**

* Run `SELECT * FROM ledger_verify_balances()` on a schedule. It returns rows
  only when the cache has drifted from the entries, which should be never; a
  non-empty result is a page, not a warning.

---

## 8. Running the tests

The Python suite in `db/ledger/tests/` tests the *database*, and stays useful
after the Kotlin service exists — it is the thing that tells you whether a
failure is in the ledger or in the service wrapping it. Keep it in CI (the
`ledger-invariants` job) alongside whatever tests the service adds.
