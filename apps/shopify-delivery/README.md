# Ravon local delivery for Shopify

A Shopify app that turns a store's orders into Ravon deliveries **exactly once**. It keeps
that guarantee when Shopify's webhooks are missed, duplicated or out of order, and when
the app is killed halfway through writing a fulfillment back.

It runs on a Shopify **development store with test orders**. The couriers are
**simulated**. No real merchant, buyer, courier or money is involved.

The app is Shopify's React Router template (see `TEMPLATE.md` for what is template code)
plus the delivery code in `app/delivery/`, `app/routes/webhooks.orders.tsx`, `db/` and
`harness/`. OAuth, session storage, HMAC verification and the GraphQL client are the
template's.

## How it works

```
Shopify ── orders/create, orders/updated, orders/cancelled ──▶ webhooks.orders.tsx
              (HMAC: template's authenticate.webhook)                │
                                                                     ▼
           ┌───────────────── one transaction ─────────────────────────────┐
           │ webhook_receipts (X-Shopify-Webhook-Id) ─ duplicate? ─▶ ack    │
           │ ingestSnapshot: jobs UNIQUE (shop, order_gid)                  │
           │   stale (older updated_at)?  refuse                            │
           │   edge not in Ravon's 36?   refuse   (and a trigger refuses)   │
           └────────────────────────────────────────────────────────────────┘
                     ▲                                   │
   sweep: orders(query: updated_at >= watermark - overlap)   worker (separate process)
   through the same ingestSnapshot                    │ dispatch: Assign (local Kotlin ravon-api)
                                                      │ simulated courier run, 5 declared edges
                                                      ▼
                         fulfillment: intent ─▶ read Shopify ─▶ fulfillmentCreate ─▶ fenced commit
                         all Admin API calls paced by extensions.cost.throttleStatus
```

| Guarantee | Mechanism | Where |
|---|---|---|
| One job per order | `UNIQUE (shop, order_gid)`; webhook and sweep share one ingest path | `db/001_delivery.sql`, `app/delivery/intake.server.ts` |
| A redelivery has no effect | receipt keyed on `X-Shopify-Webhook-Id`, committed **with** the effect | `intake.server.ts` (`handleOrderDelivery`) |
| A stale or out-of-order event is refused | Shopify `updated_at` as the version clock; Ravon's transition table, also enforced by a trigger | `app/delivery/lifecycle.ts`, `db/001_delivery.sql` |
| One dispatch per job | `UNIQUE (job_id)` on dispatches; job rows locked across the `Assign` call | `app/delivery/dispatch.server.ts` |
| One fulfillment across crashes | intent committed before the call; Shopify read before any write; commit fenced by lease owner and attempt | `app/delivery/fulfillment.server.ts` |
| A dropped webhook's order is still delivered | sweep with a watermark and an overlap window | `app/delivery/sweep.server.ts` |
| The Admin API is not throttled | pacing from `throttleStatus`, model persisted across restarts | `app/delivery/throttle.server.ts` |

The lifecycle table is Ravon's: the same 36 edges as
`Sources/RavonCore/Models/OrderLifecycle.swift` and `db/schema/03_lifecycle.sql`. The app
seeds them from `app/delivery/lifecycle.edges.json`, which `scripts/lifecycle_parity.py`
generates from the SQL and checks in CI.

## Running it

```sh
npm ci && npx prisma generate && npx prisma migrate deploy
export RAVON_PG_URL=postgresql://...      # jobs live here, not in the template's SQLite
export RAVON_DISPATCH_URL=http://127.0.0.1:18480   # a local ravon-api from ../../services
npm run db:migrate
shopify app dev --store <dev-store>.myshopify.com   # web server + tunnel
npm run worker                                      # dispatch, fulfillment, sweep
```

The worker needs the same app env as the web server (`shopify app env show`), kept in
your shell and never in a file in the repo.

## Evidence

- `PREREGISTRATION.md`: fault rates, seeds, kill point and metrics, committed before any
  reported run.
- `harness/run.ts` against `harness/fake-shopify.ts`: what CI runs on every PR. That is
  the full scenario plus a negative control for every mechanism, each required to show
  the failure the mechanism prevents.
- `harness/real-store.ts`: the development-store runs. `harness/flash-sale.ts`: the
  synthetic-load replay.
- `RESULTS.md`: every number, with its command, SHA, date and machine.
