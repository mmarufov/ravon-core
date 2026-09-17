-- Migration 4: create_order v3 (hours + min_order + structured errors) + validate_cart RPC.
-- Per Workstream A + C.

-- validate_cart: read-only, idempotent, no row locking. Returns jsonb shape consumed by
-- Swift CartValidationResult. Called by the consumer's confirm-tap loading screen.
CREATE OR REPLACE FUNCTION validate_cart(
  p_restaurant_id uuid,
  p_items         jsonb,                    -- [{menu_item_id uuid, quantity int}, ...]
  p_scheduled_for timestamptz DEFAULT NULL  -- NULL = ASAP
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  r           restaurants%ROWTYPE;
  effective_at timestamptz;
  reason      jsonb := jsonb_build_object('kind','OK');
  orderable   boolean := true;
  items_out   jsonb := '[]'::jsonb;
  subtotal    numeric := 0;
  active_count int;
  rec         record;
BEGIN
  effective_at := COALESCE(p_scheduled_for, now());

  SELECT * INTO r FROM restaurants WHERE id = p_restaurant_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'orderable', false,
      'reason', jsonb_build_object('kind','RESTAURANT_CLOSED'),
      'items', '[]'::jsonb,
      'subtotal', 0,
      'min_order_amount', 0,
      'min_order_met', false
    );
  END IF;

  IF r.restaurant_status = 'closed' THEN
    orderable := false;
    reason := jsonb_build_object('kind','RESTAURANT_CLOSED');
  ELSIF r.restaurant_status = 'paused' THEN
    orderable := false;
    reason := jsonb_build_object('kind','RESTAURANT_PAUSED');
  ELSIF r.is_accepting_orders = false THEN
    orderable := false;
    reason := jsonb_build_object('kind','RESTAURANT_NOT_ACCEPTING','until', r.accepting_orders_until);
  ELSIF NOT restaurant_within_hours(r.id, effective_at) THEN
    orderable := false;
    reason := jsonb_build_object('kind','OUT_OF_HOURS','opens_at', null);
  END IF;

  -- Throttle check (only meaningful for ASAP orders)
  IF p_scheduled_for IS NULL AND r.max_concurrent_orders IS NOT NULL THEN
    SELECT count(*) INTO active_count FROM orders
    WHERE restaurant_id = r.id
      AND status NOT IN (
        'delivered','cancelled','rejected',
        'cancelled_by_customer','cancelled_by_restaurant','cancelled_by_system',
        'scheduled'
      );
    IF active_count >= r.max_concurrent_orders THEN
      orderable := false;
      reason := jsonb_build_object('kind','OVERLOADED');
    END IF;
  END IF;

  -- Per-item evaluation
  FOR rec IN
    SELECT (it->>'menu_item_id')::uuid AS menu_item_id,
           (it->>'quantity')::int AS quantity
    FROM jsonb_array_elements(p_items) AS it
  LOOP
    DECLARE
      mi  menu_items%ROWTYPE;
      st  jsonb;
    BEGIN
      SELECT * INTO mi FROM menu_items WHERE id = rec.menu_item_id;
      IF NOT FOUND OR mi.deleted_at IS NOT NULL THEN
        st := jsonb_build_object('menu_item_id', rec.menu_item_id, 'status','DELETED');
      ELSIF mi.is_available = false THEN
        st := jsonb_build_object('menu_item_id', rec.menu_item_id, 'status','UNAVAILABLE');
      ELSIF mi.stock_count IS NOT NULL AND mi.stock_count < rec.quantity THEN
        st := jsonb_build_object(
          'menu_item_id', rec.menu_item_id,
          'status','INSUFFICIENT_STOCK',
          'have', mi.stock_count
        );
        orderable := false;
      ELSE
        st := jsonb_build_object('menu_item_id', rec.menu_item_id, 'status','OK');
        subtotal := subtotal + (mi.price * rec.quantity);
      END IF;
      items_out := items_out || jsonb_build_array(st);
    END;
  END LOOP;

  IF subtotal < r.min_order_amount THEN
    IF orderable THEN
      reason := jsonb_build_object('kind','MIN_ORDER_NOT_MET','need', r.min_order_amount);
    END IF;
    orderable := false;
  END IF;

  RETURN jsonb_build_object(
    'orderable', orderable,
    'reason', reason,
    'items', items_out,
    'subtotal', subtotal,
    'min_order_amount', r.min_order_amount,
    'min_order_met', subtotal >= r.min_order_amount
  );
