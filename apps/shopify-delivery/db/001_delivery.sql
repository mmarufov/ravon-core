-- Delivery jobs for the Shopify local-delivery app.
--
-- The template keeps OAuth sessions in SQLite through Prisma. Jobs live here, in
-- PostgreSQL, because the guarantees below are constraints and triggers, not
-- application code: "one delivery per order" is the UNIQUE key on jobs, "an event
-- the lifecycle does not allow is refused" is the trigger, and "each job is dispatched
-- once" is the UNIQUE key on dispatches. A bug in the TypeScript cannot bypass them.
--
-- Everything is in its own schema so a run can be wiped with one DROP SCHEMA.

CREATE SCHEMA IF NOT EXISTS ravon_delivery;
SET search_path = ravon_delivery;

-- Ravon's order lifecycle, the same 36 edges as Sources/RavonCore/Models/OrderLifecycle.swift
-- and db/schema/03_lifecycle.sql. Seeded by migrate.ts from app/delivery/lifecycle.edges.json,
-- which scripts/lifecycle_parity.py checks against both in CI.
CREATE TABLE IF NOT EXISTS transitions (
  from_status text   NOT NULL,
  to_status   text   NOT NULL,
  actor       text   NOT NULL CHECK (actor IN ('consumer','merchant','courier','system')),
  rpc         text   NOT NULL,
  guards      text[] NOT NULL DEFAULT '{}',
  PRIMARY KEY (from_status, to_status, actor, rpc, guards)
);

-- Orders created before a shop's intake window opened are not ours to deliver. Without
-- this, an orders/updated for a year-old order would spawn a courier.
CREATE TABLE IF NOT EXISTS shops (
  shop         text PRIMARY KEY,
  intake_start timestamptz NOT NULL
);

-- Every delivery that passed HMAC verification, duplicates included. Append-only and
-- unconstrained: this is the measurement log, not the dedupe.
CREATE TABLE IF NOT EXISTS webhook_log (
  id           bigserial PRIMARY KEY,
  shop         text NOT NULL,
  webhook_id   text NOT NULL,
  event_id     text,
  topic        text NOT NULL,
  order_gid    text,
  triggered_at timestamptz,
  arrived_at   timestamptz NOT NULL,   -- when the HTTP request reached the app
  handled_at   timestamptz NOT NULL DEFAULT clock_timestamp(),
  outcome      text NOT NULL
);

-- The dedupe. One row per X-Shopify-Webhook-Id, written in the SAME transaction as the
-- delivery's effect on the job. If they committed separately, a crash between them would
-- leave a receipt with no effect, and Shopify's retry would then be skipped as a duplicate:
-- the dedupe itself would lose the order.
CREATE TABLE IF NOT EXISTS webhook_receipts (
  shop        text NOT NULL,
  webhook_id  text NOT NULL,
  topic       text NOT NULL,
  order_gid   text,
  body_sha256 text NOT NULL,
  received_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY (shop, webhook_id)
);

CREATE TABLE IF NOT EXISTS jobs (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  shop                 text NOT NULL,
  order_gid            text NOT NULL,
  order_name           text,
  status               text NOT NULL,
  -- Shopify's version clock for the order. An event older than this is stale.
  shopify_created_at   timestamptz NOT NULL,
  shopify_updated_at   timestamptz NOT NULL,
  shopify_cancelled_at timestamptz,
  created_via          text NOT NULL CHECK (created_via IN ('webhook','sweep')),
  created_by_topic     text,
  -- Arrival time of the earliest delivery for this order, for webhook-to-dispatch latency.
  first_arrived_at     timestamptz,
  pickup_lat  double precision NOT NULL,
  pickup_lng  double precision NOT NULL,
  dropoff_lat double precision NOT NULL,
  dropoff_lng double precision NOT NULL,
  -- Simulated courier progress: when the next step of the delivery run is due.
  sim_next_at          timestamptz,
  courier_id           uuid,
  fulfillment_state    text NOT NULL DEFAULT 'none'
    CHECK (fulfillment_state IN ('none','pending','done','failed','skipped')),
  fulfillment_attempts int  NOT NULL DEFAULT 0,
  fulfillment_gid      text,
  -- Fencing for the fulfillment writer: a worker whose lease was taken over cannot commit.
  lease_owner          text,
  lease_until          timestamptz,
  created_at           timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at           timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT jobs_one_per_order UNIQUE (shop, order_gid)
);

CREATE INDEX IF NOT EXISTS jobs_status_idx ON jobs (status);
CREATE INDEX IF NOT EXISTS jobs_order_idx  ON jobs (shop, order_gid);
CREATE INDEX IF NOT EXISTS jobs_fulfill_idx ON jobs (fulfillment_state) WHERE status = 'delivered';

CREATE TABLE IF NOT EXISTS job_transitions (
  id          bigserial PRIMARY KEY,
  job_id      uuid NOT NULL REFERENCES jobs(id),
  from_status text,
  to_status   text NOT NULL,
  actor       text NOT NULL,
  rpc         text NOT NULL,
  cause       text NOT NULL,     -- webhook topic, 'sweep', 'dispatch' or 'courier_sim'
  webhook_id  text,
  at          timestamptz NOT NULL DEFAULT clock_timestamp()
);

