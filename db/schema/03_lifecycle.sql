-- 03_lifecycle.sql — the order lifecycle as data, enforced.
--
-- Sources/RavonCore/Models/OrderLifecycle.swift declares 36 edges, each pinned
-- to the RPC that performs it. Until now that declaration lived only in Swift
-- while the database enforced its own copy in the guards of 13 SECURITY DEFINER
-- functions. ADR 0001 says the Swift table is the single source of truth; the
-- comment at OrderLifecycle.swift:6-11 records what the drift cost — the
-- merchant UI hid an order at `.assigned`, exactly when the courier was at the
-- counter asking for the pickup code.
--
-- This file makes the two copies one copy. The 36 rows below are transcribed
-- from that file and nothing else, and `orders_enforce_transition` rejects any
-- status change with no matching row. An RPC cannot perform an undeclared
-- transition even by accident, and `invariants.sql` asserts the row count so
-- adding an edge to Swift without adding it here fails CI.
--
-- This is the project's own thesis applied to itself: every fleet bug was an
-- unenforced contract.

CREATE TABLE IF NOT EXISTS public.order_transitions (
  id          int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  from_status order_status NOT NULL,
  to_status   order_status NOT NULL,
  actor       text NOT NULL CHECK (actor IN ('consumer','merchant','courier','system')),
  rpc         text NOT NULL,
  guards      text[] NOT NULL DEFAULT ARRAY[]::text[],
  CONSTRAINT order_transitions_uniq UNIQUE (from_status, to_status, actor, rpc, guards)
);

-- Idempotent reseed: the table is a transcription, so it is replaced wholesale
-- rather than patched.
TRUNCATE public.order_transitions;

INSERT INTO public.order_transitions (from_status, to_status, actor, rpc, guards) VALUES
  -- system
  ('scheduled','created','system','activate_scheduled_orders','{}'),

  -- merchant
  ('created',  'accepted', 'merchant','merchant_accept_order',    '{}'),
  ('created',  'rejected', 'merchant','merchant_reject_order',    '{}'),
  ('accepted', 'preparing','merchant','merchant_start_preparing', '{}'),
  ('accepted', 'ready',    'merchant','merchant_mark_order_ready','{}'),
  ('preparing','ready',    'merchant','merchant_mark_order_ready','{}'),

  -- courier: claim. `claim_order` accepts any pickupable status, so a courier
  -- may claim before the food is ready; all three edges converge on `assigned`.
  ('accepted', 'assigned','courier','claim_order','{courierOnline,courierNotBusy,courierNotSuspended}'),
  ('preparing','assigned','courier','claim_order','{courierOnline,courierNotBusy,courierNotSuspended}'),
  ('ready',    'assigned','courier','claim_order','{courierOnline,courierNotBusy,courierNotSuspended}'),

  -- courier: the delivery run
  ('assigned',                  'courier_arrived_restaurant','courier','courier_arrived_restaurant','{}'),
  ('courier_arrived_restaurant','picked_up',                 'courier','courier_pickup_order','{pickupCode}'),
  ('picked_up',                 'delivering',                'courier','courier_start_delivering','{}'),
  ('delivering',                'courier_arrived_customer',  'courier','courier_arrived_at_customer','{}'),
  -- Hand-to-customer needs the code; leave-at-door needs a photo instead. Two
  -- edges, same endpoints, different guard — which is why `guards` is part of
  -- the uniqueness key.
  ('courier_arrived_customer','delivered','courier','courier_deliver_order','{deliveryCode}'),
  ('courier_arrived_customer','delivered','courier','courier_deliver_order','{proofImage}'),

  -- courier: pre-pickup cancel. Note these are BACKWARD edges — the order
  -- becomes claimable again rather than terminal, so "orders only move forward"
  -- is false and termination is not provable by acyclicity. What bounds it is
  -- `notOnCancelCooldown` (3 cancels / 24h), which every cycle must pass through.
  ('assigned',                  'ready','courier','cancel_order_by_courier','{notOnCancelCooldown,reassignableReason}'),
  ('courier_arrived_restaurant','ready','courier','cancel_order_by_courier','{notOnCancelCooldown,reassignableReason}'),
  ('assigned',                  'cancelled_by_courier','courier','cancel_order_by_courier','{notOnCancelCooldown,nonReassignableReason}'),
  ('courier_arrived_restaurant','cancelled_by_courier','courier','cancel_order_by_courier','{notOnCancelCooldown,nonReassignableReason}'),

  -- consumer: cancel before the food is in motion
  ('scheduled',                 'cancelled_by_customer','consumer','cancel_order_by_consumer','{}'),
  ('created',                   'cancelled_by_customer','consumer','cancel_order_by_consumer','{}'),
  ('accepted',                  'cancelled_by_customer','consumer','cancel_order_by_consumer','{}'),
  ('preparing',                 'cancelled_by_customer','consumer','cancel_order_by_consumer','{}'),
  ('ready',                     'cancelled_by_customer','consumer','cancel_order_by_consumer','{}'),
  ('assigned',                  'cancelled_by_customer','consumer','cancel_order_by_consumer','{}'),
  ('courier_arrived_restaurant','cancelled_by_customer','consumer','cancel_order_by_consumer','{}'),

  -- merchant cancel — these three RPCs did not exist; the merchant app called
  -- the CONSUMER's cancel RPC and failed silently. 06_merchant_rpcs.sql.
  ('accepted', 'cancelled_by_restaurant','merchant','merchant_cancel_order','{}'),
  ('preparing','cancelled_by_restaurant','merchant','merchant_cancel_order','{}'),
  ('ready',    'cancelled_by_restaurant','merchant','merchant_cancel_order','{}'),

  -- system: escalation ladder / no-show auto-cancel
  ('created',                   'cancelled_by_system','system','run_courier_escalation_ladder','{}'),
  ('accepted',                  'cancelled_by_system','system','run_courier_escalation_ladder','{}'),
  ('preparing',                 'cancelled_by_system','system','run_courier_escalation_ladder','{}'),
  ('ready',                     'cancelled_by_system','system','run_courier_escalation_ladder','{}'),
  ('assigned',                  'cancelled_by_system','system','run_courier_escalation_ladder','{}'),
  ('courier_arrived_restaurant','cancelled_by_system','system','run_courier_escalation_ladder','{}'),
  ('courier_arrived_customer',  'cancelled_by_system','system','mark_no_show_deliveries','{}');

