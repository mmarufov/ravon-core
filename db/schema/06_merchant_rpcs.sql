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
-- Stock and kitchen-slot reservations: take at checkout, give back at most once.
--
-- At 65ad66c this was one function, ravon_restore_stock, that skipped every
-- order with `scheduled_for IS NOT NULL` on the theory that scheduled orders
-- had not decremented at creation. That was true until the activation sweep
-- decremented them, after which cancelling one never returned its units
-- (stock 40, 10 activated -> 30, 3 cancelled -> still 30; the order-now control
-- gave 33). The asymmetry was the bug: the code that took and the code that
-- gave back were deciding "who holds a unit" from different facts.
--
-- Now both sides read the same fact, the `reserve` rows in inventory_movements.
-- Release gives back exactly what was reserved, for exactly the items that
-- were reserved, and the UNIQUE (order_id, menu_item_id, kind) key makes a
-- second release insert nothing, so it restores nothing.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ravon_reserve_stock(p_order_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  -- Callers (create_order) already hold FOR UPDATE on every item row, taken in
  -- menu_item_id order, and have checked stock against the per-item SUM.
  PERFORM set_config('ravon.inventory_op', 'order', true);

  WITH need AS (
    SELECT oi.menu_item_id, sum(oi.quantity)::int AS quantity
    FROM public.order_items oi
    JOIN public.menu_items mi ON mi.id = oi.menu_item_id
    WHERE oi.order_id = p_order_id AND mi.stock_count IS NOT NULL
    GROUP BY oi.menu_item_id
  ), mv AS (
    INSERT INTO public.inventory_movements(menu_item_id, order_id, kind, quantity)
    SELECT menu_item_id, p_order_id, 'reserve', -quantity FROM need
    RETURNING menu_item_id, quantity
  )
  -- No GREATEST(0, ...). If this would go negative the CHECK constraint on
  -- stock_count aborts the checkout, which is the correct outcome for a bug in
  -- the caller's check; a clamp would turn it into a silent oversell.
  UPDATE public.menu_items mi
  SET stock_count = mi.stock_count + mv.quantity
  FROM mv WHERE mi.id = mv.menu_item_id;

  PERFORM set_config('ravon.inventory_op', '', true);
END;
$$;

CREATE OR REPLACE FUNCTION public.ravon_restore_stock(p_order_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  -- Lock the item rows in menu_item_id order, the same order create_order uses,
  -- so a cancel and a checkout touching the same items cannot deadlock.
  PERFORM 1 FROM public.menu_items mi
  WHERE mi.id IN (SELECT menu_item_id FROM public.inventory_movements
                  WHERE order_id = p_order_id AND kind = 'reserve')
  ORDER BY mi.id
  FOR UPDATE;

  PERFORM set_config('ravon.inventory_op', 'order', true);

  WITH mv AS (
    INSERT INTO public.inventory_movements(menu_item_id, order_id, kind, quantity)
    SELECT r.menu_item_id, r.order_id, 'release', -r.quantity
    FROM public.inventory_movements r
    JOIN public.menu_items mi ON mi.id = r.menu_item_id
    WHERE r.order_id = p_order_id AND r.kind = 'reserve'
      -- An item whose tracking was switched off since checkout has nothing to
      -- return to; the release is skipped rather than written against NULL.
      AND mi.stock_count IS NOT NULL
    ON CONFLICT (order_id, menu_item_id, kind) DO NOTHING
    RETURNING menu_item_id, quantity
  )
  UPDATE public.menu_items mi
  SET stock_count = mi.stock_count + mv.quantity
  FROM mv WHERE mi.id = mv.menu_item_id;

  PERFORM set_config('ravon.inventory_op', '', true);

  -- The kitchen-slot place, if this was a scheduled order. Flipping
  -- released_at from NULL is the exactly-once gate.
  WITH h AS (
    UPDATE public.kitchen_slot_holds
    SET released_at = now()
    WHERE order_id = p_order_id AND released_at IS NULL
    RETURNING restaurant_id, slot_start
  )
  UPDATE public.kitchen_slots s
  SET taken = s.taken - 1
  FROM h
  WHERE s.restaurant_id = h.restaurant_id AND s.slot_start = h.slot_start;
END;
$$;

-- ---------------------------------------------------------------------------
-- ravon_inventory_violations: stock conservation, as data.
--
-- For every item, `initial + restocks = stock_count + units held by orders`,
-- which in ledger form is: stock_count equals the sum of its movements, and the
-- movements agree with the orders they belong to. Returns one row per
-- violation; an empty result is the pass. invariants.sql asserts it on apply,
-- CI asserts it after the seeded walk and after every rush run
-- (db/rush/rush.py), and db/schema/tests shows each check failing on a
-- deliberately corrupted database.
--
-- Not granted to any client role (12_grants.sql revokes it with the rest).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ravon_inventory_violations()
RETURNS TABLE (check_name text, detail text)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  -- 1. The cached balance is the ledger's balance.
  SELECT 'stock_equals_ledger',
         format('item %s: stock_count %s, movements sum to %s',
                mi.id, mi.stock_count, COALESCE(m.total, 0))
  FROM public.menu_items mi
  LEFT JOIN (SELECT menu_item_id, sum(quantity) AS total
             FROM public.inventory_movements GROUP BY 1) m ON m.menu_item_id = mi.id
  WHERE COALESCE(mi.stock_count, 0) <> COALESCE(m.total, 0)

  UNION ALL
  -- 2. A release gives back exactly what its reservation took, and nothing
  --    is released that was never reserved.
  SELECT 'release_matches_reserve',
         format('order %s item %s: released %s, reserved %s',
                rel.order_id, rel.menu_item_id, rel.quantity, res.quantity)
  FROM public.inventory_movements rel
  LEFT JOIN public.inventory_movements res
    ON res.order_id = rel.order_id AND res.menu_item_id = rel.menu_item_id
   AND res.kind = 'reserve'
  WHERE rel.kind = 'release'
    AND (res.id IS NULL OR rel.quantity <> -res.quantity)

  UNION ALL
  -- 3. A reservation is the order's summed demand for that item.
  SELECT 'reserve_matches_cart',
         format('order %s item %s: reserved %s, order_items sum to %s',
                res.order_id, res.menu_item_id, -res.quantity, COALESCE(oi.total, 0))
  FROM public.inventory_movements res
  LEFT JOIN (SELECT order_id, menu_item_id, sum(quantity) AS total
             FROM public.order_items GROUP BY 1, 2) oi
    ON oi.order_id = res.order_id AND oi.menu_item_id = res.menu_item_id
  WHERE res.kind = 'reserve' AND -res.quantity <> COALESCE(oi.total, 0)

  UNION ALL
  -- 4. Units are only returned by an order that is dead.
  SELECT 'live_order_released',
         format('order %s is %s but released item %s', o.id, o.status, rel.menu_item_id)
  FROM public.inventory_movements rel
  JOIN public.orders o ON o.id = rel.order_id
  WHERE rel.kind = 'release'
    AND o.status NOT IN ('rejected','cancelled','cancelled_by_customer',
                         'cancelled_by_restaurant','cancelled_by_system',
                         'cancelled_by_courier')

  UNION ALL
  -- 5. And every order that died before pickup returned them. After pickup
  --    the food is gone (a no-show), so nothing comes back.
  SELECT 'cancelled_order_released',
         format('order %s is %s, never picked up, and still holds %s of item %s',
                o.id, o.status, -res.quantity, res.menu_item_id)
  FROM public.inventory_movements res
  JOIN public.orders o      ON o.id = res.order_id
  JOIN public.menu_items mi ON mi.id = res.menu_item_id
  WHERE res.kind = 'reserve'
    AND o.status IN ('rejected','cancelled','cancelled_by_customer',
                     'cancelled_by_restaurant','cancelled_by_system',
                     'cancelled_by_courier')
    AND o.picked_up_at IS NULL
    AND mi.stock_count IS NOT NULL
    AND NOT EXISTS (SELECT 1 FROM public.inventory_movements rel
                    WHERE rel.order_id = res.order_id
                      AND rel.menu_item_id = res.menu_item_id
                      AND rel.kind = 'release')

  UNION ALL
  -- 6. A kitchen slot's count is the number of places still held in it.
  SELECT 'slot_taken_matches_holds',
         format('slot %s @ %s: taken %s, %s unreleased holds',
                ks.restaurant_id, ks.slot_start, ks.taken, COALESCE(h.n, 0))
  FROM public.kitchen_slots ks
  LEFT JOIN (SELECT restaurant_id, slot_start, count(*) AS n
             FROM public.kitchen_slot_holds WHERE released_at IS NULL
             GROUP BY 1, 2) h
    ON h.restaurant_id = ks.restaurant_id AND h.slot_start = ks.slot_start
  WHERE ks.taken <> COALESCE(h.n, 0)
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
