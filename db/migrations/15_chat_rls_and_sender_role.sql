-- Migration 15: chat_messages.sender_role + RLS lifecycle gate.
-- Per Workstream H.
--
-- - sender_role: 'consumer' | 'courier' | 'merchant' | 'system'.
-- - INSERT allowed when order status is in active set, or within 5-minute
--   grace window after delivered_at (lets consumer/courier follow up).
-- - SELECT allowed for 30 days post-terminal for dispute reference.

BEGIN;

ALTER TABLE chat_messages
  ADD COLUMN IF NOT EXISTS sender_role text;

ALTER TABLE chat_messages DROP CONSTRAINT IF EXISTS chat_messages_sender_role_valid;
ALTER TABLE chat_messages ADD CONSTRAINT chat_messages_sender_role_valid
  CHECK (sender_role IS NULL OR sender_role IN ('consumer','courier','merchant','system'));

-- Backfill from profiles.role for existing rows.
UPDATE chat_messages cm SET sender_role = p.role::text
FROM profiles p WHERE cm.sender_id = p.id AND cm.sender_role IS NULL;

-- Trigger: auto-set sender_role on INSERT from profiles.role (so RLS can check it).
CREATE OR REPLACE FUNCTION set_chat_sender_role()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.sender_role IS NULL THEN
    SELECT role::text INTO NEW.sender_role FROM profiles WHERE id = NEW.sender_id;
    NEW.sender_role := COALESCE(NEW.sender_role, 'system');
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS chat_messages_set_sender_role ON chat_messages;
CREATE TRIGGER chat_messages_set_sender_role
  BEFORE INSERT ON chat_messages
  FOR EACH ROW EXECUTE FUNCTION set_chat_sender_role();

-- Drop existing policies (Russian-named, from migration create_chat_messages).
DROP POLICY IF EXISTS "Order participants can read chat" ON chat_messages;
DROP POLICY IF EXISTS "Order participants can send chat" ON chat_messages;
DROP POLICY IF EXISTS "Recipients can mark chat read" ON chat_messages;

-- INSERT: order is in chat-active status OR within 5-min grace post-delivery.
-- Allowed actors: order user, courier, restaurant owner. Sender must be auth.uid().
CREATE POLICY chat_messages_insert ON chat_messages
FOR INSERT TO authenticated
WITH CHECK (
  sender_id = auth.uid()
  AND EXISTS (
    SELECT 1 FROM orders o
    LEFT JOIN restaurants r ON r.id = o.restaurant_id
    WHERE o.id = chat_messages.order_id
      AND (o.user_id = auth.uid() OR o.courier_id = auth.uid() OR r.owner_id = auth.uid())
      AND (
        o.status IN ('assigned','courier_arrived_restaurant','picked_up','delivering','courier_arrived_customer')
        OR (o.status = 'delivered' AND o.delivered_at > now() - interval '5 minutes')
      )
  )
);

-- SELECT: order in active state OR up to 30 days post-terminal.
CREATE POLICY chat_messages_select ON chat_messages
FOR SELECT TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM orders o
    LEFT JOIN restaurants r ON r.id = o.restaurant_id
    WHERE o.id = chat_messages.order_id
      AND (o.user_id = auth.uid() OR o.courier_id = auth.uid() OR r.owner_id = auth.uid())
      AND (
        o.status NOT IN ('delivered','cancelled','cancelled_by_customer','cancelled_by_restaurant',
                         'cancelled_by_system','cancelled_by_courier','rejected')
        OR COALESCE(o.delivered_at, o.updated_at) > now() - interval '30 days'
      )
  )
);

-- UPDATE: only mark messages NOT sent by self as read (set read_at).
CREATE POLICY chat_messages_mark_read ON chat_messages
FOR UPDATE TO authenticated
USING (
  sender_id <> auth.uid()
  AND EXISTS (
    SELECT 1 FROM orders o
    WHERE o.id = chat_messages.order_id
      AND (o.user_id = auth.uid() OR o.courier_id = auth.uid())
  )
)
WITH CHECK (
  sender_id <> auth.uid()
  AND EXISTS (
    SELECT 1 FROM orders o
    WHERE o.id = chat_messages.order_id
      AND (o.user_id = auth.uid() OR o.courier_id = auth.uid())
  )
);

CREATE INDEX IF NOT EXISTS chat_messages_order_recent_idx
  ON chat_messages (order_id, created_at DESC);

COMMIT;
