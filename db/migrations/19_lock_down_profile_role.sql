-- Migration 19: lock down profiles.role from self-escalation.
--
-- Closes the CRITICAL finding from .gstack/security-reports/2026-03-23 —
-- "any authenticated user can PATCH /profiles?id=eq.<self> and change their
-- role from 'consumer' to 'merchant', then access every restaurant's data."
--
-- Postgres RLS cannot restrict columns directly, so we use a BEFORE UPDATE
-- trigger that fires only when auth.uid() = old.id (i.e. user editing their
-- own row). Service-role contexts (admin tooling, RPCs running with elevated
-- privileges) execute with auth.uid() = NULL, so the trigger's WHEN clause
-- skips them — admin role changes still work.
--
-- Returns a structured error so the Swift `ServiceError.from(serverError:)`
-- decoder can surface a typed `.unauthorized` to the UI.

BEGIN;

CREATE OR REPLACE FUNCTION public.profiles_block_role_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.role IS DISTINCT FROM OLD.role THEN
    RAISE EXCEPTION 'role changes are not permitted'
      USING ERRCODE = '42501',
            DETAIL  = jsonb_build_object('reason', 'ROLE_CHANGE_FORBIDDEN')::text;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS profiles_block_role_change ON public.profiles;
CREATE TRIGGER profiles_block_role_change
  BEFORE UPDATE ON public.profiles
  FOR EACH ROW
  WHEN (auth.uid() IS NOT NULL AND auth.uid() = OLD.id)
  EXECUTE FUNCTION public.profiles_block_role_change();

COMMIT;

-- Verification:
--   -- As a logged-in consumer, this must fail with errcode 42501:
--   UPDATE profiles SET role = 'merchant' WHERE id = auth.uid();
--   -- ERROR:  role changes are not permitted
--   -- DETAIL: {"reason":"ROLE_CHANGE_FORBIDDEN"}
--
--   -- Same user updating other columns must succeed:
--   UPDATE profiles SET full_name = 'Test' WHERE id = auth.uid();
--   -- (returns 1 row updated)
--
--   -- Service-role admin path (e.g. via Supabase SQL editor logged in as
--   -- service-role) must still be able to change roles:
--   UPDATE profiles SET role = 'merchant' WHERE id = '<some-uuid>';
