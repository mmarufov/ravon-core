-- Migration 12: tiered earnings on courier_earnings + helper functions.
-- Per Workstream G.
--
-- - earning_type: full | partial_assigned | partial_at_restaurant |
--   partial_picked_up_lost | no_show_compensation | manual_adjustment | clawback
-- - tier_pct: 0 / 25 / 50 / 100 / -100 (clawback)
-- - cancellation_reason_code: typed if non-null
-- - status_at_event: snapshot of order.status at the moment of credit
--
-- The `delivered` trigger from Bunch 2 already inserts a default-tier row.
-- We retag those existing rows with earning_type='full', tier_pct=100.
-- New non-delivered cancellation/no-show paths insert via
-- insert_courier_earning_for_cancel(...).

BEGIN;

ALTER TABLE courier_earnings
  ADD COLUMN IF NOT EXISTS earning_type text NOT NULL DEFAULT 'full',
  ADD COLUMN IF NOT EXISTS tier_pct int NOT NULL DEFAULT 100,
  ADD COLUMN IF NOT EXISTS cancellation_reason_code text,
  ADD COLUMN IF NOT EXISTS status_at_event order_status;

-- Backfill historical rows.
UPDATE courier_earnings SET earning_type = 'full', tier_pct = 100 WHERE earning_type IS NULL OR earning_type = '';

ALTER TABLE courier_earnings DROP CONSTRAINT IF EXISTS courier_earnings_type_valid;
ALTER TABLE courier_earnings ADD CONSTRAINT courier_earnings_type_valid CHECK (
  earning_type IN (
    'full','partial_assigned','partial_at_restaurant',
    'partial_picked_up_lost','no_show_compensation','manual_adjustment','clawback'
  )
);

-- Tier table: status_at_cancel → tier_pct. Source of truth for partial-pay rule.
CREATE OR REPLACE FUNCTION earnings_tier_for_cancel(p_status_at_cancel order_status)
RETURNS int LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p_status_at_cancel
    WHEN 'assigned'                   THEN 25
    WHEN 'courier_arrived_restaurant' THEN 50
    WHEN 'picked_up'                  THEN 100
    WHEN 'delivering'                 THEN 100
    WHEN 'courier_arrived_customer'   THEN 100
    ELSE 0
  END;
$$;

CREATE OR REPLACE FUNCTION earning_type_for_status(p_status order_status)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p_status
    WHEN 'assigned'                   THEN 'partial_assigned'
    WHEN 'courier_arrived_restaurant' THEN 'partial_at_restaurant'
    WHEN 'picked_up'                  THEN 'partial_picked_up_lost'
    WHEN 'delivering'                 THEN 'partial_picked_up_lost'
    WHEN 'courier_arrived_customer'   THEN 'partial_picked_up_lost'
    ELSE 'manual_adjustment'
  END;
$$;

-- Insert helper for non-delivered earnings (cancellations + no-show + clawback).
-- p_tier_override allows clawbacks (negative percent) and manual adjustments.
CREATE OR REPLACE FUNCTION insert_courier_earning_for_cancel(
  p_order_id uuid,
  p_courier_id uuid,
  p_status_at_cancel order_status,
  p_reason_code text,
  p_tier_override int DEFAULT NULL,
  p_earning_type_override text DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_delivery_fee numeric;
  v_tier int;
  v_amount numeric;
  v_type text;
BEGIN
  SELECT delivery_fee INTO v_delivery_fee FROM orders WHERE id = p_order_id;
  IF v_delivery_fee IS NULL THEN RETURN; END IF;

  v_tier := COALESCE(p_tier_override, earnings_tier_for_cancel(p_status_at_cancel));
  v_type := COALESCE(p_earning_type_override, earning_type_for_status(p_status_at_cancel));
  v_amount := round((v_delivery_fee * v_tier / 100.0)::numeric, 2);

  -- ON CONFLICT: protect against duplicate earnings if a path retries.
  INSERT INTO courier_earnings(
    courier_id, order_id, delivery_fee, tip_amount, total_earned,
    earning_type, tier_pct, cancellation_reason_code, status_at_event
  ) VALUES (
    p_courier_id, p_order_id, v_delivery_fee, 0, v_amount,
    v_type, v_tier, p_reason_code, p_status_at_cancel
  )
  ON CONFLICT (order_id) DO UPDATE SET
    earning_type = EXCLUDED.earning_type,
    tier_pct = EXCLUDED.tier_pct,
    total_earned = EXCLUDED.total_earned,
    cancellation_reason_code = EXCLUDED.cancellation_reason_code,
    status_at_event = EXCLUDED.status_at_event;
END;
$$;

GRANT EXECUTE ON FUNCTION earnings_tier_for_cancel(order_status) TO authenticated;
GRANT EXECUTE ON FUNCTION earning_type_for_status(order_status) TO authenticated;

COMMIT;
