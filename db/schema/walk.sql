-- walk.sql — one order from create_order to delivered, plus the refusals.
--
-- Every step runs as `SET ROLE authenticated` with a JWT claim set, so table
-- grants and RLS both apply. Run as a superuser and the walk proves nothing:
-- superusers bypass RLS, so the interesting half — what the apps are REFUSED —
-- would silently pass.
--
-- Each statement is its own transaction (no BEGIN), which is how PostgREST
-- issues them. That matters: `ravon_set_actor` uses a transaction-local GUC, so
-- a single wrapping transaction would let one RPC's actor leak into the next
-- statement and mask the "status change outside a transition RPC" check.
--
--   psql -v ON_ERROR_STOP=0 -f db/schema/walk.sql

\set QUIET on
\pset pager off
\set CONSUMER '11111111-1111-1111-1111-111111111111'
\set MERCHANT '22222222-2222-2222-2222-222222222222'
\set COURIER  '33333333-3333-3333-3333-333333333333'
\set QUIET off

\echo ''
\echo '════════════════════════════════════════════════════════════'
\echo ' STEP 0 — become the consumer'
\echo '════════════════════════════════════════════════════════════'
RESET ROLE;
SELECT set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111"}', false);
SET ROLE authenticated;
SELECT current_user, auth.uid() AS acting_as;

\echo ''
\echo '── consumer sees the restaurant feed (RLS: active only) ──'
SELECT name, cuisine_type, rating, delivery_fee, min_order_amount FROM restaurants;

\echo ''
\echo '── validate_cart: 1 plov + 1 lagman = 60.00, min is 20.00 ──'
SELECT jsonb_pretty(validate_cart(
  'aaaaaaaa-0000-0000-0000-000000000001',
  '[{"menu_item_id":"cccccccc-0000-0000-0000-000000000001","quantity":1},
    {"menu_item_id":"cccccccc-0000-0000-0000-000000000003","quantity":1}]'::jsonb
)) AS cart;

\echo ''
\echo '════════════════════════════════════════════════════════════'
\echo ' STEP 1 — create_order'
\echo '════════════════════════════════════════════════════════════'
CREATE TEMP TABLE IF NOT EXISTS walk(order_id uuid);
DELETE FROM walk;
INSERT INTO walk SELECT create_order(
  'aaaaaaaa-0000-0000-0000-000000000001',
  'dddddddd-0000-0000-0000-000000000001',
  '[{"menu_item_id":"cccccccc-0000-0000-0000-000000000001","quantity":1},
    {"menu_item_id":"cccccccc-0000-0000-0000-000000000003","quantity":1}]'::jsonb,
  'Позвоните за 5 минут'
);
SELECT o.status, o.subtotal, o.delivery_fee, o.tip_amount,
       o.total AS total_generated, o.delivery_mode,
       o.delivery_address_snapshot->>'street' AS snap_street
FROM orders o JOIN walk w ON w.order_id = o.id;

\echo ''
\echo '── subtotal 60 + fee 8 = total 68, computed by the DB not the client ──'
\echo '── stock decremented (plov 40 -> 39; lagman has no stock tracking) ──'
SELECT name, stock_count FROM menu_items ORDER BY sort_order;

\echo ''
\echo '── order_status_history was appended by trigger, not by any RPC ──'
SELECT h.status, h.notes AS via_rpc FROM order_status_history h JOIN walk w ON w.order_id = h.order_id;

\echo ''
\echo '════════════════════════════════════════════════════════════'
\echo ' REFUSALS — what the consumer CANNOT do'
\echo '════════════════════════════════════════════════════════════'
\echo ''
\echo '── S4/T1: zero out the total (was: PATCH with {"total":0} succeeded) ──'
UPDATE orders SET subtotal = 0, delivery_fee = 0 WHERE id = (SELECT order_id FROM walk);

