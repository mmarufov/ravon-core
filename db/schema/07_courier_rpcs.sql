-- 07_courier_rpcs.sql — the courier run, ported from migration 13.
--
-- Guards, SLA windows and error reasons are preserved so the courier app's typed
-- error handling keeps working. Changes are called out inline; the substantive
-- ones are the attempt caps (N9), the earnings tier with no override parameter
-- (N2), the safe `fetch_available_orders` projection (S3/S6b) and the removal of
-- the `delivering → delivered` shortcut that OrderLifecycle does not declare.

-- ---------------------------------------------------------------------------
-- compute_eta_minutes — same contract, no PostGIS.
-- Original used ST_Distance over `courier_locations.geog`; see 00_prelude.sql
-- for why that dependency is gone.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.compute_eta_minutes(p_order_id uuid)
RETURNS int
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  o  public.orders%ROWTYPE;
  cl public.courier_locations%ROWTYPE;
  v_target_lat double precision;
  v_target_lng double precision;
  v_distance_m double precision;
  v_speed_mps  double precision;
BEGIN
  SELECT * INTO o FROM public.orders WHERE id = p_order_id;
  IF NOT FOUND OR o.courier_id IS NULL THEN RETURN NULL; END IF;
  SELECT * INTO cl FROM public.courier_locations WHERE courier_id = o.courier_id;
  IF NOT FOUND THEN RETURN NULL; END IF;

  IF o.status IN ('assigned','courier_arrived_restaurant') THEN
    SELECT latitude, longitude INTO v_target_lat, v_target_lng
    FROM public.restaurants WHERE id = o.restaurant_id;
  ELSE
    -- Snapshot first: the address row may have been deleted since the order.
    v_target_lat := COALESCE((o.delivery_address_snapshot->>'latitude')::double precision,
                             (SELECT latitude  FROM public.addresses WHERE id = o.address_id));
    v_target_lng := COALESCE((o.delivery_address_snapshot->>'longitude')::double precision,
                             (SELECT longitude FROM public.addresses WHERE id = o.address_id));
  END IF;

  IF v_target_lat IS NULL OR v_target_lng IS NULL THEN RETURN NULL; END IF;

  v_distance_m := public.ravon_distance_m(cl.latitude, cl.longitude, v_target_lat, v_target_lng);
  v_speed_mps  := COALESCE(NULLIF(cl.speed, 0), 25.0/3.6);   -- 25 km/h fallback
  RETURN GREATEST(1, CEIL(v_distance_m / v_speed_mps / 60.0)::int);
END;
$$;

