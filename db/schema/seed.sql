-- seed.sql — one consumer, one merchant with a restaurant and a menu, one courier.
--
-- Runs as the owner/service role (psql, the Supabase SQL editor, or
-- mcp apply_migration). It inserts into auth.users, which fires
-- handle_new_user and creates each profile with role='consumer' — the hardcoded
-- value. The two promotions below are therefore also a demonstration that the
-- admin path still works: profiles_block_role_change fires only when
-- auth.uid() IS NOT NULL, and a psql session has no JWT.
--
-- Fixed UUIDs so db/schema/walk.sql can reference the actors by name.

BEGIN;

INSERT INTO auth.users (id, email, raw_user_meta_data) VALUES
  ('11111111-1111-1111-1111-111111111111', 'consumer@ravon.tj',
     '{"full_name":"Фаррух Ализода","role":"merchant"}'::jsonb),
  ('22222222-2222-2222-2222-222222222222', 'merchant@ravon.tj',
     '{"full_name":"Ресторан Осиё"}'::jsonb),
  ('33333333-3333-3333-3333-333333333333', 'courier@ravon.tj',
     '{"full_name":"Сафар Наботов"}'::jsonb)
ON CONFLICT (id) DO NOTHING;

-- NOTE the consumer's metadata above claims "role":"merchant". That is the S1
-- exploit payload verbatim — one unauthenticated POST /auth/v1/signup with the
-- anon key. Under migration 18 it provisioned the caller as a merchant. Assert
-- that it did nothing here.
DO $$
DECLARE v_role public.user_role;
BEGIN
  SELECT role INTO v_role FROM public.profiles
  WHERE id = '11111111-1111-1111-1111-111111111111';
  IF v_role <> 'consumer' THEN
    RAISE EXCEPTION 'S1 REGRESSION: signup metadata set role=%, expected consumer', v_role;
  END IF;
  RAISE NOTICE 'S1 check: signup metadata role=merchant was ignored, profile is consumer';
END $$;

-- Operator promotions. No self-service path exists by design.
UPDATE public.profiles SET role = 'merchant', phone = '+992 44 600 6000'
WHERE id = '22222222-2222-2222-2222-222222222222';
UPDATE public.profiles SET role = 'courier',  phone = '+992 93 100 1000'
WHERE id = '33333333-3333-3333-3333-333333333333';
UPDATE public.profiles SET phone = '+992 92 500 5000'
WHERE id = '11111111-1111-1111-1111-111111111111';

-- The restaurant. owner_id is stamped by restaurants_set_owner from auth.uid()
-- when a merchant creates one through the app; seeding has no JWT, so it is
-- supplied explicitly here.
INSERT INTO public.restaurants (
  id, name, description, cuisine_type, rating, delivery_time_min,
  delivery_fee, min_order_amount, address, latitude, longitude,
  max_concurrent_orders, is_accepting_orders, owner_id, restaurant_status)
VALUES (
  'aaaaaaaa-0000-0000-0000-000000000001',
  'Осиё', 'Таджикская и узбекская кухня', 'Таджикская', 4.7, 30,
  8.00, 20.00, 'Душанбе, проспект Рудаки 105', 38.5598, 68.7870,
  25, true, '22222222-2222-2222-2222-222222222222', 'active')
ON CONFLICT (id) DO NOTHING;

-- Open all day, every day, Asia/Dushanbe. The walk calls create_order at now(),
-- and CI runs at any hour: a 09:00-23:00 window here failed every run between
-- 18:00 and 04:00 UTC with restaurant_out_of_hours. Rows are kept (rather than
-- relying on "no row = always open") so restaurant_within_hours() still takes
-- its real branch.
INSERT INTO public.restaurant_hours (restaurant_id, day_of_week, opening_time, closing_time, is_closed)
SELECT 'aaaaaaaa-0000-0000-0000-000000000001', d, '00:00'::time, '23:59:59.999999'::time, false
FROM generate_series(0, 6) AS d
ON CONFLICT (restaurant_id, day_of_week) DO NOTHING;

INSERT INTO public.menu_categories (id, restaurant_id, name, sort_order)
VALUES ('bbbbbbbb-0000-0000-0000-000000000001',
        'aaaaaaaa-0000-0000-0000-000000000001', 'Основные блюда', 0)
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.menu_items (
  id, category_id, restaurant_id, name, description, price, is_available, sort_order, stock_count)
VALUES
  ('cccccccc-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001',
   'aaaaaaaa-0000-0000-0000-000000000001','Плов','Классический плов с бараниной', 35.00, true, 0, 40),
  ('cccccccc-0000-0000-0000-000000000002','bbbbbbbb-0000-0000-0000-000000000001',
   'aaaaaaaa-0000-0000-0000-000000000001','Шашлык','Шашлык из баранины', 28.00, true, 1, 30),
  ('cccccccc-0000-0000-0000-000000000003','bbbbbbbb-0000-0000-0000-000000000001',
   'aaaaaaaa-0000-0000-0000-000000000001','Лагман','Лагман по-таджикски', 25.00, true, 2, NULL)
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.addresses (
  id, user_id, label, street, apartment, city, latitude, longitude, is_default, default_delivery_mode)
VALUES ('dddddddd-0000-0000-0000-000000000001',
        '11111111-1111-1111-1111-111111111111',
        'Дом', 'улица Рудаки 42', 'кв. 12', 'Душанбе', 38.5760, 68.7864, true, 'hand_to_me')
ON CONFLICT (id) DO NOTHING;

-- The courier is online and near the restaurant.
INSERT INTO public.courier_locations (
  courier_id, latitude, longitude, speed, is_online, last_heartbeat_at, last_moved_at)
VALUES ('33333333-3333-3333-3333-333333333333', 38.5610, 68.7880, 6.0, true, now(), now())
ON CONFLICT (courier_id) DO UPDATE
  SET is_online = true, last_heartbeat_at = now(), last_moved_at = now();

COMMIT;
