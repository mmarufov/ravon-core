# Findings: pre-order stock, kitchen capacity, and the rush harness

What the regression tests and the harness found, in the order it was found, including
what is not fixed and what did not work. Numbers are in `RESULTS.md`; everything is
local and simulated.

## F1. The order-now path was already correct under a rush

`create_order` locks the restaurant row (`SELECT ... FOR UPDATE`), then each item row,
inside one server function, so every checkout for a restaurant is serialised. Before any
of this work, a scratch probe on 65ad66c sold exactly 40 of 40 plov to 200 simultaneous
buyers in 5 of 5 trials, and to 50 in 5 of 5 (10 of 10 in total), and a capacity of 25
admitted exactly 25 in 3 of 3. The harness reproduces this on the fixed schema
(`rpc/now_stock`, `rpc/now_capacity` in `RESULTS.md`).

This matters for how the rest is read. The obvious path was right, so the bug had to be
somewhere less obvious.

## F2. Scheduled pre-orders oversold, because three code paths disagreed

A pre-order spans time: scheduled at t0, activated at t1, maybe cancelled at t2. At
65ad66c:

- **t0** `create_order` checked `stock_count < quantity` but reserved nothing for a
  scheduled order, and skipped the capacity check (`p_scheduled_for IS NULL AND ...`).
- **t1** `activate_scheduled_orders` decremented with
  `SET stock_count = GREATEST(0, mi.stock_count - oi.quantity)` and never checked
  capacity.
- **t2** `ravon_restore_stock` skipped every order with `scheduled_for IS NOT NULL`.

Measured on 65ad66c by `db/schema/tests` (NEGATIVE_CONTROL.md):

| Case | 65ad66c | Fixed |
|---|---|---|
| 60 pre-orders, 40 portions, capacity 25 | all 60 accepted, all 60 live, stock 0 | 25 live, 35 refused `OVERLOADED`, stock 15 |
| 60 pre-orders, 40 portions, no capacity | 60 live | 40 live, 20 refused `INSUFFICIENT_STOCK`, stock 0 |
| 10 pre-orders activated, 3 cancelled | stock 30 (leaked 3) | stock 33, and 33 after a second restore |
| one item on two lines, 2 + 2 against 3 | SQLSTATE 23514 from the CHECK | `P0001`, reason `INSUFFICIENT_STOCK`, `have: 3` |

And under a rush, by the harness against the 65ad66c schema (`--target rpc`): see
"Negative control" in `RESULTS.md`.

**The clamp is the instructive part.** `stock_count` has `CHECK (stock_count >= 0)`, so
without the clamp an oversold batch would have raised and aborted the sweep. The clamp
made the error go away, and with it the only signal that anything was wrong: 60 orders
went live and the stock read 0.

## F3. It was a regression, introduced by an AI-assisted commit, and it passed every gate

- The original Supabase function (`db/migrations/06_scheduled_orders.sql`) locked each
  item, checked stock, and system-cancelled with `INSUFFICIENT_STOCK`.
- `git blame 65ad66c -- db/schema/08_consumer_support_rpcs.sql` puts the clamp (line 294)
  in c17b908, "ci: apply db/schema to a fresh PostgreSQL 17 and assert its invariants",
  2026-09-29, which carries a `Co-Authored-By: Claude Opus 5.5` trailer.
- It passed review and all of `invariants.sql`: 31 `RAISE EXCEPTION` assertion sites at
  65ad66c (`git show 65ad66c:db/schema/invariants.sql | grep -c 'RAISE EXCEPTION'`; an
  earlier research note said 32). Every one of them checks the catalog: grants, policies,
  ACLs, generated columns, the transition table. None checks behaviour. No test in the
  repo touched stock; the CI walk places one order-now order.

The lesson, as machinery: a catalog invariant is not a behavioural invariant. There are
now three behavioural checks in `invariants.sql` (conservation, the exactly-once key, and
a named check that no public function clamps `stock_count` with `GREATEST(0, ...)`), a
conservation check after the CI walk, and a rush in CI.

## F4. Found and NOT fixed: one closed restaurant blocks every activation

`activate_scheduled_orders` has an `ELSE` branch for a restaurant that is not orderable at
the scheduled time. It writes `scheduled -> cancelled_by_system`, and that edge is not in
the transition table (36 edges; `scheduled` has exactly two exits: `created` and
`cancelled_by_customer`). So `orders_enforce_transition` raises
`undeclared order transition`, and because the whole sweep is one function call in one transaction,
**every other activation in the same sweep rolls back too.** One pre-order at a paused
restaurant stops pre-orders activating everywhere until it is cancelled by hand.

