-- Migration 08: Courier heartbeat + per-status SLA columns.
-- Per Workstream A.
--
-- Adds:
--   * courier_locations.last_heartbeat_at, last_moved_at, accuracy_meters,
--     ghost_strikes, strikes_reset_at  (smart-ghost detection inputs)
--   * profiles.is_suspended_until                                    (suspension gate)
--   * orders.{claimed_at, arrived_at_restaurant_at,
--             arrived_at_customer_at, expected_action_by, eta_minutes,
--             courier_delay_reason_code, courier_delay_explained_at,
--             courier_no_show_warned_at, courier_no_show_escalated_at}
--     (per-status SLA + escalation ladder state)
--
-- Backfills last_heartbeat_at = COALESCE(last_updated, now()) so existing
-- couriers are not instantly considered ghosts.

BEGIN;

ALTER TABLE courier_locations
  ADD COLUMN IF NOT EXISTS last_heartbeat_at timestamptz,
  ADD COLUMN IF NOT EXISTS last_moved_at     timestamptz,
  ADD COLUMN IF NOT EXISTS accuracy_meters   double precision,
  ADD COLUMN IF NOT EXISTS ghost_strikes     int NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS strikes_reset_at  timestamptz NOT NULL DEFAULT now();

UPDATE courier_locations SET last_heartbeat_at = COALESCE(last_updated, now())
WHERE last_heartbeat_at IS NULL;
UPDATE courier_locations SET last_moved_at = COALESCE(last_updated, now())
WHERE last_moved_at IS NULL;

ALTER TABLE courier_locations
  ALTER COLUMN last_heartbeat_at SET NOT NULL,
  ALTER COLUMN last_heartbeat_at SET DEFAULT now(),
  ALTER COLUMN last_moved_at     SET NOT NULL,
  ALTER COLUMN last_moved_at     SET DEFAULT now();

ALTER TABLE profiles
  ADD COLUMN IF NOT EXISTS is_suspended_until timestamptz NULL;

ALTER TABLE orders
  ADD COLUMN IF NOT EXISTS claimed_at                   timestamptz,
  ADD COLUMN IF NOT EXISTS arrived_at_restaurant_at     timestamptz,
  ADD COLUMN IF NOT EXISTS arrived_at_customer_at       timestamptz,
  ADD COLUMN IF NOT EXISTS expected_action_by           timestamptz,
  ADD COLUMN IF NOT EXISTS courier_delay_reason_code    text,
  ADD COLUMN IF NOT EXISTS courier_delay_explained_at   timestamptz,
  ADD COLUMN IF NOT EXISTS courier_no_show_warned_at    timestamptz,
  ADD COLUMN IF NOT EXISTS courier_no_show_escalated_at timestamptz,
  ADD COLUMN IF NOT EXISTS eta_minutes                  int;

CREATE INDEX IF NOT EXISTS courier_locations_heartbeat_idx
  ON courier_locations (last_heartbeat_at)
  WHERE is_online = true;

CREATE INDEX IF NOT EXISTS orders_action_sla_idx
  ON orders (expected_action_by)
  WHERE status IN ('assigned','courier_arrived_restaurant','picked_up','delivering','courier_arrived_customer');

COMMIT;
