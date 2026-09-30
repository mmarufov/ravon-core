# Rush results

**Local and simulated.** One laptop, one PostgreSQL, one Python client process,
synthetic buyers, latency added on localhost by Toxiproxy. No real restaurant, buyer or
network is involved. Client-observed latency includes Python event-loop overhead; these
are not a benchmark of PostgreSQL.

Pre-registration: [`PREREGISTRATION.md`](PREREGISTRATION.md), committed in 30a31de (first
committed as fec444d, then rebased onto main unchanged) before any measurement run.
Every run is in [`results.json`](results.json) and [`results-65ad66c.json`](results-65ad66c.json);
the raw logs are in [`logs/`](logs/).

## Provenance

| | |
|---|---|
| Harness and schema SHA | `c227e6faba5f38debc1a5df334f499bc43b997fa`. `results.json` records `dirty: true` because `db/rush/FINDINGS.md` was written, untracked, while the matrix ran; no code differed from the SHA |
| Date | 2026-09-30, matrix 19:43:41Z to 20:18:13Z; negative control 20:18:39Z to 20:19:18Z |
| Machine | Apple M5 Pro, 15 cores, 24 GB, macOS 27.0.1. Not idle: load average 6.24 / 8.92 / 9.75 at the start, from other sessions on the same machine |
| Database | PostgreSQL 17.10 (Homebrew), throwaway cluster on 127.0.0.1:5437, `max_connections = 1200`, `shared_buffers = 512MB`, everything else default, `fsync = on` |
| Client | Python 3.12.13, psycopg 3.3.6, one process, asyncio |
| Proxy | Toxiproxy 2.12.0, a private server on 127.0.0.1:18474, proxy 127.0.0.1:25438 to :5437 |

**Commands**

```bash
# primary matrix + secondary (real create_order), on the fixed schema
python db/rush/rush.py --dsn postgresql://postgres@127.0.0.1:5437/ravon_rush \
  --target strategies,rpc --k 100,1000 --runs 10 --latency 0,20,100 \
  --toxiproxy http://127.0.0.1:18474 --proxy-listen 127.0.0.1:25438 --out results.json

# negative control: the same rush, real create_order, on db/schema as of 65ad66c
python db/rush/rush.py --dsn postgresql://postgres@127.0.0.1:5437/ravon_rush_old \
  --target rpc --k 100,1000 --runs 10 --out results-65ad66c.json

# the CI gate, on both schemas
python db/rush/rush.py --dsn .../ravon_rush_old --target strategies,rpc --k 200 --runs 3 --gate  # exit 1
python db/rush/rush.py --dsn .../ravon_rush     --target strategies,rpc --k 200 --runs 3 --gate  # exit 0
```

Each database was created fresh, then `db/schema/apply.sh -d <db> --local` and
`seed.sql` from the schema under test (for 65ad66c, extracted with `git archive`).

## The answer first

- **Throughput was never the constraint.** A kitchen cooks about 25 orders at a time.
  Every correct strategy handled a 1,000-buyer rush at thousands of checkouts per second
  on a laptop, and the real `create_order` served 1,000 simultaneous buyers in a p99 of
  288 ms. What went wrong was correctness, and only on one path.
- **The order-now path already held.** Before this work, a scratch probe on 65ad66c sold
  exactly 40 of 40 in 10 of 10 trials (200 buyers in 5, 50 in 5). Here, on both the old
  and the fixed schema, `now_stock` sold exactly 40 in 20 of 20 runs each.
- **The scheduled path did not.** On 65ad66c, 1,000 simultaneous pre-orders for 40
  portions put **all 1,000 live, in 10 of 10 runs**. On the fix, exactly 40, in 10 of 10.
- **Read-then-write oversold in all 60 of its runs; the other three strategies oversold 0
  times in 180 runs**, with 0 lost updates and 0 conservation violations.

## Primary: four strategies, N = 40