Reproduced on 65ad66c and on the fix. Pinned by a strict xfail,
`test_a_preorder_at_a_closed_restaurant_does_not_block_every_other_activation`, which will
start failing (as XPASS) the day it is fixed.

Why not fixed here: the fix is a 37th edge, `scheduled -> cancelled_by_system` by
`system` via `activate_scheduled_orders`, which must be added to `OrderLifecycle.swift`
(the source of truth, ADR 0001), to `03_lifecycle.sql`, and to every count of "36 edges"
in the tests and docs. That is a lifecycle change, not a stock change, and it was out of
scope. The `ravon_restore_stock` call added to that branch is correct but unreachable
until the edge exists. Until then, a pre-order at a closed restaurant also keeps its
stock reserved, which at 65ad66c it did not (nothing was reserved).

## F5. The fix changes what a buyer sees

A pre-order can now be refused at checkout (`OVERLOADED` or `INSUFFICIENT_STOCK`), where
before it was accepted and then, at best, cancelled at activation. That is the right trade
(a refusal while the buyer is looking at the screen beats a cancellation at dinner time),
but it is a product change and the consumer app shows the generic "Ресторан перегружен
заказами" for a full kitchen slot.

## F6. Two capacity budgets, not one

Order-now checkouts count the live queue against `max_concurrent_orders`. Scheduled
checkouts count places in a 15-minute `kitchen_slots` row against the same number. The
two are separate: when a full slot activates, it is not checked against the live queue at
that moment, so a kitchen already at 25 live orders can briefly hold 25 more. Joining them
(counting unactivated slot places for the current window in the order-now check) is the
next step. The 15-minute width is a modelling choice, not a measurement of any kitchen.
`kitchen_slots.capacity` is copied when a slot is first used and is not resized if the
restaurant's capacity changes later.

## F7. The exactly-once key is per (order, item, kind), not per (order, kind)

The brief suggested `UNIQUE (order_id, kind)`. An order can hold several items, so the key
is `UNIQUE (order_id, menu_item_id, kind)`. Since `create_order` sums duplicate cart lines
first, an order has at most one reservation per item, and the key still makes a second
release a no-op (`ON CONFLICT DO NOTHING`) or, if written directly, a unique violation.

## F8. The harness's unsafe strategy hits a ceiling

`read_then_write` sold every one of K checkouts in every run where it completed: at
K = 100 it sold 100 for 40 portions, at K = 1,000 it sold 1,000. With one unit per
checkout, K is the maximum possible, so its oversell count cannot grow with added latency
as H1 predicted. The latency effect shows up in its tail latency and throughput instead
(see `RESULTS.md`). H1's first half holds; its second half was not testable as designed.

## F9. Two runs of the harness died of infrastructure, and are not reported

- **Run 1** died at K = 1,000, 0 ms, run 4, with "server closed the connection
  unexpectedly" on the proxied port. Two `toxiproxy-server` processes from different
  sessions on this machine were bound to the default port 8474, so a Toxiproxy API call
  could reach a server that did not hold this proxy. The matrix now uses a private server
  on port 18474, and `toxi.Proxy.verify()` reads the proxy back after every change.
- **Run 2** died after 55 runs with "Can't assign requested address": ephemeral-port
  exhaustion, 7,851 sockets in TIME_WAIT on the machine against a 16,384-port range,
  because every run opened K new connections through the proxy. Connections are now
  opened once per K and reused.

Both partial logs are in `db/rush/logs/`. Neither contributed a number.

## F10. Still true, and not addressed

- **No checkout idempotency.** `create_order` takes no client request key, and the
  consumer app's retry after a lost response re-runs create. A commit whose response is
  lost, followed by a retry, makes a second order (from reading the code, not measured).
- **One hot row.** The harness sells one dish from one restaurant. Multi-item carts,
  replicas and connection poolers are not modelled.
- **Throughput was never the constraint.** See `RESULTS.md`: every correct strategy
  sustains thousands of checkouts a second on a laptop. The real `create_order`, which
  serialises every checkout for a restaurant on the restaurant row, answered 1,000
  simultaneous buyers at a median of 3,465 checkouts per second, refusals included (about
  0.3 ms each; the earlier scratch probe, with fresh connections, measured about 1.3 ms).
  A kitchen cooks about 25 orders at a time.
