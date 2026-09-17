-- Migration 13: v2 status transition RPCs + new courier RPCs.
-- Per Workstreams A, B, C, D, E, F.
--
-- All RPCs use the structured-error pattern from Umbrella I migration 04:
--   RAISE EXCEPTION '<short>' USING ERRCODE='P0001',
--     DETAIL = jsonb_build_object('reason', '<KIND>', ...)::text
-- This lets the Swift client decode the typed reason from PostgrestError.
--
-- All RPCs are SECURITY DEFINER + SET search_path = public.

BEGIN;

-- ============================================================
-- Helper: server-computed ETA in minutes from courier to target.
--   - When status <= picked_up: target is the restaurant
--   - When status > picked_up:  target is the address (delivery)
-- Uses last_moved_at + speed if speed>0, else falls back to 25 km/h.
-- ============================================================
CREATE OR REPLACE FUNCTION compute_eta_minutes(p_order_id uuid)
RETURNS int
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  o orders%ROWTYPE;
  cl courier_locations%ROWTYPE;
  r  restaurants%ROWTYPE;
  v_target_lat double precision;
  v_target_lng double precision;
  v_distance_m double precision;
  v_speed_mps  double precision;
BEGIN
  SELECT * INTO o FROM orders WHERE id = p_order_id;
  IF NOT FOUND OR o.courier_id IS NULL THEN RETURN NULL; END IF;
  SELECT * INTO cl FROM courier_locations WHERE courier_id = o.courier_id;
  IF NOT FOUND THEN RETURN NULL; END IF;

  IF o.status::text IN ('assigned','courier_arrived_restaurant') THEN
    SELECT latitude, longitude INTO v_target_lat, v_target_lng FROM restaurants WHERE id = o.restaurant_id;
  ELSE
    -- Use snapshot if address was deleted; fallback to addresses row.
    v_target_lat := COALESCE((o.delivery_address_snapshot->>'latitude')::double precision,
                             (SELECT latitude FROM addresses WHERE id = o.address_id));
    v_target_lng := COALESCE((o.delivery_address_snapshot->>'longitude')::double precision,
                             (SELECT longitude FROM addresses WHERE id = o.address_id));
  END IF;

  IF v_target_lat IS NULL OR v_target_lng IS NULL THEN RETURN NULL; END IF;

  -- Haversine via PostGIS (ST_Distance with geog returns meters).
  v_distance_m := ST_Distance(
    cl.geog,
    ST_GeogFromText('SRID=4326;POINT(' || v_target_lng || ' ' || v_target_lat || ')')
  );
  v_speed_mps := COALESCE(NULLIF(cl.speed, 0), 25.0/3.6); -- 25 km/h fallback
  -- ETA = max(1, ceil(distance / speed / 60))
  RETURN GREATEST(1, CEIL(v_distance_m / v_speed_mps / 60.0)::int);
END;
$$;

GRANT EXECUTE ON FUNCTION compute_eta_minutes(uuid) TO authenticated;

