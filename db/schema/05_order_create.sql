-- 05_order_create.sql — validate_cart + create_order.
--
-- Ported from 04_create_order_v3_and_validate_cart.sql. The orderability gates,
-- the scheduled_for branch and the structured-error convention are preserved
-- verbatim, because Swift decodes the reason codes:
--
--   RAISE EXCEPTION '<short>' USING ERRCODE='P0001',
--     DETAIL = jsonb_build_object('reason','<KIND>', ...)::text
--
-- Four defects are closed.
--
-- N7/R10 — ADDRESS OWNERSHIP. The original did
--   SELECT to_jsonb(a.*) INTO addr_snapshot FROM addresses a WHERE a.id = p_address_id;
-- inside a SECURITY DEFINER function (so RLS on `addresses` did not apply) with
-- no ownership predicate and no NOT FOUND handling. Anyone who learned another
-- user's address UUID got that user's full address row — street, apartment,
-- coordinates — snapshotted into their own order and readable back through
-- their own orders SELECT policy. A bogus UUID silently produced an order with
-- a NULL snapshot. Now the predicate includes `user_id = v_uid`, a miss raises
-- ADDRESS_NOT_FOUND, and `orders.delivery_address_snapshot` is NOT NULL so a
-- snapshot-less order cannot exist.
--
-- N8/R8 — QUANTITY SIGN. The original accumulated
--   subtotal := subtotal + (mi.price * rec.quantity)
-- with no sign check and decremented stock by the same quantity. A cart mixing
-- a large positive line with a negative line of a cheap item cleared the
-- min_order_amount gate while producing a payable subtotal far below the goods
-- ordered, and the negative line INCREASED the restaurant's stock. Quantity is
-- now validated per line with a typed error before the CHECK constraint fires.
--
-- R7 — `total` and `order_items.total_price` are GENERATED columns now, so they
-- are removed from both INSERTs. This is not a style change: it is what makes
-- a desynchronised total impossible rather than merely incorrect-if-buggy.
--
-- STOCK: reserved at checkout for every order, order-now and scheduled alike,
-- through ravon_reserve_stock (06_merchant_rpcs.sql), which writes the
-- `reserve` rows the cancel paths later release. At 65ad66c a scheduled order
-- was checked against stock but reserved nothing and skipped the capacity
-- check, and the activation sweep then decremented with GREATEST(0, ...): 60
-- pre-orders for 40 portions all went live, against a capacity of 25, and
-- stock read 0. Duplicate cart lines are now summed per item before the check,
-- so 2 + 2 against a stock of 3 is a typed INSUFFICIENT_STOCK instead of
-- SQLSTATE 23514 from the CHECK constraint.
--
-- CAPACITY: a scheduled order takes a place in a 15-minute kitchen slot
-- (kitchen_slots, 02_tables.sql) with a conditional increment. Order-now
-- checkouts keep the live-queue count against max_concurrent_orders. The two
-- budgets are separate: an activating slot is not checked against the live
-- queue at that moment (see db/rush/FINDINGS.md).
--
-- ANON — both functions now require auth.uid(). `create_order` previously
-- inserted `user_id = auth.uid()`, and whether an anon caller could create an
-- ownerless order depended on whether `orders.user_id` was NOT NULL, which was
-- unrecoverable. It is NOT NULL here and the check is explicit as well.

