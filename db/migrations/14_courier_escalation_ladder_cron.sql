-- Migration 14: courier escalation ladder cron.
-- Per Workstream A.
--
-- Three passes per active order, every minute:
--   T+0  past expected_action_by   → stamp courier_no_show_warned_at; emit
--                                   realtime event (UPDATE on orders); courier
--                                   app shows "Что происходит?" banner.
--   T+2  still no explanation      → stamp courier_no_show_escalated_at;
--                                   insert system chat message for consumer.
--   T+5  still no explanation       → cancel_by_system + ghost-strike +
--                                   reassign-or-clawback per status.
--
-- Idempotent — safe to run repeatedly. Uses FOR UPDATE SKIP LOCKED for
-- concurrency-safe iteration.

BEGIN;

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

  -- Pass 2: T+2 escalation (system chat to consumer)
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
    INSERT INTO chat_messages(order_id, sender_id, body)
    VALUES (
      rec.id,
      COALESCE(rec.courier_id, '00000000-0000-0000-0000-000000000000'::uuid),
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

    -- Reset rolling 14-day strike counter if expired.
    SELECT ghost_strikes, strikes_reset_at INTO v_strikes, v_reset_at
      FROM courier_locations WHERE courier_id = v_courier;
    IF v_reset_at IS NOT NULL AND v_reset_at + interval '14 days' < v_now THEN
      v_strikes := 0;
      UPDATE courier_locations SET strikes_reset_at = v_now, ghost_strikes = 0 WHERE courier_id = v_courier;
    END IF;

    IF v_status IN ('assigned','courier_arrived_restaurant') THEN
      -- Reassign back to pool.
      PERFORM reassign_ghosted_order(rec.id);
    ELSE
      -- Post-pickup ghost: cancel order, full clawback (-100%).
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

    -- Strike + suspend if 3+ in 14d.
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

GRANT EXECUTE ON FUNCTION run_courier_escalation_ladder() TO authenticated;

-- pg_cron: every minute
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'courier_escalation_ladder') THEN
    PERFORM cron.schedule(
      'courier_escalation_ladder',
      '* * * * *',
      $cron$ SELECT run_courier_escalation_ladder(); $cron$
    );
  END IF;
END $$;

COMMIT;
