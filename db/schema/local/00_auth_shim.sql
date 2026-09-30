-- LOCAL ONLY — do not apply to Supabase.
--
-- Supabase ships `auth.users`, `auth.uid()`, the `anon`/`authenticated`/
-- `service_role` roles and the `storage` schema. This file creates just enough
-- of them to apply and exercise db/schema/*.sql against a plain Postgres, with
-- the same semantics PostgREST provides:
--
--   auth.uid() reads the `request.jwt.claims` GUC, so a test switches actor with
--     SELECT set_config('request.jwt.claims', '{"sub":"<uuid>"}', true);
--   and clears it (admin/cron context) with
--     SELECT set_config('request.jwt.claims', '', true);
--
-- This is exactly the mechanism the real auth.uid() uses, which is why
-- 19_lock_down_profile_role.sql:9-11 was wrong to claim SECURITY DEFINER resets
-- it: it does not. Reproducing the real semantics here is the point.

CREATE SCHEMA IF NOT EXISTS auth;

CREATE TABLE IF NOT EXISTS auth.users (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email               text UNIQUE,
  raw_user_meta_data  jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at          timestamptz NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION auth.uid()
RETURNS uuid
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  SELECT nullif(
    coalesce(
      current_setting('request.jwt.claim.sub', true),
      (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')
    ),
    ''
  )::uuid;
$$;

-- Client roles. NOLOGIN: nothing connects as these; PostgREST SET ROLEs to them.
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    CREATE ROLE anon NOLOGIN NOINHERIT;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    CREATE ROLE authenticated NOLOGIN NOINHERIT;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
    CREATE ROLE service_role NOLOGIN NOINHERIT BYPASSRLS;
  END IF;
END $$;

GRANT USAGE ON SCHEMA public TO anon, authenticated, service_role;
-- Supabase grants this natively; without it every policy calling auth.uid()
-- fails with "permission denied for schema auth".
GRANT USAGE ON SCHEMA auth TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION auth.uid() TO anon, authenticated, service_role;

-- Minimal `storage.buckets` so 12_realtime_storage.sql and the R15 invariant
-- have something real to assert against.
CREATE SCHEMA IF NOT EXISTS storage;
CREATE TABLE IF NOT EXISTS storage.buckets (
  id                 text PRIMARY KEY,
  name               text NOT NULL,
  public             boolean NOT NULL DEFAULT false,
  file_size_limit    bigint,
  allowed_mime_types text[],
  created_at         timestamptz NOT NULL DEFAULT now()
);

-- Supabase's realtime publication. Created here so 12_realtime_storage.sql's
-- ALTER PUBLICATION runs unchanged.
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime') THEN
    CREATE PUBLICATION supabase_realtime;
  END IF;
END $$;
