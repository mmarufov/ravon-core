-- 00_prelude.sql — extensions and pure helpers.
--
-- Apply order: 00 → 12, then seed.sql. See db/schema/README.md.
--
-- This file deliberately does NOT create the `auth` schema or `auth.uid()`:
-- Supabase provides both. For local verification, apply
-- `db/schema/local/00_auth_shim.sql` first (it creates a GUC-backed stand-in
-- with the same semantics PostgREST gives you).

-- pgcrypto lives in `extensions` on Supabase and would default to `public`
-- locally. Pin it so every definer function below can fully-qualify
-- `extensions.gen_random_bytes` and run unchanged in both places.
CREATE SCHEMA IF NOT EXISTS extensions;
CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;

-- ---------------------------------------------------------------------------
-- Distance. Deliberately NOT PostGIS.
--
-- The deleted database used `courier_locations.geog extensions.geography` plus
-- ST_Distance (13_courier_status_transition_rpcs_v2.sql:52). `geog` appears in
-- no Swift CodingKeys block, so dropping it breaks no client contract, and
-- removing the dependency buys three things: the schema applies to a plain
-- Postgres (which is where ADR 0005 is heading), it is verifiable locally, and
-- there is one less extension in the definer functions' search path.
--
-- Cost: no GiST index for radius search. At one-city scale (Dushanbe, tens of
-- online couriers) `find_nearby_couriers` is a seq scan over
-- `courier_locations WHERE is_online`, which is measured in microseconds. If
-- the fleet ever spans cities, add PostGIS and a GiST index then.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ravon_distance_m(
  lat1 double precision, lng1 double precision,
  lat2 double precision, lng2 double precision
) RETURNS double precision
LANGUAGE sql IMMUTABLE PARALLEL SAFE
SET search_path = ''
AS $$
  -- Haversine on a sphere of radius 6371008.8 m (WGS-84 mean).
  SELECT 2 * 6371008.8 * asin(sqrt(
      power(sin(radians(lat2 - lat1) / 2), 2)
    + cos(radians(lat1)) * cos(radians(lat2))
    * power(sin(radians(lng2 - lng1) / 2), 2)
  ));
$$;

-- A 4-digit verification code from a CSPRNG.
--
-- Replaces `lpad(floor(random() * 9000 + 1000)::text, 4, '0')`
-- (10_dual_verification_codes_and_delivery_mode.sql:38). `random()` is a seeded
-- PRNG: observing a few codes constrains the sequence. `gen_random_bytes` is a
-- CSPRNG. Length stays 4 because the merchant reads it aloud at the counter and
-- both apps render a 4-box input; brute force is bounded by the attempt counter
-- on `orders` (see 02_tables.sql), not by the keyspace.
CREATE OR REPLACE FUNCTION public.ravon_gen_code()
RETURNS text
LANGUAGE sql VOLATILE
SET search_path = ''
AS $$
  SELECT lpad(((get_byte(g, 0) << 8 | get_byte(g, 1)) % 9000 + 1000)::text, 4, '0')
  FROM (SELECT extensions.gen_random_bytes(2) AS g) s;
$$;
