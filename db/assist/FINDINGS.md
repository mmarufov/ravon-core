# Ravon Assist: findings

What surprised me, what did not work, and what is still wrong. Kept in full,
negative results included. All data is seeded and synthetic.

## 1. `add_tip` overwrites the tip, with no time limit and no trail

`add_tip` (`db/schema/08_consumer_support_rpcs.sql:87-128`) sets
`orders.tip_amount = p_amount` and rewrites `courier_earnings` to match. A
consumer can call it again after delivery, at any time, with a lower amount:
the courier's pay drops, `orders.total` (a generated column) drops with it,
and nothing records that it happened. `order_status_history` is written only
on status changes, and the tip is not a status.

`seed.py` reproduces it by calling the real RPC twice (`tip_lowered`, 5 eval
cases). The seeded ledger shows the change only because the seeder posts a
`tip_adjustment` the way a wired ledger would; the real schema has no ledger
wiring for orders at all.

**Not fixed here, on purpose.** The fix (append-only tip changes, a window
that closes, and a history row) changes a consumer-facing RPC and belongs in
its own PR with its own test. This build only depends on the bug existing.

## 2. The ledger and `db/schema` in one database fail `invariants.sql`

The extraction (1.2) checked that `db/ledger/schema.sql` *applies* on top of
`db/schema`. It does. But running `db/schema/invariants.sql` afterwards fails:

- **R5:** `ledger_account_balances` is a view in `public` without
  `security_invoker = true`.
- **R6:** every ledger SECURITY DEFINER function sets
  `search_path = public, pg_temp`, which R6 rejects as the hijackable form.

CI never sees this: the `db-invariants` job applies `db/schema` alone and the
`ledger-invariants` job applies the ledger alone. Not fixed here. The assist
layer avoids both rules' failure modes rather than adding to them (finding 4).

## 3. Policy functions are checked against the querying role

The first version of `01_assist.sql` gave the RLS policies functions that
took a merchant id, granted only to the view owner. Every read through the
views failed with `permission denied for function`: PostgreSQL checks EXECUTE
on a policy's functions against the role running the query (here
`assist_reader`), not the view owner. Granting the reader the merchant-taking
functions would have let it enumerate any merchant's ids by calling them
directly. The fix is zero-argument wrappers (`assist_scope_*()`) that read
only the session's own merchant; the `*_of(merchant)` functions are granted to
no one.

## 4. Definer views, deliberately, against R5's letter

R5 requires `security_invoker` on views in `public`, because a view owned by
the table owner bypasses RLS (finding N10). A `security_invoker` view would
need the reader to hold SELECT on the base tables, including columns it must
never see (`orders.verification_code`, the delivery address snapshot). So the
views live in their own schema, `assist`, owned by `assist_view_owner`, which
is neither superuser nor BYPASSRLS and owns no table. RLS therefore applies to
every read, and the reader holds nothing in `public`. `test_privileges.py`
asserts the owner's properties, so the reason R5 exists is still tested.

## 5. One open policy leaks nothing

The negative control for scoping opens the `ledger_entries` policy to
`USING (true)` and expects a leak. It did not leak: `assist.entries` joins
`ledger_accounts` and `ledger_transactions`, and each has its own policy, so
the join still filters every foreign row. All three policies have to be opened
before another merchant's entries appear. The test now asserts both facts.
Defence in depth that I did not design on purpose, found by a control that
failed.

## 6. Either half of the approval guard is enough on its own

`test_approval_race.py` rebuilds `assist_approve` from its own source with
parts removed and fires 50 concurrent approvals at each:

| Variant | Ledger transactions from 50 clicks |
| :--- | ---: |
| as shipped: row lock + key `assist:<id>` | 1 |
| no row lock, derived key | 1 |
| row lock, a fresh key per call | 1 |
| neither | 50 |

So the lock and the idempotency key are each sufficient, and the race is real
when both go (all 50 clicks posted on this machine). Keeping both is a choice:
the key protects against a future caller that bypasses `assist_approve`, the
lock keeps the proposal row's own state consistent.

## 7. The SDK's zod helper drops the diagnosis enum

`zodOutputFormat()` from `@anthropic-ai/sdk/helpers/zod` (SDK 0.131.0, zod
4.6.5) emitted `diagnosis` as `{"type": "string", "description": "{enum: [...]}"}`,
which constrains nothing. `zod.toJSONSchema()` keeps the enum, so the agent
derives the output schema from it (`shared/answer.ts:answerJsonSchema`), still
from the one zod definition. Every reply is also parsed with zod afterwards.

## 8. Order ids were random, so case files did not reproduce

`create_order` takes its id from the column default, `gen_random_uuid()`. The
first seeder reproduced the ledger digest exactly but not the questions, which
name order ids. It now pins the column default to a derived uuid around each
`create_order` call and restores `gen_random_uuid()` afterwards. Two fresh
databases produce identical case files.

## 9. The money-in-text check is a pattern, with known holes

Amounts may only appear through a claim's `{amount}` slot, which is filled
from a re-summed `amount_minor`. `moneyInText()` (`grade.ts`) rejects decimals,
numbers next to a currency word, and any integer of 100 or more that is not a
percentage or basis points. It cannot tell "5" (somoni) from "5" (orders)
without a currency word, and it reads English and Russian currency words only.
The structured claims are exact; this guard on free text is a heuristic.

## 10. Haiku 4.5 retires within weeks

The models overview lists Claude Haiku 4.5's retirement as "not sooner than
October 15, 2026". A headline number measured on it could stop being
reproducible within weeks, so the primary model is Claude Sonnet 5.5 and Haiku
is a one-pass comparison (`PREREGISTRATION.md`).
