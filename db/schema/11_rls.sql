-- 12_rls.sql — row-level security. Apply AFTER 11_grants.sql.
--
-- RLS here is DESIGNED, NOT RECONSTRUCTED, and that distinction is the biggest
-- unrecoverable gap in the whole rebuild. Migrations 01-19 create policies on
-- exactly four tables (menu_items, menu_categories, courier_cancellation_log,
-- chat_messages). For the other twelve — orders, profiles, restaurants,
-- addresses, courier_locations, courier_earnings, order_items,
-- order_status_history and the three modifier tables — no policy text exists in
-- any source, and none can be recovered: a Swift call site records what the
-- client ISSUED, never what the server PERMITTED. The security reports quote
-- fragments of a handful; those fragments are now the only record that they
-- ever existed.
--
-- So nothing below is a restoration. Each policy is a decision, and the shape of
-- the decision is: RLS governs READS, and for the five transactional tables it
-- is pure defence-in-depth because 11_grants.sql already withheld every write
-- privilege. A future CREATE POLICY on `orders` cannot re-open anything,
-- because there is no grant for it to qualify.
--
-- The good news the reports' authors could not have known: the over-broad
-- `orders` UPDATE policies behind S4, S5, T1 and T2 do not need removing. They
-- died with the project. The goal "no client write policies on orders" is free —
-- there is nothing to remove, only something to not create.

-- ---------------------------------------------------------------------------
-- Visibility helpers. EVERY cross-table test in this file goes through one of
-- these, and that is not a style preference — it is the fix for a bug the
-- end-to-end walk caught in the first draft of this file.
--
-- The first version wrote the ownership tests inline, so `restaurants`' policy
-- contained `EXISTS (SELECT ... FROM orders)` while `orders`' policy contained
-- `EXISTS (SELECT ... FROM restaurants)`. Each policy triggered the other and
-- Postgres refused every query on both tables with
--     ERROR: infinite recursion detected in policy for relation "orders"
-- which then cascaded to `menu_items`, `menu_categories` and the modifier
-- tables, because their ownership tests read `restaurants` too. An RLS policy
-- that reads another RLS-protected table is a latent cycle.
--
-- SECURITY DEFINER breaks it: the helper runs as the schema owner, so the inner
-- read does not re-enter any policy. None of these takes a caller-supplied
-- identity — each reads auth.uid() itself — so none can be used to ask a
-- question about somebody else.
-- ---------------------------------------------------------------------------

