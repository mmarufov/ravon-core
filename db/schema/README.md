# `db/schema` — the authored schema

This is the definition of the Ravon database. `db/migrations/` is kept as the
historical record of what the deleted project was incrementally patched into; it is
**not** a rebuild source and cannot be one — only 1 of the 15 tables the apps touch
was ever `CREATE`d there.

## Apply

```bash
# Supabase (or any remote)
./db/schema/apply.sh "postgresql://postgres:<pw>@db.<ref>.supabase.co:5432/postgres"

# Local Postgres 17, with the auth/storage shim
createdb ravon_local
./db/schema/apply.sh -d ravon_local --local
psql -d ravon_local -f db/schema/seed.sql
psql -d ravon_local -f db/schema/walk.sql        # one order, create_order → delivered
```

`--local` first applies `local/00_auth_shim.sql`, which stands in for the `auth`
schema, `auth.uid()`, the `anon`/`authenticated` roles and `storage.buckets` that
Supabase provides natively. **Never apply that file to Supabase.**

## File order, and why 12 is last

| File | Contents |
|---|---|
| `00_prelude.sql` | pgcrypto, haversine, CSPRNG code generator |
| `01_types.sql` | the two real enums (`order_status`, `user_role`) |
| `02_tables.sql` | 16 tables |
| `03_lifecycle.sql` | `order_transitions` (36 edges) + the enforcing trigger |
| `04_orderability.sql` | hours / open-closed / `set_accepting_orders` |
| `05_order_create.sql` | `validate_cart`, `create_order` |
| `06_merchant_rpcs.sql` | the five `merchant_*` transitions |
| `07_courier_rpcs.sql` | claim, the delivery run, cancel, offer feed |
| `08_consumer_support_rpcs.sql` | consumer cancel, tip, and three reconstructed RPCs |
| `09_triggers.sql` | signup, role lock, codes, status history |
| `10_courier_reports.sql` | delay/problem reports + the escalation ladder |
| `11_rls.sql` | policies and the visibility helpers |
| `12_grants.sql` | **the deny-by-default baseline — applied last** |
| `13_realtime_storage.sql` | buckets, the realtime publication, cron |
| `invariants.sql` | assertions; the CI gate |
| `seed.sql` | one consumer, one merchant + restaurant + menu, one courier |
| `walk.sql` | the end-to-end walk, including the refusals |

`12_grants.sql` runs **after** every object exists, and that ordering is load-bearing
rather than stylistic. `ALTER DEFAULT PRIVILEGES ... REVOKE EXECUTE ON FUNCTIONS FROM
PUBLIC` writes nothing to `pg_default_acl` — revoking a default that was never
explicitly granted is a no-op against Postgres's built-in `EXECUTE TO PUBLIC`. Only an
explicit `REVOKE` against an object that already exists produces a non-NULL `proacl`
that excludes `PUBLIC`.

The first draft had grants at position 11, and `invariants.sql` caught the
consequence: the two RLS helper functions created afterwards came out with
`proacl = NULL`, so `anon` could execute two `SECURITY DEFINER` functions. That is a
self-inflicted instance of the exact finding this schema exists to eliminate —
*omitting a GRANT does not deny access* — and it was caught by an assertion rather
than by review.

## What the design rests on

Three primitives, in order of how much work they do:

1. **The missing GRANT.** Clients hold no `INSERT`/`UPDATE`/`DELETE` on `orders`,
   `order_items`, `order_status_history`, `courier_earnings`,
   `courier_cancellation_log` or `order_transitions`. A policy is only ever consulted
   if the table-level grant exists, so a future `CREATE POLICY` on `orders` cannot
   re-open anything. Four of the nine security findings were one defect — an `orders`
   `UPDATE` policy that constrained which *rows* but not which *columns* — and no
   policy rewrite can fix that, because Postgres RLS has no column dimension.
2. **Column-level grants**, for the cases where a client legitimately writes some of a
   row: `UPDATE (read_at)` on `chat_messages` makes `body` immutable while keeping
   read receipts working; the absence of `UPDATE (role)` on `profiles` is what makes
   privilege escalation inexpressible; `restaurants` grants exclude `owner_id` and
   `rating`.
3. **Generated columns and CHECKs**, for invariants no privilege can express.
   `orders.total` is `GENERATED ALWAYS AS (subtotal + delivery_fee + tip_amount)
   STORED`, so it is unwritable by *every* role — including a future Kotlin service —
   and a desynchronised total is not merely forbidden, it is impossible.

RLS is the fourth layer and governs reads. For the transactional tables it is pure
defence-in-depth. Every cross-table test in `11_rls.sql` goes through a
`SECURITY DEFINER` helper, because a policy that reads another RLS-protected table is
a latent cycle — the first draft had `restaurants`' policy reading `orders` and
`orders`' policy reading `restaurants`, and Postgres refused every query on both with
`infinite recursion detected in policy`.

## Two things worth knowing before changing anything

**The lifecycle is declared once.** `order_transitions` holds the same 36 edges as
`Sources/RavonCore/Models/OrderLifecycle.swift`, `orders_enforce_transition` refuses
any status change with no matching row, and `scripts/lifecycle_parity.py` fails CI if
the two copies diverge. Adding a transition means adding it in both places.

**Every RPC declares its actor.** A transition RPC calls
`ravon_set_actor('merchant','merchant_accept_order')` before it writes, and the
trigger reads that transaction-local GUC to pick the right edge — a consumer cancel
and a merchant cancel differ only in who called. A status write with no actor
declared is rejected outright, which is what makes "there is no other legal way to
move an order" true rather than aspirational.

## Known residuals

Recorded in full, with reasoning, in `.context/plans/backend-standup.md`. The short
version: money is `numeric(10,2)` rather than `bigint` minor units (changing the unit
means a coordinated change across three app repos); verification codes are stored in
plaintext because the merchant and consumer screens read them; proof-of-delivery is
path-shape-checked, not object-verified; and there is no self-service path to becoming
a merchant or courier.
