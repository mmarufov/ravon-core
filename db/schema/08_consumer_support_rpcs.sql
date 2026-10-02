-- 08_consumer_support_rpcs.sql — consumer cancel, tipping, and the three RPCs
-- the apps call that exist in NO migration anywhere.
--
-- `get_merchant_stats`, `find_nearby_couriers` and `add_tip` were
-- dashboard-created: they are called from Swift
-- (SupabaseService+Restaurants.swift:257, SupabaseService+Courier.swift:229,
-- SupabaseService+Orders.swift:214) and their definitions are permanently gone.
-- Everything below for those three is a RECONSTRUCTION from the call site and
-- the decoded shape, not a recovery. Their signatures and return shapes are
-- pinned by the Swift side, so those are certain; the bodies are a decision.

-- ---------------------------------------------------------------------------
-- cancel_order_by_consumer
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cancel_order_by_consumer(
  p_order_id uuid,
  p_reason   text DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_status public.order_status;
  v_user uuid;
  v_courier uuid;
BEGIN
  SELECT status, user_id, courier_id INTO v_status, v_user, v_courier
  FROM public.orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'order_not_found'
      USING ERRCODE='P0001', DETAIL=jsonb_build_object('reason','ORDER_NOT_FOUND')::text;
  END IF;
  IF v_user IS DISTINCT FROM v_uid THEN
    RAISE EXCEPTION 'unauthorized'
      USING ERRCODE='P0001', DETAIL=jsonb_build_object('reason','UNAUTHORIZED')::text;
  END IF;
  IF v_status IN ('picked_up','delivering','courier_arrived_customer') THEN
    RAISE EXCEPTION 'cancel_after_pickup_not_allowed'
      USING ERRCODE='P0001', DETAIL=jsonb_build_object(
        'reason','CANCEL_AFTER_PICKUP_NOT_ALLOWED','status', v_status)::text;
  END IF;
  -- Mirrors OrderStatus.consumerCanCancel; the invariant suite asserts the two
  -- agree, and the transition table below is the third copy that must also agree.
  IF v_status NOT IN ('scheduled','created','accepted','preparing','ready',
                      'assigned','courier_arrived_restaurant') THEN
    RAISE EXCEPTION 'order_already_terminal'
      USING ERRCODE='P0001', DETAIL=jsonb_build_object(
        'reason','ORDER_ALREADY_TERMINAL','status', v_status)::text;
  END IF;

  -- Tier the courier's earning if one was already engaged.
  IF v_courier IS NOT NULL THEN
    PERFORM public.ravon_record_cancel_earning(
      p_order_id, v_courier, v_status, 'CONSUMER_CHANGED_MIND');
  END IF;

  PERFORM public.ravon_set_actor('consumer','cancel_order_by_consumer');

  UPDATE public.orders SET
    status = 'cancelled_by_customer',
    cancellation_reason = p_reason,
    cancellation_reason_code = 'CONSUMER_CHANGED_MIND',
    cancelled_by = v_uid, expected_action_by = NULL, updated_at = now()
  WHERE id = p_order_id;

  PERFORM public.ravon_restore_stock(p_order_id);

  IF v_courier IS NOT NULL THEN
    UPDATE public.courier_locations SET current_order_id = NULL WHERE courier_id = v_courier;
  END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- add_tip — RECONSTRUCTED. Definition unrecoverable.
--
-- Note what R7 buys here: `orders.total` is a GENERATED column, so this
-- function sets `tip_amount` and the total follows automatically. The original
-- had to remember to update both, and a courier holding a bare
-- `auth.uid() = courier_id` UPDATE policy could set `tip_amount` directly
-- (S5/T2) after which the `create_courier_earning` trigger paid out on the
-- tampered value. Now clients have no UPDATE grant on `orders` at all, and the
-- total cannot disagree with its components even if they did.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.add_tip(
  p_order_id uuid,
  p_amount   numeric
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  o public.orders;
BEGIN
  IF p_amount IS NULL OR p_amount < 0 OR p_amount > 10000 THEN
    RAISE EXCEPTION 'invalid_tip_amount'
      USING ERRCODE='P0001', DETAIL=jsonb_build_object(
        'reason','INVALID_TIP_AMOUNT','amount', p_amount)::text;
  END IF;

  SELECT * INTO o FROM public.orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'order_not_found'
      USING ERRCODE='P0001', DETAIL=jsonb_build_object('reason','ORDER_NOT_FOUND')::text;
  END IF;
  IF o.user_id IS DISTINCT FROM v_uid THEN
    RAISE EXCEPTION 'unauthorized'
      USING ERRCODE='P0001', DETAIL=jsonb_build_object('reason','UNAUTHORIZED')::text;
  END IF;
  -- Tipping before the food arrives invites the consumer to tip and then cancel.
  IF o.status <> 'delivered' THEN
    RAISE EXCEPTION 'order_not_delivered'
      USING ERRCODE='P0001', DETAIL=jsonb_build_object(
        'reason','ORDER_NOT_DELIVERED','status', o.status)::text;
  END IF;

  UPDATE public.orders SET tip_amount = p_amount, updated_at = now()
  WHERE id = p_order_id;

  -- Keep the courier's earning consistent with the new tip.
  UPDATE public.courier_earnings
  SET tip_amount = p_amount, total_earned = delivery_fee + p_amount
  WHERE order_id = p_order_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- get_merchant_stats — RECONSTRUCTED. Returns the four keys MerchantStats
-- decodes (MerchantStats.swift:493-496), all non-optional, so each must always
-- be present and non-NULL — hence the COALESCEs.
--
-- S2/R9: the original took a client-supplied `p_restaurant_id` and, per the
-- report, checked only `profiles.role = 'merchant'`. Any merchant read any
-- competitor's revenue. Ownership is checked here.
-- "Today" is Asia/Dushanbe, matching the rest of the system.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_merchant_stats(p_restaurant_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_day_start timestamptz;
  v_count int;
  v_revenue numeric;
  v_active int;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not_authenticated'
      USING ERRCODE='P0001', DETAIL=jsonb_build_object('reason','NOT_AUTHENTICATED')::text;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.restaurants
                 WHERE id = p_restaurant_id AND owner_id = v_uid) THEN
    RAISE EXCEPTION 'unauthorized'
      USING ERRCODE='P0001', DETAIL=jsonb_build_object('reason','UNAUTHORIZED')::text;
  END IF;

  v_day_start := date_trunc('day', now() AT TIME ZONE 'Asia/Dushanbe')
                   AT TIME ZONE 'Asia/Dushanbe';

  -- Revenue counts delivered orders only: an accepted-then-cancelled order is
  -- not revenue, and counting it makes the dashboard disagree with any payout.
  SELECT count(*), COALESCE(sum(total), 0)
    INTO v_count, v_revenue
  FROM public.orders
  WHERE restaurant_id = p_restaurant_id
    AND created_at >= v_day_start
    AND status = 'delivered';

  SELECT count(*) INTO v_active
  FROM public.orders
  WHERE restaurant_id = p_restaurant_id
    AND status IN ('created','accepted','preparing','ready','assigned',
                   'courier_arrived_restaurant','picked_up','delivering',
                   'courier_arrived_customer');

  RETURN jsonb_build_object(
    'today_order_count',   v_count,
    'today_revenue',       v_revenue,
    'average_order_value', CASE WHEN v_count > 0
                                THEN round(v_revenue / v_count, 2)
                                ELSE 0 END,
    'active_order_count',  v_active);
END;
$$;

-- ---------------------------------------------------------------------------
-- find_nearby_couriers — RECONSTRUCTED. Shape pinned by NearbyCourier
-- (courier_id, latitude, longitude, heading, speed, distance_km, last_updated).
--
-- S3 named this as an anon-callable SECURITY DEFINER function returning live
-- courier GPS. It is a genuine PII surface: real-time location of identifiable
-- people. Restricted to merchants who own a restaurant and to couriers, and
-- never granted to anon (11_grants.sql). It deliberately does not return the
-- courier's name or current order.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.find_nearby_couriers(double precision, double precision, double precision);
CREATE FUNCTION public.find_nearby_couriers(
  p_latitude  double precision,
  p_longitude double precision,
  p_radius_km double precision DEFAULT 8
)
RETURNS TABLE (
  courier_id   uuid,
  latitude     double precision,
  longitude    double precision,
  heading      double precision,
  speed        double precision,
  distance_km  double precision,
  last_updated timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_role public.user_role;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not_authenticated'
      USING ERRCODE='P0001', DETAIL=jsonb_build_object('reason','NOT_AUTHENTICATED')::text;
  END IF;
  SELECT role INTO v_role FROM public.profiles WHERE id = v_uid;
  IF v_role NOT IN ('merchant','courier') THEN
    RAISE EXCEPTION 'unauthorized'
      USING ERRCODE='P0001', DETAIL=jsonb_build_object('reason','UNAUTHORIZED')::text;
  END IF;

  RETURN QUERY
  SELECT cl.courier_id, cl.latitude, cl.longitude, cl.heading, cl.speed,
         round((public.ravon_distance_m(p_latitude, p_longitude,
                                        cl.latitude, cl.longitude) / 1000.0)::numeric, 2)::double precision,
         cl.last_updated
  FROM public.courier_locations cl
  WHERE cl.is_online
    -- A stale heartbeat is not an online courier. The original had no such
    -- filter, so a phone that died an hour ago still showed on the map.
    AND cl.last_heartbeat_at > now() - interval '2 minutes'
    AND public.ravon_distance_m(p_latitude, p_longitude, cl.latitude, cl.longitude)
        <= p_radius_km * 1000.0
  ORDER BY 6;
END;
$$;

-- ---------------------------------------------------------------------------
-- activate_scheduled_orders — the system edge `scheduled → created`.
--
-- N4/R16: this and the other sweeps are NOT granted to any client role. A batch
-- job's authorization model should not be "the WHERE clause happens to be
-- narrow." They run under pg_cron (12_realtime_storage.sql) or from a future
-- scheduler holding a dedicated role.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.activate_scheduled_orders()
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  rec record;
  v_activated int := 0;
  v_ok boolean;
BEGIN
  PERFORM public.ravon_set_actor('system','activate_scheduled_orders');

  FOR rec IN
    SELECT id, restaurant_id, scheduled_for
    FROM public.orders
    WHERE status = 'scheduled'
      AND scheduled_for IS NOT NULL
      AND scheduled_for <= now()
    FOR UPDATE SKIP LOCKED
  LOOP
    v_ok := public.restaurant_is_orderable(rec.restaurant_id, now());

    IF COALESCE(v_ok, false) THEN
      UPDATE public.orders SET
        status = 'created',
        expected_action_by = now() + interval '8 minutes',
        updated_at = now()
      WHERE id = rec.id;

      -- Nothing is decremented here. Stock and the kitchen-slot place were
      -- reserved at checkout (create_order), and activation consumes that
      -- reservation. At 65ad66c this block decremented a second time with
      -- GREATEST(0, stock - qty), which never refused anything: 60 activations
      -- against 40 portions ended at stock 0 with 60 live orders.

      v_activated := v_activated + 1;
    ELSE
      UPDATE public.orders SET
        status = 'cancelled_by_system',
        cancellation_reason_code = 'RESTAURANT_NOT_OPEN_AT_SCHEDULED_TIME',
        expected_action_by = NULL, updated_at = now()
      WHERE id = rec.id;
      -- Its reservation dies with it.
      PERFORM public.ravon_restore_stock(rec.id);
    END IF;
  END LOOP;

  RETURN v_activated;
END;
$$;

-- ---------------------------------------------------------------------------
-- mark_no_show_deliveries — courier_arrived_customer → cancelled_by_system
-- after the hand-off SLA lapses. Not client-callable (R16).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.mark_no_show_deliveries()
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE v_rows int;
BEGIN
  PERFORM public.ravon_set_actor('system','mark_no_show_deliveries');

  WITH due AS (
    SELECT id, courier_id, status FROM public.orders
    WHERE status = 'courier_arrived_customer'
      AND expected_action_by IS NOT NULL
      AND expected_action_by < now() - interval '5 minutes'
    FOR UPDATE SKIP LOCKED
  ), upd AS (
    UPDATE public.orders o SET
      status = 'cancelled_by_system',
      no_show = true,
      no_show_started_at = COALESCE(o.no_show_started_at, now()),
      cancellation_reason_code = 'CUSTOMER_NO_SHOW',
      expected_action_by = NULL, updated_at = now()
    FROM due WHERE o.id = due.id
    RETURNING o.id, due.courier_id, due.status
  )
  SELECT count(*) INTO v_rows FROM upd;

  -- The courier showed up and waited; they are paid.
  INSERT INTO public.courier_earnings(
    courier_id, order_id, delivery_fee, tip_amount, total_earned,
    earning_type, tier_pct, cancellation_reason_code, status_at_event)
  SELECT o.courier_id, o.id, o.delivery_fee, 0, o.delivery_fee,
         'no_show_compensation', 100, 'CUSTOMER_NO_SHOW', 'courier_arrived_customer'
  FROM public.orders o
  WHERE o.no_show AND o.courier_id IS NOT NULL
    AND o.status = 'cancelled_by_system'
  ON CONFLICT (order_id) DO NOTHING;

  RETURN v_rows;
END;
$$;