\echo ''
\echo '── R7: even the owner cannot write the generated total ──'
RESET ROLE;
UPDATE orders SET total = 0 WHERE id = (SELECT order_id FROM walk);
SELECT set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111"}', false);
SET ROLE authenticated;

\echo ''
\echo '── S1: self-promote to merchant ──'
UPDATE profiles SET role = 'merchant' WHERE id = :'CONSUMER';

\echo ''
\echo '── N7: snapshot someone else''s address into my order ──'
SELECT create_order('aaaaaaaa-0000-0000-0000-000000000001',
  '00000000-0000-0000-0000-0000000000ff',
  '[{"menu_item_id":"cccccccc-0000-0000-0000-000000000001","quantity":1}]'::jsonb);

\echo ''
\echo '── N8: negative quantity to clear the min-order gate cheaply ──'
SELECT create_order('aaaaaaaa-0000-0000-0000-000000000001',
  'dddddddd-0000-0000-0000-000000000001',
  '[{"menu_item_id":"cccccccc-0000-0000-0000-000000000001","quantity":10},
    {"menu_item_id":"cccccccc-0000-0000-0000-000000000003","quantity":-9}]'::jsonb);

\echo ''
\echo '── N4/N3: drive the marketplace batch state machine ──'
SELECT run_courier_escalation_ladder();

\echo ''
\echo '════════════════════════════════════════════════════════════'
\echo ' STEP 2 — merchant accepts, prepares, marks ready'
\echo '════════════════════════════════════════════════════════════'
RESET ROLE;
SELECT set_config('request.jwt.claims', '{"sub":"22222222-2222-2222-2222-222222222222"}', false);
SET ROLE authenticated;

\echo '── the merchant can see the order (RLS: owns the restaurant) ──'
SELECT status, subtotal, total, verification_code AS pickup_code
FROM orders WHERE id = (SELECT order_id FROM walk);

\echo ''
\echo '── merchant_accept_order (new RPC #1) ──'
SELECT merchant_accept_order((SELECT order_id FROM walk), 20);
SELECT status, accepted_at IS NOT NULL AS stamped, estimated_prep_time
FROM orders WHERE id = (SELECT order_id FROM walk);

\echo ''
\echo '── merchant_start_preparing (new RPC #2) ──'
SELECT merchant_start_preparing((SELECT order_id FROM walk));
SELECT status FROM orders WHERE id = (SELECT order_id FROM walk);

\echo ''
\echo '── merchant_mark_order_ready (new RPC #3) ──'
SELECT merchant_mark_order_ready((SELECT order_id FROM walk));
SELECT status FROM orders WHERE id = (SELECT order_id FROM walk);

\echo ''
\echo '── refused: merchant_start_preparing again (wrong from-state) ──'
SELECT merchant_start_preparing((SELECT order_id FROM walk));

\echo ''
\echo '── refused: merchant_cancel_order with a courier-fault reason ──'
SELECT merchant_cancel_order((SELECT order_id FROM walk), 'COURIER_NON_RESPONSIVE');

\echo ''
\echo '── refused: direct PATCH of status, bypassing the RPC ──'
UPDATE orders SET status = 'delivered' WHERE id = (SELECT order_id FROM walk);

\echo ''
\echo '════════════════════════════════════════════════════════════'
\echo ' STEP 3 — courier claims and runs the delivery'
\echo '════════════════════════════════════════════════════════════'
RESET ROLE;
SELECT set_config('request.jwt.claims', '{"sub":"33333333-3333-3333-3333-333333333333"}', false);
SET ROLE authenticated;

\echo '── offer feed: NO verification codes, NO customer address ──'
SELECT restaurant_name, total, distance_km
FROM fetch_available_orders(38.5610, 68.7880, 8);
\echo '   (the returned column list is the whole point: compare `SETOF orders`)'

\echo ''
\echo '── the raw orders table shows a courier nothing until they claim ──'
SELECT count(*) AS unassigned_orders_visible FROM orders;

