-- Measurement tables for the fault harness. Not part of the app: nothing in
-- app/delivery reads them, and production never writes them (the fault layer and the
-- capture hook are off unless RAVON_FAULTS / RAVON_CAPTURE are set).

CREATE SCHEMA IF NOT EXISTS harness;

CREATE TABLE IF NOT EXISTS harness.fault_log (
  id               bigserial PRIMARY KEY,
  webhook_id       text NOT NULL,
  topic            text,
  order_gid        text,
  action           text NOT NULL CHECK (action IN ('drop','once','dup')),
  delays_ms        int[] NOT NULL,
  arrived_at       timestamptz NOT NULL,
  forward_statuses int[] NOT NULL DEFAULT '{}',
  forwarded_at     timestamptz[] NOT NULL DEFAULT '{}'
);

-- Raw deliveries as Shopify sent them, for the recorded-payload CI run and the
-- flash-sale replay. Exported scrubbed (harness/export-capture.ts); never committed raw.
CREATE TABLE IF NOT EXISTS harness.capture (
  id         bigserial PRIMARY KEY,
  arrived_at timestamptz NOT NULL,
  headers    jsonb NOT NULL,
  raw_body   text NOT NULL
);
