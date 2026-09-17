-- Migration 6: Scheduled-for-later orders.
-- Per Workstream F + user decision #1.
-- Apply AFTER migration 04 (create_order v3 must already accept p_scheduled_for).

-- New column: NULL = ASAP, non-null = scheduled time
ALTER TABLE orders ADD COLUMN IF NOT EXISTS scheduled_for timestamptz NULL;

-- Add 'scheduled' to the order_status enum at the front (preserves all existing rawValues).
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_enum WHERE enumlabel = 'scheduled'
      AND enumtypid = (SELECT oid FROM pg_type WHERE typname = 'order_status')
  ) THEN
    ALTER TYPE order_status ADD VALUE 'scheduled' BEFORE 'created';
  END IF;
END$$;

-- Activation function: moves a scheduled order to 'created', re-validates, decrements stock.
-- Idempotent — calling twice for the same order is a no-op.
CREATE OR REPLACE FUNCTION activate_scheduled_order(p_order_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  o    orders%ROWTYPE;
  r    restaurants%ROWTYPE;
  rec  record;
  mi   menu_items%ROWTYPE;
BEGIN
  SELECT * INTO o FROM orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND OR o.status <> 'scheduled' THEN
    RETURN;
  END IF;

  SELECT * INTO r FROM restaurants WHERE id = o.restaurant_id FOR UPDATE;
  IF NOT FOUND OR r.restaurant_status <> 'active'
     OR NOT restaurant_within_hours(r.id, COALESCE(o.scheduled_for, now())) THEN
    UPDATE orders SET status = 'cancelled_by_system',
                      cancellation_reason = 'RESTAURANT_NOT_OPEN_AT_SCHEDULED_TIME',
                      updated_at = now()
    WHERE id = o.id;
    RETURN;
  END IF;

  -- Re-validate items + decrement stock
  FOR rec IN
    SELECT id AS oi_id, menu_item_id, quantity
    FROM order_items
    WHERE order_id = o.id
  LOOP
    IF rec.menu_item_id IS NULL THEN
      UPDATE orders SET status = 'cancelled_by_system',
                        cancellation_reason = 'ITEM_DELETED',
                        updated_at = now()
      WHERE id = o.id;
      RETURN;
    END IF;
    SELECT * INTO mi FROM menu_items WHERE id = rec.menu_item_id FOR UPDATE;
    IF NOT FOUND OR mi.deleted_at IS NOT NULL OR mi.is_available = false THEN
      UPDATE orders SET status = 'cancelled_by_system',
                        cancellation_reason = 'ITEM_UNAVAILABLE',
                        updated_at = now()
      WHERE id = o.id;
      RETURN;
    END IF;
    IF mi.stock_count IS NOT NULL AND mi.stock_count < rec.quantity THEN
      UPDATE orders SET status = 'cancelled_by_system',
                        cancellation_reason = 'INSUFFICIENT_STOCK',
                        updated_at = now()
      WHERE id = o.id;
      RETURN;
    END IF;
    IF mi.stock_count IS NOT NULL THEN
      UPDATE menu_items SET stock_count = stock_count - rec.quantity WHERE id = mi.id;
    END IF;
  END LOOP;

  UPDATE orders SET status = 'created', updated_at = now() WHERE id = o.id;
END;
$$;

-- Sweep function: activates all due scheduled orders.
CREATE OR REPLACE FUNCTION activate_scheduled_orders()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  rec record;
BEGIN
  FOR rec IN
    SELECT o.id
    FROM orders o
    JOIN restaurants r ON r.id = o.restaurant_id
    WHERE o.status = 'scheduled'
      AND o.scheduled_for - (COALESCE(r.delivery_time_min, 30) || ' minutes')::interval <= now()
  LOOP
    PERFORM activate_scheduled_order(rec.id);
  END LOOP;
END;
$$;

GRANT EXECUTE ON FUNCTION activate_scheduled_order(uuid) TO authenticated;

-- pg_cron: run every minute
SELECT cron.schedule(
  'activate_scheduled_orders',
  '* * * * *',
  $$ SELECT activate_scheduled_orders(); $$
);