-- Does the caller own this restaurant? R9 in query form: the test is a foreign
-- key comparison, not a `profiles.role = 'merchant'` check, which is what made
-- S2 an escalation across every restaurant in the marketplace.
CREATE OR REPLACE FUNCTION public.ravon_owns_restaurant(p_restaurant_id uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT EXISTS (SELECT 1 FROM public.restaurants
                 WHERE id = p_restaurant_id AND owner_id = auth.uid());
$$;

CREATE OR REPLACE FUNCTION public.ravon_is_order_participant(p_order_id uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.orders o
    LEFT JOIN public.restaurants r ON r.id = o.restaurant_id
    WHERE o.id = p_order_id
      AND (o.user_id = auth.uid() OR o.courier_id = auth.uid() OR r.owner_id = auth.uid())
  );
$$;

-- Do the caller and this user share any order? Gates counterparty profile reads.
CREATE OR REPLACE FUNCTION public.ravon_shares_order_with(p_user_id uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.orders o
    LEFT JOIN public.restaurants r ON r.id = o.restaurant_id
    WHERE (o.user_id = auth.uid() OR o.courier_id = auth.uid() OR r.owner_id = auth.uid())
      AND (o.user_id = p_user_id OR o.courier_id = p_user_id OR r.owner_id = p_user_id)
  );
$$;

-- Has the caller ever ordered from this restaurant? Lets a past order render
-- even after the restaurant is paused or closed.
CREATE OR REPLACE FUNCTION public.ravon_has_order_at_restaurant(p_restaurant_id uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT EXISTS (SELECT 1 FROM public.orders
                 WHERE restaurant_id = p_restaurant_id
                   AND (user_id = auth.uid() OR courier_id = auth.uid()));
$$;

-- May the caller see this courier's live position? Own row, or an order of
-- theirs is currently in this courier's hands. Not "any courier", which is what
-- find_nearby_couriers used to hand to anyone holding the anon key.
CREATE OR REPLACE FUNCTION public.ravon_can_track_courier(p_courier_id uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT p_courier_id = auth.uid() OR EXISTS (
    SELECT 1 FROM public.orders o
    LEFT JOIN public.restaurants r ON r.id = o.restaurant_id
    WHERE o.courier_id = p_courier_id
      AND o.status IN ('assigned','courier_arrived_restaurant','picked_up',
                       'delivering','courier_arrived_customer')
      AND (o.user_id = auth.uid() OR r.owner_id = auth.uid())
  );
$$;

-- Is this order in a state where chat is open to its participants?
CREATE OR REPLACE FUNCTION public.ravon_order_chat_open(p_order_id uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.orders o
    WHERE o.id = p_order_id
      AND (o.status IN ('assigned','courier_arrived_restaurant','picked_up',
                        'delivering','courier_arrived_customer')
        -- 5-minute grace after delivery so a hand-off dispute can be raised.
        OR (o.status = 'delivered' AND o.delivered_at > now() - interval '5 minutes'))
  );
$$;

ALTER TABLE public.profiles                  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.restaurants               ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.restaurant_hours          ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.menu_categories           ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.menu_items                ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.modifier_groups           ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.modifier_options          ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.menu_item_modifier_groups ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.addresses                 ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.orders                    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.order_items               ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.order_status_history      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.courier_locations         ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.courier_earnings          ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.chat_messages             ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.courier_cancellation_log  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.order_transitions         ENABLE ROW LEVEL SECURITY;
-- Stock ledger and kitchen slots: RLS on and NO policy, so no client role can
-- read or write them at all. Only the SECURITY DEFINER checkout, activation and
-- cancel paths touch them.
ALTER TABLE public.inventory_movements       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.kitchen_slots             ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.kitchen_slot_holds        ENABLE ROW LEVEL SECURITY;

-- ===========================================================================
-- profiles
-- ===========================================================================
DROP POLICY IF EXISTS profiles_select ON public.profiles;
CREATE POLICY profiles_select ON public.profiles
  FOR SELECT TO authenticated
  -- Own row, or a counterparty on a shared order: the merchant needs the
  -- consumer's name on the ticket, the consumer needs the courier's. Narrower
  -- than "all profiles", which is the shape that makes a user directory out of
  -- a delivery app.
  USING (id = auth.uid() OR public.ravon_shares_order_with(id));

DROP POLICY IF EXISTS profiles_update_self ON public.profiles;
CREATE POLICY profiles_update_self ON public.profiles
  FOR UPDATE TO authenticated
  USING (id = auth.uid())
  WITH CHECK (id = auth.uid());
-- Note: `role` is not reachable through this policy, because the policy is not
-- what protects it — the missing UPDATE(role) column grant is (R1).

-- ===========================================================================
-- restaurants
-- ===========================================================================
DROP POLICY IF EXISTS restaurants_select ON public.restaurants;
CREATE POLICY restaurants_select ON public.restaurants
  FOR SELECT TO authenticated
  USING (
    restaurant_status = 'active'
    OR owner_id = auth.uid()
    -- A consumer with a past order at a since-paused restaurant must still be
    -- able to render that order: fetchOrders embeds `restaurants(*)`
    -- (SupabaseService+Orders.swift:9) and an invisible restaurant makes the embed
    -- NULL, which Order decodes as no restaurant and the order card renders blank.
    OR public.ravon_has_order_at_restaurant(id)
  );

DROP POLICY IF EXISTS restaurants_insert_own ON public.restaurants;
CREATE POLICY restaurants_insert_own ON public.restaurants
  FOR INSERT TO authenticated
  -- owner_id is stamped by restaurants_set_owner before this is evaluated.
  WITH CHECK (owner_id = auth.uid());

DROP POLICY IF EXISTS restaurants_update_own ON public.restaurants;
CREATE POLICY restaurants_update_own ON public.restaurants
  FOR UPDATE TO authenticated
  USING (owner_id = auth.uid())
  WITH CHECK (owner_id = auth.uid());

-- ===========================================================================
-- restaurant_hours — readable for everyone (it is the open/closed schedule a
-- consumer has to see); writable only by the owner.
-- ===========================================================================
DROP POLICY IF EXISTS restaurant_hours_select ON public.restaurant_hours;
CREATE POLICY restaurant_hours_select ON public.restaurant_hours
  FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS restaurant_hours_write_own ON public.restaurant_hours;
CREATE POLICY restaurant_hours_write_own ON public.restaurant_hours
  FOR ALL TO authenticated
  USING (public.ravon_owns_restaurant(restaurant_hours.restaurant_id))
  WITH CHECK (public.ravon_owns_restaurant(restaurant_hours.restaurant_id));

-- ===========================================================================
-- menu_categories / menu_items — the two tables whose original policies DO
-- survive (01:21-60). Shape preserved: consumers see live rows, the owner sees
-- everything including soft-deleted. The ownership term is `owner_id =
-- auth.uid()` rather than the bare `profiles.role = 'merchant'` that made S2 a
-- cross-tenant escalation.
-- ===========================================================================
DROP POLICY IF EXISTS menu_categories_select ON public.menu_categories;
CREATE POLICY menu_categories_select ON public.menu_categories
  FOR SELECT TO authenticated
  USING (
    deleted_at IS NULL
    OR public.ravon_owns_restaurant(menu_categories.restaurant_id)
  );

DROP POLICY IF EXISTS menu_categories_write_own ON public.menu_categories;
CREATE POLICY menu_categories_write_own ON public.menu_categories
  FOR ALL TO authenticated
  USING (public.ravon_owns_restaurant(menu_categories.restaurant_id))
  WITH CHECK (public.ravon_owns_restaurant(menu_categories.restaurant_id));

DROP POLICY IF EXISTS menu_items_select ON public.menu_items;
CREATE POLICY menu_items_select ON public.menu_items
  FOR SELECT TO authenticated
  USING (
    deleted_at IS NULL
    OR public.ravon_owns_restaurant(menu_items.restaurant_id)
  );

DROP POLICY IF EXISTS menu_items_write_own ON public.menu_items;
CREATE POLICY menu_items_write_own ON public.menu_items
  FOR ALL TO authenticated
  USING (public.ravon_owns_restaurant(menu_items.restaurant_id))
  WITH CHECK (public.ravon_owns_restaurant(menu_items.restaurant_id));

-- ===========================================================================
-- modifiers
-- ===========================================================================
DROP POLICY IF EXISTS modifier_groups_select ON public.modifier_groups;
CREATE POLICY modifier_groups_select ON public.modifier_groups
  FOR SELECT TO authenticated USING (true);
DROP POLICY IF EXISTS modifier_groups_write_own ON public.modifier_groups;
CREATE POLICY modifier_groups_write_own ON public.modifier_groups
  FOR ALL TO authenticated
  USING (public.ravon_owns_restaurant(modifier_groups.restaurant_id))
  WITH CHECK (public.ravon_owns_restaurant(modifier_groups.restaurant_id));

DROP POLICY IF EXISTS modifier_options_select ON public.modifier_options;
CREATE POLICY modifier_options_select ON public.modifier_options
  FOR SELECT TO authenticated USING (true);
DROP POLICY IF EXISTS modifier_options_write_own ON public.modifier_options;
CREATE POLICY modifier_options_write_own ON public.modifier_options
  FOR ALL TO authenticated
  USING (public.ravon_owns_restaurant(
           (SELECT restaurant_id FROM public.modifier_groups WHERE id = modifier_options.group_id)))
  WITH CHECK (public.ravon_owns_restaurant(
           (SELECT restaurant_id FROM public.modifier_groups WHERE id = modifier_options.group_id)));

DROP POLICY IF EXISTS mimg_select ON public.menu_item_modifier_groups;
CREATE POLICY mimg_select ON public.menu_item_modifier_groups
  FOR SELECT TO authenticated USING (true);
DROP POLICY IF EXISTS mimg_write_own ON public.menu_item_modifier_groups;
CREATE POLICY mimg_write_own ON public.menu_item_modifier_groups
  FOR ALL TO authenticated
  USING (public.ravon_owns_restaurant(
           (SELECT restaurant_id FROM public.menu_items WHERE id = menu_item_modifier_groups.menu_item_id)))
  WITH CHECK (public.ravon_owns_restaurant(
           (SELECT restaurant_id FROM public.menu_items WHERE id = menu_item_modifier_groups.menu_item_id)));

-- ===========================================================================
-- addresses — strictly own. Note fetchAddresses (SupabaseService+Addresses.swift:8)
-- and markMessagesAsRead (SupabaseService+Chat.swift:36) both issue queries with
-- NO ownership predicate at all; they were relying entirely on a policy nobody
-- wrote down. These are those policies.
-- ===========================================================================
DROP POLICY IF EXISTS addresses_own ON public.addresses;
CREATE POLICY addresses_own ON public.addresses
  FOR ALL TO authenticated
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

-- ===========================================================================
-- orders — SELECT only. There is deliberately no INSERT, UPDATE or DELETE
-- policy, and no grant either, so the absence is enforced twice.
-- ===========================================================================
DROP POLICY IF EXISTS orders_select_participant ON public.orders;
CREATE POLICY orders_select_participant ON public.orders
  FOR SELECT TO authenticated
  USING (
    user_id = auth.uid()
    OR courier_id = auth.uid()
    OR public.ravon_owns_restaurant(restaurant_id)
  );
-- Consequence worth stating: an UNASSIGNED order is visible to no courier
-- through this table. The offer feed therefore MUST go through
-- fetch_available_orders(), which returns a safe projection. The legacy direct
-- query at SupabaseService+Courier.swift:291 — `.from("orders").select("*, restaurants(*)")`
-- filtered on a null courier — now correctly returns zero rows instead of
-- handing every courier both verification codes and the consumer's address.

-- ===========================================================================
-- order_items / order_status_history — visible with the parent order.
-- ===========================================================================
DROP POLICY IF EXISTS order_items_select ON public.order_items;
CREATE POLICY order_items_select ON public.order_items
  FOR SELECT TO authenticated
  USING (public.ravon_is_order_participant(order_id));

DROP POLICY IF EXISTS order_status_history_select ON public.order_status_history;
CREATE POLICY order_status_history_select ON public.order_status_history
  FOR SELECT TO authenticated
  USING (public.ravon_is_order_participant(order_id));

-- ===========================================================================
-- courier_locations
-- ===========================================================================
DROP POLICY IF EXISTS courier_locations_select ON public.courier_locations;
CREATE POLICY courier_locations_select ON public.courier_locations
  FOR SELECT TO authenticated
  USING (public.ravon_can_track_courier(courier_id));

DROP POLICY IF EXISTS courier_locations_upsert_self ON public.courier_locations;
CREATE POLICY courier_locations_upsert_self ON public.courier_locations
  FOR INSERT TO authenticated WITH CHECK (courier_id = auth.uid());
DROP POLICY IF EXISTS courier_locations_update_self ON public.courier_locations;
CREATE POLICY courier_locations_update_self ON public.courier_locations
  FOR UPDATE TO authenticated
  USING (courier_id = auth.uid()) WITH CHECK (courier_id = auth.uid());

-- ===========================================================================
-- courier_earnings / courier_cancellation_log — own rows, read only.
-- ===========================================================================
DROP POLICY IF EXISTS courier_earnings_select_self ON public.courier_earnings;
CREATE POLICY courier_earnings_select_self ON public.courier_earnings
  FOR SELECT TO authenticated USING (courier_id = auth.uid());

DROP POLICY IF EXISTS courier_cancel_log_self_select ON public.courier_cancellation_log;
CREATE POLICY courier_cancel_log_self_select ON public.courier_cancellation_log
  FOR SELECT TO authenticated USING (courier_id = auth.uid());

-- ===========================================================================
-- chat_messages — the one set of policies that survives (15:46-97), preserved
-- including the 5-minute post-delivery INSERT grace and the 30-day SELECT
-- window. The N5 hole in `chat_messages_mark_read` is closed by the column
-- grant in 11_grants.sql, not here — RLS cannot express it.
-- ===========================================================================
DROP POLICY IF EXISTS chat_messages_select ON public.chat_messages;
CREATE POLICY chat_messages_select ON public.chat_messages
  FOR SELECT TO authenticated
  USING (
    public.ravon_is_order_participant(order_id)
    AND created_at > now() - interval '30 days'
  );

DROP POLICY IF EXISTS chat_messages_insert ON public.chat_messages;
CREATE POLICY chat_messages_insert ON public.chat_messages
  FOR INSERT TO authenticated
  WITH CHECK (
    sender_id = auth.uid()
    AND public.ravon_is_order_participant(order_id)
    AND public.ravon_order_chat_open(order_id)
  );

DROP POLICY IF EXISTS chat_messages_mark_read ON public.chat_messages;
CREATE POLICY chat_messages_mark_read ON public.chat_messages
  FOR UPDATE TO authenticated
  -- Only messages NOT sent by self, which is what the name always claimed.
  USING (sender_id <> auth.uid() AND public.ravon_is_order_participant(order_id))
  WITH CHECK (sender_id <> auth.uid() AND public.ravon_is_order_participant(order_id));

-- ===========================================================================
-- order_transitions — the lifecycle contract is public to clients. Readable so
-- an app can render "what can happen next" from the server's copy instead of a
-- hand-rolled per-screen status array.
-- ===========================================================================
DROP POLICY IF EXISTS order_transitions_select ON public.order_transitions;
CREATE POLICY order_transitions_select ON public.order_transitions
  FOR SELECT TO authenticated USING (true);
