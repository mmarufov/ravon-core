# Architecture

One diagram. It is deliberately small enough to redraw on a whiteboard in five minutes,
because that is what it is for.

**Solid lines exist today. Dashed lines do not** — the service tier is in extraction and
the Supabase project behind the right-hand side has been deleted. See
[what is real](../README.md#whats-real-whats-simulated-whats-not-built).

```mermaid
flowchart TB
    subgraph clients["Untrusted — ships on a device the user controls"]
        C["Consumer iOS<br/>browse · order · track"]
        M["Merchant iOS<br/>menu · hours · queue"]
        K["Courier iOS<br/>claim · navigate · deliver"]
    end

    CORE["<b>RavonCore</b> — shared Swift package<br/>models · auth · realtime · theme<br/><i>~90% of client surface</i>"]

    C --- CORE
    M --- CORE
    K --- CORE

    subgraph trusted["Trusted — server-side, holds credentials clients never see"]
        direction TB
        SVC["<b>Service tier</b> (Kotlin, in extraction)<br/>dispatch · order saga · ledger · fraud"]
        PG[("<b>PostgreSQL</b><br/>RLS · pg_cron · PostGIS<br/>append-only transition log")]
        RT["Realtime<br/>(Postgres CDC → WebSocket)"]
        AUTH["Supabase Auth<br/>email OTP · JWT"]

        SVC -.->|"service role"| PG
        PG --> RT
    end

    CORE ==>|"PostgREST: reads<br/>menus · restaurants · history"| PG
    CORE ==>|"WebSocket: order status,<br/>courier location, chat"| RT
    CORE ==>|"JWT"| AUTH
    CORE -.->|"gRPC: writes<br/>place · assign · settle"| SVC

    AUTH -.->|"JWKS: verify iss/aud/exp,<br/>sub → user id"| SVC

    style trusted fill:#f6f6f8,stroke:#1A1A2E,stroke-width:2px
    style clients fill:#fff4f1,stroke:#FF3008,stroke-width:2px
    style SVC stroke-dasharray: 5 5
```

## Reading it

**The trust boundary is the box, not the network hop.** Everything in the top box runs on
hardware the user owns, so every value it sends is an assertion, not a fact. The anon key
it ships with is public client config; anything reachable with it must be safe against
someone calling the API directly with `curl`. That is why RLS stays on even after the
service tier lands — it becomes defence in depth behind the service rather than the only
gate.

**Two transports, on purpose.** Commands (place an order, assign a courier, move money)
go over gRPC to the service tier because they need global state and transactional
integrity. Reads and subscriptions stay on PostgREST and Supabase Realtime because a
generated typed client and a working Postgres-CDC websocket already exist and rebuilding
them buys nothing. This is what an incremental extraction looks like partway through; see
[ADR 0005](adr/0005-extract-to-kotlin-not-rewrite.md).

**One identity, two transports.** The clients hold a Supabase JWT. The service tier
verifies it against Supabase's JWKS endpoint and connects to Postgres as its own role —
not as the end user — which is how it can write rows clients cannot.

**Dispatch does not belong on a phone.** It currently lives in `Sources/RavonCore/Dispatch/`,
which is a layering error stated plainly: a courier's phone cannot see the other couriers,
and minimum-cost matching is meaningless without them. It sits there because that is where
it could be built and measured; it is the first thing that moves. See
[ADR 0005](adr/0005-extract-to-kotlin-not-rewrite.md).

## The five things to say out loud when drawing it

1. Three clients, one shared package — the apps are thin.
2. The line around the server side is a trust boundary, and the clients are outside it.
3. Writes go through a service that owns global state; reads go straight to Postgres.
4. Realtime is Postgres change-data-capture, not a second source of truth.
5. Auth is one identity provider; the service verifies, it does not issue.
