-- 13_realtime_storage.sql — storage buckets, the realtime publication, cron.

-- ===========================================================================
-- 1. Storage buckets — T3, including the bucket the finding missed.
--
-- The report found `restaurant-images` and `menu-item-images` with
-- `file_size_limit IS NULL` and `allowed_mime_types IS NULL`, verified by live
-- query, so the ONLY validation was client-side (SupabaseService+Images.swift:7
-- 5 MB + a filename-extension allowlist) and bypassable by calling the Storage
-- API directly with the anon key.
--
-- The finding was also incomplete: there is a THIRD bucket, `delivery-proofs`
-- (SupabaseService+Courier.swift:179), with a client-only 500 KB check at :176
-- and a comment at :173 conceding "server-side check is added in v2". Neither
-- report covers it, and it is the one that matters most, because a delivery
-- proof is evidence in a payment dispute.
--
-- Limits mirror the client's intent so no working upload breaks. Note the MIME
-- list is what the SERVER enforces on the declared content-type; a filename
-- extension is not a content type, which is why the client check was never
-- sufficient.
-- ===========================================================================
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES
  ('restaurant-images', 'restaurant-images', true,  5242880,
     ARRAY['image/jpeg','image/png','image/webp']),
  ('menu-item-images',  'menu-item-images',  true,  5242880,
     ARRAY['image/jpeg','image/png','image/webp']),
  -- NOT public: a delivery proof is a photo of someone's front door. The image
  -- buckets are public because menu photos are; this one must not be.
  ('delivery-proofs',   'delivery-proofs',   false, 512000,
     ARRAY['image/jpeg'])
ON CONFLICT (id) DO UPDATE SET
  public             = EXCLUDED.public,
  file_size_limit    = EXCLUDED.file_size_limit,
  allowed_mime_types = EXCLUDED.allowed_mime_types;

-- ===========================================================================
-- 2. Realtime publication — exactly the five tables RealtimeService subscribes
-- to (RealtimeService.swift:117, :249, :305, :346, :436). Anything else in the
-- publication is WAL traffic and row exposure for no subscriber.
--
-- `orders` is REPLICA IDENTITY FULL (02_tables.sql) because the service reads
-- `change.oldRecord["status"]` in three places; without it the old tuple carries
-- only the primary key and every oldStatus silently decodes as nil.
-- ===========================================================================
DO $$
DECLARE t text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime') THEN
    CREATE PUBLICATION supabase_realtime;
  END IF;
  FOREACH t IN ARRAY ARRAY['orders','menu_items','restaurants',
                           'courier_locations','chat_messages']
  LOOP
    IF NOT EXISTS (
      SELECT 1 FROM pg_publication_tables
      WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = t
    ) THEN
      EXECUTE format('ALTER PUBLICATION supabase_realtime ADD TABLE public.%I', t);
    END IF;
  END LOOP;
END $$;

-- ===========================================================================
-- 3. Scheduled work.
--
-- Guarded: pg_cron is a Supabase extension and is absent from a plain local
-- Postgres, so this block is a no-op there and the rest of the schema still
-- applies. The sweeps themselves are not granted to any client role (R16), so
-- cron is the only caller.
-- ===========================================================================
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    RAISE NOTICE 'pg_cron absent — skipping schedules (expected on local Postgres)';
    RETURN;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'courier_escalation_ladder') THEN
    PERFORM cron.schedule('courier_escalation_ladder', '* * * * *',
      $cron$ SELECT public.run_courier_escalation_ladder(); $cron$);
  END IF;

  IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'mark_no_show_deliveries') THEN
    PERFORM cron.schedule('mark_no_show_deliveries', '* * * * *',
      $cron$ SELECT public.mark_no_show_deliveries(); $cron$);
  END IF;

  IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'activate_scheduled_orders') THEN
    PERFORM cron.schedule('activate_scheduled_orders', '* * * * *',
      $cron$ SELECT public.activate_scheduled_orders(); $cron$);
  END IF;

  -- 30-day purge of soft-deleted menu rows (M 07).
  IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'purge_soft_deleted') THEN
    PERFORM cron.schedule('purge_soft_deleted', '17 3 * * *',
      $cron$
        DELETE FROM public.menu_items
        WHERE deleted_at IS NOT NULL AND deleted_at < now() - interval '30 days';
        DELETE FROM public.menu_categories
        WHERE deleted_at IS NOT NULL AND deleted_at < now() - interval '30 days';
      $cron$);
  END IF;
END $$;
