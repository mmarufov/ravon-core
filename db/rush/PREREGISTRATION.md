# Rush harness: pre-registration

Written and committed on 2026-09-30, **before the first measurement run**. `RESULTS.md`
reports against this file. Any change after the first run is listed at the bottom of
`RESULTS.md` under "Deviations from the pre-registration", with the reason.

Everything here is **local and simulated**: one laptop, one PostgreSQL, one Python client
process, synthetic buyers. No real restaurant, buyer or network is involved.

## Question

When K buyers press "order" at the same instant for N portions of one dish, which checkout
strategies sell more than N, lose stock updates, or break stock conservation, and how does
added client-to-database latency change that?

## Hypotheses, stated before measuring

- **H1.** The app-side read-then-write strategy oversells in every cell with K > N, and
  oversells more as latency grows, because the window between its read and its write is
  at least one round trip.
- **H2.** Row lock, conditional decrement and reservation rows oversell 0 times, lose 0
  updates and break conservation 0 times, in every run of every cell.
- **H3.** For the three single-statement or single-RPC strategies, added latency adds about
  one round trip to each checkout and does not lengthen any lock hold. Read-then-write
  holds its row lock across client round trips, so its latency grows by a multiple of the
  added latency.
- **H4.** Throughput is not the binding constraint. Every correct strategy sustains far
  more checkouts per second, on one restaurant's hot row, than a kitchen that cooks about
  25 orders at a time could ever accept.

## Fixed parameters

| Parameter | Value |
|---|---|
| N (portions) | 40 |
| Units per checkout | 1 |
| K (concurrent checkouts) | 100 and 1,000 |
| Added latency | 0, 20 and 100 ms |
| Runs per cell | 10 |
| Seeds | run `r` uses seed `r`, for r = 0..9 |
| Cells | 4 strategies x 2 K x 3 latencies = 24 cells, 240 runs |

**What a seed controls.** Only the order in which the K checkout tasks are created and
released. Scheduling after release is up to the OS and PostgreSQL and is not reproducible
by seed. The seed is recorded so a run's launch order can be reproduced, not its
interleaving.

## Strategies

All four run in a scratch schema `rush` (`db/rush/strategies.sql`) with the same two
tables: `rush.items(id, stock)` and `rush.orders(id, item_id, qty)`. Reservation rows add
`rush.units(id, item_id, order_id)`, prefilled with N rows.

1. **`read_then_write`**: the plausible app-side version, not a strawman. It is what an
   ORM does inside a transaction at PostgreSQL's default READ COMMITTED isolation
   (Rails: `transaction { item = Item.find(id); raise if item.stock < q; item.update!(stock: item.stock - q); Order.create! }`):
   `BEGIN`; `SELECT stock`; the client checks `stock >= 1`; `UPDATE items SET stock = <value read> - 1`;
   `INSERT` the order; `COMMIT`. Five round trips, and the row lock taken by the `UPDATE`
   is held across the `INSERT` and `COMMIT` round trips.
2. **`row_lock`**: the mechanism `public.create_order` uses. One RPC, `SELECT rush.checkout_row_lock(item)`,
   which does `SELECT ... FOR UPDATE`, checks, decrements and inserts inside the function.
   One round trip; the lock is held only inside the server.
3. **`conditional_decrement`**: one autocommit statement,
   `WITH d AS (UPDATE items SET stock = stock - 1 WHERE id = $1 AND stock >= 1 RETURNING id) INSERT INTO orders ... SELECT ... FROM d`.
4. **`reservation_rows`**: one autocommit statement that claims one free row of
   `rush.units` with `FOR UPDATE SKIP LOCKED` and inserts the order. Stock is the count of
   unclaimed units.

## Procedure per run

1. Reset: truncate `rush.orders` (and `rush.units`), set stock to N (or insert N units).
2. Open K connections through Toxiproxy, each autocommit with `statement_timeout = 120s`.
   Connection setup is not timed.
3. Configure the latency toxic for the cell (see below).
4. Create the K tasks in seed-shuffled order; every task waits on one `asyncio.Event`.
5. Release the event. Time each checkout from release to its response.
6. After the last response: read final stock and count orders, then close all connections.

## Latency injection

- Toxiproxy (`toxiproxy-server` 2.12.0) proxies `127.0.0.1:25437` to PostgreSQL on
  `127.0.0.1:5437`.
- The 0 ms cells also go through the proxy, with no toxic, so proxy overhead is the same
  in every cell.
- Latency is one `latency` toxic on the **downstream** stream (database to client), with
  jitter 0. Every round trip therefore gains exactly the added latency once.

## Metrics, defined before measuring

| Metric | Definition |
|---|---|
| `sold` | rows in `rush.orders` after the run (each is one unit) |
| `oversells` | `max(0, sold - N)` |
| `lost_updates` | `sold - (N - final_stock)`: checkouts that were acknowledged but whose decrement is not in the final stock. For `reservation_rows`, `final_stock` is the count of unclaimed units |
| `conservation_violation` | 1 if `final_stock + sold != N`, else 0, per run; reported as a count of runs |
| `p50`, `p99` | client-observed milliseconds per checkout, over all K checkouts including refusals, nearest-rank |
| `throughput` | K divided by seconds from release to the last response |

Per cell, `RESULTS.md` reports the sum of oversells, lost updates and conservation
violations over its 10 runs, the maximum oversell in one run, and the median across runs
of p50, p99 and throughput.

## Secondary measurement (also pre-registered)

The real `public.create_order` (order-now path) and the scheduled pre-order path, on
`db/schema` with the fix applied, called as the seeded consumer through `SET ROLE
authenticated` plus JWT claims, exactly as PostgREST would. K = 100 and 1,000, 0 ms added,
10 runs each, N = 40, `max_concurrent_orders` NULL for the stock test and 25 for the
capacity test. Metrics: sold, oversells, conservation (via `public.ravon_inventory_violations()`),
p50, p99.

## CI gate (`rush-invariants`)

K = 200, 0 ms added, 3 runs per strategy, on a GitHub `ubuntu-latest` runner with
PostgreSQL 17 in Docker. The job fails if `row_lock`, `conditional_decrement`,
`reservation_rows`, or the real `create_order` (order-now and scheduled, then activation)
report any oversell or conservation violation. It also fails if `read_then_write` reports
0 oversells in all 3 runs: that is the harness's own negative control, and a detector that
never fires is not evidence.

## Environment

- Apple M5 Pro, 15 cores, 24 GB, macOS 27.0.1.
- PostgreSQL 17.10 (Homebrew), a throwaway cluster on port 5437, `max_connections = 1200`,
  `shared_buffers = 512MB`, everything else default (including `fsync = on`).
- Python 3.12, psycopg 3.3.6, one process, asyncio.

## Known limits, stated in advance

- Client-observed latency includes Python event-loop overhead. These are not a benchmark
  of PostgreSQL.
- One hot row on one database. A multi-item cart, a replica, or a pooler is not modelled.
- Toxiproxy adds latency on localhost TCP. It is not a real network: no loss, no
  reordering, no bandwidth limit.

## Stopping rule

Every cell is run once, all 10 runs, and every run is reported. A run is repeated only if
the harness itself crashes (not the database refusing a checkout), and any such repeat is
listed in `RESULTS.md`.
