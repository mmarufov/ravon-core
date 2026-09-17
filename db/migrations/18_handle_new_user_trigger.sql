-- Migration 18: handle_new_user trigger.
--
-- Currently the iOS apps rely on a client-side "insert into profiles" path
-- after sign-up, which is fragile (network drop between auth.signUp and the
-- profiles insert leaves an orphan auth.users row with no profile). This
-- migration moves profile creation server-side so it is atomic with auth row
-- creation.
--
-- Reads `full_name` and `role` from auth.users.raw_user_meta_data, which the
-- Swift AuthService.signUp() already passes via the `data:` parameter.
-- Falls back to ('', 'consumer') if the metadata is missing.

BEGIN;

CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO public.profiles (id, full_name, role, created_at, updated_at)
  VALUES (
    NEW.id,
    COALESCE(NEW.raw_user_meta_data->>'full_name', ''),
    COALESCE((NEW.raw_user_meta_data->>'role')::user_role, 'consumer'::user_role),
    now(),
    now()
  )
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

COMMIT;

-- Verification:
--   1. Sign up a new user via the iOS app or REST: SELECT id FROM auth.users
--      ORDER BY created_at DESC LIMIT 1;
--   2. Confirm the profile exists with the same id:
--      SELECT id, full_name, role FROM profiles WHERE id = '<id>';
--   3. Confirm role defaults to 'consumer' when metadata is missing:
--      INSERT INTO auth.users (id, email) VALUES (gen_random_uuid(), 'x@y.z');
--      -- (this requires service-role; not for normal app use)