Per cell, 10 runs. `sold`, `oversells`, `lost updates` and `conservation violations` are
per run or summed as labelled; p50, p99 and checkouts/s are medians across the 10 runs.
"Measured RTT" is the median of three `SELECT 1` round trips taken after the toxic was set,
so the injected latency is observed rather than assumed. "Checkouts/s" is K divided by the
time from release to the last response, and it counts refusals: at K = 1,000, 960 of every
1,000 checkouts are cheap "sold out" answers, so it is not a sales rate.

| K | added | measured RTT | strategy | sold per run | oversells (sum of 10) | max in one run | lost updates (sum) | conservation violations (runs) | p50 ms | p99 ms | checkouts/s |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 100 | 0 ms | 0.3 ms | `read_then_write` | 100 | 600 | 60 | 990 | 10 of 10 | 82.1 | 157 | 674 |
| 100 | 0 ms | 0.3 ms | `row_lock` | 40 | 0 | 0 | 0 | 0 of 10 | 15.6 | 21.0 | 4,700 |
| 100 | 0 ms | 0.3 ms | `conditional_decrement` | 40 | 0 | 0 | 0 | 0 of 10 | 11.7 | 16.7 | 5,908 |
| 100 | 0 ms | 0.3 ms | `reservation_rows` | 40 | 0 | 0 | 0 | 0 of 10 | 18.5 | 21.4 | 4,641 |
| 100 | 20 ms | 21.7 ms | `read_then_write` | 100 | 600 | 60 | 990 | 10 of 10 | 2,281 | 4,430 | 22 |
| 100 | 20 ms | 21.7 ms | `row_lock` | 40 | 0 | 0 | 0 | 0 of 10 | 56.2 | 65.1 | 1,527 |
| 100 | 20 ms | 21.7 ms | `conditional_decrement` | 40 | 0 | 0 | 0 | 0 of 10 | 48.9 | 64.1 | 1,536 |
| 100 | 20 ms | 21.7 ms | `reservation_rows` | 40 | 0 | 0 | 0 | 0 of 10 | 38.7 | 41.0 | 2,428 |
| 100 | 100 ms | 101.2 ms | `read_then_write` | 100 | 600 | 60 | 990 | 10 of 10 | 10,447 | 20,379 | 5 |
| 100 | 100 ms | 101.2 ms | `row_lock` | 40 | 0 | 0 | 0 | 0 of 10 | 110 | 112 | 892 |
| 100 | 100 ms | 101.2 ms | `conditional_decrement` | 40 | 0 | 0 | 0 | 0 of 10 | 107 | 109 | 913 |
| 100 | 100 ms | 101.2 ms | `reservation_rows` | 40 | 0 | 0 | 0 | 0 of 10 | 106 | 108 | 925 |
| 1,000 | 0 ms | 0.1 ms | `read_then_write` | 1000 | 9,600 | 960 | 9,990 | 10 of 10 | 1,266 | 1,740 | 574 |
| 1,000 | 0 ms | 0.1 ms | `row_lock` | 40 | 0 | 0 | 0 | 0 of 10 | 59.9 | 92.0 | 10,810 |
| 1,000 | 0 ms | 0.1 ms | `conditional_decrement` | 40 | 0 | 0 | 0 | 0 of 10 | 45.4 | 54.3 | 18,273 |
| 1,000 | 0 ms | 0.1 ms | `reservation_rows` | 40 | 0 | 0 | 0 | 0 of 10 | 67.1 | 76.5 | 13,032 |
| 1,000 | 20 ms | 21.3 ms | `read_then_write` | 1000 | 9,600 | 960 | 9,990 | 10 of 10 | 22,911 | 44,597 | 22 |
| 1,000 | 20 ms | 21.3 ms | `row_lock` | 40 | 0 | 0 | 0 | 0 of 10 | 94.7 | 135 | 7,379 |
| 1,000 | 20 ms | 21.3 ms | `conditional_decrement` | 40 | 0 | 0 | 0 | 0 of 10 | 76.3 | 111 | 9,108 |
| 1,000 | 20 ms | 21.3 ms | `reservation_rows` | 40 | 0 | 0 | 0 | 0 of 10 | 80.4 | 94.0 | 10,605 |
| 1,000 | 100 ms | 101.2 ms | `read_then_write` | 94 to 584 | 4,731 | 544 | 5,121 | 10 of 10 | 103,848 | 120,603 | 8 |
| 1,000 | 100 ms | 101.2 ms | `row_lock` | 40 | 0 | 0 | 0 | 0 of 10 | 155 | 180 | 5,525 |
| 1,000 | 100 ms | 101.2 ms | `conditional_decrement` | 40 | 0 | 0 | 0 | 0 of 10 | 140 | 165 | 6,089 |
| 1,000 | 100 ms | 101.2 ms | `reservation_rows` | 40 | 0 | 0 | 0 | 0 of 10 | 141 | 160 | 6,241 |

