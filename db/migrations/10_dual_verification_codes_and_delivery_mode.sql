-- Migration 10: dual verification codes + delivery mode + photo-proof column.
-- Per Workstreams C + J.
--
-- - delivery_verification_code: 4-digit, generated alongside the existing
--   pickup verification_code at order INSERT. Consumer sees it; courier
--   enters it at delivery to confirm hand-off.
-- - delivery_mode: 'hand_to_me' | 'leave_at_door'. Defaulted from address.
-- - delivery_proof_url: URL to a photo in the 'delivery-proofs' bucket;
--   required when delivery_mode='leave_at_door'.

BEGIN;

ALTER TABLE orders
  ADD COLUMN IF NOT EXISTS delivery_verification_code text;

ALTER TABLE addresses
  ADD COLUMN IF NOT EXISTS default_delivery_mode text NOT NULL DEFAULT 'hand_to_me';

ALTER TABLE addresses DROP CONSTRAINT IF EXISTS addresses_delivery_mode_valid;
ALTER TABLE addresses ADD CONSTRAINT addresses_delivery_mode_valid CHECK (
  default_delivery_mode IN ('hand_to_me','leave_at_door')
);

ALTER TABLE orders
  ADD COLUMN IF NOT EXISTS delivery_mode text NOT NULL DEFAULT 'hand_to_me',
  ADD COLUMN IF NOT EXISTS delivery_proof_url text;

ALTER TABLE orders DROP CONSTRAINT IF EXISTS orders_delivery_mode_valid;
ALTER TABLE orders ADD CONSTRAINT orders_delivery_mode_valid CHECK (
  delivery_mode IN ('hand_to_me','leave_at_door')
);

-- Update the existing INSERT trigger function to ALSO generate delivery_verification_code.
CREATE OR REPLACE FUNCTION generate_verification_code()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.verification_code IS NULL THEN
    NEW.verification_code := lpad(floor(random() * 9000 + 1000)::text, 4, '0');
  END IF;
  IF NEW.delivery_verification_code IS NULL THEN
    NEW.delivery_verification_code := lpad(floor(random() * 9000 + 1000)::text, 4, '0');
  END IF;
  RETURN NEW;
END;
$$;

-- Backfill delivery_verification_code on existing non-terminal orders.
UPDATE orders
SET delivery_verification_code = lpad(floor(random() * 9000 + 1000)::text, 4, '0')
WHERE delivery_verification_code IS NULL
  AND status NOT IN ('delivered','cancelled','rejected',
                     'cancelled_by_customer','cancelled_by_restaurant','cancelled_by_system');

-- Sync trigger: delivery_mode is copied from the address default at INSERT.
CREATE OR REPLACE FUNCTION sync_order_delivery_mode_from_address()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  v_default text;
BEGIN
  IF NEW.address_id IS NOT NULL THEN
    SELECT default_delivery_mode INTO v_default FROM addresses WHERE id = NEW.address_id;
    IF v_default IS NOT NULL THEN
      NEW.delivery_mode := v_default;
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS orders_sync_delivery_mode ON orders;
CREATE TRIGGER orders_sync_delivery_mode
  BEFORE INSERT ON orders
  FOR EACH ROW EXECUTE FUNCTION sync_order_delivery_mode_from_address();

COMMIT;
