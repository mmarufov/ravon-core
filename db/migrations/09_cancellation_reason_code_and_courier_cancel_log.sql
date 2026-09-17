-- Migration 09: typed cancellation reason code + cancelled_by_courier enum value
-- + per-courier cancel log (for cooldown enforcement).
-- Per Workstream B.

-- 1. Add 'cancelled_by_courier' to order_status enum (terminal).
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_enum WHERE enumlabel = 'cancelled_by_courier'
      AND enumtypid = (SELECT oid FROM pg_type WHERE typname='order_status')
  ) THEN
    ALTER TYPE order_status ADD VALUE 'cancelled_by_courier';
  END IF;
END $$;

-- 2. Typed reason code on orders. Coexists with legacy free-text cancellation_reason.
ALTER TABLE orders
  ADD COLUMN IF NOT EXISTS cancellation_reason_code text;

ALTER TABLE orders DROP CONSTRAINT IF EXISTS cancellation_reason_code_valid;
ALTER TABLE orders ADD CONSTRAINT cancellation_reason_code_valid CHECK (
  cancellation_reason_code IS NULL OR cancellation_reason_code IN (
    -- Consumer-initiated
    'CONSUMER_CHANGED_MIND','CONSUMER_DUPLICATE',
    -- Restaurant-initiated
    'RESTAURANT_CLOSED','RESTAURANT_OUT_OF_ITEMS','RESTAURANT_REJECTED','RESTAURANT_TOO_LONG_WAIT',
    -- Courier-initiated (whitelist for cancel_order_by_courier)
    'COURIER_VEHICLE_ISSUE','COURIER_SAFETY_ISSUE','COURIER_RESTAURANT_CLOSED',
    'COURIER_ITEMS_UNAVAILABLE','COURIER_NON_RESPONSIVE',
    -- System-initiated
    'SYSTEM_TIMEOUT','SYSTEM_FRAUD_SUSPECTED',
    -- Pre-existing scheduled-order cancellation reasons (Umbrella I)
    'RESTAURANT_NOT_OPEN_AT_SCHEDULED_TIME','ITEM_UNAVAILABLE','INSUFFICIENT_STOCK','ITEM_DELETED',
    -- Customer no-show (Workstream I — informational; no_show=true on delivered)
    'CUSTOMER_NO_SHOW'
  )
);

-- 3. Courier cancellation log — feeds 24h cooldown logic.
CREATE TABLE IF NOT EXISTS courier_cancellation_log (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  courier_id uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  order_id   uuid NOT NULL REFERENCES orders(id)   ON DELETE CASCADE,
  reason_code text NOT NULL,
  status_at_cancel order_status NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS courier_cancellation_log_recent_idx
  ON courier_cancellation_log(courier_id, created_at DESC);

ALTER TABLE courier_cancellation_log ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS courier_cancel_log_self_select ON courier_cancellation_log;
CREATE POLICY courier_cancel_log_self_select ON courier_cancellation_log
  FOR SELECT TO authenticated
  USING (courier_id = auth.uid());

-- INSERT only via SECURITY DEFINER RPCs in migration 13 (no direct INSERT policy).
