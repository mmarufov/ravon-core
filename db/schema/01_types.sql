-- 01_types.sql — the two real enums.
--
-- The deleted database had NO `CREATE TYPE` for either of these: `order_status`
-- was only ever reached by `ALTER TYPE ... ADD VALUE`
-- (06_scheduled_orders.sql:15, 09_cancellation_reason_code...:11) and
-- `user_role` only by the cast at 18_handle_new_user_trigger.sql:26. Both were
-- dashboard-created. These are the authored originals.
--
-- Everything else that `.context/architecture/12-BACKEND-INVENTORY.md` called an
-- enum is NOT one, and is a text column with a CHECK in 02_tables.sql instead:
--   delivery_mode      text+CHECK — proven at 10_dual_verification_codes:25,29
--   sender_role        text+CHECK — proven at 15_chat_rls_and_sender_role:12,15
--   earning_type       text+CHECK — proven at 12_tiered_earnings:18,27
--   restaurant_status  text+CHECK — kind was UNRECOVERABLE (no cast, no
--                      ALTER TYPE, no CHECK anywhere). Chosen as text+CHECK
--                      because nothing in the corpus requires an enum and a
--                      CHECK domain is cheap to extend where an enum is not.
--   courier_status     does not exist server-side at all — it is a client-side
--                      computed property (CourierStatus.swift) with zero wire
--                      mapping. Deliberately not created.

-- 17 values. Order matters: it is the sort order PostgREST returns for
-- `.order("status")` and it must match Swift `OrderStatus.allCases`, which is
-- declaration order in Order.swift:4-20. `scheduled` is first because
-- 06_scheduled_orders.sql:15 added it `BEFORE 'created'`.
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'order_status') THEN
    CREATE TYPE public.order_status AS ENUM (
      'scheduled',
      'created',
      'accepted',
      'preparing',
      'ready',
      'assigned',
      'courier_arrived_restaurant',
      'picked_up',
      'delivering',
      'courier_arrived_customer',
      'delivered',
      -- Legacy, no producer. Kept so historical rows and all three apps'
      -- `case .cancelled:` branches still decode; excluded from reachability by
      -- design (OrderLifecycle.orphanedLegacyStatuses).
      'cancelled',
      'rejected',
      'cancelled_by_customer',
      'cancelled_by_restaurant',
      'cancelled_by_system',
      'cancelled_by_courier'
    );
  END IF;
END $$;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'user_role') THEN
    CREATE TYPE public.user_role AS ENUM ('consumer', 'courier', 'merchant');
  END IF;
END $$;
