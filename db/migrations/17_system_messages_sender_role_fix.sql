-- Migration 17: force sender_role='system' on all programmatic chat inserts.
--
-- Background: migration 15 added a BEFORE INSERT trigger that fills sender_role
-- from profiles.role when the caller doesn't set it. For automated messages
-- posted by the escalation cron, courier_explain_delay, report_problem_post_pickup,
-- courier_report_customer_no_show, and courier_report_restaurant_delay, the
-- correct tag is 'system' regardless of which uid we use as sender_id. Without
-- this fix, those messages get tagged with the courier's role and apps can't
-- distinguish system notices from courier-typed messages.
--
-- Strategy: the trigger already respects an explicit sender_role
-- (it only fills when NEW.sender_role IS NULL). We update each programmatic
-- insert to set sender_role='system'.

BEGIN;

-- 1. Escalation ladder cron — Pass 2 system message.
CREATE OR REPLACE FUNCTION run_courier_escalation_ladder()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  rec record;
  v_status order_status;
  v_courier uuid;
  v_strikes int;
  v_reset_at timestamptz;
  v_now timestamptz := now();
BEGIN
  -- Pass 1: T+0 warnings (banner only)
  FOR rec IN
    SELECT id FROM orders
    WHERE status IN ('assigned','courier_arrived_restaurant','picked_up','delivering','courier_arrived_customer')
      AND expected_action_by IS NOT NULL
      AND expected_action_by <= v_now
      AND courier_no_show_warned_at IS NULL
      AND courier_delay_explained_at IS NULL
    FOR UPDATE SKIP LOCKED
  LOOP
    UPDATE orders SET courier_no_show_warned_at = v_now WHERE id = rec.id;
  END LOOP;

  -- Pass 2: T+2 escalation — system chat to consumer
  FOR rec IN
    SELECT id, courier_id FROM orders
    WHERE status IN ('assigned','courier_arrived_restaurant','picked_up','delivering','courier_arrived_customer')
      AND expected_action_by IS NOT NULL
      AND expected_action_by + interval '2 minutes' <= v_now
      AND courier_no_show_escalated_at IS NULL
      AND courier_delay_explained_at IS NULL
    FOR UPDATE SKIP LOCKED
  LOOP
    UPDATE orders SET courier_no_show_escalated_at = v_now WHERE id = rec.id;
    INSERT INTO chat_messages(order_id, sender_id, sender_role, body)
    VALUES (
      rec.id,
      COALESCE(rec.courier_id, '00000000-0000-0000-0000-000000000000'::uuid),
      'system',
      'Курьер не отвечает, мы пытаемся с ним связаться.'
    );
  END LOOP;

  -- Pass 3: T+5 force-cancel + ghost-strike + reassign-or-clawback
  FOR rec IN
    SELECT id, status, courier_id FROM orders
    WHERE status IN ('assigned','courier_arrived_restaurant','picked_up','delivering','courier_arrived_customer')
      AND expected_action_by IS NOT NULL
      AND expected_action_by + interval '5 minutes' <= v_now
      AND courier_delay_explained_at IS NULL
    FOR UPDATE SKIP LOCKED
  LOOP
    v_status := rec.status; v_courier := rec.courier_id;

    SELECT ghost_strikes, strikes_reset_at INTO v_strikes, v_reset_at
      FROM courier_locations WHERE courier_id = v_courier;
    IF v_reset_at IS NOT NULL AND v_reset_at + interval '14 days' < v_now THEN
      v_strikes := 0;
      UPDATE courier_locations SET strikes_reset_at = v_now, ghost_strikes = 0 WHERE courier_id = v_courier;
    END IF;

    IF v_status IN ('assigned','courier_arrived_restaurant') THEN
      PERFORM reassign_ghosted_order(rec.id);
    ELSE
      PERFORM insert_courier_earning_for_cancel(
        rec.id, v_courier, v_status, 'COURIER_NON_RESPONSIVE', -100, 'clawback'
      );
      UPDATE orders SET
        status = 'cancelled_by_system',
        cancellation_reason_code = 'COURIER_NON_RESPONSIVE',
        cancellation_reason = 'Курьер не отвечает после получения заказа',
        expected_action_by = NULL
      WHERE id = rec.id;
    END IF;

    IF v_courier IS NOT NULL THEN
      UPDATE courier_locations SET ghost_strikes = COALESCE(ghost_strikes,0) + 1
      WHERE courier_id = v_courier
      RETURNING ghost_strikes INTO v_strikes;

      IF v_strikes >= 3 THEN
        UPDATE profiles SET is_suspended_until = v_now + interval '24 hours' WHERE id = v_courier;
        UPDATE courier_locations SET is_online = false WHERE courier_id = v_courier;
      END IF;
    END IF;
  END LOOP;
END;
$$;

