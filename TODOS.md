# TODOS

## Post-Merchant Overhaul

### Deprecate `is_active` column on restaurants
**Priority:** Medium
**What:** Remove the `is_active` boolean from `restaurants` table, replace all references with `restaurant_status`.
**Why:** `is_active` is now redundant with `restaurant_status`. A DB trigger syncs them for backwards compat, but dual state is confusing.
**How:** Update consumer/courier apps to filter on `restaurant_status = 'active'` instead of `is_active = true`. Then drop the column and trigger.
**Depends on:** Merchant overhaul PR shipping + consumer/courier apps updated.
**Added:** 2026-03-31

### Add owner-scoped RLS for modifier_options and menu_item_modifier_groups
**Priority:** High
**What:** Add RLS policies for `modifier_options` (via join to modifier_groups.restaurant_id → restaurants.owner_id) and `menu_item_modifier_groups` junction table.
**Why:** Migration 2 covers modifier_groups but not modifier_options or the junction table. Existing policies only check `role = 'merchant'` without owner scoping.
**How:** Follow the same join pattern as existing modifier_options read policy, but check `owner_id = auth.uid()` instead of just `is_active`.
**Depends on:** Migration 2 (owner_id on restaurants).
**Added:** 2026-03-31

### Strengthen onboarding gate
**Priority:** Low
**What:** Update `activateRestaurant()` onboarding check to require at least 1 available item with price > 0, not just that rows exist.
**Why:** Current check only verifies rows exist. Merchant could go live with all items unavailable or $0.
**How:** Add `is_available = true AND price > 0` filter to the menu items count in onboarding progress.
**Depends on:** Onboarding progress implementation in this PR.
**Added:** 2026-03-31
