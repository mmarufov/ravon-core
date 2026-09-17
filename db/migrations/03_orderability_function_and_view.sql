-- Migration 3: Server-truth orderability function + view.
-- Per Workstream A.

-- Helper: given an Asia/Dushanbe wall-clock time, are we within today's open window?
-- Handles past-midnight (close < open) and the no-hours-row case (always-open).
CREATE OR REPLACE FUNCTION restaurant_within_hours(
  p_restaurant uuid,
  p_at         timestamptz DEFAULT now()
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  tjk_ts   timestamp;
  tjk_dow  int;
  tjk_time time;
  row      restaurant_hours%ROWTYPE;
BEGIN
  tjk_ts   := (p_at AT TIME ZONE 'Asia/Dushanbe');
  -- DB convention: 0=Sun .. 6=Sat. Postgres extract(dow): 0=Sun .. 6=Sat — already aligned.
  tjk_dow  := EXTRACT(DOW FROM tjk_ts)::int;
  tjk_time := tjk_ts::time;

  SELECT * INTO row
  FROM restaurant_hours
  WHERE restaurant_id = p_restaurant
    AND day_of_week = tjk_dow
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN true; -- no row for today → always open (preserves prior client-side default)
  END IF;

  IF row.is_closed THEN
    RETURN false;
  END IF;

  IF row.opening_time = row.closing_time THEN
    RETURN false; -- intentional fully-closed marker
  END IF;

  IF row.closing_time > row.opening_time THEN
    RETURN tjk_time >= row.opening_time AND tjk_time <= row.closing_time;
  ELSE
    -- past-midnight: e.g. 18:00–02:00 → either after open OR before close
    RETURN tjk_time >= row.opening_time OR tjk_time <= row.closing_time;
  END IF;
END;
$$;

-- Single source of truth: status + accepting + within_hours.
CREATE OR REPLACE FUNCTION restaurant_is_orderable(
  p_restaurant uuid,
  p_at         timestamptz DEFAULT now()
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT r.restaurant_status = 'active'
     AND r.is_accepting_orders = true
     AND restaurant_within_hours(r.id, p_at)
  FROM restaurants r
  WHERE r.id = p_restaurant;
$$;

-- View used by the consumer feed to show the orderability badge per row.
CREATE OR REPLACE VIEW restaurants_orderable AS
SELECT r.*,
       restaurant_is_orderable(r.id) AS is_orderable_now
FROM restaurants r
WHERE r.restaurant_status = 'active';

GRANT SELECT ON restaurants_orderable TO authenticated, anon;

-- Lightweight RPC the consumer detail screen calls to render bottom CTA state without
-- re-fetching the full restaurant. Returns the same structured reason as validate_cart.
CREATE OR REPLACE FUNCTION get_restaurant_orderability(
  p_restaurant_id uuid,
  p_at            timestamptz DEFAULT now()
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  r        restaurants%ROWTYPE;
  next_open timestamptz;
  hours_today restaurant_hours%ROWTYPE;
BEGIN
  SELECT * INTO r FROM restaurants WHERE id = p_restaurant_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'is_orderable_now', false,
      'reason', jsonb_build_object('kind','RESTAURANT_CLOSED'),
      'opens_at', null
    );
  END IF;

  IF r.restaurant_status = 'closed' THEN
    RETURN jsonb_build_object(
      'is_orderable_now', false,
      'reason', jsonb_build_object('kind','RESTAURANT_CLOSED'),
      'opens_at', null
    );
  END IF;

  IF r.restaurant_status = 'paused' THEN
    RETURN jsonb_build_object(
      'is_orderable_now', false,
      'reason', jsonb_build_object('kind','RESTAURANT_PAUSED'),
      'opens_at', null
    );
  END IF;

  IF r.is_accepting_orders = false THEN
    RETURN jsonb_build_object(
      'is_orderable_now', false,
      'reason', jsonb_build_object(
        'kind','RESTAURANT_NOT_ACCEPTING',
        'until', r.accepting_orders_until
      ),
      'opens_at', null
    );
  END IF;

  IF NOT restaurant_within_hours(r.id, p_at) THEN
    -- Compute next opening today or this week (approximation: server returns null and
    -- the client renders a label from RestaurantHours.nextOpenAt(...)).
    RETURN jsonb_build_object(
      'is_orderable_now', false,
      'reason', jsonb_build_object('kind','OUT_OF_HOURS', 'opens_at', null),
      'opens_at', null
    );
  END IF;

  RETURN jsonb_build_object(
    'is_orderable_now', true,
    'reason', jsonb_build_object('kind','OK'),
    'opens_at', null
  );
END;
$$;

GRANT EXECUTE ON FUNCTION restaurant_within_hours(uuid, timestamptz) TO authenticated, anon;
GRANT EXECUTE ON FUNCTION restaurant_is_orderable(uuid, timestamptz) TO authenticated, anon;
GRANT EXECUTE ON FUNCTION get_restaurant_orderability(uuid, timestamptz) TO authenticated, anon;