-- 2. courier_explain_delay — courier-typed but routed as a system notice.
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

  INSERT INTO chat_messages(order_id, sender_id, sender_role, body)
  VALUES (p_order_id, v_uid, 'system',
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

-- 3. report_problem_post_pickup — system-tagged.
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

  UPDATE orders SET expected_action_by = NULL WHERE id = p_order_id;

  INSERT INTO chat_messages(order_id, sender_id, sender_role, body)
  VALUES (p_order_id, v_uid, 'system',
    'Курьер сообщил о проблеме: ' || p_reason_code || COALESCE(' — ' || p_free_form, ''));
END;
$$;

-- 4. courier_report_customer_no_show — system-tagged.
CREATE OR REPLACE FUNCTION courier_report_customer_no_show(p_order_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_courier uuid;
  v_status order_status;
BEGIN
  SELECT courier_id, status INTO v_courier, v_status FROM orders WHERE id = p_order_id;
  IF v_courier IS DISTINCT FROM v_uid THEN
    RAISE EXCEPTION 'unauthorized'
      USING ERRCODE='P0001', DETAIL=jsonb_build_object('reason','UNAUTHORIZED')::text;
  END IF;
  IF v_status <> 'courier_arrived_customer' THEN
    RAISE EXCEPTION 'invalid_status_transition'
      USING ERRCODE='P0001', DETAIL=jsonb_build_object('reason','INVALID_STATUS_TRANSITION','status', v_status)::text;
  END IF;

  UPDATE orders SET
    no_show_started_at = now(),
    expected_action_by = now() + interval '5 minutes',
    courier_delay_reason_code = 'customer_unreachable'
  WHERE id = p_order_id;

  INSERT INTO chat_messages(order_id, sender_id, sender_role, body)
  VALUES (p_order_id, v_uid, 'system',
    'Курьер на месте. Если не выйдете в течение 5 минут, заказ будет отмечен как доставленный (без передачи).');
END;
$$;

-- 5. courier_report_restaurant_delay — system-tagged.
CREATE OR REPLACE FUNCTION courier_report_restaurant_delay(
  p_order_id uuid,
  p_extra_minutes int
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_courier uuid;
  v_status order_status;
  v_total int;
BEGIN
  IF p_extra_minutes IS NULL OR p_extra_minutes <= 0 OR p_extra_minutes > 15 THEN
    RAISE EXCEPTION 'invalid_extra_minutes'
      USING ERRCODE='P0001', DETAIL=jsonb_build_object('reason','INVALID_EXTRA_MINUTES')::text;
  END IF;

  SELECT courier_id, status, restaurant_delay_min INTO v_courier, v_status, v_total
  FROM orders WHERE id = p_order_id FOR UPDATE;
  IF v_courier IS DISTINCT FROM v_uid THEN
    RAISE EXCEPTION 'unauthorized'
      USING ERRCODE='P0001', DETAIL=jsonb_build_object('reason','UNAUTHORIZED')::text;
  END IF;
  IF v_status <> 'courier_arrived_restaurant' THEN
    RAISE EXCEPTION 'invalid_status_transition'
      USING ERRCODE='P0001', DETAIL=jsonb_build_object('reason','INVALID_STATUS_TRANSITION','status', v_status)::text;
  END IF;

  v_total := COALESCE(v_total, 0) + p_extra_minutes;

  IF v_total > 30 THEN
    PERFORM insert_courier_earning_for_cancel(
      p_order_id, v_uid, v_status, 'RESTAURANT_TOO_LONG_WAIT', NULL, NULL
    );
    UPDATE orders SET
      status = 'cancelled_by_system',
      cancellation_reason_code = 'RESTAURANT_TOO_LONG_WAIT',
      cancellation_reason = 'Ресторан превысил допустимое время ожидания (30 минут)',
      restaurant_delay_min = v_total,
      expected_action_by = NULL
    WHERE id = p_order_id;
  ELSE
    UPDATE orders SET
      restaurant_delay_min = v_total,
      expected_action_by = COALESCE(expected_action_by, now()) + (p_extra_minutes || ' minutes')::interval,
      courier_delay_reason_code = 'restaurant_slow',
      courier_delay_explained_at = now()
    WHERE id = p_order_id;
    INSERT INTO chat_messages(order_id, sender_id, sender_role, body)
    VALUES (p_order_id, v_uid, 'system',
      'Курьер на месте, ресторан задерживает выдачу примерно на ' || p_extra_minutes::text || ' мин.');
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION run_courier_escalation_ladder()                TO authenticated;
GRANT EXECUTE ON FUNCTION courier_explain_delay(uuid, text, text)        TO authenticated;
GRANT EXECUTE ON FUNCTION report_problem_post_pickup(uuid, text, text)   TO authenticated;
GRANT EXECUTE ON FUNCTION courier_report_customer_no_show(uuid)          TO authenticated;
GRANT EXECUTE ON FUNCTION courier_report_restaurant_delay(uuid, int)     TO authenticated;

COMMIT;
