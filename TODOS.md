# TODOS

## Post-Merchant Overhaul

### Deprecate `is_active` column on restaurants
**Priority:** Medium
**What:** Remove the `is_active` boolean from `restaurants` table, replace all references with `restaurant_status`.
**Why:** `is_active` is now redundant with `restaurant_status`. A DB trigger syncs them for backwards compat, but dual state is confusing.
**How:** Update consumer/courier apps to filter on `restaurant_status = 'active'` instead of `is_active = true`. Then drop the column and trigger.
**Depends on:** Consumer/courier apps updated to use `restaurant_status`.
**Added:** 2026-03-31