-- ---------------------------------------------------------------------------
-- validate_cart — read-only, no locking. Returns the jsonb shape
-- CartValidationResult decodes.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.validate_cart(
  p_restaurant_id uuid,
  p_items         jsonb,                    -- [{menu_item_id uuid, quantity int, unit_price numeric?}]
  p_scheduled_for timestamptz DEFAULT NULL  -- NULL = ASAP
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
-- DEFINER is required despite this being a read: the throttle counts ALL of the
-- restaurant's active orders, and a consumer's RLS on `orders` exposes only
-- their own rows, so an INVOKER version would silently under-count and never
-- report OVERLOADED.
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  r            public.restaurants%ROWTYPE;
  effective_at timestamptz;
  reason       jsonb := jsonb_build_object('kind','OK');
  orderable    boolean := true;
  items_out    jsonb := '[]'::jsonb;
  subtotal     numeric := 0;
  active_count int;
  rec          record;
  item_totals  jsonb;
  slot_full    boolean;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'not_authenticated'
      USING ERRCODE='P0001', DETAIL=jsonb_build_object('reason','NOT_AUTHENTICATED')::text;
  END IF;

  effective_at := COALESCE(p_scheduled_for, now());

  SELECT * INTO r FROM public.restaurants WHERE id = p_restaurant_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'orderable', false,
      'reason', jsonb_build_object('kind','RESTAURANT_CLOSED'),
      'items', '[]'::jsonb, 'subtotal', 0,
      'min_order_amount', 0, 'min_order_met', false);
  END IF;

  IF r.restaurant_status IN ('closed','draft') THEN
    orderable := false; reason := jsonb_build_object('kind','RESTAURANT_CLOSED');
  ELSIF r.restaurant_status = 'paused' THEN
    orderable := false; reason := jsonb_build_object('kind','RESTAURANT_PAUSED');
  ELSIF r.is_accepting_orders = false THEN
    orderable := false;
    reason := jsonb_build_object('kind','RESTAURANT_NOT_ACCEPTING','until', r.accepting_orders_until);
  ELSIF NOT public.restaurant_within_hours(r.id, effective_at) THEN
    orderable := false; reason := jsonb_build_object('kind','OUT_OF_HOURS','opens_at', null);
  END IF;

  -- Throttle applies to ASAP orders only; scheduled rows are held outside the
  -- live queue. `scheduled` is excluded from the active set for the same reason.
  IF p_scheduled_for IS NULL AND r.max_concurrent_orders IS NOT NULL THEN
    SELECT count(*) INTO active_count FROM public.orders
    WHERE restaurant_id = r.id
      AND status NOT IN ('delivered','cancelled','rejected','scheduled',
                         'cancelled_by_customer','cancelled_by_restaurant',
                         'cancelled_by_system','cancelled_by_courier');
    IF active_count >= r.max_concurrent_orders THEN
      orderable := false; reason := jsonb_build_object('kind','OVERLOADED');
    END IF;
  END IF;

  -- A scheduled order is refused when its kitchen slot is full (create_order).
  IF p_scheduled_for IS NOT NULL AND r.max_concurrent_orders IS NOT NULL THEN
    SELECT ks.taken >= ks.capacity INTO slot_full
    FROM public.kitchen_slots ks
    WHERE ks.restaurant_id = r.id
      AND ks.slot_start = date_bin('15 minutes', p_scheduled_for,
                                   timestamptz '2000-01-01 00:00+00');
    IF COALESCE(slot_full, false) AND orderable THEN
      orderable := false; reason := jsonb_build_object('kind','OVERLOADED');
    END IF;
  END IF;

  -- Stock is compared against the whole cart's demand for an item, not one
  -- line's: the consumer app splits an item across lines when the lines carry
  -- different modifiers.
  SELECT COALESCE(jsonb_object_agg(menu_item_id, total), '{}'::jsonb) INTO item_totals
  FROM (SELECT it->>'menu_item_id' AS menu_item_id, sum((it->>'quantity')::int) AS total
        FROM jsonb_array_elements(p_items) AS it
        GROUP BY 1) t
  WHERE menu_item_id IS NOT NULL;

  FOR rec IN
    SELECT (it->>'menu_item_id')::uuid AS menu_item_id,
           (it->>'quantity')::int      AS quantity,
           (it->>'unit_price')::numeric AS expected_price
    FROM jsonb_array_elements(p_items) AS it
  LOOP
    DECLARE
      mi public.menu_items%ROWTYPE;
      st jsonb;
    BEGIN
      SELECT * INTO mi FROM public.menu_items WHERE id = rec.menu_item_id;
      IF NOT FOUND OR mi.deleted_at IS NOT NULL THEN
        st := jsonb_build_object('menu_item_id', rec.menu_item_id, 'status','DELETED');
        orderable := false;
      ELSIF mi.is_available = false THEN
        st := jsonb_build_object('menu_item_id', rec.menu_item_id, 'status','UNAVAILABLE');
        orderable := false;
      ELSIF rec.quantity IS NULL OR rec.quantity < 1 OR rec.quantity > 99 THEN
        -- N8: surfaced as a per-item status rather than a bare constraint error.
        st := jsonb_build_object('menu_item_id', rec.menu_item_id, 'status','UNAVAILABLE');
        orderable := false;
      ELSIF mi.stock_count IS NOT NULL
            AND mi.stock_count < (item_totals->>(rec.menu_item_id::text))::int THEN
        st := jsonb_build_object('menu_item_id', rec.menu_item_id,
                                 'status','INSUFFICIENT_STOCK','have', mi.stock_count);
        orderable := false;
      ELSIF rec.expected_price IS NOT NULL AND rec.expected_price <> mi.price THEN
        -- D9: CartItemStatus.priceChanged existed in Swift with no SQL path that
        -- could ever emit it — the client could decode a status the server never
        -- sent. It is emitted now, but only when the caller supplies the price it
        -- is holding. `unit_price` is optional in p_items, so existing callers
        -- (which send only menu_item_id + quantity) are unaffected and this
        -- branch stays dormant until a client opts in.
        st := jsonb_build_object('menu_item_id', rec.menu_item_id, 'status','PRICE_CHANGED',
                                 'old_price', rec.expected_price, 'new_price', mi.price);
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
    'min_order_met', subtotal >= r.min_order_amount);
