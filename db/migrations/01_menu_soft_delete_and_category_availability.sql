-- Migration 1: Soft-delete + category availability
-- Per Workstream D of the federated umbrella plan.
-- Apply via Supabase MCP `apply_migration` or SQL editor.

ALTER TABLE menu_items     ADD COLUMN IF NOT EXISTS deleted_at timestamptz NULL;
ALTER TABLE menu_categories ADD COLUMN IF NOT EXISTS deleted_at timestamptz NULL;
ALTER TABLE menu_categories ADD COLUMN IF NOT EXISTS is_available boolean NOT NULL DEFAULT true;

-- Partial index speeds up consumer fetches that filter on `deleted_at IS NULL`.
CREATE INDEX IF NOT EXISTS menu_items_active_idx
  ON menu_items(restaurant_id, sort_order)
  WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS menu_categories_active_idx
  ON menu_categories(restaurant_id, sort_order)
  WHERE deleted_at IS NULL;

-- Update consumer-facing RLS policies to exclude soft-deleted rows.
-- Adjust policy names to match the project — these are illustrative.
DROP POLICY IF EXISTS "menu_items_select_consumer" ON menu_items;
CREATE POLICY "menu_items_select_consumer"
  ON menu_items FOR SELECT
  TO authenticated
  USING (
    deleted_at IS NULL
    AND is_available = true
    AND EXISTS (
      SELECT 1 FROM restaurants r
      WHERE r.id = menu_items.restaurant_id
        AND r.restaurant_status = 'active'
    )
  );

-- Merchants must still see soft-deleted rows for the restore flow.
DROP POLICY IF EXISTS "menu_items_select_merchant" ON menu_items;
CREATE POLICY "menu_items_select_merchant"
  ON menu_items FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM restaurants r
      WHERE r.id = menu_items.restaurant_id
        AND r.owner_id = auth.uid()
    )
  );

DROP POLICY IF EXISTS "menu_categories_select_consumer" ON menu_categories;
CREATE POLICY "menu_categories_select_consumer"
  ON menu_categories FOR SELECT
  TO authenticated
  USING (
    deleted_at IS NULL
    AND is_available = true
  );

DROP POLICY IF EXISTS "menu_categories_select_merchant" ON menu_categories;
CREATE POLICY "menu_categories_select_merchant"
  ON menu_categories FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM restaurants r
      WHERE r.id = menu_categories.restaurant_id
        AND r.owner_id = auth.uid()
    )
  );