-- ---------------------------------------------------------------------------
-- Who is acting.
--
-- The trigger needs the actor, which is not derivable from the row: a consumer
-- cancel and a merchant cancel differ only in who called. Every transition RPC
-- therefore declares itself via a transaction-local GUC. `true` scopes the
-- setting to the current transaction, so it cannot leak between pooled requests.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ravon_set_actor(p_actor text, p_rpc text)
RETURNS void
LANGUAGE sql VOLATILE
SET search_path = ''
AS $$
  SELECT set_config('ravon.actor', p_actor, true),
         set_config('ravon.rpc',   p_rpc,   true);
$$;

CREATE OR REPLACE FUNCTION public.orders_enforce_transition()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_actor text := nullif(current_setting('ravon.actor', true), '');
  v_rpc   text := nullif(current_setting('ravon.rpc',   true), '');
BEGIN
  IF NEW.status = OLD.status THEN
    RETURN NEW;
  END IF;

  -- No actor declared means the write did not come through a transition RPC.
  -- That is the whole point: there is no other legal way to move a status.
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'status change outside a transition RPC'
      USING ERRCODE = 'P0001',
            DETAIL  = jsonb_build_object(
                        'reason','TRANSITION_NOT_DECLARED',
                        'from', OLD.status, 'to', NEW.status)::text;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.order_transitions t
    WHERE t.from_status = OLD.status
      AND t.to_status   = NEW.status
      AND t.actor       = v_actor
      AND (v_rpc IS NULL OR t.rpc = v_rpc)
  ) THEN
    RAISE EXCEPTION 'undeclared order transition'
      USING ERRCODE = 'P0001',
            DETAIL  = jsonb_build_object(
                        'reason','INVALID_STATUS_TRANSITION',
                        'from', OLD.status, 'to', NEW.status,
                        'actor', v_actor, 'rpc', v_rpc)::text;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS orders_enforce_transition ON public.orders;
CREATE TRIGGER orders_enforce_transition
  BEFORE UPDATE OF status ON public.orders
  FOR EACH ROW EXECUTE FUNCTION public.orders_enforce_transition();
