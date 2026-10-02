-- 12_grants.sql — the grant baseline. Applied LAST, after every object exists.
--
-- ORDERING, THE HARD WAY. This file was originally numbered 11 and applied
-- before the policies, following security-by-construction.md's advice to put
-- the baseline "in the first schema file". That is wrong, and invariants.sql
-- caught it: the two RLS helper functions created afterwards in 11_rls.sql came
-- out with `proacl = NULL`, which in Postgres means the built-in default —
-- EXECUTE TO PUBLIC — so `anon` could execute two SECURITY DEFINER functions.
--
-- The `ALTER DEFAULT PRIVILEGES ... REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC`
-- below does NOT prevent this, and it is worth knowing why: `pg_default_acl` is
-- empty after it runs. REVOKE of a default that was never explicitly GRANTed
-- records no deviation, so it is a no-op against the built-in default. Only an
-- explicit REVOKE against an existing object writes a non-NULL `proacl` that
-- excludes PUBLIC.
--
-- Which is a live, self-inflicted instance of exactly the finding this schema
-- was written to eliminate — "omitting a GRANT does not deny access" — and it
-- was caught by an assertion rather than by review. That is the whole argument
-- for the assertion.
--
-- This file, not 12_rls.sql, is where the nine findings across the two security
-- reports actually die. The reports' own prescription ("no client write policies
-- on orders") names the wrong primitive: a policy is only ever CONSULTED if the
-- table-level GRANT exists, so dropping policies leaves the grant in place and
-- the next CREATE POLICY re-opens the hole. The load-bearing primitive is the
-- MISSING GRANT.
--
-- The same mistake in the other direction ran through migrations 01-19: they
-- contain 30-odd `GRANT EXECUTE ... TO authenticated` lines and ZERO REVOKEs.
-- Postgres grants EXECUTE to PUBLIC on every newly created function, and
-- Supabase's bootstrap additionally runs
--   ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON FUNCTIONS TO anon, authenticated;
-- so those GRANT lines were decorative — they granted a privilege the role
-- already had and restricted nothing. Whether that default was in effect in the
-- deleted project is unrecoverable, which is exactly why this has to be a
-- build-time baseline rather than an audit.

-- ===========================================================================
-- 1. Deny by default.
-- ===========================================================================
REVOKE ALL ON ALL TABLES    IN SCHEMA public FROM anon, authenticated;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM anon, authenticated;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC, anon, authenticated;

-- Future objects created by this role start closed too. (Scoped to this role's
-- creations, which is why invariants.sql re-checks the live state rather than
-- trusting this line.)
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC, anon, authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  REVOKE ALL ON TABLES FROM anon, authenticated;

-- R6/N11: with CREATE on `public`, a client can define a function or operator
-- that an unqualified reference inside a SECURITY DEFINER function resolves to,
-- executing attacker code as the function owner. Every definer function in this
-- schema uses `SET search_path = ''` with qualified names, so the hijack has
-- nowhere to land — and this revoke removes the ability to try.
REVOKE CREATE ON SCHEMA public FROM PUBLIC, anon, authenticated;
GRANT  USAGE  ON SCHEMA public TO   anon, authenticated;

-- ===========================================================================
-- 2. anon gets nothing.
--
-- Deliberate, and a change from the deleted project, which granted anon SELECT
-- on `restaurants_orderable` and EXECUTE on three definer functions (03:79,
-- :152-154) plus — per S3, at confidence 10/10 — three more that leaked live
-- courier GPS, consumer addresses and verification codes.
--
-- The anon key is not a secret. It is compiled into three App Store binaries,
-- so rotating it costs three releases and buys nothing, and every object
-- reachable with it must be safe against direct curl with no app involved. The
-- cheapest way to make that true is for it to reach nothing: all three apps
-- authenticate before they read anything, so nothing is lost today.
--
-- If browse-before-signup is ever wanted, it is an explicit, reviewed addition
-- of SELECT on `restaurants`/`menu_items` — not a default.
-- ===========================================================================

-- ===========================================================================
-- 3. authenticated — reads.
-- ===========================================================================
GRANT SELECT ON
  public.profiles, public.restaurants, public.restaurant_hours,
  public.menu_categories, public.menu_items,
  public.modifier_groups, public.modifier_options, public.menu_item_modifier_groups,
  public.addresses, public.orders, public.order_items, public.order_status_history,
  public.courier_locations, public.courier_earnings, public.chat_messages,
  public.courier_cancellation_log, public.order_transitions,
  public.restaurants_orderable
TO authenticated;

-- ===========================================================================
-- 4. authenticated — writes, per table, per column where it matters.
-- ===========================================================================

-- profiles: no INSERT (handle_new_user owns creation), and crucially no
-- UPDATE(role). R1. This single omitted column is what makes S1 unexpressible:
-- there is no grant for a policy to qualify, so `PATCH /profiles {"role":...}`
-- fails at the privilege layer before RLS or any trigger is consulted.
GRANT UPDATE (full_name, phone, avatar_url) ON public.profiles TO authenticated;