## Secondary: the real `create_order`, as PostgREST would call it

Seeded consumer, `SET ROLE authenticated` plus JWT claims, N = 40, 0 ms added, direct
connection (no proxy). For the scheduled scenarios, "live" is counted after
`activate_scheduled_orders()`. Conservation is `public.ravon_inventory_violations()`
returning no rows plus `stock + live units = 40`.

**Fixed schema (c227e6f):**

| K | scenario | bound | live after the rush (per run) | oversells (sum of 10) | conservation violations (runs) | p50 ms | p99 ms |
|---|---|---|---|---|---|---|---|
| 100 | `now_stock` | 40 | 40 | 0 | 0 of 10 | 41.7 | 49.6 |
| 100 | `now_capacity` | 25 | 25 | 0 | 0 of 10 | 18.3 | 23.8 |
| 100 | `scheduled_stock` | 40 | 40 | 0 | 0 of 10 | 22.6 | 27.8 |
| 100 | `scheduled_capacity` | 25 | 25 | 0 | 0 of 10 | 20.1 | 26.3 |
| 1,000 | `now_stock` | 40 | 40 | 0 | 0 of 10 | 219 | 288 |
| 1,000 | `now_capacity` | 25 | 25 | 0 | 0 of 10 | 107 | 171 |
| 1,000 | `scheduled_stock` | 40 | 40 | 0 | 0 of 10 | 107 | 161 |
| 1,000 | `scheduled_capacity` | 25 | 25 | 0 | 0 of 10 | 102 | 164 |

**Negative control, 65ad66c** (the conservation function does not exist there, so
conservation is `stock + live units = 40` only):

| K | scenario | bound | live after the rush (per run) | oversells (sum of 10) | conservation violations (runs) | p50 ms | p99 ms |
|---|---|---|---|---|---|---|---|
| 100 | `now_stock` | 40 | 40 | 0 | 0 of 10 | 36.3 | 41.8 |
| 100 | `now_capacity` | 25 | 25 | 0 | 0 of 10 | 16.8 | 22.1 |
| 100 | `scheduled_stock` | 40 | 100 | 600 | 10 of 10 | 19.0 | 35.2 |
| 100 | `scheduled_capacity` | 25 | 100 | 750 | 10 of 10 | 18.5 | 35.4 |
| 1,000 | `now_stock` | 40 | 40 | 0 | 0 of 10 | 160 | 228 |
| 1,000 | `now_capacity` | 25 | 25 | 0 | 0 of 10 | 93.5 | 151 |
| 1,000 | `scheduled_stock` | 40 | 1000 | 9,600 | 10 of 10 | 308 | 568 |
| 1,000 | `scheduled_capacity` | 25 | 1000 | 9,750 | 10 of 10 | 171 | 332 |

