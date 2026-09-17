-- Migration 7: Daily cron that hard-deletes soft-deleted menu items + categories older than 30 days.
-- Per Workstream D + user decision #3.
-- Order rows are protected by `ON DELETE SET NULL` (set in migration 02) and the OrderItem snapshot.

SELECT cron.schedule(
  'purge_soft_deleted_menu',
  '0 3 * * *',  -- daily at 03:00 server time
  $$
    DELETE FROM menu_items
    WHERE deleted_at IS NOT NULL
      AND deleted_at < now() - interval '30 days';

    DELETE FROM menu_categories
    WHERE deleted_at IS NOT NULL
      AND deleted_at < now() - interval '30 days';
  $$
);
