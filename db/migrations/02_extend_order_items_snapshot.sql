-- Migration 2: Extend order_items snapshot so historical orders survive item deletion.
-- Per Workstream D.

ALTER TABLE order_items ADD COLUMN IF NOT EXISTS item_description text NULL;
ALTER TABLE order_items ADD COLUMN IF NOT EXISTS item_image_url   text NULL;
ALTER TABLE order_items ADD COLUMN IF NOT EXISTS modifiers_snapshot jsonb NOT NULL DEFAULT '[]'::jsonb;

-- Allow null menu_item_id so hard-deleted items don't fail FK
ALTER TABLE order_items ALTER COLUMN menu_item_id DROP NOT NULL;

-- Replace the FK with ON DELETE SET NULL
ALTER TABLE order_items DROP CONSTRAINT IF EXISTS order_items_menu_item_id_fkey;
ALTER TABLE order_items
  ADD CONSTRAINT order_items_menu_item_id_fkey
  FOREIGN KEY (menu_item_id) REFERENCES menu_items(id) ON DELETE SET NULL;

-- One-time backfill for existing rows: copy description/image from current menu_items where possible.
UPDATE order_items oi
SET item_description = mi.description,
    item_image_url   = mi.image_url
FROM menu_items mi
WHERE oi.menu_item_id = mi.id
  AND (oi.item_description IS NULL OR oi.item_image_url IS NULL);

-- One-time backfill of modifiers_snapshot from order_item_modifiers.
UPDATE order_items oi
SET modifiers_snapshot = COALESCE((
  SELECT jsonb_agg(jsonb_build_object(
    'group_name', oim.modifier_group_name,
    'option_name', oim.modifier_option_name,
    'price_adjustment', oim.price_adjustment
  ))
  FROM order_item_modifiers oim
  WHERE oim.order_item_id = oi.id
), '[]'::jsonb)
WHERE jsonb_array_length(oi.modifiers_snapshot) = 0;