-- ---------------------------------------------------------------------------
-- update_courier_heartbeat — rate-limited, accuracy-gated, suspension-aware.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.update_courier_heartbeat(
  p_latitude        double precision,
  p_longitude       double precision,
  p_accuracy_meters double precision DEFAULT NULL,
  p_heading         double precision DEFAULT NULL,
  p_speed           double precision DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_existing public.courier_locations%ROWTYPE;
  v_susp timestamptz;
  v_moved double precision;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not_authenticated'
      USING ERRCODE='P0001', DETAIL=jsonb_build_object('reason','NOT_AUTHENTICATED')::text;
  END IF;

  SELECT is_suspended_until INTO v_susp FROM public.profiles WHERE id = v_uid;
  IF v_susp IS NOT NULL AND v_susp > now() THEN
    RAISE EXCEPTION 'courier_suspended'
      USING ERRCODE='P0001', DETAIL=jsonb_build_object('reason','COURIER_SUSPENDED','until', v_susp)::text;
  END IF;

  -- Cell-tower-only fixes are 500-2000 m; treat as no fix at all.
  IF p_accuracy_meters IS NOT NULL AND p_accuracy_meters > 200 THEN
    RAISE EXCEPTION 'accuracy_too_low'
      USING ERRCODE='P0001', DETAIL=jsonb_build_object(
        'reason','ACCURACY_TOO_LOW','accuracy', p_accuracy_meters)::text;
  END IF;

  SELECT * INTO v_existing FROM public.courier_locations WHERE courier_id = v_uid;
  IF FOUND THEN
    -- Soft flood guard: silently ignore sub-second updates.
    IF v_existing.last_heartbeat_at > now() - interval '1 second' THEN RETURN; END IF;
    v_moved := public.ravon_distance_m(v_existing.latitude, v_existing.longitude,
                                       p_latitude, p_longitude);
    UPDATE public.courier_locations SET
      latitude = p_latitude, longitude = p_longitude,
      heading = p_heading, speed = p_speed, accuracy_meters = p_accuracy_meters,
      last_updated = now(), last_heartbeat_at = now(),
      -- >25 m counts as movement. A courier parked with the app open is not
      -- "active"; this is the anti-stationary-fraud signal the ghost ladder reads.
      last_moved_at = CASE WHEN v_moved > 25 THEN now() ELSE v_existing.last_moved_at END,
      is_online = true
    WHERE courier_id = v_uid;
  ELSE
    INSERT INTO public.courier_locations(
      courier_id, latitude, longitude, heading, speed,
      accuracy_meters, is_online, last_updated, last_heartbeat_at, last_moved_at)
    VALUES (v_uid, p_latitude, p_longitude, p_heading, p_speed,
            p_accuracy_meters, true, now(), now(), now());
  END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- Earnings tier for a cancellation.
--
-- N2: migration 12's `insert_courier_earning_for_cancel` took
-- `p_tier_override int` and computed `delivery_fee * v_tier / 100` with no
-- bound, so `p_tier_override = 1000000` minted a million-fold payout — and its
-- `ON CONFLICT (order_id) DO UPDATE` made that cleanly overwrite any existing
-- earning rather than erroring. There is no override parameter here. The tier is
-- a function of the status at the event and nothing else, the column has a
-- CHECK domain, and the fee is read from the order rather than passed in.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.earnings_tier_for_cancel(p_status public.order_status)
RETURNS int
LANGUAGE sql IMMUTABLE
SET search_path = ''
AS $$
  SELECT CASE p_status
           WHEN 'assigned'                   THEN 25
           WHEN 'courier_arrived_restaurant' THEN 50
           WHEN 'picked_up'                  THEN 100
           WHEN 'delivering'                 THEN 100
           WHEN 'courier_arrived_customer'   THEN 100
           ELSE 0
         END;
$$;

CREATE OR REPLACE FUNCTION public.earning_type_for_status(p_status public.order_status)
RETURNS text
LANGUAGE sql IMMUTABLE
SET search_path = ''
AS $$
  SELECT CASE p_status
           WHEN 'assigned'                   THEN 'partial_assigned'
           WHEN 'courier_arrived_restaurant' THEN 'partial_at_restaurant'
           WHEN 'picked_up'                  THEN 'partial_picked_up_lost'
           WHEN 'delivering'                 THEN 'partial_picked_up_lost'
           WHEN 'courier_arrived_customer'   THEN 'partial_picked_up_lost'
           ELSE 'manual_adjustment'
         END;
$$;

CREATE OR REPLACE FUNCTION public.ravon_record_cancel_earning(
  p_order_id    uuid,
  p_courier_id  uuid,
  p_status      public.order_status,
  p_reason_code text
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_tier int   := public.earnings_tier_for_cancel(p_status);
  v_type text  := public.earning_type_for_status(p_status);
  v_fee  numeric;
BEGIN
  IF v_tier = 0 THEN RETURN; END IF;

  SELECT delivery_fee INTO v_fee FROM public.orders WHERE id = p_order_id;

  INSERT INTO public.courier_earnings(
    courier_id, order_id, delivery_fee, tip_amount, total_earned,
    earning_type, tier_pct, cancellation_reason_code, status_at_event)
  VALUES (
    p_courier_id, p_order_id, COALESCE(v_fee,0), 0,
    round(COALESCE(v_fee,0) * v_tier / 100.0, 2),
    v_type, v_tier, p_reason_code, p_status)
  ON CONFLICT (order_id) DO NOTHING;   -- append-only in spirit: never overwrite
END;
$$;

-- ---------------------------------------------------------------------------
-- claim_order — accepted | preparing | ready → assigned
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.claim_order(p_order_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_susp timestamptz;
  v_is_online boolean;
  v_busy uuid;
  v_excluded uuid[];
  v_status public.order_status;
  v_existing_courier uuid;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = v_uid AND role = 'courier') THEN
    RAISE EXCEPTION 'unauthorized'
      USING ERRCODE='P0001', DETAIL=jsonb_build_object('reason','UNAUTHORIZED')::text;
  END IF;

  SELECT is_suspended_until INTO v_susp FROM public.profiles WHERE id = v_uid;
  IF v_susp IS NOT NULL AND v_susp > now() THEN
    RAISE EXCEPTION 'courier_suspended'
      USING ERRCODE='P0001', DETAIL=jsonb_build_object('reason','COURIER_SUSPENDED','until', v_susp)::text;
  END IF;

  SELECT is_online INTO v_is_online FROM public.courier_locations WHERE courier_id = v_uid;
  IF v_is_online IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'courier_must_be_online'
      USING ERRCODE='P0001', DETAIL=jsonb_build_object('reason','COURIER_MUST_BE_ONLINE')::text;
  END IF;

  SELECT id INTO v_busy FROM public.orders
  WHERE courier_id = v_uid
    AND status NOT IN ('delivered','cancelled','rejected',
                       'cancelled_by_customer','cancelled_by_restaurant',
                       'cancelled_by_system','cancelled_by_courier')
  LIMIT 1;
  IF v_busy IS NOT NULL THEN
    RAISE EXCEPTION 'courier_busy'
      USING ERRCODE='P0001', DETAIL=jsonb_build_object(
        'reason','COURIER_ALREADY_HAS_ACTIVE_ORDER','order_id', v_busy)::text;
  END IF;

  SELECT status, courier_id, excluded_courier_ids
    INTO v_status, v_existing_courier, v_excluded
  FROM public.orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'order_not_found'
      USING ERRCODE='P0001', DETAIL=jsonb_build_object('reason','ORDER_NOT_FOUND')::text;
  END IF;
  IF v_existing_courier IS NOT NULL OR v_status NOT IN ('accepted','preparing','ready') THEN
    RAISE EXCEPTION 'order_no_longer_pickupable'
      USING ERRCODE='P0001', DETAIL=jsonb_build_object(
        'reason','ORDER_NO_LONGER_PICKUPABLE','status', v_status)::text;
  END IF;
  IF v_uid = ANY(v_excluded) THEN
    RAISE EXCEPTION 'courier_excluded'
      USING ERRCODE='P0001', DETAIL=jsonb_build_object('reason','COURIER_EXCLUDED_FROM_ORDER')::text;
  END IF;

  PERFORM public.ravon_set_actor('courier','claim_order');

  UPDATE public.orders SET
    courier_id = v_uid, status = 'assigned', claimed_at = now(),
    expected_action_by = now() + interval '8 minutes',
    eta_minutes = NULL, updated_at = now()
  WHERE id = p_order_id;

  UPDATE public.courier_locations SET current_order_id = p_order_id WHERE courier_id = v_uid;

  -- Compute the ETA immediately so the consumer sees a number without waiting
  -- for the next heartbeat.
  UPDATE public.orders SET eta_minutes = public.compute_eta_minutes(p_order_id)
  WHERE id = p_order_id;

  RETURN v_uid;
END;
$$;

-- ---------------------------------------------------------------------------
-- courier_arrived_restaurant — assigned → courier_arrived_restaurant
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.courier_arrived_restaurant(p_order_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE v_rows int;
BEGIN
  PERFORM public.ravon_set_actor('courier','courier_arrived_restaurant');

  UPDATE public.orders SET
    status = 'courier_arrived_restaurant',
    arrived_at_restaurant_at = now(),
    expected_action_by = now() + interval '6 minutes',
    courier_delay_reason_code = NULL, courier_delay_explained_at = NULL,
    courier_no_show_warned_at = NULL, courier_no_show_escalated_at = NULL,
    updated_at = now()
  WHERE id = p_order_id AND courier_id = auth.uid() AND status = 'assigned';

  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows = 0 THEN
    RAISE EXCEPTION 'invalid_status_transition'
      USING ERRCODE='P0001', DETAIL=jsonb_build_object('reason','INVALID_STATUS_TRANSITION')::text;
  END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- courier_pickup_order — courier_arrived_restaurant → picked_up
--
-- N9: the code is 4 digits out of a 9,000 keyspace and both this and
-- courier_deliver_order could be called in a loop with nothing counting. The
-- length was never the defect; the absent attempt counter was.
--
-- WHY THIS RETURNS jsonb INSTEAD OF RAISING.
--
-- The first version of this function did
--     UPDATE orders SET pickup_code_attempts = pickup_code_attempts + 1 ...;
--     RAISE EXCEPTION 'invalid_verification_code' ...
-- with a comment claiming the client could not retry its way around the
-- counter. That is exactly backwards, and the end-to-end walk proved it: three
-- wrong codes in a row left `pickup_code_attempts = 0` and reported
-- "attempts_remaining: 4" every time. PostgREST runs each RPC in one
-- transaction, and RAISE aborts that transaction — so the increment is rolled
-- back with everything else. A counter and an exception cannot coexist in one
-- transaction.
--
-- So a WRONG CODE is not an error, it is a result: the function returns
-- normally, the transaction commits, and the counter sticks. Genuine errors
-- (order not found, not your order, wrong status) still RAISE, because they
-- need no counter.
--
-- The client contract is unchanged: SupabaseService.pickUpOrder still throws
-- ServiceError.invalidVerificationCode. It now decodes `{"ok":false}` and
-- throws it itself rather than having Postgres throw for it.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.courier_pickup_order(uuid, text);
CREATE FUNCTION public.courier_pickup_order(
  p_order_id uuid,
  p_verification_code text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_status public.order_status;
  v_code text;
  v_courier uuid;
  v_attempts int;
BEGIN
  SELECT status, verification_code, courier_id, pickup_code_attempts
    INTO v_status, v_code, v_courier, v_attempts
  FROM public.orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'order_not_found'
      USING ERRCODE='P0001', DETAIL=jsonb_build_object('reason','ORDER_NOT_FOUND')::text;
  END IF;
  IF v_courier IS DISTINCT FROM v_uid THEN
    RAISE EXCEPTION 'unauthorized'
      USING ERRCODE='P0001', DETAIL=jsonb_build_object('reason','UNAUTHORIZED')::text;
  END IF;
  IF v_status <> 'courier_arrived_restaurant' THEN
    RAISE EXCEPTION 'order_no_longer_pickupable'
      USING ERRCODE='P0001', DETAIL=jsonb_build_object(
        'reason','ORDER_NO_LONGER_PICKUPABLE','status', v_status)::text;
  END IF;

  IF v_attempts >= 5 THEN
    RETURN jsonb_build_object('ok', false, 'reason','CODE_ATTEMPTS_EXHAUSTED',
                              'attempts_remaining', 0);
  END IF;

  IF v_code IS DISTINCT FROM p_verification_code THEN
    UPDATE public.orders SET pickup_code_attempts = pickup_code_attempts + 1
    WHERE id = p_order_id;
    -- RETURN, not RAISE. See the note above this function.
    RETURN jsonb_build_object('ok', false, 'reason','INVALID_VERIFICATION_CODE',
                              'attempts_remaining', 4 - v_attempts);
  END IF;

  PERFORM public.ravon_set_actor('courier','courier_pickup_order');

  UPDATE public.orders SET
    status = 'picked_up', picked_up_at = now(),
    expected_action_by = now() + interval '1 minute',
    courier_delay_reason_code = NULL, courier_delay_explained_at = NULL,
    courier_no_show_warned_at = NULL, courier_no_show_escalated_at = NULL,
    updated_at = now()
  WHERE id = p_order_id;

  RETURN jsonb_build_object('ok', true);
END;
$$;

-- ---------------------------------------------------------------------------
-- courier_start_delivering — picked_up → delivering
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.courier_start_delivering(p_order_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_rows int;
  v_eta int;
BEGIN
  PERFORM public.ravon_set_actor('courier','courier_start_delivering');

  UPDATE public.orders SET
    status = 'delivering',
    courier_delay_reason_code = NULL, courier_delay_explained_at = NULL,
    courier_no_show_warned_at = NULL, courier_no_show_escalated_at = NULL,
    updated_at = now()
  WHERE id = p_order_id AND courier_id = auth.uid() AND status = 'picked_up';

  -- The original used `IF NOT FOUND` after an UPDATE, which in plpgsql reflects
  -- the last *SELECT INTO*, not the UPDATE's row count — it is always false
  -- here, so a wrong-status call fell through and silently did nothing.
  -- GET DIAGNOSTICS is the correct test.
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows = 0 THEN
    RAISE EXCEPTION 'invalid_status_transition'
      USING ERRCODE='P0001', DETAIL=jsonb_build_object('reason','INVALID_STATUS_TRANSITION')::text;
  END IF;

  v_eta := public.compute_eta_minutes(p_order_id);
  UPDATE public.orders SET
    eta_minutes = v_eta,
    expected_action_by = now() + ((COALESCE(v_eta, 15) + 3) || ' minutes')::interval
  WHERE id = p_order_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- courier_arrived_at_customer — delivering → courier_arrived_customer
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.courier_arrived_at_customer(p_order_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE v_rows int;
BEGIN
  PERFORM public.ravon_set_actor('courier','courier_arrived_at_customer');

  UPDATE public.orders SET
    status = 'courier_arrived_customer', arrived_at_customer_at = now(),
    expected_action_by = now() + interval '5 minutes',
    courier_delay_reason_code = NULL, courier_delay_explained_at = NULL,
    courier_no_show_warned_at = NULL, courier_no_show_escalated_at = NULL,
    updated_at = now()
  WHERE id = p_order_id AND courier_id = auth.uid() AND status = 'delivering';

  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows = 0 THEN
    RAISE EXCEPTION 'invalid_status_transition'
      USING ERRCODE='P0001', DETAIL=jsonb_build_object('reason','INVALID_STATUS_TRANSITION')::text;
  END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- courier_deliver_order — courier_arrived_customer → delivered
--
-- TWO changes of substance.
--
-- 1. The original accepted `delivering` as well as `courier_arrived_customer`
--    (13:400), letting a courier skip the arrival stamp entirely.
--    OrderLifecycle.swift declares only `courier_arrived_customer → delivered`,
--    and the prompt names that file as the specification, so the shortcut is
--    gone. `orders_enforce_transition` would reject it anyway — which is the
--    point of having the graph in one place.
--
-- 2. N9 attempt cap on the delivery code, same reasoning as pickup.
--
-- N6 is REDUCED, NOT CLOSED. The original's entire proof requirement for
-- leave-at-door was `length(p_delivery_proof_url) >= 4`, so
-- `courier_deliver_order(id, NULL, 'xxxx')` marked an order delivered and paid
-- full fare with no photo. The check here still cannot confirm the object
-- exists, belongs to this order or was uploaded by this courier — that needs a
-- verified `delivery_proofs` row (R13), which needs an upload-verification path
-- the client does not have. What is added: the path must be well-formed and
-- prefixed with this order's id, which is the strongest binding available
-- without a storage round-trip. See the plan's residual list.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.courier_deliver_order(uuid, text, text);
CREATE FUNCTION public.courier_deliver_order(
  p_order_id           uuid,
  p_delivery_code      text DEFAULT NULL,
  p_delivery_proof_url text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_status public.order_status;
  v_courier uuid;
  v_mode text;
  v_code text;
  v_attempts int;
BEGIN
  SELECT status, courier_id, delivery_mode, delivery_verification_code, delivery_code_attempts
    INTO v_status, v_courier, v_mode, v_code, v_attempts
  FROM public.orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'order_not_found'
      USING ERRCODE='P0001', DETAIL=jsonb_build_object('reason','ORDER_NOT_FOUND')::text;
  END IF;
  IF v_courier IS DISTINCT FROM v_uid THEN
    RAISE EXCEPTION 'unauthorized'
      USING ERRCODE='P0001', DETAIL=jsonb_build_object('reason','UNAUTHORIZED')::text;
  END IF;
  IF v_status <> 'courier_arrived_customer' THEN
    RAISE EXCEPTION 'invalid_status_transition'
      USING ERRCODE='P0001', DETAIL=jsonb_build_object(
        'reason','INVALID_STATUS_TRANSITION','status', v_status,
        'expected','courier_arrived_customer')::text;
  END IF;

  IF v_mode = 'hand_to_me' THEN
    -- Returns rather than raises, for the same transactional reason as
    -- courier_pickup_order above: RAISE would roll the counter back.
    IF v_attempts >= 5 THEN
      RETURN jsonb_build_object('ok', false, 'reason','CODE_ATTEMPTS_EXHAUSTED',
                                'attempts_remaining', 0);
    END IF;
    IF v_code IS DISTINCT FROM p_delivery_code THEN
      UPDATE public.orders SET delivery_code_attempts = delivery_code_attempts + 1
      WHERE id = p_order_id;
      RETURN jsonb_build_object('ok', false, 'reason','WRONG_DELIVERY_CODE',
                                'attempts_remaining', 4 - v_attempts);
    END IF;
  ELSE  -- leave_at_door
    IF p_delivery_proof_url IS NULL
       OR p_delivery_proof_url NOT LIKE (p_order_id::text || '/%') THEN
      RAISE EXCEPTION 'missing_proof_image'
        USING ERRCODE='P0001', DETAIL=jsonb_build_object('reason','MISSING_PROOF_IMAGE')::text;
    END IF;
  END IF;

  PERFORM public.ravon_set_actor('courier','courier_deliver_order');

  UPDATE public.orders SET
    status = 'delivered', delivered_at = now(),
    delivery_proof_url = COALESCE(p_delivery_proof_url, delivery_proof_url),
    expected_action_by = NULL, updated_at = now()
  WHERE id = p_order_id;

  -- Full-fare earning on a completed delivery. The tip is whatever is on the
  -- order at this moment; a later add_tip tops it up.
  INSERT INTO public.courier_earnings(
    courier_id, order_id, delivery_fee, tip_amount, total_earned,
    earning_type, tier_pct, status_at_event)
  SELECT v_uid, o.id, o.delivery_fee, o.tip_amount,
         o.delivery_fee + o.tip_amount, 'full', 100, 'delivered'
  FROM public.orders o WHERE o.id = p_order_id
  ON CONFLICT (order_id) DO NOTHING;

  UPDATE public.courier_locations SET current_order_id = NULL WHERE courier_id = v_uid;

  RETURN jsonb_build_object('ok', true);
END;
$$;

-- ---------------------------------------------------------------------------
-- cancel_order_by_courier — branches on the reason code.
--
-- Restaurant-fault reasons return the order to the pool (`→ ready`);
-- everything else terminates it (`→ cancelled_by_courier`). This is two edges,
-- not one: the invariant suite caught the original single-edge model because it
-- left `.cancelledByCourier` unreachable.
--
-- The `→ ready` edge is BACKWARD, so the graph has a genuine cycle and
-- termination is not provable by acyclicity. What bounds it is the 3-per-24h
-- cooldown below, which every cycle must pass through.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cancel_order_by_courier(
  p_order_id    uuid,
  p_reason_code text
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_status public.order_status;
  v_courier uuid;
  v_recent int;
  v_reassignable boolean;
BEGIN
  SELECT status, courier_id INTO v_status, v_courier
  FROM public.orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'order_not_found'
      USING ERRCODE='P0001', DETAIL=jsonb_build_object('reason','ORDER_NOT_FOUND')::text;
  END IF;
  IF v_courier IS DISTINCT FROM v_uid THEN
    RAISE EXCEPTION 'unauthorized'
      USING ERRCODE='P0001', DETAIL=jsonb_build_object('reason','UNAUTHORIZED')::text;
  END IF;
  IF v_status NOT IN ('assigned','courier_arrived_restaurant') THEN
    RAISE EXCEPTION 'cancel_not_allowed_at_status'
      USING ERRCODE='P0001', DETAIL=jsonb_build_object(
        'reason','CANCEL_NOT_ALLOWED_AT_STATUS','status', v_status)::text;
  END IF;

  IF p_reason_code NOT IN ('COURIER_VEHICLE_ISSUE','COURIER_SAFETY_ISSUE',
                           'COURIER_RESTAURANT_CLOSED','COURIER_ITEMS_UNAVAILABLE',
                           'COURIER_NON_RESPONSIVE','RESTAURANT_TOO_LONG_WAIT') THEN
    RAISE EXCEPTION 'invalid_cancellation_reason'
      USING ERRCODE='P0001', DETAIL=jsonb_build_object(
        'reason','INVALID_CANCELLATION_REASON','code', p_reason_code)::text;
  END IF;

  -- notOnCancelCooldown. This is the guard that bounds every cycle in the graph.
  SELECT count(*) INTO v_recent FROM public.courier_cancellation_log
  WHERE courier_id = v_uid AND created_at > now() - interval '24 hours';
  IF v_recent >= 3 THEN
    RAISE EXCEPTION 'cancel_cooldown_active'
      USING ERRCODE='P0001', DETAIL=jsonb_build_object(
        'reason','CANCEL_COOLDOWN_ACTIVE','recent_cancels', v_recent)::text;
  END IF;

  v_reassignable := p_reason_code IN ('COURIER_RESTAURANT_CLOSED',
                                      'COURIER_ITEMS_UNAVAILABLE',
                                      'RESTAURANT_TOO_LONG_WAIT');

  INSERT INTO public.courier_cancellation_log(courier_id, order_id, reason_code, status_at_cancel)
  VALUES (v_uid, p_order_id, p_reason_code, v_status);

  PERFORM public.ravon_record_cancel_earning(p_order_id, v_uid, v_status, p_reason_code);

  PERFORM public.ravon_set_actor('courier','cancel_order_by_courier');

  IF v_reassignable THEN
    UPDATE public.orders SET
      status = 'ready', courier_id = NULL, claimed_at = NULL,
      arrived_at_restaurant_at = NULL,
      excluded_courier_ids = array_append(excluded_courier_ids, v_uid),
      reassign_count = reassign_count + 1,
      expected_action_by = now() + interval '8 minutes',
      eta_minutes = NULL, updated_at = now()
    WHERE id = p_order_id;
  ELSE
    UPDATE public.orders SET
      status = 'cancelled_by_courier',
      cancellation_reason_code = p_reason_code,
      cancelled_by = v_uid, expected_action_by = NULL, updated_at = now()
    WHERE id = p_order_id;
    PERFORM public.ravon_restore_stock(p_order_id);
  END IF;

  UPDATE public.courier_locations SET current_order_id = NULL WHERE courier_id = v_uid;
END;
$$;

-- ---------------------------------------------------------------------------
-- fetch_available_orders — the offer feed.
--
-- S3 + S6(b): the original returned `SETOF orders` (13:719) — every column,
-- which by migration 10 includes `verification_code` and
-- `delivery_verification_code`, plus `delivery_address_snapshot`. It had no
-- `auth.uid() IS NULL` gate and no role check, and its only caller-dependent
-- predicate was
--   NOT (auth.uid() = ANY(COALESCE(o.excluded_courier_ids, '{}')))
-- For an anon caller auth.uid() is NULL and `NULL = ANY('{}')` is FALSE (not
-- NULL) on an empty array, so `NOT false` = true: an unauthenticated caller
-- received every never-reassigned unclaimed order, with both verification codes
-- and the consumer's home address. Orders with a non-empty exclusion array
-- evaluated to NULL and dropped out, which is the only reason the leak was not
-- total.
--
-- This version returns an explicit column list. No codes. No address snapshot —
-- a courier deciding whether to accept an offer needs the restaurant's location
-- and the payout, not the customer's street, and the snapshot becomes readable
-- through the order row only once they have claimed it.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.fetch_available_orders(double precision, double precision, double precision);
CREATE FUNCTION public.fetch_available_orders(
  p_latitude   double precision DEFAULT NULL,
  p_longitude  double precision DEFAULT NULL,
  p_radius_km  double precision DEFAULT 8
)
RETURNS TABLE (
  id             uuid,
  restaurant_id  uuid,
  status         public.order_status,
  subtotal       numeric,
  delivery_fee   numeric,
  total          numeric,
  created_at     timestamptz,
  reassign_count int,
  restaurant_name      text,
  restaurant_address   text,
  restaurant_latitude  double precision,
  restaurant_longitude double precision,
  distance_km    double precision
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not_authenticated'
      USING ERRCODE='P0001', DETAIL=jsonb_build_object('reason','NOT_AUTHENTICATED')::text;
  END IF;
  -- `pr.` alias is required, not cosmetic: this function's RETURNS TABLE
  -- declares an output column named `id`, which plpgsql exposes as a variable,
  -- so an unqualified `id` here fails with "column reference id is ambiguous".
  IF NOT EXISTS (SELECT 1 FROM public.profiles pr
                 WHERE pr.id = v_uid AND pr.role = 'courier') THEN
    RAISE EXCEPTION 'unauthorized'
      USING ERRCODE='P0001', DETAIL=jsonb_build_object('reason','UNAUTHORIZED')::text;
  END IF;

  RETURN QUERY
  SELECT o.id, o.restaurant_id, o.status, o.subtotal, o.delivery_fee, o.total,
         o.created_at, o.reassign_count,
         r.name, r.address, r.latitude, r.longitude,
         CASE
           WHEN p_latitude IS NULL OR r.latitude IS NULL THEN NULL
           ELSE round((public.ravon_distance_m(p_latitude, p_longitude,
                                               r.latitude, r.longitude) / 1000.0)::numeric, 2)::double precision
         END
  FROM public.orders o
  JOIN public.restaurants r ON r.id = o.restaurant_id
  WHERE o.courier_id IS NULL
    AND o.status IN ('accepted','preparing','ready')
    -- Written so an empty array and a NULL behave the same, unlike the original.
    AND NOT (v_uid = ANY(o.excluded_courier_ids))
    AND (
      p_latitude IS NULL OR r.latitude IS NULL
      OR public.ravon_distance_m(p_latitude, p_longitude, r.latitude, r.longitude)
         <= p_radius_km * 1000.0
    )
  ORDER BY o.created_at;
END;
$$;