-- restaurants: owner_id is absent (ownership cannot be reassigned) and so is
-- `rating` — a merchant editing its own rating is fraud, and the original had
-- no column restriction at all. is_accepting_orders/accepting_orders_until are
-- absent because they go through set_accepting_orders(), the one RPC in the
-- corpus that always had a proper ownership check.
GRANT INSERT ON public.restaurants TO authenticated;
GRANT UPDATE (
  name, description, image_url, cuisine_type, address, latitude, longitude,
  opening_time, closing_time, delivery_fee, min_order_amount, delivery_time_min,
  max_concurrent_orders, restaurant_status
) ON public.restaurants TO authenticated;

GRANT INSERT, UPDATE, DELETE ON public.restaurant_hours          TO authenticated;
GRANT INSERT, UPDATE, DELETE ON public.menu_categories           TO authenticated;
GRANT INSERT, UPDATE, DELETE ON public.menu_items                TO authenticated;
GRANT INSERT, UPDATE, DELETE ON public.modifier_groups           TO authenticated;
GRANT INSERT, UPDATE, DELETE ON public.modifier_options          TO authenticated;
GRANT INSERT, UPDATE, DELETE ON public.menu_item_modifier_groups TO authenticated;
GRANT INSERT, UPDATE, DELETE ON public.addresses                 TO authenticated;

-- courier_locations: the courier app upserts its own row directly
-- (SupabaseService+Courier.swift:206, :249) and PATCHes is_online /
-- current_order_id (:259, :348), so the grant has to exist. Columns are enumerated so a courier
-- cannot write ghost_strikes or strikes_reset_at — the fields the escalation
-- ladder uses to decide whether to suspend them.
GRANT INSERT ON public.courier_locations TO authenticated;
GRANT UPDATE (latitude, longitude, heading, speed, accuracy_meters,
              is_online, current_order_id, last_updated)
  ON public.courier_locations TO authenticated;

-- chat_messages: INSERT plus UPDATE on read_at ONLY. This is the N5 fix.
-- The old policy was named `chat_messages_mark_read` and its comment promised
-- "only ... set read_at", but USING/WITH CHECK asserted only `sender_id <>
-- auth.uid()` plus order participation, and RLS has no column dimension — so a
-- courier could rewrite the consumer's message `body`, which is the dispute
-- evidence, or forge `sender_role`. A column-level grant is the primitive RLS
-- lacks, and it keeps markMessagesAsRead (SupabaseService+Chat.swift:36)
-- working unchanged.
GRANT INSERT ON public.chat_messages TO authenticated;
GRANT UPDATE (read_at) ON public.chat_messages TO authenticated;

-- ===========================================================================
-- 5. NOT granted, stated explicitly because absence is the mechanism.
--
--   orders                 — no INSERT/UPDATE/DELETE. R2. Kills S4, S5, T1, T2.
--                            Every transition is a SECURITY DEFINER RPC; there
--                            is no second path. The four merchant operations
--                            that used to PATCH this table directly
--                            (SupabaseService+Orders.swift:125-179) are now
--                            06_merchant_rpcs.sql, and `assignCourier` (:192)
--                            is gone entirely — it set an arbitrary courier_id
--                            and worked only for the actor whose policy had no
--                            ownership check.
--   order_items            — no writes. Created by create_order only.
--   order_status_history   — no writes. Append-only audit trail; trigger-fed.
--   courier_earnings       — no writes. Money.
--   courier_cancellation_log — no writes. It is the cooldown evidence; a courier
--                            who could DELETE from it would have no cooldown.
--   order_transitions      — read-only. It is the contract.
--   DELETE on profiles/restaurants/menu_items — soft delete only.
-- ===========================================================================

-- ===========================================================================
-- 6. Function EXECUTE — an allowlist, mirrored in db/schema/client-executable.allow
--    so invariants.sql can assert that the live grants and the reviewed list agree.
--
-- Everything not listed stays revoked, including every `ravon_*` helper, every
-- trigger function, and the three sweeps.
-- ===========================================================================

-- RLS visibility helpers. These are called FROM policy expressions, and a
-- policy is evaluated as the querying role — so without EXECUTE here every
-- query on order_items, chat_messages and courier_locations fails with
-- "permission denied for function ravon_is_order_participant". The walk caught
-- this too. They are SECURITY DEFINER but take no caller-supplied identity:
-- each reads auth.uid() itself, so they answer only about the caller. Not
-- granted to anon.
GRANT EXECUTE ON FUNCTION public.ravon_owns_restaurant(uuid)          TO authenticated;
GRANT EXECUTE ON FUNCTION public.ravon_is_order_participant(uuid)     TO authenticated;
GRANT EXECUTE ON FUNCTION public.ravon_shares_order_with(uuid)        TO authenticated;
GRANT EXECUTE ON FUNCTION public.ravon_has_order_at_restaurant(uuid)  TO authenticated;
GRANT EXECUTE ON FUNCTION public.ravon_can_track_courier(uuid)        TO authenticated;
GRANT EXECUTE ON FUNCTION public.ravon_order_chat_open(uuid)          TO authenticated;

