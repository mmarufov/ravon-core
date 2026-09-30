-- 04_orderability.sql — server-truth "can this restaurant take an order".
--
-- Ported from 03_orderability_function_and_view.sql with three security changes.
-- The logic (Asia/Dushanbe wall clock, past-midnight windows, no-row = always
-- open) is preserved exactly, because RestaurantHours.nextOpenAt() in Swift
-- mirrors it and the two must agree.
--
-- CHANGE 1 — these are SECURITY INVOKER, not DEFINER.
--   Migration 03 made all three SECURITY DEFINER and then granted EXECUTE to
--   `anon` (03:152-154), putting three RLS-bypassing functions on the
--   unauthenticated attack surface for no reason: they only read `restaurants`
--   and `restaurant_hours`, which the consumer feed makes world-readable
--   anyway. As INVOKER they need no exemption from R3 at all. This is the
--   cheapest possible fix for three of S3's Layer-1 objects — delete the
--   privilege rather than audit it.
--
-- CHANGE 2 — the view is `security_invoker = true`.
--   `restaurants_orderable` was `SELECT r.*` over `restaurants` with no
--   security_invoker (03:73) and `GRANT SELECT ... TO anon` (03:79). A view
--   without security_invoker executes with the view OWNER's privileges, so RLS
--   on `restaurants` did not apply through it and any holder of the anon key —
--   extractable from any of the three App Store binaries — read every column of
--   every active restaurant row. That was N10, and security_invoker closes it
--   by making the view a lens rather than a bypass.
--
-- CHANGE 3 — fully-qualified identifiers under `SET search_path = ''`.
--   Migration 03 used `SET search_path = public`, which satisfies the
--   `function_search_path_mutable` linter while preserving the hijack it is
--   supposed to prevent: an unqualified reference inside a definer function
--   resolves against a schema the caller may be able to CREATE in. Empty
--   search_path plus qualified names is the version that is actually safe (R6).

CREATE OR REPLACE FUNCTION public.restaurant_within_hours(
  p_restaurant uuid,
  p_at         timestamptz DEFAULT now()
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SET search_path = ''
AS $$
DECLARE
  tjk_ts   timestamp;
  tjk_dow  int;
  tjk_time time;
  h        public.restaurant_hours%ROWTYPE;
BEGIN
  tjk_ts   := (p_at AT TIME ZONE 'Asia/Dushanbe');
  -- Postgres extract(dow) is 0=Sun..6=Sat, already aligned with the DB
  -- convention and with RestaurantHours.dayName.
  tjk_dow  := EXTRACT(DOW FROM tjk_ts)::int;
  tjk_time := tjk_ts::time;

  SELECT * INTO h
  FROM public.restaurant_hours
  WHERE restaurant_id = p_restaurant AND day_of_week = tjk_dow
  LIMIT 1;

  IF NOT FOUND       THEN RETURN true;  END IF;  -- no row today → always open
  IF h.is_closed     THEN RETURN false; END IF;
  IF h.opening_time = h.closing_time THEN RETURN false; END IF;  -- explicit closed marker

  IF h.closing_time > h.opening_time THEN
    RETURN tjk_time >= h.opening_time AND tjk_time <= h.closing_time;
  ELSE
    -- past-midnight window, e.g. 18:00–02:00
    RETURN tjk_time >= h.opening_time OR tjk_time <= h.closing_time;
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.restaurant_is_orderable(
  p_restaurant uuid,
  p_at         timestamptz DEFAULT now()
)
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path = ''
AS $$
  SELECT r.restaurant_status = 'active'
     AND r.is_accepting_orders = true
     AND public.restaurant_within_hours(r.id, p_at)
  FROM public.restaurants r
  WHERE r.id = p_restaurant;
$$;

DROP VIEW IF EXISTS public.restaurants_orderable;
CREATE VIEW public.restaurants_orderable
  WITH (security_invoker = true) AS
SELECT r.*, public.restaurant_is_orderable(r.id) AS is_orderable_now
FROM public.restaurants r
WHERE r.restaurant_status = 'active';

CREATE OR REPLACE FUNCTION public.get_restaurant_orderability(
  p_restaurant_id uuid,
  p_at            timestamptz DEFAULT now()
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SET search_path = ''
AS $$
DECLARE
  r public.restaurants%ROWTYPE;
BEGIN
  SELECT * INTO r FROM public.restaurants WHERE id = p_restaurant_id;
  IF NOT FOUND OR r.restaurant_status = 'closed' THEN
    RETURN jsonb_build_object('is_orderable_now', false,
      'reason', jsonb_build_object('kind','RESTAURANT_CLOSED'), 'opens_at', null);
  END IF;
  IF r.restaurant_status = 'paused' THEN
    RETURN jsonb_build_object('is_orderable_now', false,
      'reason', jsonb_build_object('kind','RESTAURANT_PAUSED'), 'opens_at', null);
  END IF;
  IF r.restaurant_status = 'draft' THEN
    RETURN jsonb_build_object('is_orderable_now', false,
      'reason', jsonb_build_object('kind','RESTAURANT_CLOSED'), 'opens_at', null);
  END IF;
  IF r.is_accepting_orders = false THEN
    RETURN jsonb_build_object('is_orderable_now', false,
      'reason', jsonb_build_object('kind','RESTAURANT_NOT_ACCEPTING',
                                   'until', r.accepting_orders_until), 'opens_at', null);
  END IF;
  IF NOT public.restaurant_within_hours(r.id, p_at) THEN
    -- opens_at stays null: the client renders the label from
    -- RestaurantHours.nextOpenAt(), which has the full week of rows.
    RETURN jsonb_build_object('is_orderable_now', false,
      'reason', jsonb_build_object('kind','OUT_OF_HOURS','opens_at', null), 'opens_at', null);
  END IF;
  RETURN jsonb_build_object('is_orderable_now', true,
    'reason', jsonb_build_object('kind','OK'), 'opens_at', null);
END;
$$;

-- set_accepting_orders — ported from 05_set_accepting_orders_with_until.sql.
-- Migration 05 is instructive: it is the ONE function in the entire corpus with
-- a real ownership check (05:20-27), which is exactly why it resisted anon while
-- everything around it did not.
CREATE OR REPLACE FUNCTION public.set_accepting_orders(
  p_restaurant_id uuid,
  p_accepting     boolean,
  p_until         timestamptz DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
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
  IF NOT EXISTS (
    SELECT 1 FROM public.restaurants
    WHERE id = p_restaurant_id AND owner_id = v_uid
  ) THEN
    RAISE EXCEPTION 'unauthorized'
      USING ERRCODE='P0001', DETAIL=jsonb_build_object('reason','UNAUTHORIZED')::text;
  END IF;

  UPDATE public.restaurants
  SET is_accepting_orders    = p_accepting,
      accepting_orders_until = CASE WHEN p_accepting THEN NULL ELSE p_until END,
      updated_at             = now()
  WHERE id = p_restaurant_id;
END;
$$;
