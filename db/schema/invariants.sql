-- invariants.sql — one assertion per security rule. Run with ON_ERROR_STOP=1.
--
-- The repo has five CI jobs (build/test, lifecycle invariants, dispatch
-- simulation, schema drift, secret scan) and NONE of them asserts anything about
-- grants, policies, constraints or generated columns. That is why nine findings
-- across two security reports produced exactly one migration, and why the
-- second report's `"critical": 0` was a false negative rather than a fix record:
-- it ran a month BEFORE the only migration that ever addressed a CRITICAL.
--
-- The lesson, turned into machinery: a scanner's totals block is never evidence
-- of a fix. Only an assertion that fails the build is. Each block below fails
-- loudly and names the rule it enforces.
--
--   psql -v ON_ERROR_STOP=1 -f db/schema/invariants.sql

\set ON_ERROR_STOP on

DO $$
DECLARE
  v_bad text;
  v_n   int;
BEGIN
  -- =========================================================================
  -- R2 — clients hold NO write privilege on transactional tables.
  -- Kills S4, S5, T1, T2 structurally: there is no grant for a future
  -- CREATE POLICY to qualify.
  -- =========================================================================
  SELECT string_agg(format('%s:%s:%s', r.rolname, t.tbl, p.priv), ', ')
    INTO v_bad
  FROM (VALUES ('orders'),('order_items'),('order_status_history'),
               ('courier_earnings'),('courier_cancellation_log'),
               ('order_transitions'),('inventory_movements'),
               ('kitchen_slots'),('kitchen_slot_holds')) AS t(tbl)
  CROSS JOIN (VALUES ('anon'),('authenticated')) AS r(rolname)
  CROSS JOIN (VALUES ('INSERT'),('UPDATE'),('DELETE')) AS p(priv)
  WHERE has_table_privilege(r.rolname, 'public.' || t.tbl, p.priv);
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'R2 violated — client write privilege on a transactional table: %', v_bad;
  END IF;

  -- =========================================================================
  -- R1 — role is never client-writable, and never read from user metadata.
  -- =========================================================================
  IF has_column_privilege('authenticated', 'public.profiles', 'role', 'UPDATE') THEN
    RAISE EXCEPTION 'R1 violated — authenticated holds UPDATE(role) on profiles';
  END IF;
  IF has_table_privilege('authenticated', 'public.profiles', 'INSERT') THEN
    RAISE EXCEPTION 'R1 violated — authenticated holds INSERT on profiles';
  END IF;

  -- The S1 regression test. Migration 18 read the role out of
  -- raw_user_meta_data and migration 19 did not close it, so
  -- `POST /auth/v1/signup {"data":{"role":"merchant"}}` provisioned a merchant
  -- with nothing but the anon key. Any function body that mentions BOTH user
  -- metadata and `role` re-opens it.
  -- Matches the extraction itself -- `raw_user_meta_data->>'role'` -- rather
  -- than co-occurrence of the two words. handle_new_user legitimately reads
  -- `full_name` from metadata and legitimately names the `role` COLUMN when it
  -- writes the hardcoded 'consumer', so a co-occurrence test flags the fixed
  -- version as broken. What must never appear is the JSON path to `role`.
  SELECT string_agg(p.proname, ', ') INTO v_bad
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.prosrc ~* '(raw_user_meta_data|user_metadata|app_metadata)[[:space:]]*-+>>?[[:space:]]*''role''';
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'R1 violated — function reads role from user metadata: %', v_bad;
  END IF;

  -- And nothing anywhere may trust a JWT claim for authorization state, since
  -- GoTrue mirrors raw_user_meta_data into the access token and
  -- `PUT /auth/v1/user` lets the user rewrite it at will. Nothing in the old
  -- corpus read it -- that was luck, not design.
  SELECT string_agg(p.proname, ', ') INTO v_bad
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.prosrc ~* 'jwt[^[:alnum:]]*(claims?)?[[:space:]]*-+>>?[[:space:]]*''(role|user_metadata|app_metadata)''';
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'R18 violated — function trusts a user-writable JWT claim: %', v_bad;
  END IF;

  -- =========================================================================
  -- R3 — no SECURITY DEFINER function is reachable by anon, unless the
  -- checked-in allowlist says so. The one rule that would have prevented S3,
  -- N1, N2, N3 and N4 simultaneously, and the only one that survives someone
  -- adding a function next year. The allowlist is currently empty by design.
  -- =========================================================================
  SELECT string_agg(p.proname, ', ') INTO v_bad
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.prosecdef
    AND has_function_privilege('anon', p.oid, 'EXECUTE');
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'R3 violated — anon can EXECUTE SECURITY DEFINER function(s): %', v_bad;
  END IF;

  -- anon reaches no table either.
  SELECT string_agg(format('%s:%s', c.relname, p.priv), ', ') INTO v_bad
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  CROSS JOIN (VALUES ('SELECT'),('INSERT'),('UPDATE'),('DELETE')) AS p(priv)
  WHERE n.nspname = 'public' AND c.relkind IN ('r','v')
    AND has_table_privilege('anon', c.oid, p.priv);
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'R3 violated — anon holds table privilege(s): %', v_bad;
  END IF;

  -- =========================================================================
  -- R5 — no view bypasses RLS. Kills N10, where `restaurants_orderable` was
  -- `SELECT r.*` with no security_invoker and GRANT SELECT to anon, so any
  -- holder of the anon key read every column of every active restaurant.
  -- =========================================================================
  SELECT string_agg(c.relname, ', ') INTO v_bad
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND c.relkind = 'v'
    AND NOT COALESCE(c.reloptions::text LIKE '%security_invoker=true%', false);
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'R5 violated — view(s) without security_invoker=true: %', v_bad;
  END IF;

  -- =========================================================================
  -- R6 — definer functions cannot be search_path-hijacked. Migrations 01-19
  -- set `search_path = public`, which satisfies the
  -- `function_search_path_mutable` linter while PRESERVING the hijack.
  -- =========================================================================
  -- Postgres stores `SET search_path = ''` as the proconfig entry
  -- `search_path=""`, so the test is: an entry must exist, and it must be
  -- empty. A search_path of `public` is the hijackable form that migrations
  -- 01-19 used throughout.
  SELECT string_agg(p.proname, ', ') INTO v_bad
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.prosecdef
    AND NOT EXISTS (
      SELECT 1 FROM unnest(COALESCE(p.proconfig, ARRAY[]::text[])) cfg
      WHERE cfg IN ('search_path=', 'search_path=""')
    );
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'R6 violated — definer function(s) without empty search_path: %', v_bad;
  END IF;

  IF EXISTS (SELECT 1 FROM information_schema.role_table_grants
             WHERE grantee IN ('anon','authenticated') AND privilege_type = 'TRUNCATE') THEN
    RAISE EXCEPTION 'R6 violated — client holds TRUNCATE';
  END IF;

  -- =========================================================================
  -- R7 — money is derived, not supplied. A generated column is unwritable by
  -- EVERY role, including a future Kotlin service role, so a total cannot
  -- desynchronise from its components even if R2 is later weakened.
  -- =========================================================================
  IF NOT EXISTS (SELECT 1 FROM pg_attribute
                 WHERE attrelid = 'public.orders'::regclass
                   AND attname = 'total' AND attgenerated = 's') THEN
    RAISE EXCEPTION 'R7 violated — orders.total is not a STORED generated column';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_attribute
                 WHERE attrelid = 'public.order_items'::regclass
                   AND attname = 'total_price' AND attgenerated = 's') THEN
    RAISE EXCEPTION 'R7 violated — order_items.total_price is not generated';
  END IF;

  -- =========================================================================
  -- R8 / R12 / R13 — domain constraints exist BY NAME, so a later ALTER that
  -- drops one fails here rather than silently widening the domain.
  -- =========================================================================
  SELECT string_agg(want.name, ', ') INTO v_bad
  FROM (VALUES
    ('orders_cancellation_reason_code_valid'),
    ('orders_courier_delay_reason_valid'),
    ('orders_leave_at_door_needs_proof'),
    ('courier_earnings_type_valid'),
    ('chat_messages_sender_role_valid'),
    ('courier_cancellation_log_reason_valid'),
    ('restaurant_hours_day_uniq'),
    ('modifier_groups_selection_range')
  ) AS want(name)
  WHERE NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = want.name);
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'R8 violated — missing named constraint(s): %', v_bad;
  END IF;

  -- N8: quantity had NO check in migrations 01-19, and create_order summed
  -- `price * quantity` with no sign test.
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.order_items'::regclass AND contype = 'c'
      AND pg_get_constraintdef(oid) ILIKE '%quantity%'
  ) THEN
    RAISE EXCEPTION 'R8 violated — order_items has no quantity CHECK';
  END IF;

  -- N9: the length was never the defect; the absent attempt counter was.
  SELECT string_agg(col, ', ') INTO v_bad
  FROM (VALUES ('pickup_code_attempts'),('delivery_code_attempts')) AS want(col)
  WHERE NOT EXISTS (SELECT 1 FROM pg_attribute
                    WHERE attrelid = 'public.orders'::regclass AND attname = want.col);
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'R12 violated — missing code attempt counter(s): %', v_bad;
  END IF;

  -- =========================================================================
  -- R9 — ownership is a foreign key, not a policy clause. Migrations 01, 05 and
  -- 15 wrote policies against `restaurants.owner_id`, a column their own
  -- migration set never created.
  -- =========================================================================
  IF NOT EXISTS (SELECT 1 FROM pg_attribute
                 WHERE attrelid = 'public.restaurants'::regclass
                   AND attname = 'owner_id' AND attnotnull) THEN
    RAISE EXCEPTION 'R9 violated — restaurants.owner_id is missing or nullable';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                 WHERE conrelid = 'public.restaurants'::regclass AND contype = 'f'
                   AND 'owner_id' = ANY (
                     SELECT attname FROM pg_attribute
                     WHERE attrelid = conrelid AND attnum = ANY(conkey))) THEN
    RAISE EXCEPTION 'R9 violated — restaurants.owner_id has no foreign key';
  END IF;

  -- =========================================================================
  -- R10 — an order cannot exist without a resolved address snapshot. Kills N7,
  -- where a bogus UUID silently produced an order with a NULL snapshot and a
  -- known-but-foreign UUID stole another user's street address.
  -- =========================================================================
  IF NOT EXISTS (SELECT 1 FROM pg_attribute
                 WHERE attrelid = 'public.orders'::regclass
                   AND attname = 'delivery_address_snapshot' AND attnotnull) THEN
    RAISE EXCEPTION 'R10 violated — orders.delivery_address_snapshot is nullable';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_attribute
                 WHERE attrelid = 'public.orders'::regclass
                   AND attname = 'user_id' AND attnotnull) THEN
    RAISE EXCEPTION 'R10 violated — orders.user_id is nullable (anon could create orders)';
  END IF;

  -- =========================================================================
  -- R15 — storage limits live on the bucket. Kills T3 including the third
  -- bucket (`delivery-proofs`) that neither report covered.
  -- =========================================================================
  SELECT count(*) INTO v_n FROM storage.buckets
  WHERE file_size_limit IS NULL OR allowed_mime_types IS NULL;
  IF v_n > 0 THEN
    RAISE EXCEPTION 'R15 violated — % storage bucket(s) with no size or MIME limit', v_n;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM storage.buckets WHERE id = 'delivery-proofs' AND public = false) THEN
    RAISE EXCEPTION 'R15 violated — delivery-proofs bucket is public or missing';
  END IF;

  -- =========================================================================
  -- R16 — batch sweeps are not client-callable. Kills N1, N3, N4 and S3's
  -- auto_cancel_stale_orders.
  -- =========================================================================
  SELECT string_agg(format('%s/%s', p.proname, r.rolname), ', ') INTO v_bad
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  CROSS JOIN (VALUES ('anon'),('authenticated')) AS r(rolname)
  WHERE n.nspname = 'public'
    AND (p.proname ~ '(ladder|sweep|no_show_deliveries|activate_scheduled_orders|auto_cancel|reassign_ghosted)')
    AND has_function_privilege(r.rolname, p.oid, 'EXECUTE');
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'R16 violated — sweep function(s) client-executable: %', v_bad;
  END IF;

  -- The two functions that were deleted outright rather than revoked must stay
  -- deleted: reassign_ghosted_order (N1, no auth check at all) and
  -- insert_courier_earning_for_cancel (N2, unbounded tier override).
  SELECT string_agg(p.proname, ', ') INTO v_bad
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname IN ('reassign_ghosted_order','insert_courier_earning_for_cancel',
                      'auto_cancel_stale_orders');
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'R16 violated — a deleted-by-design function was re-created: %', v_bad;
  END IF;

  -- =========================================================================
  -- Lifecycle — the transition table must match OrderLifecycle.swift's 36
  -- declared edges. Adding an edge in Swift without adding it here (or the
  -- reverse) fails CI, which is what keeps the two copies one copy.
  -- =========================================================================
  SELECT count(*) INTO v_n FROM public.order_transitions;
  IF v_n <> 36 THEN
    RAISE EXCEPTION 'lifecycle drift — order_transitions has % rows, OrderLifecycle.swift declares 36', v_n;
  END IF;

  -- The five merchant RPCs that OrderLifecycle.unimplementedRPCs used to name
  -- must now exist. This is the assertion that proves the gap is closed.
  SELECT string_agg(want.fn, ', ') INTO v_bad
  FROM (VALUES ('merchant_accept_order'),('merchant_start_preparing'),
               ('merchant_reject_order'),('merchant_mark_order_ready'),
               ('merchant_cancel_order')) AS want(fn)
  WHERE NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                    WHERE n.nspname = 'public' AND p.proname = want.fn);
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'lifecycle gap — merchant RPC(s) still missing: %', v_bad;
  END IF;

  -- Every RPC named by the transition table must exist, or the graph describes
  -- behaviour the server cannot perform.
  SELECT string_agg(DISTINCT t.rpc, ', ') INTO v_bad
  FROM public.order_transitions t
  WHERE NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                    WHERE n.nspname = 'public' AND p.proname = t.rpc);
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'lifecycle gap — transition table references absent RPC(s): %', v_bad;
  END IF;

  -- The status trigger is what makes the table load-bearing rather than
  -- decorative.
  IF NOT EXISTS (SELECT 1 FROM pg_trigger
                 WHERE tgrelid = 'public.orders'::regclass
                   AND tgname = 'orders_enforce_transition' AND NOT tgisinternal) THEN
    RAISE EXCEPTION 'lifecycle — orders_enforce_transition trigger is missing';
  END IF;

  -- =========================================================================
  -- Realtime — REPLICA IDENTITY FULL on orders, or every oldRecord["status"]
  -- read in RealtimeService silently becomes nil.
  -- =========================================================================
  IF (SELECT relreplident FROM pg_class WHERE oid = 'public.orders'::regclass) <> 'f' THEN
    RAISE EXCEPTION 'realtime — orders is not REPLICA IDENTITY FULL; oldRecord.status would be null';
  END IF;

  SELECT count(*) INTO v_n FROM pg_publication_tables
  WHERE pubname = 'supabase_realtime' AND schemaname = 'public';
  IF v_n <> 5 THEN
    RAISE EXCEPTION 'realtime — supabase_realtime publishes % tables, expected exactly 5', v_n;
  END IF;

  -- =========================================================================
  -- RLS is on for every table. A table with RLS off and a SELECT grant is
  -- world-readable to every authenticated user.
  -- =========================================================================
  SELECT string_agg(c.relname, ', ') INTO v_bad
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND c.relkind = 'r' AND NOT c.relrowsecurity;
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'RLS disabled on table(s): %', v_bad;
  END IF;

  -- No write policy may exist on the transactional tables, so the intent is
  -- recorded twice: once as a missing grant, once as a missing policy.
  SELECT string_agg(format('%s.%s', tablename, policyname), ', ') INTO v_bad
  FROM pg_policies
  WHERE schemaname = 'public'
    AND tablename IN ('orders','order_items','order_status_history',
                      'courier_earnings','courier_cancellation_log',
                      'inventory_movements','kitchen_slots','kitchen_slot_holds')
    AND cmd <> 'SELECT';
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'R2 violated — non-SELECT policy on a transactional table: %', v_bad;
  END IF;

  -- =========================================================================
  -- STOCK — conservation, and the two structural guarantees behind it.
  --
  -- The 32 checks above are about the catalog: grants, policies, generated
  -- columns, the transition table. They all passed at 65ad66c while scheduled
  -- pre-orders let 60 orders go live for 40 portions, because nothing here
  -- checked behaviour and no test in the repo touched stock. A catalog
  -- invariant is not a behavioural one; these are the behavioural ones, and
  -- db/rush plus db/schema/tests exercise them under load.
  -- =========================================================================
  SELECT string_agg(format('%s: %s', check_name, detail), '; ') INTO v_bad
  FROM public.ravon_inventory_violations();
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'STOCK — conservation violated: %', v_bad;
  END IF;

  -- Returning units twice must be a constraint violation, not a bug to find.
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                 WHERE conname = 'inventory_movements_once' AND contype = 'u') THEN
    RAISE EXCEPTION 'STOCK — inventory_movements has no UNIQUE (order_id, menu_item_id, kind)';
  END IF;

  -- The regression, by name. A clamp on stock anywhere in the order paths
  -- turns an oversell into a silent zero.
  SELECT string_agg(p.proname, ', ') INTO v_bad
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.prosrc ~* 'greatest\s*\(\s*0\s*,\s*[a-z_.]*stock_count';
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'STOCK — GREATEST(0, stock_count ...) clamp in: %', v_bad;
  END IF;

  RAISE NOTICE 'all invariants hold';
END $$;