-- Orderability. These three are SECURITY INVOKER (04_orderability.sql), so they
-- are not an RLS bypass and need no exemption.
GRANT EXECUTE ON FUNCTION public.restaurant_within_hours(uuid, timestamptz)       TO authenticated;
GRANT EXECUTE ON FUNCTION public.restaurant_is_orderable(uuid, timestamptz)       TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_restaurant_orderability(uuid, timestamptz)   TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_accepting_orders(uuid, boolean, timestamptz) TO authenticated;

-- Order creation.
GRANT EXECUTE ON FUNCTION public.validate_cart(uuid, jsonb, timestamptz)          TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_order(uuid, uuid, jsonb, text, timestamptz) TO authenticated;

-- Merchant transitions — the five that did not exist.
GRANT EXECUTE ON FUNCTION public.merchant_accept_order(uuid, int)       TO authenticated;
GRANT EXECUTE ON FUNCTION public.merchant_start_preparing(uuid)         TO authenticated;
GRANT EXECUTE ON FUNCTION public.merchant_mark_order_ready(uuid)        TO authenticated;
GRANT EXECUTE ON FUNCTION public.merchant_reject_order(uuid, text)      TO authenticated;
GRANT EXECUTE ON FUNCTION public.merchant_cancel_order(uuid, text)      TO authenticated;

-- Courier transitions.
GRANT EXECUTE ON FUNCTION public.claim_order(uuid)                              TO authenticated;
GRANT EXECUTE ON FUNCTION public.courier_arrived_restaurant(uuid)               TO authenticated;
GRANT EXECUTE ON FUNCTION public.courier_pickup_order(uuid, text)               TO authenticated;
GRANT EXECUTE ON FUNCTION public.courier_start_delivering(uuid)                 TO authenticated;
GRANT EXECUTE ON FUNCTION public.courier_arrived_at_customer(uuid)              TO authenticated;
GRANT EXECUTE ON FUNCTION public.courier_deliver_order(uuid, text, text)        TO authenticated;
GRANT EXECUTE ON FUNCTION public.cancel_order_by_courier(uuid, text)            TO authenticated;

-- Consumer.
GRANT EXECUTE ON FUNCTION public.cancel_order_by_consumer(uuid, text)  TO authenticated;
GRANT EXECUTE ON FUNCTION public.add_tip(uuid, numeric)                TO authenticated;

-- Courier telemetry and reports.
GRANT EXECUTE ON FUNCTION public.update_courier_heartbeat(double precision, double precision, double precision, double precision, double precision) TO authenticated;
GRANT EXECUTE ON FUNCTION public.courier_explain_delay(uuid, text, text)            TO authenticated;
GRANT EXECUTE ON FUNCTION public.report_problem_post_pickup(uuid, text, text)       TO authenticated;
GRANT EXECUTE ON FUNCTION public.courier_report_customer_no_show(uuid)              TO authenticated;
GRANT EXECUTE ON FUNCTION public.courier_report_restaurant_delay(uuid, int)         TO authenticated;

-- Feeds.
GRANT EXECUTE ON FUNCTION public.fetch_available_orders(double precision, double precision, double precision) TO authenticated;
GRANT EXECUTE ON FUNCTION public.find_nearby_couriers(double precision, double precision, double precision)   TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_merchant_stats(uuid)                                                     TO authenticated;

-- Deliberately NOT granted, each one a finding:
--   activate_scheduled_orders()        N3 — anyone could force-activate or
--                                      cancel another user's scheduled order.
--   mark_no_show_deliveries()          N4 — whole-table sweep.
--   run_courier_escalation_ladder()    N4 — whole-table sweep that writes
--                                      profiles.is_suspended_until.
--   compute_eta_minutes(uuid)          leaked "a courier is assigned" plus a
--                                      distance for any order id — a coarse
--                                      locator. No Swift call site needs it;
--                                      it is used internally by definer
--                                      functions, which run as owner.
--   reassign_ghosted_order(uuid)       N1 — DELETED, not merely revoked. It was
--                                      SECURITY DEFINER, granted to
--                                      `authenticated`, took only p_order_id and
--                                      contained no auth.uid() reference at all:
--                                      any free account could strip any active
--                                      order's courier, mint an earning against
--                                      them, and after three calls push the order
--                                      to cancelled_by_system. A one-call-per-order
--                                      denial of service against the whole
--                                      marketplace. Its legitimate job — requeueing
--                                      a ghosted order — belongs to the escalation
--                                      ladder, which is where it now lives.
--   insert_courier_earning_for_cancel  N2 — DELETED. Its p_tier_override int had
--                                      no bound, so 1000000 minted a
--                                      million-fold payout, and its
--                                      ON CONFLICT DO UPDATE overwrote existing
--                                      earnings cleanly. Replaced by
--                                      ravon_record_cancel_earning, which has no
--                                      override parameter, reads the fee from the
--                                      order, and DO NOTHINGs on conflict.
