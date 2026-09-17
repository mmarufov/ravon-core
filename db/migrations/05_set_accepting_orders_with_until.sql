-- Migration 5: set_accepting_orders RPC with auto-resume + pg_cron flip-back.
-- Per Workstream B + decision #4.

ALTER TABLE restaurants ADD COLUMN IF NOT EXISTS accepting_orders_until timestamptz NULL;

-- RPC: owner-only setter for is_accepting_orders + accepting_orders_until.
CREATE OR REPLACE FUNCTION set_accepting_orders(
  p_restaurant_id uuid,
  p_accepting     boolean,
  p_until         timestamptz DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  is_owner boolean;
BEGIN
  SELECT EXISTS(
    SELECT 1 FROM restaurants
    WHERE id = p_restaurant_id AND owner_id = auth.uid()
  ) INTO is_owner;

  IF NOT is_owner THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = '42501';
  END IF;

  -- "until" only meaningful when toggling OFF
  IF p_accepting THEN
    UPDATE restaurants
    SET is_accepting_orders = true, accepting_orders_until = NULL
    WHERE id = p_restaurant_id;
  ELSE
    UPDATE restaurants
    SET is_accepting_orders = false, accepting_orders_until = p_until
    WHERE id = p_restaurant_id;
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION set_accepting_orders(uuid, boolean, timestamptz) TO authenticated;

-- pg_cron job: every 5 minutes flip restaurants back when accepting_orders_until <= now()
-- Requires the pg_cron extension to be enabled (already in use for Batch 1 auto-cancel).
SELECT cron.schedule(
  'auto_resume_accepting_orders',
  '*/5 * * * *',
  $$
    UPDATE restaurants
    SET is_accepting_orders = true, accepting_orders_until = NULL
    WHERE is_accepting_orders = false
      AND accepting_orders_until IS NOT NULL
      AND accepting_orders_until <= now();
  $$
);