On 65ad66c every scheduled checkout was accepted and activated: 1,000 live pre-orders for
40 portions, stock 0, in 10 of 10 runs. With the capacity of 25 the result is the same,
because 65ad66c never checked capacity for scheduled orders. The order-now rows are the
control: identical, and correct, on both schemas.

## The CI gate, and its own negative control

| Schema | `rush.py --target strategies,rpc --k 200 --runs 3 --gate` |
|---|---|
| 65ad66c | **exit 1**: 6 failures, all on the scheduled path (`scheduled_stock` oversold 160 per run, `scheduled_capacity` 175) |
| fixed (c227e6f) | exit 0 |
| GitHub `ubuntu-latest`, CI run 36767334379, PostgreSQL 17 in Docker | exit 0; `read_then_write` sold 200 of 200 in each of 3 runs (160 oversold per run), every other row 0 |

The gate also fails if `read_then_write` never oversells, so a harness that stopped
detecting oversells would fail CI rather than pass it.

## Hypotheses, as pre-registered

- **H1, read-then-write oversells in every cell: held**, 60 of 60 runs. **"Oversells more
  as latency grows": not testable as designed.** With one unit per checkout it sold every
  one of K in every run that completed, so K is a ceiling and oversells cannot grow (F8 in
  FINDINGS.md). At K = 1,000 with 100 ms added, oversells went *down* (sold 94 to 584 per
  run), because the pre-registered `statement_timeout = 120s` cancelled 416 to 906 of
  1,000 checkouts while they queued for the row lock. It still oversold by 54 to 544 in
  every run. Latency made it both wrong and slow.
- **H2, the other three oversell 0, lose 0 updates, break conservation 0 times: held**,
  180 of 180 runs.
- **H3, one round trip for the single-statement strategies, a multiple for
  read-then-write: held.** At K = 100 the three single-round-trip strategies went from a
  p50 of 12 to 19 ms to 106 to 110 ms with 100 ms added: about one round trip.
  Read-then-write holds its row lock across the `INSERT` and `COMMIT` round trips, so
  buyers queue behind each other for about 2 x the added latency each: its p99 was 4.4 s
  at 20 ms and 20.4 s at 100 ms for K = 100 (100 x 2 x 20 ms = 4 s; 100 x 2 x 100 ms =
  20 s), and 44.6 s at 20 ms for K = 1,000.
- **H4, throughput is not the constraint: held.** See "The answer first".

## Deviations from the pre-registration

1. **Two aborted runs, not reported.** Run 1 stopped at K = 1,000, 0 ms, run 4: two
   `toxiproxy-server` processes from different sessions were bound to port 8474. Run 2
   stopped after 55 runs on ephemeral-port exhaustion (7,851 sockets in TIME_WAIT on the
   machine). Both partial logs are in `logs/`; see FINDINGS.md F9. The reported matrix is
   run 3, complete, every cell once.
2. **Private Toxiproxy on port 18474, proxy on 25438**, instead of 8474 and 25437, and
   `toxi.Proxy.verify()` reads the proxy back after every change.
3. **Connections are opened once per K and reused across runs**, instead of K new
   connections per run. Setup was never timed, so no reported number is setup time. The
   first run on a fresh pool is slower, because each backend's plan cache starts cold:
   this raises some p99s in run 0 and is visible in `results.json`.
4. **Added: a measured round trip per run** (`probe_rtt_ms`).
5. **Added: the negative control against 65ad66c** (`results-65ad66c.json`) and the gate
   on both schemas. Not in the pre-registration; added because a detector nobody has
   watched fire is not evidence.
6. The harness SHA (c227e6f) is later than the pre-registration commit (30a31de). The
   differences are items 2 to 4, all in `rush.py` and `toxi.py`; strategies, K, N, seeds,
   latencies and metric definitions are unchanged.
7. Python is 3.12.13 (the pre-registration said 3.12).
8. Smoke runs during development (K = 100, 1 to 2 runs) are not reported.
