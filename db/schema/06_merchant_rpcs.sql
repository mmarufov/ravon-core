-- 06_merchant_rpcs.sql — the five RPCs that unblock the merchant app.
--
-- `OrderLifecycle.unimplementedRPCs` resolves to exactly these five, and all
-- three apps were blocked on the same gap:
--     merchant_accept_order, merchant_start_preparing, merchant_reject_order,
--     merchant_mark_order_ready, merchant_cancel_order
--
-- Before this file, four of the five merchant operations were direct table
-- UPDATEs from the client (SupabaseService.swift:393-447) riding on an `orders`
-- UPDATE policy that constrained which ROWS but not which COLUMNS — the defect
-- behind S4, S5, T1 and T2, and one that no policy rewrite can fix because
-- Postgres RLS has no column dimension. The fifth, merchant cancel, had no
-- implementation at all: the merchant app called the CONSUMER's
-- `cancel_order_by_consumer` and failed silently, which is why its cancel button
-- renders disabled off `unimplementedRPCs`.
--
-- Implemented against Sources/RavonCore/Models/OrderLifecycle.swift, which
-- declares 9 merchant edges across these 5 RPCs. Each function declares its
-- actor so `orders_enforce_transition` (03_lifecycle.sql) re-checks the edge
-- against the transition table — the guard is not a comment here, it is a row.
--
-- Every function is SECURITY DEFINER with `SET search_path = ''` and fully
-- qualified identifiers, and none is granted to `anon` (11_grants.sql).

-- ---------------------------------------------------------------------------
-- Shared precondition: the caller owns the restaurant this order was placed
-- against. R9 — ownership is a foreign key (`restaurants.owner_id NOT NULL
-- REFERENCES profiles`), so this is a join rather than the bare
-- `profiles.role = 'merchant'` check that made S2 a horizontal escalation
-- across every restaurant in the marketplace.
--
-- Returns the locked order row so callers do not re-SELECT it.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ravon_require_order_merchant(p_order_id uuid)
RETURNS public.orders
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  o     public.orders;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not_authenticated'
      USING ERRCODE='P0001', DETAIL=jsonb_build_object('reason','NOT_AUTHENTICATED')::text;
  END IF;

  SELECT * INTO o FROM public.orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'order_not_found'
      USING ERRCODE='P0001', DETAIL=jsonb_build_object('reason','ORDER_NOT_FOUND')::text;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.restaurants r
    JOIN public.profiles    p ON p.id = r.owner_id
    WHERE r.id = o.restaurant_id
      AND r.owner_id = v_uid
      AND p.role = 'merchant'
  ) THEN
    RAISE EXCEPTION 'unauthorized'
      USING ERRCODE='P0001', DETAIL=jsonb_build_object('reason','UNAUTHORIZED')::text;
  END IF;

  RETURN o;
END;
$$;

