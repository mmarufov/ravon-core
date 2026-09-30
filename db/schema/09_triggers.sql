-- 09_triggers.sql — triggers, including the fix for the CRITICAL that survived
-- its own patch.

-- ===========================================================================
-- handle_new_user — profile creation, atomic with the auth row.
--
-- THE S1 FIX. Migration 18:26 read the role straight out of client-supplied
-- metadata:
--     COALESCE((NEW.raw_user_meta_data->>'role')::user_role, 'consumer')
-- and AuthService.signUp() supplied it (AuthService.swift:63-72). So
--     POST /auth/v1/signup {"data":{"role":"merchant"}}
-- with nothing but the anon key — no session, no app — provisioned the caller as
-- a merchant, and every merchant policy then applied. Migration 19 added a
-- BEFORE UPDATE trigger that closed the PATCH route, which is why the finding
-- was believed fixed; but signup is an INSERT, so 19 never touched this path. The
-- net effect of that PR was to relocate the escalation from "escalate after
-- signup" to "declare at signup," which is cheaper for the attacker.
--
-- The role is hardcoded. It is not read from metadata, not defaulted from it,
-- not consulted at all — `raw_user_meta_data` is referenced here only for
-- `full_name`, and invariants.sql asserts no function body in the database
-- mentions `role` alongside user metadata.
--
-- Consequence to own: there is now no self-service path to becoming a merchant
-- or courier. That is correct — those are privileged marketplace roles — but it
-- means promotion is an operator action until an approval flow exists. See the
-- plan's open questions.
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  INSERT INTO public.profiles (id, full_name, role, created_at, updated_at)
  VALUES (
    NEW.id,
    COALESCE(NEW.raw_user_meta_data->>'full_name', ''),
    -- Hardcoded. Never client input. R1.
    'consumer'::public.user_role,
    now(), now()
  )
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- ===========================================================================
-- profiles_block_role_change — defence in depth behind the missing grant.
--
-- The primary control is that no client role holds UPDATE(role) on `profiles`
-- (11_grants.sql). This trigger is the second line, and it fixes two things
-- about migration 19's version.
--
-- 1. It fired only `WHEN (auth.uid() = OLD.id)`. Any path permitting an update
--    to SOMEONE ELSE'S profile row skipped it entirely and could change `role`
--    freely — fail-open on exactly the cross-tenant shape that report-1 finding
--    2 established was already how the merchant policies were written. The
--    condition here is `auth.uid() IS NOT NULL`: any authenticated request,
--    own row or not.
--
-- 2. Its rationale was factually wrong. 19:9-11 claimed "RPCs running with
--    elevated privileges execute with auth.uid() = NULL". SECURITY DEFINER
--    changes `current_user`; it does NOT reset the `request.jwt.claims` GUC that
--    auth.uid() reads, so inside a definer RPC invoked by a user auth.uid() is
--    still that user. That error happened to fail safe, but it is the belief
--    that produces an unsafe design next time. The admin exemption here is
--    deliberate and correctly reasoned: auth.uid() IS NULL means there is no JWT
--    at all — a psql session, a migration, or pg_cron — not merely elevated
--    privilege.
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.profiles_block_role_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NEW.role IS DISTINCT FROM OLD.role THEN
    RAISE EXCEPTION 'role changes are not permitted'
      USING ERRCODE = '42501',
            DETAIL  = jsonb_build_object('reason','ROLE_CHANGE_FORBIDDEN')::text;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS profiles_block_role_change ON public.profiles;
CREATE TRIGGER profiles_block_role_change
  BEFORE UPDATE ON public.profiles
  FOR EACH ROW
  WHEN (auth.uid() IS NOT NULL)
  EXECUTE FUNCTION public.profiles_block_role_change();

-- ===========================================================================
-- Verification codes at order INSERT.
--
-- Migration 10's binding was unrecoverable: it replaced the function body and
-- said "update the existing INSERT trigger function", but no migration ever
-- issued CREATE TRIGGER for it — name, timing and table were gone. Re-declared
-- here as BEFORE INSERT ON orders, which is the only timing consistent with the
-- codes being present on the returned row.
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.generate_verification_code()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NEW.verification_code IS NULL THEN
    NEW.verification_code := public.ravon_gen_code();
  END IF;
  IF NEW.delivery_verification_code IS NULL THEN
    NEW.delivery_verification_code := public.ravon_gen_code();
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS orders_generate_codes ON public.orders;
CREATE TRIGGER orders_generate_codes
  BEFORE INSERT ON public.orders
  FOR EACH ROW EXECUTE FUNCTION public.generate_verification_code();

-- ===========================================================================
-- delivery_mode inherited from the address at INSERT (M 10:55-73).
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.sync_order_delivery_mode_from_address()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE v_default text;
BEGIN
  IF NEW.address_id IS NOT NULL THEN
    SELECT default_delivery_mode INTO v_default
    FROM public.addresses WHERE id = NEW.address_id;
    IF v_default IS NOT NULL THEN
      NEW.delivery_mode := v_default;
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS orders_sync_delivery_mode ON public.orders;
CREATE TRIGGER orders_sync_delivery_mode
  BEFORE INSERT ON public.orders
  FOR EACH ROW EXECUTE FUNCTION public.sync_order_delivery_mode_from_address();