\echo ''
\echo '── claim_order ──'
SELECT claim_order((SELECT order_id FROM walk)) AS claimed_by;
SELECT status, courier_id IS NOT NULL AS assigned, eta_minutes
FROM orders WHERE id = (SELECT order_id FROM walk);

\echo ''
\echo '── courier_arrived_restaurant ──'
SELECT courier_arrived_restaurant((SELECT order_id FROM walk));
SELECT status FROM orders WHERE id = (SELECT order_id FROM walk);

\echo ''
\echo '── N9: wrong pickup code, three times. Attempts are counted. ──'
SELECT courier_pickup_order((SELECT order_id FROM walk), '0000') AS try1;
SELECT courier_pickup_order((SELECT order_id FROM walk), '0001') AS try2;
SELECT courier_pickup_order((SELECT order_id FROM walk), '0002') AS try3;
SELECT pickup_code_attempts FROM orders WHERE id = (SELECT order_id FROM walk);

\echo ''
\echo '── the real code, read from the merchant''s screen ──'
SELECT courier_pickup_order((SELECT order_id FROM walk),
  (SELECT verification_code FROM orders WHERE id = (SELECT order_id FROM walk)));
SELECT status, picked_up_at IS NOT NULL AS stamped
FROM orders WHERE id = (SELECT order_id FROM walk);

\echo ''
\echo '── courier_start_delivering ──'
SELECT courier_start_delivering((SELECT order_id FROM walk));
SELECT status, eta_minutes FROM orders WHERE id = (SELECT order_id FROM walk);

\echo ''
\echo '── refused: deliver straight from `delivering` (migration 13 allowed'
\echo '   this; OrderLifecycle.swift does not declare the edge) ──'
SELECT courier_deliver_order((SELECT order_id FROM walk),
  (SELECT delivery_verification_code FROM orders WHERE id = (SELECT order_id FROM walk)));

\echo ''
\echo '── courier_arrived_at_customer ──'
SELECT courier_arrived_at_customer((SELECT order_id FROM walk));
SELECT status FROM orders WHERE id = (SELECT order_id FROM walk);

\echo ''
\echo '── courier_deliver_order with the consumer''s code ──'
SELECT courier_deliver_order((SELECT order_id FROM walk),
  (SELECT delivery_verification_code FROM orders WHERE id = (SELECT order_id FROM walk)));
SELECT status, delivered_at IS NOT NULL AS stamped
FROM orders WHERE id = (SELECT order_id FROM walk);

\echo ''
\echo '── the courier was paid, by the RPC, with no tier override in existence ──'
SELECT earning_type, tier_pct, delivery_fee, tip_amount, total_earned
FROM courier_earnings WHERE order_id = (SELECT order_id FROM walk);

\echo ''
\echo '════════════════════════════════════════════════════════════'
\echo ' STEP 4 — consumer tips after delivery'
\echo '════════════════════════════════════════════════════════════'
RESET ROLE;
SELECT set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111"}', false);
SET ROLE authenticated;
SELECT add_tip((SELECT order_id FROM walk), 12.00);

\echo '── total follows the tip automatically: it is a generated column ──'
SELECT subtotal, delivery_fee, tip_amount, total
FROM orders WHERE id = (SELECT order_id FROM walk);
SELECT total_earned FROM courier_earnings WHERE order_id = (SELECT order_id FROM walk);

\echo ''
\echo '════════════════════════════════════════════════════════════'
\echo ' FINAL — the full audit trail, appended by trigger'
\echo '════════════════════════════════════════════════════════════'
SELECT h.status, h.notes AS via_rpc,
       (h.changed_by IS NOT NULL) AS had_jwt
FROM order_status_history h
WHERE h.order_id = (SELECT order_id FROM walk)
ORDER BY h.created_at;

RESET ROLE;
SELECT set_config('request.jwt.claims', '', false);
