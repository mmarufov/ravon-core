-- Migration 11: reassignment columns on orders (consumed by RPC reassign_ghosted_order).
-- Per Workstream E.

ALTER TABLE orders
  ADD COLUMN IF NOT EXISTS reassign_count int NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS excluded_courier_ids uuid[] NOT NULL DEFAULT ARRAY[]::uuid[];
