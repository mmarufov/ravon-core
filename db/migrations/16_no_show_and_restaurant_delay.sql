-- Migration 16: customer no-show timer + restaurant-not-ready timer.
-- Per Workstream I.

BEGIN;

ALTER TABLE orders
  ADD COLUMN IF NOT EXISTS no_show              boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS no_show_started_at   timestamptz,
  ADD COLUMN IF NOT EXISTS restaurant_delay_min int NOT NULL DEFAULT 0;

-- Courier reports the consumer is not responding at the door.
-- Server starts a 5-minute timer; if not transitioned to delivered by then,
-- mark_delivered_no_show fires and stamps no_show=true.
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

  INSERT INTO chat_messages(order_id, sender_id, body)
  VALUES (p_order_id, v_uid,
    'Курьер на месте. Если не выйдете в течение 5 минут, заказ будет отмечен как доставленный (без передачи).');
END;
$$;

-- Cron pass for no-show: when no_show_started_at + 5min < now() and still
-- in courier_arrived_customer, mark delivered + no_show=true. Earnings = full.
CREATE OR REPLACE FUNCTION mark_no_show_deliveries()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  rec record;
BEGIN
  FOR rec IN
    SELECT id, courier_id FROM orders
    WHERE status = 'courier_arrived_customer'
      AND no_show_started_at IS NOT NULL
      AND no_show_started_at + interval '5 minutes' <= now()
    FOR UPDATE SKIP LOCKED
  LOOP
    UPDATE orders SET
      status = 'delivered',
      delivered_at = now(),
      no_show = true,
      cancellation_reason_code = 'CUSTOMER_NO_SHOW',
      expected_action_by = NULL
    WHERE id = rec.id;
    -- create_courier_earning trigger fires (full earning on delivered).
  END LOOP;
END;
$$;

-- Courier reports the restaurant is delaying — extends SLA up to 30 min.
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
    -- 30-min cap: auto-cancel with restaurant fault, courier earns 50%.
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
    -- cleanup_cancelled_order trigger clears courier_locations.current_order_id.
  ELSE
    UPDATE orders SET
      restaurant_delay_min = v_total,
      expected_action_by = COALESCE(expected_action_by, now()) + (p_extra_minutes || ' minutes')::interval,
      courier_delay_reason_code = 'restaurant_slow',
      courier_delay_explained_at = now()
    WHERE id = p_order_id;
    INSERT INTO chat_messages(order_id, sender_id, body)
    VALUES (p_order_id, v_uid,
      'Курьер на месте, ресторан задерживает выдачу примерно на ' || p_extra_minutes::text || ' мин.');
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION courier_report_customer_no_show(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION mark_no_show_deliveries() TO authenticated;
GRANT EXECUTE ON FUNCTION courier_report_restaurant_delay(uuid, int) TO authenticated;

-- Schedule no-show pass alongside the escalation cron (each minute).
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'mark_no_show_deliveries') THEN
    PERFORM cron.schedule(
      'mark_no_show_deliveries',
      '* * * * *',
      $cron$ SELECT mark_no_show_deliveries(); $cron$
    );
  END IF;
END $$;

COMMIT;