END;
$$;

-- ---------------------------------------------------------------------------
-- create_order
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.create_order(
  p_restaurant_id uuid,
  p_address_id    uuid,
  p_items         jsonb,
  p_notes         text DEFAULT NULL,
  p_scheduled_for timestamptz DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid          uuid := auth.uid();
  r              public.restaurants%ROWTYPE;
  effective_at   timestamptz;
  new_order_id   uuid;
  status_value   public.order_status;
  subtotal       numeric := 0;
  v_active_count int;
  rec            record;
  mi             public.menu_items%ROWTYPE;
  addr_snapshot  jsonb;
  v_slot         timestamptz;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not_authenticated'
      USING ERRCODE='P0001', DETAIL=jsonb_build_object('reason','NOT_AUTHENTICATED')::text;
  END IF;

  effective_at := COALESCE(p_scheduled_for, now());

  SELECT * INTO r FROM public.restaurants WHERE id = p_restaurant_id FOR UPDATE;
  IF NOT FOUND OR r.restaurant_status = 'closed' THEN
    RAISE EXCEPTION 'restaurant_closed'
      USING ERRCODE='P0001', DETAIL=jsonb_build_object('reason','RESTAURANT_CLOSED')::text;
  END IF;
  IF r.restaurant_status = 'paused' THEN
    RAISE EXCEPTION 'restaurant_paused'
      USING ERRCODE='P0001', DETAIL=jsonb_build_object('reason','RESTAURANT_PAUSED')::text;
  END IF;
  IF r.restaurant_status <> 'active' THEN
    RAISE EXCEPTION 'restaurant_not_active'
      USING ERRCODE='P0001', DETAIL=jsonb_build_object('reason','RESTAURANT_CLOSED')::text;
  END IF;
  IF r.is_accepting_orders = false THEN
    RAISE EXCEPTION 'restaurant_not_accepting'
      USING ERRCODE='P0001', DETAIL=jsonb_build_object(
        'reason','RESTAURANT_NOT_ACCEPTING','until', r.accepting_orders_until)::text;
  END IF;
  IF NOT public.restaurant_within_hours(r.id, effective_at) THEN
    RAISE EXCEPTION 'restaurant_out_of_hours'
      USING ERRCODE='P0001', DETAIL=jsonb_build_object('reason','OUT_OF_HOURS')::text;
  END IF;

  IF p_scheduled_for IS NOT NULL THEN
    IF p_scheduled_for < now() + interval '5 minutes'
       OR p_scheduled_for > now() + interval '7 days' THEN
      RAISE EXCEPTION 'scheduled_time_invalid'
        USING ERRCODE='P0001', DETAIL=jsonb_build_object('reason','SCHEDULED_TIME_INVALID')::text;
    END IF;
  END IF;

  IF p_scheduled_for IS NULL AND r.max_concurrent_orders IS NOT NULL THEN
    SELECT count(*) INTO v_active_count FROM public.orders
    WHERE restaurant_id = r.id
      AND status NOT IN ('delivered','cancelled','rejected','scheduled',
                         'cancelled_by_customer','cancelled_by_restaurant',
                         'cancelled_by_system','cancelled_by_courier');
    IF v_active_count >= r.max_concurrent_orders THEN
      RAISE EXCEPTION 'restaurant_overloaded'
        USING ERRCODE='P0001', DETAIL=jsonb_build_object('reason','OVERLOADED')::text;
    END IF;
  END IF;

  -- N7/R10: ownership is in the predicate, and a miss is loud.
  SELECT to_jsonb(a.*) INTO addr_snapshot
  FROM public.addresses a
  WHERE a.id = p_address_id AND a.user_id = v_uid;
  IF addr_snapshot IS NULL THEN
    RAISE EXCEPTION 'address_not_found'
      USING ERRCODE='P0001', DETAIL=jsonb_build_object('reason','ADDRESS_NOT_FOUND')::text;
  END IF;

  status_value := CASE WHEN p_scheduled_for IS NOT NULL
                       THEN 'scheduled'::public.order_status
                       ELSE 'created'::public.order_status END;

  IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'cart_empty'
      USING ERRCODE='P0001', DETAIL=jsonb_build_object('reason','CART_EMPTY')::text;
  END IF;

  -- Per-line validation first, so a negative line cannot hide inside a sum.
  FOR rec IN
    SELECT (it->>'menu_item_id')::uuid AS menu_item_id,
           (it->>'quantity')::int      AS quantity
    FROM jsonb_array_elements(p_items) AS it
  LOOP
    IF rec.quantity IS NULL OR rec.quantity < 1 OR rec.quantity > 99 THEN
      RAISE EXCEPTION 'invalid_quantity'
        USING ERRCODE='P0001', DETAIL=jsonb_build_object(
          'reason','INVALID_QUANTITY','menu_item_id', rec.menu_item_id,
          'quantity', rec.quantity)::text;
    END IF;
  END LOOP;

  -- Then once per ITEM, with every line for it summed, and in menu_item_id
  -- order so that two checkouts (or a checkout and ravon_restore_stock) lock
  -- item rows in the same order.
  FOR rec IN
    SELECT (it->>'menu_item_id')::uuid        AS menu_item_id,
           sum((it->>'quantity')::int)::int   AS quantity
    FROM jsonb_array_elements(p_items) AS it
    GROUP BY 1
    ORDER BY 1
  LOOP
    SELECT * INTO mi FROM public.menu_items WHERE id = rec.menu_item_id FOR UPDATE;
    IF NOT FOUND OR mi.deleted_at IS NOT NULL OR mi.is_available = false THEN
      RAISE EXCEPTION 'item_unavailable'
        USING ERRCODE='P0001', DETAIL=jsonb_build_object(
          'reason','ITEM_UNAVAILABLE','menu_item_id', rec.menu_item_id)::text;
    END IF;
    -- Cross-restaurant carts were never checked. An order's items must all
    -- belong to the restaurant the order is against, or the merchant is asked to
    -- cook a competitor's dish and the subtotal is billed to the wrong party.
    IF mi.restaurant_id <> p_restaurant_id THEN
      RAISE EXCEPTION 'item_wrong_restaurant'
        USING ERRCODE='P0001', DETAIL=jsonb_build_object(
          'reason','ITEM_UNAVAILABLE','menu_item_id', rec.menu_item_id)::text;
    END IF;
    IF mi.stock_count IS NOT NULL AND mi.stock_count < rec.quantity THEN
      RAISE EXCEPTION 'insufficient_stock'
        USING ERRCODE='P0001', DETAIL=jsonb_build_object(
          'reason','INSUFFICIENT_STOCK','menu_item_id', rec.menu_item_id,
          'have', mi.stock_count)::text;
    END IF;
    subtotal := subtotal + (mi.price * rec.quantity);
  END LOOP;

  IF subtotal < r.min_order_amount THEN
    RAISE EXCEPTION 'min_order_not_met'
      USING ERRCODE='P0001', DETAIL=jsonb_build_object(
        'reason','MIN_ORDER_NOT_MET','need', r.min_order_amount)::text;
  END IF;

  -- A scheduled order takes a place in its kitchen slot now, at checkout, so
  -- that the refusal happens while the buyer is still looking at the screen
  -- rather than as a system cancel at activation. The conditional increment is
  -- the capacity check; the restaurant row lock above already serialises this
  -- block, and the WHERE clause would keep it correct without that lock.
  IF p_scheduled_for IS NOT NULL AND r.max_concurrent_orders IS NOT NULL THEN
    v_slot := date_bin('15 minutes', p_scheduled_for, timestamptz '2000-01-01 00:00+00');
    INSERT INTO public.kitchen_slots(restaurant_id, slot_start, capacity)
    VALUES (r.id, v_slot, r.max_concurrent_orders)
    ON CONFLICT (restaurant_id, slot_start) DO NOTHING;

    UPDATE public.kitchen_slots
    SET taken = taken + 1
    WHERE restaurant_id = r.id AND slot_start = v_slot AND taken < capacity;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'kitchen_slot_full'
        USING ERRCODE='P0001', DETAIL=jsonb_build_object(
          'reason','OVERLOADED','slot_start', v_slot)::text;
    END IF;
  END IF;

  -- `total` is GENERATED and must not appear here.
  INSERT INTO public.orders(
    user_id, restaurant_id, address_id, status,
    subtotal, delivery_fee, delivery_address_snapshot, notes, scheduled_for)
  VALUES (
    v_uid, p_restaurant_id, p_address_id, status_value,
    subtotal, r.delivery_fee, addr_snapshot, p_notes, p_scheduled_for)
  RETURNING id INTO new_order_id;

  IF v_slot IS NOT NULL THEN
    INSERT INTO public.kitchen_slot_holds(order_id, restaurant_id, slot_start)
    VALUES (new_order_id, r.id, v_slot);
  END IF;

  FOR rec IN
    SELECT (it->>'menu_item_id')::uuid AS menu_item_id,
           (it->>'quantity')::int      AS quantity
    FROM jsonb_array_elements(p_items) AS it
  LOOP
    SELECT * INTO mi FROM public.menu_items WHERE id = rec.menu_item_id;

    -- `total_price` is GENERATED and must not appear here.
    INSERT INTO public.order_items(
      order_id, menu_item_id, quantity, unit_price,
      item_name, item_description, item_image_url, modifiers_snapshot)
    VALUES (
      new_order_id, mi.id, rec.quantity, mi.price,
      mi.name, mi.description, mi.image_url, '[]'::jsonb);
  END LOOP;

  -- One reservation per item for the summed quantity, order-now and scheduled
  -- alike. The activation sweep consumes it and does not decrement again.
  PERFORM public.ravon_reserve_stock(new_order_id);

  RETURN new_order_id;
END;
$$;