-- ---------------------------------------------------------------------------
-- Return reserved stock when an order dies before it is cooked.
--
-- This is a RECONSTRUCTION, not a recovery: `cleanup_cancelled_order` is
-- referenced in the corpus but its definition is gone, so this is what it
-- should have done rather than what it did. Only non-scheduled orders
-- decremented stock in create_order, so only those are restored, and the
-- restore is idempotent per call site (each cancel RPC transitions the status in
-- the same transaction, so it cannot run twice for one order).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ravon_restore_stock(p_order_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  UPDATE public.menu_items mi
  SET stock_count = mi.stock_count + oi.quantity
  FROM public.order_items oi
  JOIN public.orders o ON o.id = oi.order_id
  WHERE oi.order_id = p_order_id
    AND oi.menu_item_id = mi.id
    AND mi.stock_count IS NOT NULL
    AND o.scheduled_for IS NULL;
END;
$$;

-- ===========================================================================
-- 1. merchant_accept_order — created → accepted
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.merchant_accept_order(
  p_order_id              uuid,
  p_estimated_prep_minutes int DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  o public.orders;
BEGIN
  o := public.ravon_require_order_merchant(p_order_id);

  IF o.status <> 'created' THEN
    RAISE EXCEPTION 'invalid_status_transition'
      USING ERRCODE='P0001', DETAIL=jsonb_build_object(
        'reason','INVALID_STATUS_TRANSITION','status', o.status,
        'expected','created')::text;
  END IF;

  IF p_estimated_prep_minutes IS NOT NULL
     AND (p_estimated_prep_minutes < 1 OR p_estimated_prep_minutes > 240) THEN
    RAISE EXCEPTION 'invalid_prep_time'
      USING ERRCODE='P0001', DETAIL=jsonb_build_object(
        'reason','INVALID_PREP_TIME','minutes', p_estimated_prep_minutes)::text;
  END IF;

  PERFORM public.ravon_set_actor('merchant','merchant_accept_order');

  UPDATE public.orders SET
    status              = 'accepted',
    accepted_at         = now(),
    estimated_prep_time = COALESCE(p_estimated_prep_minutes, estimated_prep_time),
    -- The order is now claimable. Give the marketplace an SLA window to find a
    -- courier, matching the 8-minute window claim_order stamps on itself.
    expected_action_by  = now() + interval '8 minutes',
    updated_at          = now()
  WHERE id = p_order_id;
END;
$$;

-- ===========================================================================
-- 2. merchant_start_preparing — accepted → preparing
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.merchant_start_preparing(p_order_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  o public.orders;
BEGIN
  o := public.ravon_require_order_merchant(p_order_id);

  IF o.status <> 'accepted' THEN
    RAISE EXCEPTION 'invalid_status_transition'
      USING ERRCODE='P0001', DETAIL=jsonb_build_object(
        'reason','INVALID_STATUS_TRANSITION','status', o.status,
        'expected','accepted')::text;
  END IF;

  PERFORM public.ravon_set_actor('merchant','merchant_start_preparing');

  UPDATE public.orders SET
    status     = 'preparing',
    updated_at = now()
  WHERE id = p_order_id;
END;
$$;

-- ===========================================================================
-- 3. merchant_mark_order_ready — accepted → ready, preparing → ready
--
-- Two `from` states by design: a small kitchen that cooks immediately never
-- passes through `preparing`, and OrderLifecycle declares both edges.
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.merchant_mark_order_ready(p_order_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  o public.orders;
BEGIN
  o := public.ravon_require_order_merchant(p_order_id);

  IF o.status NOT IN ('accepted','preparing') THEN
    RAISE EXCEPTION 'invalid_status_transition'
      USING ERRCODE='P0001', DETAIL=jsonb_build_object(
        'reason','INVALID_STATUS_TRANSITION','status', o.status,
        'expected','accepted|preparing')::text;
  END IF;

  PERFORM public.ravon_set_actor('merchant','merchant_mark_order_ready');

  UPDATE public.orders SET
    status     = 'ready',
    updated_at = now()
  WHERE id = p_order_id;
END;
$$;

-- ===========================================================================
-- 4. merchant_reject_order — created → rejected
--
-- Distinct from cancel: rejection happens before acceptance, so nothing has
-- been cooked and the reason is fixed at RESTAURANT_REJECTED. The free-text
-- reason is retained because the merchant app collects one.
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.merchant_reject_order(
  p_order_id uuid,
  p_reason   text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  o public.orders;
BEGIN
  o := public.ravon_require_order_merchant(p_order_id);

  IF o.status <> 'created' THEN
    RAISE EXCEPTION 'invalid_status_transition'
      USING ERRCODE='P0001', DETAIL=jsonb_build_object(
        'reason','INVALID_STATUS_TRANSITION','status', o.status,
        'expected','created')::text;
  END IF;

  PERFORM public.ravon_set_actor('merchant','merchant_reject_order');

  UPDATE public.orders SET
    status                   = 'rejected',
    rejected_at              = now(),
    cancellation_reason      = p_reason,
    cancellation_reason_code = 'RESTAURANT_REJECTED',
    cancelled_by             = auth.uid(),
    expected_action_by       = NULL,
    updated_at               = now()
  WHERE id = p_order_id;

  PERFORM public.ravon_restore_stock(p_order_id);
END;
$$;

-- ===========================================================================
-- 5. merchant_cancel_order — accepted | preparing | ready → cancelled_by_restaurant
--
-- The one that did not exist. The merchant app called
-- `cancel_order_by_consumer`, which checks `orders.user_id = auth.uid()` and so
-- could never match for a merchant — it failed for every order, and because the
-- merchant app's mapError sites are no-ops it failed silently.
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.merchant_cancel_order(
  p_order_id    uuid,
  p_reason_code text DEFAULT 'RESTAURANT_OUT_OF_ITEMS'
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  o public.orders;
BEGIN
  o := public.ravon_require_order_merchant(p_order_id);

  IF o.status NOT IN ('accepted','preparing','ready') THEN
    RAISE EXCEPTION 'invalid_status_transition'
      USING ERRCODE='P0001', DETAIL=jsonb_build_object(
        'reason','INVALID_STATUS_TRANSITION','status', o.status,
        'expected','accepted|preparing|ready')::text;
  END IF;

  -- The merchant may only claim a restaurant-fault reason. Without this a
  -- merchant could stamp COURIER_NON_RESPONSIVE on its own cancellation and
  -- move the blame — and the reason code is what earnings tiers and courier
  -- suspension decisions are computed from.
  IF p_reason_code NOT IN ('RESTAURANT_CLOSED','RESTAURANT_OUT_OF_ITEMS',
                           'RESTAURANT_REJECTED','RESTAURANT_TOO_LONG_WAIT') THEN
    RAISE EXCEPTION 'invalid_cancellation_reason'
      USING ERRCODE='P0001', DETAIL=jsonb_build_object(
        'reason','INVALID_CANCELLATION_REASON','code', p_reason_code)::text;
  END IF;

  PERFORM public.ravon_set_actor('merchant','merchant_cancel_order');

  UPDATE public.orders SET
    status                   = 'cancelled_by_restaurant',
    cancellation_reason_code = p_reason_code,
    cancelled_by             = auth.uid(),
    expected_action_by       = NULL,
    updated_at               = now()
  WHERE id = p_order_id;

  PERFORM public.ravon_restore_stock(p_order_id);

  -- A courier can be mid-run at `ready` only if they had already claimed, in
  -- which case the status would be `assigned` and this RPC would have refused.
  -- Clearing defensively costs nothing and prevents a courier being pinned to a
  -- dead order if a future edge makes that reachable.
  UPDATE public.courier_locations
  SET current_order_id = NULL
  WHERE current_order_id = p_order_id;
END;
$$;