-- ===========================================================================
-- order_status_history — the audit trail, appended by trigger only.
--
-- The table had ZERO SQL evidence in the corpus: none of the 13 transition RPCs
-- wrote to it, yet the consumer app reads it (SupabaseService.swift:293). Either
-- a dashboard-created trigger did this, or the history was always empty and the
-- screen always blank. Appending here rather than in each RPC means no
-- transition can forget, and because clients hold no INSERT grant on the table
-- the trail cannot be forged or back-dated.
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.orders_append_status_history()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF TG_OP = 'INSERT' OR NEW.status IS DISTINCT FROM OLD.status THEN
    INSERT INTO public.order_status_history(order_id, status, changed_by, notes)
    VALUES (
      NEW.id, NEW.status,
      -- NULL for system/cron transitions, which is the honest record.
      auth.uid(),
      nullif(current_setting('ravon.rpc', true), '')
    );
  END IF;
  RETURN NULL;   -- AFTER trigger
END;
$$;

DROP TRIGGER IF EXISTS orders_status_history ON public.orders;
CREATE TRIGGER orders_status_history
  AFTER INSERT OR UPDATE OF status ON public.orders
  FOR EACH ROW EXECUTE FUNCTION public.orders_append_status_history();

-- ===========================================================================
-- chat sender_role — denormalised so the UI can style system notices without a
-- join (M 15:23-38). Programmatic inserts force 'system' (M 17).
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.set_chat_sender_role()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE v_role public.user_role;
BEGIN
  IF auth.uid() IS NULL THEN
    NEW.sender_role := 'system';
  ELSE
    SELECT role INTO v_role FROM public.profiles WHERE id = NEW.sender_id;
    -- Always derived from the profile, never from the client payload:
    -- ChatMessageInsert does not carry sender_role, and a client that added it
    -- would be overwritten here rather than trusted.
    NEW.sender_role := COALESCE(v_role::text, 'system');
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS chat_messages_set_sender_role ON public.chat_messages;
CREATE TRIGGER chat_messages_set_sender_role
  BEFORE INSERT ON public.chat_messages
  FOR EACH ROW EXECUTE FUNCTION public.set_chat_sender_role();

-- ===========================================================================
-- updated_at maintenance. Swift decodes `orders.updated_at` and
-- `profiles.updated_at` as non-optional Date, and `.order("updated_at")` at
-- SupabaseService.swift:817 sorts the courier's active order on it.
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.ravon_touch_updated_at()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS profiles_touch      ON public.profiles;
CREATE TRIGGER profiles_touch      BEFORE UPDATE ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION public.ravon_touch_updated_at();
DROP TRIGGER IF EXISTS restaurants_touch   ON public.restaurants;
CREATE TRIGGER restaurants_touch   BEFORE UPDATE ON public.restaurants
  FOR EACH ROW EXECUTE FUNCTION public.ravon_touch_updated_at();
DROP TRIGGER IF EXISTS menu_items_touch    ON public.menu_items;
CREATE TRIGGER menu_items_touch    BEFORE UPDATE ON public.menu_items
  FOR EACH ROW EXECUTE FUNCTION public.ravon_touch_updated_at();

-- ===========================================================================
-- restaurants.owner_id is assigned by the server.
--
-- `RestaurantInsert` (Restaurant.swift:127-136) carries no owner_id, so with
-- owner_id NOT NULL the merchant app's createRestaurant would fail outright.
-- The fix is not to add it to the payload — a client-supplied owner is the S2
-- horizontal-escalation shape — but to stamp it from the verified identity.
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.restaurants_set_owner()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NEW.owner_id IS NULL THEN
    NEW.owner_id := auth.uid();
  END IF;
  IF NEW.owner_id IS NULL THEN
    RAISE EXCEPTION 'not_authenticated'
      USING ERRCODE='P0001', DETAIL=jsonb_build_object('reason','NOT_AUTHENTICATED')::text;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS restaurants_set_owner ON public.restaurants;
CREATE TRIGGER restaurants_set_owner
  BEFORE INSERT ON public.restaurants
  FOR EACH ROW EXECUTE FUNCTION public.restaurants_set_owner();

-- ===========================================================================
-- Every stock edit that is not an order movement is an `adjust` row.
--
-- Merchants set stock_count directly (menu_items_write_own, 11_rls.sql), and a
-- restock is legitimate. Logging it is what lets the conservation check tell a
-- restock from a leak: stock_count must always equal the sum of its movements.
--
-- Order movements (reserve, release) write their own rows and set the
-- transaction-local `ravon.inventory_op` so this trigger does not log them a
-- second time. The same pattern as ravon_set_actor: a GUC no client can reach
-- through PostgREST, set only inside SECURITY DEFINER functions. If anything
-- else sets it and moves stock, ravon_inventory_violations() reports the gap.
--
-- NULL means "not tracked" and counts as 0, so switching tracking off or on is
-- an adjustment of the whole balance and the ledger stays exact.
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.menu_items_log_stock_adjustment()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_delta int;
BEGIN
  IF current_setting('ravon.inventory_op', true) = 'order' THEN
    RETURN NULL;
  END IF;
  IF TG_OP = 'INSERT' THEN
    v_delta := COALESCE(NEW.stock_count, 0);
  ELSE
    v_delta := COALESCE(NEW.stock_count, 0) - COALESCE(OLD.stock_count, 0);
  END IF;
  IF v_delta <> 0 THEN
    INSERT INTO public.inventory_movements(menu_item_id, order_id, kind, quantity)
    VALUES (NEW.id, NULL, 'adjust', v_delta);
  END IF;
  RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS menu_items_log_stock_adjustment ON public.menu_items;
CREATE TRIGGER menu_items_log_stock_adjustment
  AFTER INSERT OR UPDATE OF stock_count ON public.menu_items
  FOR EACH ROW EXECUTE FUNCTION public.menu_items_log_stock_adjustment();
