# Pre-registration: Shopify local-delivery fault harness

Committed before the first measured run. Anything changed after a run starts is listed
under "Amendments" at the bottom with the reason, and the run it affects is labelled.

Everything here is a **development store with test orders** and **simulated couriers**.
No real merchant, buyer, courier or money is involved anywhere.

## What is claimed, and what would refute it

| Claim | Metric | Target | Refuted if |
|---|---|---|---|
| One delivery per order | jobs per order (PostgreSQL `jobs`) | exactly 1 for every order | any order has 0 or 2+ |
| One dispatch per order | `dispatches` rows per order | exactly 1 for every non-cancelled order | any has 0 or 2+ |
| One fulfillment per order across crashes | fulfillments per order **read from Shopify** at the end | exactly 1 for every non-cancelled order | any has 0 or 2+ |
| Dropped webhooks are recovered | orders whose every delivery was dropped, and how many the sweep recovered | all of them | any never dispatches |
| Stale and out-of-order events are refused | `rejected_events`; cancelled orders whose job ends non-cancelled | 0 resurrected | any cancelled order dispatched after its cancel was applied |
| Tampered and replayed deliveries are rejected | HTTP status / outcome per probe | 401 tampered; no new job or dispatch for replays | any tampered 2xx, any replay creating a job |
| Pacing keeps the API from throttling | THROTTLED responses | 0 with pacing on | any |

## Run R1: the measured run on the development store

- Orders: **200 delivered-cohort orders** plus **20 cancel-cohort orders**, created with
  `orderCreate` by `harness/real-store.ts`, paced to **5 per minute** (Shopify's documented
  `orderCreate` limit for development stores). Each has one custom line item, a test buyer,
  and a "Ravon local delivery (simulated)" shipping line. The cancel cohort is cancelled
  with `orderCancel(reason: CUSTOMER)` after a seeded delay of 0 to 20 s.
- Fault layer (`RAVON_FAULTS`): `seed=r1-2026-10,drop=0.2,dup=0.1,delayMinMs=0,delayMaxMs=30000`.
  Per delivery: 20% acknowledged and dropped, 10% forwarded twice, the rest once, each
  forward after its own uniform 0 to 30 s delay.
- Crash injection (`RAVON_CRASH`): `seed=r1-crash,rate=0.15,point=after_fulfillment_reply`.
  The worker SIGKILLs itself after Shopify replies to `fulfillmentCreate` and before the
  local commit, on the first attempt of each selected job. Expected about 30 of 200.
  **R1 is valid only if at least 20 kills happen** (counted twice: lines in
  `RAVON_CRASH_LOG`, and SIGKILL exits seen by the supervisor; they must agree).
- Sweep: every 60 s, overlap 300 s, page size 50.
- Simulation: 40 couriers, 2 s per step (a 10 s delivery run). Lease 15 s.
- Dispatch: the **local** Kotlin `ravon-api` built from `services/` at the run's SHA, never
  the deployed one.
- Reported: jobs, dispatches and fulfillments per order (distribution, not just the mean);
  orders with every delivery dropped; orders recovered by the sweep; time to recover
  (job created minus Shopify `createdAt`, p50 and max); deliveries dropped, duplicated and
  reordered (realized counts); throttle events; kills.

## Security probes (after R1, faults off, same app and database)

- 10 tampered: a captured delivery with one byte of the body changed, original HMAC. Expect 401.
- 10 same-id replays: a captured delivery resent byte for byte. Expect outcome `duplicate`.
- 10 new-id replays: a captured body re-signed with the app secret under a fresh
  `X-Shopify-Webhook-Id` (HMAC does not cover headers, so the receipt table cannot catch
  this). Expect no new job and no new dispatch.

## Negative controls on the development store (each 30 orders, R1's fault parameters)

| Run | Off | Schema | Predicted failure |
|---|---|---|---|
| R2 | `dedupe` (receipts and job key) | `--control no_job_key` | at least one order with 2+ jobs and 2+ dispatches |
| R3 | `sweep` | normal | every order whose deliveries were all dropped is never dispatched |
| R4 | `status_check`, crash rate 0.5 | normal | every crashed job's retry sends a second `fulfillmentCreate`. **Two outcomes are possible and both are reported:** Shopify creates a second fulfillment, or Shopify refuses it because the fulfillment order is already closed. If Shopify refuses, the control shows the job ending `failed` instead of `done`, not a double fulfillment, and the report says so. |

## Throttle burst (R6, development store, read-only)

300 `RavonOrderFulfillmentState` queries, concurrency 10, as fast as possible: once with
pacing on (expect 0 THROTTLED), once with `RAVON_DISABLE=pacing` (expect more than 0).
The bucket's `maximumAvailable` and `restoreRate` are recorded from the responses.

## Flash-sale replay (F1, local, synthetic load)

- The `orders/create` payloads captured in R1, cloned into **1,000 orders** with new ids,
  re-signed with the app secret, sent in **60 s** at a uniform rate, plus **100 duplicate
  deliveries** (same webhook id, resent at a random later point in the minute). No drops.
- Target: the local web server (`react-router-serve` build), the worker, the **local**
  Kotlin `ravon-api`, and the harness's fake Shopify for every Admin API call (the
  development store cannot hold 1,000 orders a minute: see the 5 per minute limit).
  Fake bucket set to the `maximumAvailable` and `restoreRate` measured in R1/R6.
- 300 simulated couriers, 0.5 s per step, so courier supply is not what is measured.
- Reported: webhook-to-dispatch latency p50 and p99 (dispatch `assigned_at` minus the
  first delivery's `arrived_at`), duplicate jobs (target 0), duplicate dispatches
  (target 0), throttle events. Labelled synthetic load everywhere.

## CI (fake Shopify, recorded payloads, no network, no secrets)

Same harness against `harness/fake-shopify.ts`, payload shapes from the captured R1
deliveries (scrubbed), HMACs computed with a dummy secret. Full run: 200 + 20 orders,
drop 0.2, dup 0.1, delay 0 to 3 s, crash rate 0.15, sweep every 2 s with 10 s overlap,
fake search-index lag 0.5 to 1.5 s, 100 ms steps, 1.5 s lease. It must meet every target
above. Each negative control (dedupe, receipts-only, sweep, status_check, lifecycle,
pacing, sweep overlap 0) must show its predicted failure, or the job fails.

## Amendments

- Before this file was committed, the harness was run against the fake Shopify while it
  was being written, to debug it. Those runs are not reported anywhere. The first was
  what showed that a restarted worker bursts into a drained bucket (57 THROTTLED with
  pacing on), which led to the persisted bucket model in `throttle.server.ts`.
- 2026-10-01, before any reported run: the `overlap0` control is run at search-index lag
  1 to 5 s with sweeps every 1 s, paired with an `overlap_on` run at the same settings,
  instead of at the full run's 0.5 to 1.5 s lag. At the full run's settings a miss needs
  the sweep to land in a sub-second window, about 6% per all-dropped order, so with about
  6 such orders per run the control would show its failure in only about 30% of runs. The
  first local run of `overlap0` at the old settings did not show a miss.
- 2026-10-01: the harness's settle check now counts Admin API requests as progress and
  waits 30 s of no change while jobs are still moving. The old 6 s rule ended `pacing_on`
  while the pacer was correctly waiting out a small bucket (21 of 100 fulfilled).