END;
$$;

GRANT EXECUTE ON FUNCTION validate_cart(uuid, jsonb, timestamptz) TO authenticated;

-- create_order v3 — replaces the existing create_order. Adds:
--   * hours enforcement via restaurant_is_orderable
--   * min_order_amount enforcement
--   * scheduled_for branch (no stock decrement, status=scheduled)
--   * structured error via DETAIL jsonb on RAISE
--
-- Backwards-compatible: the p_scheduled_for arg defaults to NULL.
CREATE OR REPLACE FUNCTION create_order(
  p_restaurant_id uuid,
  p_address_id    uuid,
  p_items         jsonb,
  p_notes         text DEFAULT NULL,
  p_scheduled_for timestamptz DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  r              restaurants%ROWTYPE;
  effective_at   timestamptz;
  new_order_id   uuid;
  status_value   text;
  subtotal       numeric := 0;
  v_total        numeric;
  v_active_count int;
  rec            record;
  mi             menu_items%ROWTYPE;
  addr_snapshot  jsonb;
BEGIN
  effective_at := COALESCE(p_scheduled_for, now());

  SELECT * INTO r FROM restaurants WHERE id = p_restaurant_id FOR UPDATE;
  IF NOT FOUND OR r.restaurant_status = 'closed' THEN
    RAISE EXCEPTION 'restaurant_closed'
      USING ERRCODE = 'P0001', DETAIL = jsonb_build_object('reason','RESTAURANT_CLOSED')::text;
  END IF;
  IF r.restaurant_status = 'paused' THEN
    RAISE EXCEPTION 'restaurant_paused'
      USING ERRCODE = 'P0001', DETAIL = jsonb_build_object('reason','RESTAURANT_PAUSED')::text;
  END IF;
  IF r.restaurant_status <> 'active' THEN
    RAISE EXCEPTION 'restaurant_not_active'
      USING ERRCODE = 'P0001', DETAIL = jsonb_build_object('reason','RESTAURANT_CLOSED')::text;
  END IF;
  IF r.is_accepting_orders = false THEN
    RAISE EXCEPTION 'restaurant_not_accepting'
      USING ERRCODE = 'P0001', DETAIL = jsonb_build_object(
        'reason','RESTAURANT_NOT_ACCEPTING','until', r.accepting_orders_until
      )::text;
  END IF;
  IF NOT restaurant_within_hours(r.id, effective_at) THEN
    RAISE EXCEPTION 'restaurant_out_of_hours'
      USING ERRCODE = 'P0001', DETAIL = jsonb_build_object('reason','OUT_OF_HOURS')::text;
  END IF;

  -- Schedule window check
  IF p_scheduled_for IS NOT NULL THEN
    IF p_scheduled_for < now() + interval '5 minutes'
       OR p_scheduled_for > now() + interval '7 days' THEN
      RAISE EXCEPTION 'scheduled_time_invalid'
        USING ERRCODE = 'P0001', DETAIL = jsonb_build_object('reason','SCHEDULED_TIME_INVALID')::text;
    END IF;
  END IF;

  -- Throttle (skip for scheduled — they're held outside the live queue)
  IF p_scheduled_for IS NULL AND r.max_concurrent_orders IS NOT NULL THEN
    SELECT count(*) INTO v_active_count FROM orders
    WHERE restaurant_id = r.id
      AND status NOT IN (
        'delivered','cancelled','rejected',
        'cancelled_by_customer','cancelled_by_restaurant','cancelled_by_system',
        'scheduled'
      );
    IF v_active_count >= r.max_concurrent_orders THEN
      RAISE EXCEPTION 'restaurant_overloaded'
        USING ERRCODE = 'P0001', DETAIL = jsonb_build_object('reason','OVERLOADED')::text;
    END IF;
  END IF;

  -- Address snapshot
  SELECT to_jsonb(a.*) INTO addr_snapshot FROM addresses a WHERE a.id = p_address_id;

  status_value := CASE WHEN p_scheduled_for IS NOT NULL THEN 'scheduled' ELSE 'created' END;

  -- Compute subtotal and validate items
  FOR rec IN
    SELECT (it->>'menu_item_id')::uuid AS menu_item_id,
           (it->>'quantity')::int AS quantity
    FROM jsonb_array_elements(p_items) AS it
  LOOP
    SELECT * INTO mi FROM menu_items WHERE id = rec.menu_item_id FOR UPDATE;
    IF NOT FOUND OR mi.deleted_at IS NOT NULL OR mi.is_available = false THEN
      RAISE EXCEPTION 'item_unavailable'
        USING ERRCODE = 'P0001',
              DETAIL = jsonb_build_object('reason','ITEM_UNAVAILABLE','menu_item_id', rec.menu_item_id)::text;
    END IF;
    IF mi.stock_count IS NOT NULL AND mi.stock_count < rec.quantity THEN
      RAISE EXCEPTION 'insufficient_stock'
        USING ERRCODE = 'P0001',
              DETAIL = jsonb_build_object(
                'reason','INSUFFICIENT_STOCK',
                'menu_item_id', rec.menu_item_id,
                'have', mi.stock_count
              )::text;
    END IF;
    subtotal := subtotal + (mi.price * rec.quantity);
  END LOOP;

  IF subtotal < r.min_order_amount THEN
    RAISE EXCEPTION 'min_order_not_met'
      USING ERRCODE = 'P0001',
            DETAIL = jsonb_build_object('reason','MIN_ORDER_NOT_MET','need', r.min_order_amount)::text;
  END IF;

  v_total := subtotal + r.delivery_fee;

  INSERT INTO orders(
    user_id, restaurant_id, address_id, status,
    subtotal, delivery_fee, total,
    delivery_address_snapshot, notes, scheduled_for
  )
  VALUES (
    auth.uid(), p_restaurant_id, p_address_id, status_value,
    subtotal, r.delivery_fee, v_total,
    addr_snapshot, p_notes, p_scheduled_for
  )
  RETURNING id INTO new_order_id;

  -- Insert order_items with snapshot fields. Decrement stock ONLY for non-scheduled orders.
  FOR rec IN
    SELECT (it->>'menu_item_id')::uuid AS menu_item_id,
           (it->>'quantity')::int AS quantity
    FROM jsonb_array_elements(p_items) AS it
  LOOP
    SELECT * INTO mi FROM menu_items WHERE id = rec.menu_item_id;
    INSERT INTO order_items(
      order_id, menu_item_id, quantity, unit_price, total_price,
      item_name, item_description, item_image_url, modifiers_snapshot
    )
    VALUES (
      new_order_id, mi.id, rec.quantity, mi.price, mi.price * rec.quantity,
      mi.name, mi.description, mi.image_url, '[]'::jsonb
    );

    IF p_scheduled_for IS NULL AND mi.stock_count IS NOT NULL THEN
      UPDATE menu_items
      SET stock_count = stock_count - rec.quantity
      WHERE id = mi.id;
    END IF;
  END LOOP;

  RETURN new_order_id;
END;
$$;

GRANT EXECUTE ON FUNCTION create_order(uuid, uuid, jsonb, text, timestamptz) TO authenticated;
