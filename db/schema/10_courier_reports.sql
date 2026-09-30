-- 10_courier_reports.sql — the four non-transition RPCs the courier app calls,
-- plus the escalation ladder that owns six of the seven system edges.
--
-- Without these the courier app gets a 404 from PostgREST on four buttons.

-- ---------------------------------------------------------------------------
-- courier_explain_delay — pauses the SLA and tells the consumer why.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.courier_explain_delay(
  p_order_id    uuid,
  p_reason_code text,
  p_free_form   text DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_courier uuid;
BEGIN
  IF p_reason_code NOT IN ('traffic','restaurant_slow','address_unclear',
                           'customer_unreachable','other') THEN
    RAISE EXCEPTION 'invalid_reason_code'
      USING ERRCODE='P0001', DETAIL=jsonb_build_object(
        'reason','INVALID_REASON_CODE','code', p_reason_code)::text;
  END IF;

  SELECT courier_id INTO v_courier FROM public.orders WHERE id = p_order_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'order_not_found'
      USING ERRCODE='P0001', DETAIL=jsonb_build_object('reason','ORDER_NOT_FOUND')::text;
  END IF;
  IF v_courier IS DISTINCT FROM v_uid THEN
    RAISE EXCEPTION 'unauthorized'
      USING ERRCODE='P0001', DETAIL=jsonb_build_object('reason','UNAUTHORIZED')::text;
  END IF;

  UPDATE public.orders SET
    courier_delay_reason_code  = p_reason_code,
    courier_delay_explained_at = now(),
    expected_action_by = COALESCE(expected_action_by, now()) + interval '5 minutes',
    updated_at = now()
  WHERE id = p_order_id;

  INSERT INTO public.chat_messages(order_id, sender_id, body)
  VALUES (p_order_id, v_uid,
    CASE p_reason_code
      WHEN 'traffic'              THEN 'Курьер: пробки на дороге, чуть задерживаюсь.'
      WHEN 'restaurant_slow'      THEN 'Курьер: ресторан задерживает выдачу.'
      WHEN 'address_unclear'      THEN 'Курьер: не могу найти адрес, уточните пожалуйста.'
      WHEN 'customer_unreachable' THEN 'Курьер: не могу с вами связаться.'
      ELSE                             'Курьер сообщил о задержке.'
    END || COALESCE(' — ' || p_free_form, ''));
END;
$$;

-- ---------------------------------------------------------------------------
-- report_problem_post_pickup — holds escalation, notifies, does not cancel.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.report_problem_post_pickup(
  p_order_id    uuid,
  p_reason_code text,
  p_free_form   text DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_courier uuid;
  v_status public.order_status;
BEGIN
  SELECT status, courier_id INTO v_status, v_courier
  FROM public.orders WHERE id = p_order_id;
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
      USING ERRCODE='P0001', DETAIL=jsonb_build_object(
        'reason','INVALID_STATUS_TRANSITION','status', v_status)::text;
  END IF;

  -- Pause the SLA so the ladder does not trip on a problem already reported.
  UPDATE public.orders SET expected_action_by = NULL, updated_at = now()
  WHERE id = p_order_id;

  INSERT INTO public.chat_messages(order_id, sender_id, body)
  VALUES (p_order_id, v_uid,
    'Курьер сообщил о проблеме: ' || p_reason_code || COALESCE(' — ' || p_free_form, ''));
END;
$$;

-- ---------------------------------------------------------------------------
-- courier_report_customer_no_show — starts the 5-minute hand-off clock that
-- mark_no_show_deliveries later acts on.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.courier_report_customer_no_show(p_order_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_courier uuid;
  v_status public.order_status;
BEGIN
  SELECT courier_id, status INTO v_courier, v_status
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
        'reason','INVALID_STATUS_TRANSITION','status', v_status)::text;
  END IF;

  UPDATE public.orders SET
    no_show_started_at = now(),
    expected_action_by = now() + interval '5 minutes',
    courier_delay_reason_code = 'customer_unreachable',
    updated_at = now()
  WHERE id = p_order_id;

  INSERT INTO public.chat_messages(order_id, sender_id, body)
  VALUES (p_order_id, v_uid,
    'Курьер на месте. Если не выйдете в течение 5 минут, заказ будет отмечен как недоставленный.');
END;
$$;

-- ---------------------------------------------------------------------------
-- courier_report_restaurant_delay — accumulates restaurant delay, and at a
-- 30-minute cumulative cap kills the order as restaurant-fault.
--
-- DISCREPANCY, recorded rather than hidden: that cap performs
-- `courier_arrived_restaurant → cancelled_by_system`, and
-- OrderLifecycle.swift declares that edge ONLY for
-- actor=system / rpc=run_courier_escalation_ladder. So either the Swift
-- declaration is missing an edge for this RPC, or this RPC is conceptually one
-- trigger of the ladder's policy. Treated as the latter — it declares itself as
-- the ladder, because "the system cancels a stalled order" is exactly the
-- ladder's job and the only difference is that a courier's report rather than a
-- cron tick noticed. Flagged in .context/plans/backend-standup.md: the clean
-- fix is an explicit 37th edge in OrderLifecycle.swift.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.courier_report_restaurant_delay(
  p_order_id      uuid,
  p_extra_minutes int
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_courier uuid;
  v_status public.order_status;
  v_total int;
BEGIN
  IF p_extra_minutes IS NULL OR p_extra_minutes <= 0 OR p_extra_minutes > 15 THEN
    RAISE EXCEPTION 'invalid_extra_minutes'
      USING ERRCODE='P0001', DETAIL=jsonb_build_object('reason','INVALID_EXTRA_MINUTES')::text;
  END IF;

  SELECT courier_id, status, restaurant_delay_min INTO v_courier, v_status, v_total
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
    RAISE EXCEPTION 'invalid_status_transition'
      USING ERRCODE='P0001', DETAIL=jsonb_build_object(
        'reason','INVALID_STATUS_TRANSITION','status', v_status)::text;
  END IF;

  -- D5: no COALESCE. restaurant_delay_min is NOT NULL DEFAULT 0, so a NULL here
  -- would be a real corruption and should be loud rather than silently zero.
  v_total := v_total + p_extra_minutes;

  IF v_total > 30 THEN
    PERFORM public.ravon_record_cancel_earning(
      p_order_id, v_uid, v_status, 'RESTAURANT_TOO_LONG_WAIT');

    PERFORM public.ravon_set_actor('system','run_courier_escalation_ladder');

    UPDATE public.orders SET
      status = 'cancelled_by_system',
      cancellation_reason_code = 'RESTAURANT_TOO_LONG_WAIT',
      cancellation_reason = 'Ресторан превысил допустимое время ожидания (30 минут)',
      restaurant_delay_min = v_total,
      expected_action_by = NULL, updated_at = now()
    WHERE id = p_order_id;

    PERFORM public.ravon_restore_stock(p_order_id);
    UPDATE public.courier_locations SET current_order_id = NULL WHERE courier_id = v_uid;
  ELSE
    UPDATE public.orders SET
      restaurant_delay_min = v_total,
      expected_action_by = COALESCE(expected_action_by, now())
                           + (p_extra_minutes || ' minutes')::interval,
      courier_delay_reason_code = 'restaurant_slow',
      courier_delay_explained_at = now(),
      updated_at = now()
    WHERE id = p_order_id;

    INSERT INTO public.chat_messages(order_id, sender_id, body)
    VALUES (p_order_id, v_uid,
      'Курьер на месте, ресторан задерживает выдачу примерно на '
      || p_extra_minutes::text || ' мин.');
  END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- run_courier_escalation_ladder — owns six of the seven system edges.
--
-- Three passes off one SLA column: warn, escalate, then give up. This is a
-- compact reimplementation of migration 14's ladder, not a line-for-line port —
-- the original's exact pass boundaries were entangled with columns that no
-- longer exist in the same shape. Behaviour preserved: warn once, escalate
-- once, requeue a ghosted order up to 3 times and then cancel it, and suspend a
-- courier after 3 ghost strikes in a rolling window.
--
-- NOT granted to any client role (R16/N4). Migration 14:114 and 17:284 granted
-- it to `authenticated`, and it is a whole-table sweep that writes `orders`,
-- `chat_messages`, `courier_locations` and `profiles.is_suspended_until` for
-- rows the caller has no relationship to. Its narrow WHERE clause limited the
-- damage, but a batch job's authorization model should not be "the WHERE clause
-- happens to be narrow."
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.run_courier_escalation_ladder()
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  rec record;
  v_acted int := 0;
BEGIN
  PERFORM public.ravon_set_actor('system','run_courier_escalation_ladder');

  FOR rec IN
    SELECT id, courier_id, status, reassign_count, expected_action_by,
           courier_no_show_warned_at, courier_no_show_escalated_at
    FROM public.orders
    WHERE expected_action_by IS NOT NULL
      AND expected_action_by < now()
      AND status IN ('created','accepted','preparing','ready',
                     'assigned','courier_arrived_restaurant')
    FOR UPDATE SKIP LOCKED
  LOOP
    -- Pass 1 (T+0): warn.
    IF rec.courier_no_show_warned_at IS NULL THEN
      UPDATE public.orders SET courier_no_show_warned_at = now(), updated_at = now()
      WHERE id = rec.id;
      IF rec.courier_id IS NOT NULL THEN
        INSERT INTO public.chat_messages(order_id, sender_id, body)
        VALUES (rec.id, rec.courier_id, 'Система: курьер задерживается, уточняем статус.');
      END IF;

    -- Pass 2 (T+2): escalate.
    ELSIF rec.courier_no_show_escalated_at IS NULL
          AND rec.courier_no_show_warned_at < now() - interval '2 minutes' THEN
      UPDATE public.orders SET courier_no_show_escalated_at = now(), updated_at = now()
      WHERE id = rec.id;

    -- Pass 3 (T+5): requeue, or give up.
    ELSIF rec.courier_no_show_escalated_at IS NOT NULL
          AND rec.courier_no_show_escalated_at < now() - interval '3 minutes' THEN

      IF rec.courier_id IS NOT NULL AND rec.reassign_count < 3 THEN
        PERFORM public.ravon_record_cancel_earning(
          rec.id, rec.courier_id, rec.status, 'COURIER_NON_RESPONSIVE');

        UPDATE public.orders SET
          status = 'ready', courier_id = NULL, claimed_at = NULL,
          arrived_at_restaurant_at = NULL,
          excluded_courier_ids = array_append(excluded_courier_ids, rec.courier_id),
          reassign_count = reassign_count + 1,
          courier_no_show_warned_at = NULL, courier_no_show_escalated_at = NULL,
          expected_action_by = now() + interval '8 minutes',
          eta_minutes = NULL, updated_at = now()
        WHERE id = rec.id;

        UPDATE public.courier_locations
        SET current_order_id = NULL,
            ghost_strikes = ghost_strikes + 1,
            strikes_reset_at = CASE WHEN strikes_reset_at < now() - interval '24 hours'
                                    THEN now() ELSE strikes_reset_at END
        WHERE courier_id = rec.courier_id;

        -- Three strikes in the window: a 24-hour suspension. This is the one
        -- place `profiles.is_suspended_until` is written.
        UPDATE public.profiles SET is_suspended_until = now() + interval '24 hours'
        WHERE id = rec.courier_id
          AND EXISTS (SELECT 1 FROM public.courier_locations cl
                      WHERE cl.courier_id = rec.courier_id AND cl.ghost_strikes >= 3);
      ELSE
        UPDATE public.orders SET
          status = 'cancelled_by_system',
          cancellation_reason_code = 'SYSTEM_TIMEOUT',
          expected_action_by = NULL, updated_at = now()
        WHERE id = rec.id;
        PERFORM public.ravon_restore_stock(rec.id);
        IF rec.courier_id IS NOT NULL THEN
          UPDATE public.courier_locations SET current_order_id = NULL
          WHERE courier_id = rec.courier_id;
        END IF;
      END IF;
    ELSE
      CONTINUE;   -- not yet due for the next pass
    END IF;

    v_acted := v_acted + 1;
  END LOOP;

  RETURN v_acted;
END;
$$;