-- Events the job refused, and why. Refusing is the mechanism; this is its audit trail.
CREATE TABLE IF NOT EXISTS rejected_events (
  id               bigserial PRIMARY KEY,
  job_id           uuid REFERENCES jobs(id),
  shop             text NOT NULL,
  order_gid        text NOT NULL,
  source           text NOT NULL,
  webhook_id       text,
  reason           text NOT NULL CHECK (reason IN ('stale','no_edge')),
  requested_status text,
  job_status       text,
  event_updated_at timestamptz,
  job_updated_at   timestamptz,
  at               timestamptz NOT NULL DEFAULT clock_timestamp()
);

-- One row per Assign result. UNIQUE (job_id) makes "dispatched once" a database fact.
CREATE TABLE IF NOT EXISTS dispatches (
  id           bigserial PRIMARY KEY,
  job_id       uuid NOT NULL REFERENCES jobs(id),
  courier_id   uuid NOT NULL,
  cost_minutes double precision NOT NULL,
  batch_id     uuid NOT NULL,
  batch_size   int NOT NULL,
  assigned_at  timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT dispatch_once UNIQUE (job_id)
);

-- The fulfillment intent: committed BEFORE Shopify is called, so a process killed after
-- Shopify accepted the write but before the local commit leaves evidence that a write may
-- have happened. The retry reads Shopify before it writes again.
CREATE TABLE IF NOT EXISTS fulfillment_intents (
  job_id          uuid NOT NULL REFERENCES jobs(id),
  attempt         int  NOT NULL,
  worker          text NOT NULL,
  tracking_number text NOT NULL,
  request         jsonb,
  outcome         text,     -- created | adopted | rejected | skipped_cancelled | error
  fulfillment_gid text,
  detail          text,
  started_at      timestamptz NOT NULL DEFAULT clock_timestamp(),
  finished_at     timestamptz,
  PRIMARY KEY (job_id, attempt)
);

CREATE TABLE IF NOT EXISTS sweep_state (
  shop       text PRIMARY KEY,
  watermark  timestamptz NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE IF NOT EXISTS sweep_runs (
  id            bigserial PRIMARY KEY,
  shop          text NOT NULL,
  started_at    timestamptz NOT NULL,
  finished_at   timestamptz,
  query_from    timestamptz NOT NULL,
  pages         int NOT NULL DEFAULT 0,
  orders_seen   int NOT NULL DEFAULT 0,
  jobs_created  int NOT NULL DEFAULT 0,
  applied       int NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS throttle_events (
  id             bigserial PRIMARY KEY,
  shop           text NOT NULL,
  operation      text NOT NULL,
  kind           text NOT NULL CHECK (kind IN ('throttled','paced')),
  requested_cost double precision,
  available      double precision,
  maximum        double precision,
  restore_rate   double precision,
  wait_ms        double precision,
  at             timestamptz NOT NULL DEFAULT clock_timestamp()
);

-- Simulated couriers. There are no real couriers: these exist so Assign has a supply side.
CREATE TABLE IF NOT EXISTS sim_couriers (
  id         uuid PRIMARY KEY,
  lat        double precision NOT NULL,
  lng        double precision NOT NULL,
  busy_job   uuid,
  idle_since timestamptz NOT NULL
);

-- The lifecycle, enforced where it cannot be skipped. A job is born `created`; a status
-- change must match a declared (from, to, actor, rpc) edge, with actor and rpc set by
-- the caller in transaction-local settings, the same convention as db/schema/03_lifecycle.sql.
CREATE OR REPLACE FUNCTION enforce_job_transition() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  v_actor text := current_setting('ravon.actor', true);
  v_rpc   text := current_setting('ravon.rpc', true);
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.status <> 'created' THEN
      RAISE EXCEPTION 'job must be created in status created, not %', NEW.status
        USING ERRCODE = 'P0001', HINT = 'UNDECLARED_TRANSITION';
    END IF;
    RETURN NEW;
  END IF;
  IF NEW.status = OLD.status THEN
    RETURN NEW;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM ravon_delivery.transitions t
    WHERE t.from_status = OLD.status AND t.to_status = NEW.status
      AND t.actor = v_actor AND t.rpc = v_rpc
  ) THEN
    RAISE EXCEPTION 'undeclared transition % -> % by % via %', OLD.status, NEW.status, v_actor, v_rpc
      USING ERRCODE = 'P0001', HINT = 'UNDECLARED_TRANSITION';
  END IF;
  NEW.updated_at := clock_timestamp();
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS jobs_enforce_transition ON jobs;
CREATE TRIGGER jobs_enforce_transition
  BEFORE INSERT OR UPDATE OF status ON jobs
  FOR EACH ROW EXECUTE FUNCTION enforce_job_transition();

-- The pacer's last view of each shop's cost bucket, so a restarted worker paces from
-- where its predecessor left off instead of from nothing.
CREATE TABLE IF NOT EXISTS throttle_state (
  shop         text PRIMARY KEY,
  available    double precision NOT NULL,
  maximum      double precision NOT NULL,
  restore_rate double precision NOT NULL,
  observed_at  timestamptz NOT NULL,
  costs        jsonb NOT NULL DEFAULT '{}'   -- last requestedQueryCost per operation
);