-- ============================================================
-- Helper: rate-limited heartbeat upsert.
--   - Rejects > 1 update / second / courier (basic flood guard).
--   - Rejects accuracy_meters > 200 (cell-tower-only fix; treat as offline).
--   - Rejects when courier is suspended.
--   - Updates last_moved_at only when geog moves > 25 m (anti-stationary-fraud).
-- ============================================================
CREATE OR REPLACE FUNCTION update_courier_heartbeat(
  p_latitude        double precision,
  p_longitude       double precision,
  p_accuracy_meters double precision DEFAULT NULL,
  p_heading         double precision DEFAULT NULL,
  p_speed           double precision DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_existing courier_locations%ROWTYPE;
  v_susp timestamptz;
  v_new_geog extensions.geography;
  v_distance_moved double precision;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not_authenticated'
      USING ERRCODE='P0001', DETAIL=jsonb_build_object('reason','NOT_AUTHENTICATED')::text;
  END IF;

  SELECT is_suspended_until INTO v_susp FROM profiles WHERE id = v_uid;
  IF v_susp IS NOT NULL AND v_susp > now() THEN
    RAISE EXCEPTION 'courier_suspended'
      USING ERRCODE='P0001', DETAIL=jsonb_build_object('reason','COURIER_SUSPENDED','until', v_susp)::text;
  END IF;

  -- Reject low-accuracy fixes (cell-tower fallback ≈ 500-2000m). Server treats as offline.
  IF p_accuracy_meters IS NOT NULL AND p_accuracy_meters > 200 THEN
    RAISE EXCEPTION 'accuracy_too_low'
      USING ERRCODE='P0001', DETAIL=jsonb_build_object('reason','ACCURACY_TOO_LOW','accuracy', p_accuracy_meters)::text;
  END IF;

  v_new_geog := ST_GeogFromText('SRID=4326;POINT(' || p_longitude || ' ' || p_latitude || ')');

  SELECT * INTO v_existing FROM courier_locations WHERE courier_id = v_uid;
  IF FOUND THEN
    -- Soft rate limit: ignore updates < 1 second apart (no error, just skip).
    IF v_existing.last_heartbeat_at > now() - interval '1 second' THEN RETURN; END IF;
    v_distance_moved := ST_Distance(v_existing.geog, v_new_geog);

    UPDATE courier_locations SET
      latitude = p_latitude,
      longitude = p_longitude,
      heading = p_heading,
      speed = p_speed,
      accuracy_meters = p_accuracy_meters,
      last_updated = now(),
      last_heartbeat_at = now(),
      last_moved_at = CASE WHEN v_distance_moved > 25 THEN now() ELSE v_existing.last_moved_at END,
      is_online = true
    WHERE courier_id = v_uid;
  ELSE
    INSERT INTO courier_locations(
      courier_id, latitude, longitude, heading, speed,
      accuracy_meters, is_online, last_updated, last_heartbeat_at, last_moved_at
    ) VALUES (
      v_uid, p_latitude, p_longitude, p_heading, p_speed,
      p_accuracy_meters, true, now(), now(), now()
    );
  END IF;

  -- Roll heartbeat-driven ETA refresh on the active order, if any.
  UPDATE orders SET eta_minutes = compute_eta_minutes(orders.id), updated_at = now()
  WHERE courier_id = v_uid
    AND status IN ('assigned','courier_arrived_restaurant','picked_up','delivering','courier_arrived_customer');
END;
$$;

GRANT EXECUTE ON FUNCTION update_courier_heartbeat(double precision, double precision, double precision, double precision, double precision) TO authenticated;

-- ============================================================
-- claim_order v2: suspension, busy, excluded-courier checks; SLA stamping.
-- ============================================================
CREATE OR REPLACE FUNCTION claim_order(p_order_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_susp timestamptz;
  v_is_online boolean;
  v_already_active uuid;
  v_excluded uuid[];
  v_status order_status;
  v_existing_courier uuid;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = v_uid AND role = 'courier') THEN
    RAISE EXCEPTION 'unauthorized'
      USING ERRCODE='P0001', DETAIL=jsonb_build_object('reason','UNAUTHORIZED')::text;
  END IF;

  SELECT is_suspended_until INTO v_susp FROM profiles WHERE id = v_uid;
  IF v_susp IS NOT NULL AND v_susp > now() THEN
    RAISE EXCEPTION 'courier_suspended'
      USING ERRCODE='P0001', DETAIL=jsonb_build_object('reason','COURIER_SUSPENDED','until', v_susp)::text;
  END IF;

  SELECT is_online INTO v_is_online FROM courier_locations WHERE courier_id = v_uid;
  IF v_is_online IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'courier_must_be_online'
      USING ERRCODE='P0001', DETAIL=jsonb_build_object('reason','COURIER_MUST_BE_ONLINE')::text;
  END IF;

  SELECT id INTO v_already_active FROM orders
  WHERE courier_id = v_uid
    AND status NOT IN ('delivered','cancelled','rejected',
                       'cancelled_by_customer','cancelled_by_restaurant',
                       'cancelled_by_system','cancelled_by_courier');
  IF v_already_active IS NOT NULL THEN
    RAISE EXCEPTION 'courier_busy'
      USING ERRCODE='P0001', DETAIL=jsonb_build_object('reason','COURIER_ALREADY_HAS_ACTIVE_ORDER','order_id', v_already_active)::text;
  END IF;

  SELECT status, courier_id, excluded_courier_ids
    INTO v_status, v_existing_courier, v_excluded
  FROM orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'order_not_found'
      USING ERRCODE='P0001', DETAIL=jsonb_build_object('reason','ORDER_NOT_FOUND')::text;
  END IF;
  IF v_existing_courier IS NOT NULL OR v_status NOT IN ('accepted','preparing','ready') THEN
    RAISE EXCEPTION 'order_no_longer_pickupable'
      USING ERRCODE='P0001', DETAIL=jsonb_build_object('reason','ORDER_NO_LONGER_PICKUPABLE','status', v_status)::text;
  END IF;
  IF v_uid = ANY(v_excluded) THEN
    RAISE EXCEPTION 'courier_excluded'
      USING ERRCODE='P0001', DETAIL=jsonb_build_object('reason','COURIER_EXCLUDED_FROM_ORDER')::text;
  END IF;

  UPDATE orders
  SET courier_id = v_uid,
      status = 'assigned',
      claimed_at = now(),
      expected_action_by = now() + interval '8 minutes',
      eta_minutes = NULL  -- recomputed by next heartbeat
  WHERE id = p_order_id;

  UPDATE courier_locations SET current_order_id = p_order_id WHERE courier_id = v_uid;

  -- Compute ETA right after assigning so consumer sees a number immediately.
  UPDATE orders SET eta_minutes = compute_eta_minutes(p_order_id) WHERE id = p_order_id;

  RETURN v_uid;
END;
$$;

-- ============================================================
-- courier_arrived_restaurant: stamp + reset SLA for the next step.
-- ============================================================
CREATE OR REPLACE FUNCTION courier_arrived_restaurant(p_order_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_rows int;
BEGIN
  UPDATE orders SET
    status = 'courier_arrived_restaurant',
    arrived_at_restaurant_at = now(),
    expected_action_by = now() + interval '6 minutes',
    courier_delay_reason_code = NULL,
    courier_delay_explained_at = NULL,
    courier_no_show_warned_at = NULL,
    courier_no_show_escalated_at = NULL
  WHERE id = p_order_id
    AND courier_id = v_uid
    AND status = 'assigned';
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows = 0 THEN
    RAISE EXCEPTION 'invalid_status_transition'
      USING ERRCODE='P0001', DETAIL=jsonb_build_object('reason','INVALID_STATUS_TRANSITION')::text;
  END IF;
END;
$$;

-- ============================================================
-- courier_pickup_order v2: structured error on wrong code, SLA stamp.
-- ============================================================
CREATE OR REPLACE FUNCTION courier_pickup_order(p_order_id uuid, p_verification_code text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_status order_status;
  v_code text;
  v_courier uuid;
BEGIN
  SELECT status, verification_code, courier_id INTO v_status, v_code, v_courier
  FROM orders WHERE id = p_order_id FOR UPDATE;
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
      USING ERRCODE='P0001', DETAIL=jsonb_build_object('reason','ORDER_NO_LONGER_PICKUPABLE','status', v_status)::text;
  END IF;
  IF v_code IS DISTINCT FROM p_verification_code THEN
    RAISE EXCEPTION 'invalid_verification_code'
      USING ERRCODE='P0001', DETAIL=jsonb_build_object('reason','INVALID_VERIFICATION_CODE')::text;
  END IF;

  UPDATE orders SET
    status = 'picked_up',
    picked_up_at = now(),
    expected_action_by = now() + interval '1 minute',
    courier_delay_reason_code = NULL,
    courier_delay_explained_at = NULL,
    courier_no_show_warned_at = NULL,
    courier_no_show_escalated_at = NULL
  WHERE id = p_order_id;
END;
$$;

-- ============================================================
-- courier_start_delivering: stamp + dynamic ETA-based SLA.
-- ============================================================
CREATE OR REPLACE FUNCTION courier_start_delivering(p_order_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_eta int;
BEGIN
  UPDATE orders SET
    status = 'delivering',
    courier_delay_reason_code = NULL,
    courier_delay_explained_at = NULL,
    courier_no_show_warned_at = NULL,
    courier_no_show_escalated_at = NULL
  WHERE id = p_order_id
    AND courier_id = v_uid
    AND status = 'picked_up';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'invalid_status_transition'
      USING ERRCODE='P0001', DETAIL=jsonb_build_object('reason','INVALID_STATUS_TRANSITION')::text;
  END IF;

  v_eta := compute_eta_minutes(p_order_id);
  UPDATE orders SET
    eta_minutes = v_eta,
    expected_action_by = now() + ((COALESCE(v_eta, 15) + 3) || ' minutes')::interval
  WHERE id = p_order_id;
END;
$$;

-- ============================================================
-- courier_arrived_at_customer: stamp + 5-min handoff SLA.
-- ============================================================
CREATE OR REPLACE FUNCTION courier_arrived_at_customer(p_order_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_rows int;
BEGIN
  UPDATE orders SET
    status = 'courier_arrived_customer',
    arrived_at_customer_at = now(),
    expected_action_by = now() + interval '5 minutes',
    courier_delay_reason_code = NULL,
    courier_delay_explained_at = NULL,
    courier_no_show_warned_at = NULL,
    courier_no_show_escalated_at = NULL
  WHERE id = p_order_id
    AND courier_id = v_uid
    AND status = 'delivering';
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows = 0 THEN
    RAISE EXCEPTION 'invalid_status_transition'
      USING ERRCODE='P0001', DETAIL=jsonb_build_object('reason','INVALID_STATUS_TRANSITION')::text;
  END IF;
END;
$$;

-- ============================================================
-- courier_deliver_order v2:
--   - hand_to_me   → require p_delivery_code (matched against delivery_verification_code)
--   - leave_at_door → require p_delivery_proof_url
-- ============================================================
CREATE OR REPLACE FUNCTION courier_deliver_order(
  p_order_id           uuid,
  p_delivery_code      text DEFAULT NULL,
  p_delivery_proof_url text DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_status order_status;
  v_courier uuid;
  v_mode text;
  v_code text;
BEGIN
  SELECT status, courier_id, delivery_mode, delivery_verification_code
    INTO v_status, v_courier, v_mode, v_code
  FROM orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'order_not_found'
      USING ERRCODE='P0001', DETAIL=jsonb_build_object('reason','ORDER_NOT_FOUND')::text;
  END IF;
  IF v_courier IS DISTINCT FROM v_uid THEN
    RAISE EXCEPTION 'unauthorized'
      USING ERRCODE='P0001', DETAIL=jsonb_build_object('reason','UNAUTHORIZED')::text;
  END IF;
  IF v_status NOT IN ('delivering','courier_arrived_customer') THEN
    RAISE EXCEPTION 'invalid_status_transition'
      USING ERRCODE='P0001', DETAIL=jsonb_build_object('reason','INVALID_STATUS_TRANSITION','status', v_status)::text;
  END IF;

  IF v_mode = 'hand_to_me' THEN
    IF v_code IS DISTINCT FROM p_delivery_code THEN
      RAISE EXCEPTION 'wrong_delivery_code'
        USING ERRCODE='P0001', DETAIL=jsonb_build_object('reason','WRONG_DELIVERY_CODE')::text;
    END IF;
  ELSE -- leave_at_door
    IF p_delivery_proof_url IS NULL OR length(p_delivery_proof_url) < 4 THEN
      RAISE EXCEPTION 'missing_proof_image'
        USING ERRCODE='P0001', DETAIL=jsonb_build_object('reason','MISSING_PROOF_IMAGE')::text;
    END IF;
  END IF;

  UPDATE orders SET
    status = 'delivered',
    delivered_at = now(),
    delivery_proof_url = COALESCE(p_delivery_proof_url, delivery_proof_url),
    expected_action_by = NULL
  WHERE id = p_order_id;
END;
$$;

-- ============================================================
-- cancel_order_by_consumer v2: typed reason; refuses post-pickup;
-- partial earnings for assigned/at-restaurant.
-- ============================================================
CREATE OR REPLACE FUNCTION cancel_order_by_consumer(p_order_id uuid, p_reason text DEFAULT NULL)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_status order_status;
  v_user uuid;
  v_courier uuid;
BEGIN
  SELECT status, user_id, courier_id INTO v_status, v_user, v_courier
  FROM orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'order_not_found'
      USING ERRCODE='P0001', DETAIL=jsonb_build_object('reason','ORDER_NOT_FOUND')::text;
  END IF;
  IF v_user <> v_uid THEN
    RAISE EXCEPTION 'unauthorized'
      USING ERRCODE='P0001', DETAIL=jsonb_build_object('reason','UNAUTHORIZED')::text;
  END IF;
  IF v_status IN ('picked_up','delivering','courier_arrived_customer') THEN
    RAISE EXCEPTION 'cancel_after_pickup_not_allowed'
      USING ERRCODE='P0001', DETAIL=jsonb_build_object('reason','CANCEL_AFTER_PICKUP_NOT_ALLOWED','status', v_status)::text;
  END IF;
  IF v_status NOT IN ('created','accepted','preparing','ready','assigned','courier_arrived_restaurant','scheduled') THEN
    RAISE EXCEPTION 'order_already_terminal'
      USING ERRCODE='P0001', DETAIL=jsonb_build_object('reason','ORDER_ALREADY_TERMINAL','status', v_status)::text;
  END IF;

  -- Tier earning if courier was already engaged.
  IF v_courier IS NOT NULL THEN
    PERFORM insert_courier_earning_for_cancel(
      p_order_id, v_courier, v_status, 'CONSUMER_CHANGED_MIND', NULL, NULL
    );
  END IF;

  UPDATE orders SET
    status = 'cancelled_by_customer',
    cancelled_by = v_uid,
    cancellation_reason = p_reason,
    cancellation_reason_code = 'CONSUMER_CHANGED_MIND'
  WHERE id = p_order_id;
END;
$$;

-- ============================================================
-- cancel_order_by_courier: Hybrid scope (pre-pickup whitelist).
-- ============================================================
CREATE OR REPLACE FUNCTION cancel_order_by_courier(p_order_id uuid, p_reason_code text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_status order_status;
  v_courier uuid;
  v_recent int;
  v_excluded uuid[];
BEGIN
  IF p_reason_code NOT IN (
    'COURIER_VEHICLE_ISSUE','COURIER_SAFETY_ISSUE','COURIER_RESTAURANT_CLOSED',
    'COURIER_ITEMS_UNAVAILABLE','RESTAURANT_TOO_LONG_WAIT'
  ) THEN
    RAISE EXCEPTION 'invalid_reason_code'
      USING ERRCODE='P0001', DETAIL=jsonb_build_object('reason','INVALID_REASON_CODE','code', p_reason_code)::text;
  END IF;

  -- 24h cooldown: 3 self-cancels in 24h → 24h block.
  SELECT count(*) INTO v_recent
  FROM courier_cancellation_log
  WHERE courier_id = v_uid AND created_at > now() - interval '24 hours';
  IF v_recent >= 3 THEN
    RAISE EXCEPTION 'courier_cancel_cooldown'
      USING ERRCODE='P0001', DETAIL=jsonb_build_object('reason','COURIER_CANCEL_COOLDOWN','recent_cancels', v_recent)::text;
  END IF;

  SELECT status, courier_id, excluded_courier_ids INTO v_status, v_courier, v_excluded
  FROM orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'order_not_found'
      USING ERRCODE='P0001', DETAIL=jsonb_build_object('reason','ORDER_NOT_FOUND')::text;
  END IF;
  IF v_courier IS DISTINCT FROM v_uid THEN
    RAISE EXCEPTION 'unauthorized'
      USING ERRCODE='P0001', DETAIL=jsonb_build_object('reason','UNAUTHORIZED')::text;
  END IF;
  IF v_status NOT IN ('assigned','courier_arrived_restaurant') THEN
    RAISE EXCEPTION 'cannot_cancel_post_pickup'
      USING ERRCODE='P0001', DETAIL=jsonb_build_object('reason','CANNOT_CANCEL_POST_PICKUP','status', v_status)::text;
  END IF;

  -- Earning per tier (assigned=25%, arrived_restaurant=50%).
  PERFORM insert_courier_earning_for_cancel(
    p_order_id, v_uid, v_status, p_reason_code, NULL, NULL
  );

  -- Log for cooldown.
  INSERT INTO courier_cancellation_log(courier_id, order_id, reason_code, status_at_cancel)
    VALUES (v_uid, p_order_id, p_reason_code, v_status);

  -- For RESTAURANT-related codes: return order to pool, exclude this courier.
  IF p_reason_code IN ('COURIER_RESTAURANT_CLOSED','COURIER_ITEMS_UNAVAILABLE','RESTAURANT_TOO_LONG_WAIT') THEN
    UPDATE orders SET
      status = 'ready',
      courier_id = NULL,
      claimed_at = NULL,
      arrived_at_restaurant_at = NULL,
      expected_action_by = NULL,
      excluded_courier_ids = array_append(COALESCE(v_excluded, ARRAY[]::uuid[]), v_uid),
      reassign_count = COALESCE(reassign_count,0) + 1,
      cancellation_reason_code = p_reason_code
    WHERE id = p_order_id;
    -- Clear courier's current order so they can claim again
    UPDATE courier_locations SET current_order_id = NULL WHERE courier_id = v_uid;
  ELSE
    -- Vehicle/safety: hard cancel.
    UPDATE orders SET
      status = 'cancelled_by_courier',
      cancelled_by = v_uid,
      cancellation_reason_code = p_reason_code
    WHERE id = p_order_id;
    -- cleanup_cancelled_order trigger clears courier_locations.current_order_id.
  END IF;
END;
$$;

-- ============================================================
-- report_problem_post_pickup: holds escalation, alerts (chat), no cancel.
-- ============================================================
CREATE OR REPLACE FUNCTION report_problem_post_pickup(
  p_order_id uuid,
  p_reason_code text,
  p_free_form text DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_courier uuid;
  v_status order_status;
BEGIN
  SELECT status, courier_id INTO v_status, v_courier
  FROM orders WHERE id = p_order_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'order_not_found'
      USING ERRCODE='P0001', DETAIL=jsonb_build_object('reason','ORDER_NOT_FOUND')::text;
  END IF;
  IF v_courier IS DISTINCT FROM v_uid THEN
    RAISE EXCEPTION 'unauthorized'
      USING ERRCODE='P0001', DETAIL=jsonb_build_object('reason','UNAUTHORIZED')::text;
  END IF;
  IF v_status NOT IN ('picked_up','delivering','courier_arrived_customer') THEN
    RAISE EXCEPTION 'invalid_status_transition'
      USING ERRCODE='P0001', DETAIL=jsonb_build_object('reason','INVALID_STATUS_TRANSITION','status', v_status)::text;
  END IF;

  -- Pause SLA so escalation ladder doesn't trip.
  UPDATE orders SET expected_action_by = NULL WHERE id = p_order_id;

  -- System chat note for consumer (sender_role added in migration 15; safe to write before it).
  INSERT INTO chat_messages(order_id, sender_id, body)
  VALUES (p_order_id, v_uid,
    'Курьер сообщил о проблеме: ' || p_reason_code || COALESCE(' — ' || p_free_form, ''));
END;
$$;

-- ============================================================
-- courier_explain_delay: courier responds to T+0 banner.
-- ============================================================
CREATE OR REPLACE FUNCTION courier_explain_delay(
  p_order_id uuid,
  p_reason_code text,
  p_free_form text DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_courier uuid;
BEGIN
  IF p_reason_code NOT IN ('traffic','restaurant_slow','address_unclear','customer_unreachable','other') THEN
    RAISE EXCEPTION 'invalid_reason_code'
      USING ERRCODE='P0001', DETAIL=jsonb_build_object('reason','INVALID_REASON_CODE','code', p_reason_code)::text;
  END IF;
  SELECT courier_id INTO v_courier FROM orders WHERE id = p_order_id;
  IF v_courier IS DISTINCT FROM v_uid THEN
    RAISE EXCEPTION 'unauthorized'
      USING ERRCODE='P0001', DETAIL=jsonb_build_object('reason','UNAUTHORIZED')::text;
  END IF;

  UPDATE orders SET
    courier_delay_reason_code = p_reason_code,
    courier_delay_explained_at = now(),
    expected_action_by = COALESCE(expected_action_by, now()) + interval '5 minutes'
  WHERE id = p_order_id;

  INSERT INTO chat_messages(order_id, sender_id, body)
  VALUES (p_order_id, v_uid,
    CASE p_reason_code
      WHEN 'traffic'              THEN 'Курьер: пробки на дороге, чуть задерживаюсь.'
      WHEN 'restaurant_slow'      THEN 'Курьер: ресторан задерживает выдачу.'
      WHEN 'address_unclear'      THEN 'Курьер: не могу найти адрес, уточните пожалуйста.'
      WHEN 'customer_unreachable' THEN 'Курьер: не могу с вами связаться.'
      ELSE                              'Курьер сообщил о задержке.'
    END
    || COALESCE(' — ' || p_free_form, ''));
END;
$$;

-- ============================================================
-- reassign_ghosted_order: returns order to pool with exclusion.
-- ============================================================
CREATE OR REPLACE FUNCTION reassign_ghosted_order(p_order_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  o orders%ROWTYPE;
  v_count int;
BEGIN
  SELECT * INTO o FROM orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN RETURN; END IF;
  IF o.status NOT IN ('assigned','courier_arrived_restaurant') THEN
    -- Post-pickup: food is gone, this is a clawback path handled by the cron.
    RETURN;
  END IF;

  -- Insert partial earning (ghosting still counts up to 50%).
  IF o.courier_id IS NOT NULL THEN
    PERFORM insert_courier_earning_for_cancel(
      o.id, o.courier_id, o.status, 'COURIER_NON_RESPONSIVE', NULL, NULL
    );
  END IF;

  v_count := COALESCE(o.reassign_count, 0) + 1;

  IF v_count >= 3 THEN
    UPDATE orders SET
      status = 'cancelled_by_system',
      cancellation_reason_code = 'RESTAURANT_TOO_LONG_WAIT',
      cancellation_reason = 'Не удалось назначить курьера 3 раза подряд',
      reassign_count = v_count
    WHERE id = o.id;
    RETURN;
  END IF;

  UPDATE orders SET
    status = 'ready',
    courier_id = NULL,
    claimed_at = NULL,
    arrived_at_restaurant_at = NULL,
    expected_action_by = NULL,
    courier_delay_reason_code = NULL,
    courier_delay_explained_at = NULL,
    courier_no_show_warned_at = NULL,
    courier_no_show_escalated_at = NULL,
    eta_minutes = NULL,
    reassign_count = v_count,
    excluded_courier_ids = CASE WHEN o.courier_id IS NULL THEN excluded_courier_ids
                                ELSE array_append(COALESCE(excluded_courier_ids, ARRAY[]::uuid[]), o.courier_id)
                           END
  WHERE id = o.id;

  -- Clear current_order_id for the ghosted courier
  IF o.courier_id IS NOT NULL THEN
    UPDATE courier_locations SET current_order_id = NULL WHERE courier_id = o.courier_id;
  END IF;
END;
$$;

-- ============================================================
-- fetch_available_orders v2: respect excluded_courier_ids.
-- (We re-create with the same signature; original lives in earlier migration.)
-- ============================================================
CREATE OR REPLACE FUNCTION fetch_available_orders(
  p_latitude  double precision,
  p_longitude double precision,
  p_radius_km double precision DEFAULT 50.0
) RETURNS SETOF orders
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, extensions
AS $$
  SELECT o.*
  FROM orders o
  JOIN restaurants r ON r.id = o.restaurant_id
  WHERE o.courier_id IS NULL
    AND o.status IN ('accepted','preparing','ready')
    AND NOT (auth.uid() = ANY(COALESCE(o.excluded_courier_ids, ARRAY[]::uuid[])))
    AND ST_DWithin(
      ST_MakePoint(r.longitude, r.latitude)::extensions.geography,
      ST_MakePoint(p_longitude, p_latitude)::extensions.geography,
      p_radius_km * 1000
    )
  ORDER BY o.created_at;
$$;

GRANT EXECUTE ON FUNCTION compute_eta_minutes(uuid)                               TO authenticated;
GRANT EXECUTE ON FUNCTION update_courier_heartbeat(double precision, double precision, double precision, double precision, double precision) TO authenticated;
GRANT EXECUTE ON FUNCTION claim_order(uuid)                                       TO authenticated;
GRANT EXECUTE ON FUNCTION courier_arrived_restaurant(uuid)                        TO authenticated;
GRANT EXECUTE ON FUNCTION courier_pickup_order(uuid, text)                        TO authenticated;
GRANT EXECUTE ON FUNCTION courier_start_delivering(uuid)                          TO authenticated;
GRANT EXECUTE ON FUNCTION courier_arrived_at_customer(uuid)                       TO authenticated;
GRANT EXECUTE ON FUNCTION courier_deliver_order(uuid, text, text)                 TO authenticated;
GRANT EXECUTE ON FUNCTION cancel_order_by_consumer(uuid, text)                    TO authenticated;
GRANT EXECUTE ON FUNCTION cancel_order_by_courier(uuid, text)                     TO authenticated;
GRANT EXECUTE ON FUNCTION report_problem_post_pickup(uuid, text, text)            TO authenticated;
GRANT EXECUTE ON FUNCTION courier_explain_delay(uuid, text, text)                 TO authenticated;
GRANT EXECUTE ON FUNCTION reassign_ghosted_order(uuid)                            TO authenticated;
GRANT EXECUTE ON FUNCTION fetch_available_orders(double precision, double precision, double precision) TO authenticated;

COMMIT;
