-- 02_tables.sql — the 16 tables.
--
-- Sources unioned per table, in the order they were trusted:
--   M  db/migrations/*.sql      — ALTER/reference evidence (1 CREATE TABLE only)
--   S  Sources/RavonCore/Models — 265 wire keys across 14 CodingKeys blocks
--   C  SupabaseService.swift    — projections, filters, embeds, onConflict targets
--
-- `order_item_modifiers` is deliberately absent: migration 02 folded it into
-- `order_items.modifiers_snapshot` and the model has zero call sites. The Swift
-- type `OrderItemModifier` survives in Modifier.swift and is now dead code.
--
-- Money is `numeric(10,2)`, NOT bigint minor units. security-by-construction.md
-- R7 asks for minor units and it is the better representation, but all three
-- apps decode these columns as Swift `Double` (Order.swift:271-273,
-- MenuItem.swift:9, Restaurant.swift:16-18). Changing the unit is a coordinated
-- change across RavonCore plus three app repos, which is out of scope for
-- standing the database up. What IS taken from R7 — and is the half that
-- actually kills the finding class — is that `total` is GENERATED: it is
-- unwritable by every role including a future service role, so no bug can
-- desynchronise a total from its components. See .context/plans/backend-standup.md.

-- ===========================================================================
-- profiles
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.profiles (
  id                 uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  full_name          text NOT NULL DEFAULT '',
  phone              text,
  -- R1: never client input. 09_triggers.sql hardcodes 'consumer' at signup and
  -- 11_grants.sql grants no UPDATE(role) to any client role.
  role               user_role NOT NULL DEFAULT 'consumer',
  avatar_url         text,
  is_suspended_until timestamptz,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now()
);

-- ===========================================================================
-- restaurants
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.restaurants (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name                   text NOT NULL,
  description            text,
  image_url              text,
  -- S-only, and hard-decoded (Restaurant.swift:69): absence or NULL throws and
  -- the whole consumer feed fails. NOT NULL with a default rather than nullable.
  cuisine_type           text NOT NULL DEFAULT '',
  -- S-only, hard-decoded, and `.order("rating")` sorts on it (C :179).
  rating                 double precision NOT NULL DEFAULT 0
                           CHECK (rating >= 0 AND rating <= 5),
  -- D4: M proves nullable (`COALESCE(r.delivery_time_min, 30)` at 06:100) but S
  -- decodes non-optional. NOT NULL DEFAULT 30 satisfies both.
  delivery_time_min      int NOT NULL DEFAULT 30 CHECK (delivery_time_min > 0),
  delivery_fee           numeric(10,2) NOT NULL DEFAULT 0 CHECK (delivery_fee >= 0),
  min_order_amount       numeric(10,2) NOT NULL DEFAULT 0 CHECK (min_order_amount >= 0),
  address                text,
  latitude               double precision,
  longitude              double precision,
  -- Legacy single-window hours. `restaurant_hours` is the real source and is
  -- what restaurant_within_hours() reads; these two are retained only because
  -- Restaurant.swift still declares them.
  opening_time           time,
  closing_time           time,
  max_concurrent_orders  int CHECK (max_concurrent_orders IS NULL OR max_concurrent_orders > 0),
  is_accepting_orders    boolean NOT NULL DEFAULT true,
  accepting_orders_until timestamptz,
  -- D6 / R9. Referenced by RLS at 01:43, 01:64, 05:22, 15:54, 15:70 and by
  -- fetchMyRestaurant (C :1132), yet created by NO migration — three migrations
  -- referenced a column their own set never created. Declared NOT NULL here so
  -- that class of error is impossible, and so ownership is a foreign key rather
  -- than a policy clause.
  -- Server-assigned from auth.uid() by `restaurants_set_owner` (09_triggers.sql),
  -- never client input: RestaurantInsert omits it entirely, and a
  -- client-supplied owner_id would be precisely the S2 shape. 11_grants.sql
  -- withholds UPDATE on this column so it cannot be reassigned either.
  owner_id               uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  -- DEFAULT 'draft', not 'active'. RestaurantInsert sends no status, and
  -- activateRestaurant (C :1147-1151) filters `.eq("restaurant_status","draft")`
  -- — so an 'active' default would make that call match zero rows and the
  -- merchant could never complete onboarding. The onboarding flow only makes
  -- sense if a new restaurant is invisible to the consumer feed until it opts in.
  restaurant_status      text NOT NULL DEFAULT 'draft'
                           CHECK (restaurant_status IN ('draft','active','paused','closed')),
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now()
);
-- UNIQUE, not a plain index. createRestaurant's doc comment claims "1 per
-- merchant enforced by DB unique index" (SupabaseService.swift:1107) and its
-- only actual enforcement is a client-side pre-check (:1113) that two
-- concurrent calls both pass. Another contract written in a comment and
-- enforced nowhere.
CREATE UNIQUE INDEX IF NOT EXISTS restaurants_owner_uniq ON public.restaurants(owner_id);
CREATE INDEX IF NOT EXISTS restaurants_feed_idx   ON public.restaurants(restaurant_status, rating DESC);

-- ===========================================================================
-- restaurant_hours
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.restaurant_hours (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  restaurant_id uuid NOT NULL REFERENCES public.restaurants(id) ON DELETE CASCADE,
  day_of_week   int  NOT NULL CHECK (day_of_week BETWEEN 0 AND 6),  -- 0=Sunday
  opening_time  time NOT NULL,
  closing_time  time NOT NULL,
  is_closed     boolean NOT NULL DEFAULT false,
  -- Composite UNIQUE asserted by exactly one source: `onConflict:
  -- "restaurant_id,day_of_week"` at C :896. Without it that upsert errors.
  CONSTRAINT restaurant_hours_day_uniq UNIQUE (restaurant_id, day_of_week)
);

-- ===========================================================================
-- menu_categories / menu_items
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.menu_categories (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  restaurant_id uuid NOT NULL REFERENCES public.restaurants(id) ON DELETE CASCADE,
  name          text NOT NULL,
  sort_order    int  NOT NULL DEFAULT 0,
  is_available  boolean NOT NULL DEFAULT true,   -- M 01:7
  deleted_at    timestamptz,                     -- M 01:6
  created_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS menu_categories_active_idx
  ON public.menu_categories(restaurant_id, sort_order) WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS public.menu_items (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  -- S-only and hard-decoded (MenuItem.swift:9): every menu fetch fails without it.
  category_id   uuid NOT NULL REFERENCES public.menu_categories(id) ON DELETE CASCADE,
  restaurant_id uuid NOT NULL REFERENCES public.restaurants(id) ON DELETE CASCADE,
  name          text NOT NULL,
  description   text,
  price         numeric(10,2) NOT NULL CHECK (price >= 0),
  image_url     text,
  is_available  boolean NOT NULL DEFAULT true,
  sort_order    int  NOT NULL DEFAULT 0,
  stock_count   int CHECK (stock_count IS NULL OR stock_count >= 0),
  deleted_at    timestamptz,                     -- M 01:5
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS menu_items_active_idx
  ON public.menu_items(restaurant_id, sort_order) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS menu_items_category_idx ON public.menu_items(category_id);

-- ===========================================================================
-- modifiers — three tables with ZERO SQL evidence anywhere in the corpus.
-- They exist only because Swift decodes them and SupabaseService embeds them
-- (C :910-930). Shapes are therefore S-only; every column here is a decision,
-- not a recovery.
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.modifier_groups (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  restaurant_id  uuid NOT NULL REFERENCES public.restaurants(id) ON DELETE CASCADE,
  name           text NOT NULL,
  is_required    boolean NOT NULL DEFAULT false,
  min_selections int NOT NULL DEFAULT 0 CHECK (min_selections >= 0),
  max_selections int NOT NULL DEFAULT 1 CHECK (max_selections >= 1),
  sort_order     int NOT NULL DEFAULT 0,
  CONSTRAINT modifier_groups_selection_range CHECK (min_selections <= max_selections)
);

CREATE TABLE IF NOT EXISTS public.modifier_options (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  -- Wire key is `group_id` (ModifierOption CodingKeys), not `modifier_group_id`.
  group_id         uuid NOT NULL REFERENCES public.modifier_groups(id) ON DELETE CASCADE,
  name             text NOT NULL,
  price_adjustment numeric(10,2) NOT NULL DEFAULT 0,
  is_available     boolean NOT NULL DEFAULT true,
  sort_order       int NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS modifier_options_group_idx ON public.modifier_options(group_id);

CREATE TABLE IF NOT EXISTS public.menu_item_modifier_groups (
  menu_item_id      uuid NOT NULL REFERENCES public.menu_items(id) ON DELETE CASCADE,
  modifier_group_id uuid NOT NULL REFERENCES public.modifier_groups(id) ON DELETE CASCADE,
  PRIMARY KEY (menu_item_id, modifier_group_id)
);

-- ===========================================================================
-- addresses
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.addresses (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id               uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  -- label/street/city are S-only, single-word wire keys that the drift tool
  -- cannot even report (its identifier regex requires an underscore). street and
  -- city are non-optional Swift String, so a missing column throws on the whole
  -- address fetch.
  label                 text NOT NULL,
  street                text NOT NULL,
  apartment             text,
  city                  text NOT NULL,
  latitude              double precision,
  longitude             double precision,
  is_default            boolean NOT NULL DEFAULT false,   -- `.order("is_default")` at C :252
  default_delivery_mode text NOT NULL DEFAULT 'hand_to_me' -- M 10:17
                          CHECK (default_delivery_mode IN ('hand_to_me','leave_at_door')),
  created_at            timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS addresses_user_idx ON public.addresses(user_id, is_default DESC);

-- ===========================================================================
-- orders
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.orders (
  id                        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  -- Resolves unknowable #6 ("was orders.user_id NOT NULL?") by decision: it is.
  -- An anon caller reaching create_order would insert auth.uid() = NULL and now
  -- fails loudly instead of creating an ownerless order.
  user_id                   uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  restaurant_id             uuid NOT NULL REFERENCES public.restaurants(id) ON DELETE RESTRICT,
  address_id                uuid REFERENCES public.addresses(id) ON DELETE SET NULL,
  courier_id                uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  status                    order_status NOT NULL DEFAULT 'created',

  subtotal                  numeric(10,2) NOT NULL CHECK (subtotal >= 0),
  delivery_fee              numeric(10,2) NOT NULL DEFAULT 0 CHECK (delivery_fee >= 0),
  tip_amount                numeric(10,2) NOT NULL DEFAULT 0 CHECK (tip_amount >= 0),
  -- R7. Unwritable by every role, so S4/S5/T1/T2's financial half is not merely
  -- forbidden, it is inexpressible: Postgres rejects the write and there is
  -- nothing to test. Note this is why create_order no longer INSERTs `total`.
  total                     numeric(10,2)
                              GENERATED ALWAYS AS (subtotal + delivery_fee + tip_amount) STORED,

  -- D2: M writes `to_jsonb(a.*)` over the whole addresses row (04:202) — 11
  -- fields — while Swift AddressSnapshot declares 6. M wins; narrowing to 6
  -- would discard data already being written. R10 makes it NOT NULL so an
  -- unresolvable or foreign address cannot produce an order at all.
  delivery_address_snapshot jsonb NOT NULL,
  notes                     text,
  created_at                timestamptz NOT NULL DEFAULT now(),
  updated_at                timestamptz NOT NULL DEFAULT now(),

  estimated_prep_time       int CHECK (estimated_prep_time IS NULL OR estimated_prep_time > 0),
  -- `estimated_delivery_time` is intentionally NOT created: D10 found it fully
  -- orphaned (no SQL, no writer, no reader in any app). Swift decodes it with
  -- decodeIfPresent, so its absence is not a decode error.

  cancellation_reason       text,
  cancellation_reason_code  text,
  cancelled_by              uuid REFERENCES public.profiles(id) ON DELETE SET NULL,

  -- The column named `verification_code` IS the pickup code; Swift maps it to
  -- `pickupVerificationCode`. Kept under the old name so the wire contract holds.
  verification_code          text,
  delivery_verification_code text,
  -- N9/R12: the defect was never the 4-digit length, it was that nothing capped
  -- attempts while courier_pickup_order / courier_deliver_order can be called in
  -- a loop. The CHECK is the backstop; the RPCs raise a typed error at 5.
  pickup_code_attempts       int NOT NULL DEFAULT 0 CHECK (pickup_code_attempts   BETWEEN 0 AND 5),
  delivery_code_attempts     int NOT NULL DEFAULT 0 CHECK (delivery_code_attempts BETWEEN 0 AND 5),

  picked_up_at              timestamptz,
  delivered_at              timestamptz,
  accepted_at               timestamptz,
  rejected_at               timestamptz,
  scheduled_for             timestamptz,

  claimed_at                   timestamptz,
  arrived_at_restaurant_at     timestamptz,
  arrived_at_customer_at       timestamptz,
  expected_action_by           timestamptz,
  eta_minutes                  int,
  courier_delay_reason_code    text,
  courier_delay_explained_at   timestamptz,
  courier_no_show_warned_at    timestamptz,
  courier_no_show_escalated_at timestamptz,

  -- D5: migrations 11/16 declared these NOT NULL DEFAULT and then COALESCEd them
  -- six times anyway — the author did not trust the declaration to have applied,
  -- which is itself evidence the live DB had diverged. Declared once here; the
  -- defensive COALESCEs are dropped from the ported RPCs so a NULL would be loud.
  reassign_count            int NOT NULL DEFAULT 0 CHECK (reassign_count >= 0),
  excluded_courier_ids      uuid[] NOT NULL DEFAULT ARRAY[]::uuid[],

  delivery_mode             text NOT NULL DEFAULT 'hand_to_me'
                              CHECK (delivery_mode IN ('hand_to_me','leave_at_door')),
  delivery_proof_url        text,

  no_show                   boolean NOT NULL DEFAULT false,
  no_show_started_at        timestamptz,
  restaurant_delay_min      int NOT NULL DEFAULT 0 CHECK (restaurant_delay_min >= 0),

  -- 18 values, verbatim from M 09:20-36. CancellationReason.swift:8-37 declares
  -- the same 18 — an exact match with no drift, the only clean agreement in the
  -- corpus.
  CONSTRAINT orders_cancellation_reason_code_valid CHECK (
    cancellation_reason_code IS NULL OR cancellation_reason_code IN (
      'CONSUMER_CHANGED_MIND','CONSUMER_DUPLICATE',
      'RESTAURANT_CLOSED','RESTAURANT_OUT_OF_ITEMS','RESTAURANT_REJECTED','RESTAURANT_TOO_LONG_WAIT',
      'COURIER_VEHICLE_ISSUE','COURIER_SAFETY_ISSUE','COURIER_RESTAURANT_CLOSED',
      'COURIER_ITEMS_UNAVAILABLE','COURIER_NON_RESPONSIVE',
      'SYSTEM_TIMEOUT','SYSTEM_FRAUD_SUSPECTED',
      'RESTAURANT_NOT_OPEN_AT_SCHEDULED_TIME','ITEM_UNAVAILABLE','INSUFFICIENT_STOCK','ITEM_DELETED',
      'CUSTOMER_NO_SHOW'
    )
  ),
  -- R8: was `text` with NO check while Swift CourierDelayReason declares 5
  -- values, so the database accepted values the client could not decode.
  CONSTRAINT orders_courier_delay_reason_valid CHECK (
    courier_delay_reason_code IS NULL OR courier_delay_reason_code IN (
      'traffic','restaurant_slow','address_unclear','customer_unreachable','other'
    )
  ),
  -- R13, weak form. The strong form is a FK to a verified `delivery_proofs` row;
  -- that needs an upload-verification path the client does not have yet, so for
  -- now this only guarantees the column is populated, NOT that the object
  -- exists. N6 is therefore reduced, not closed — see the plan's residual list.
  CONSTRAINT orders_leave_at_door_needs_proof CHECK (
    status <> 'delivered' OR delivery_mode <> 'leave_at_door' OR delivery_proof_url IS NOT NULL
  )
);
CREATE INDEX IF NOT EXISTS orders_user_idx       ON public.orders(user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS orders_restaurant_idx ON public.orders(restaurant_id, created_at DESC);
CREATE INDEX IF NOT EXISTS orders_courier_idx    ON public.orders(courier_id, updated_at DESC);
CREATE INDEX IF NOT EXISTS orders_status_idx     ON public.orders(status);
CREATE INDEX IF NOT EXISTS orders_action_sla_idx ON public.orders(expected_action_by)
  WHERE expected_action_by IS NOT NULL;

-- RealtimeService reads `change.oldRecord["status"]` at RealtimeService.swift:129,
-- :181, :220. The default replica identity ships only the primary key in the old
-- tuple, so every oldStatus would silently decode as nil and every
-- status-change-driven UI update would misfire. This line is an infrastructure
-- precondition recorded nowhere else in the corpus.
ALTER TABLE public.orders REPLICA IDENTITY FULL;

-- ===========================================================================
-- order_items
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.order_items (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id           uuid NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
  -- Nullable with ON DELETE SET NULL, verbatim from M 02:9-15: the row survives
  -- a hard-deleted menu item and the UI reads the snapshot columns instead.
  menu_item_id       uuid REFERENCES public.menu_items(id) ON DELETE SET NULL,
  -- R8/N8. There was no quantity check anywhere in 01-19, and create_order
  -- accumulated `subtotal + (mi.price * rec.quantity)` with no sign test: a cart
  -- mixing a large positive line with a negative line of a cheap item cleared
  -- the min_order gate while producing a payable subtotal far below the goods
  -- ordered, and the negative line INCREASED the restaurant's stock.
  quantity           int NOT NULL CHECK (quantity BETWEEN 1 AND 99),
  unit_price         numeric(10,2) NOT NULL CHECK (unit_price >= 0),
  total_price        numeric(10,2) GENERATED ALWAYS AS (unit_price * quantity) STORED,
  item_name          text NOT NULL,
  item_description   text,                                        -- M 02:4
  item_image_url     text,                                        -- M 02:5
  modifiers_snapshot jsonb NOT NULL DEFAULT '[]'::jsonb           -- M 02:6
);
CREATE INDEX IF NOT EXISTS order_items_order_idx ON public.order_items(order_id);

-- ===========================================================================
-- order_status_history — one table, zero SQL evidence in the corpus. It exists
-- because Swift decodes it (C :293) and because the state machine needs an audit
-- trail. Appended by trigger only (09_triggers.sql), never by a client: clients
-- hold no INSERT grant, so the trail cannot be forged or back-dated.
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.order_status_history (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id   uuid NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
  status     order_status NOT NULL,
  changed_by uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  notes      text,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS order_status_history_order_idx
  ON public.order_status_history(order_id, created_at);

-- ===========================================================================
-- courier_locations
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.courier_locations (
  -- PK is courier_id, not a surrogate id: asserted by `onConflict: "courier_id"`
  -- at C :688 and :731, and CourierLocation's CodingKeys has no `id` (its
  -- Identifiable `id` is a computed alias for courierId).
  courier_id        uuid PRIMARY KEY REFERENCES public.profiles(id) ON DELETE CASCADE,
  latitude          double precision NOT NULL,
  longitude         double precision NOT NULL,
  heading           double precision,
  speed             double precision,
  is_online         boolean NOT NULL DEFAULT false,
  current_order_id  uuid REFERENCES public.orders(id) ON DELETE SET NULL,
  -- D3: M proves nullable (`COALESCE(last_updated, now())` at 08:26) but S
  -- decodes non-optional (CourierLocation.swift:60) — a latent decode crash.
  -- NOT NULL DEFAULT now() satisfies both.
  last_updated      timestamptz NOT NULL DEFAULT now(),
  last_heartbeat_at timestamptz NOT NULL DEFAULT now(),
  last_moved_at     timestamptz NOT NULL DEFAULT now(),
  accuracy_meters   double precision,
  ghost_strikes     int NOT NULL DEFAULT 0 CHECK (ghost_strikes >= 0),
  strikes_reset_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS courier_locations_online_idx
  ON public.courier_locations(is_online, last_heartbeat_at DESC) WHERE is_online;

-- ===========================================================================
-- courier_earnings
--
-- Retained because the courier app reads it (C :844-871). NOT wired to
-- db/ledger/: that schema is verified, owned by another session, and
-- HANDOFF-for-kotlin.md is explicit that the only write path is ledger_post().
-- Superseding this table with ledger postings is a later, deliberate migration.
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.courier_earnings (
  id                       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  courier_id               uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  -- D8: M 12:96 upserts `ON CONFLICT (order_id)` but never writes the target
  -- out. order_id is the only target consistent with its DO UPDATE semantics
  -- (one earning per order), so it is declared UNIQUE here.
  order_id                 uuid NOT NULL UNIQUE REFERENCES public.orders(id) ON DELETE CASCADE,
  delivery_fee             numeric(10,2) NOT NULL DEFAULT 0,
  tip_amount               numeric(10,2) NOT NULL DEFAULT 0 CHECK (tip_amount >= 0),
  total_earned             numeric(10,2) NOT NULL DEFAULT 0,
  earning_type             text NOT NULL DEFAULT 'full',          -- M 12:18
  -- R8: was `int` with no CHECK despite migration 12's own comment documenting
  -- the domain as 0/25/50/100/-100. Unbounded is what made N2's
  -- `p_tier_override = 1000000` mint a million-fold payout; that parameter does
  -- not exist in this rebuild AND the column now has a domain.
  tier_pct                 int NOT NULL DEFAULT 100
                             CHECK (tier_pct IN (-100, 0, 25, 50, 100)),
  cancellation_reason_code text,
  status_at_event          order_status,                          -- M 12:21
  created_at               timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT courier_earnings_type_valid CHECK (                  -- M 12:27
    earning_type IN ('full','partial_assigned','partial_at_restaurant',
                     'partial_picked_up_lost','no_show_compensation',
                     'manual_adjustment','clawback')
  )
);
CREATE INDEX IF NOT EXISTS courier_earnings_courier_idx
  ON public.courier_earnings(courier_id, created_at DESC);

-- ===========================================================================
-- chat_messages
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.chat_messages (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id    uuid NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
  sender_id   uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  sender_role text,                                               -- M 15:12
  body        text NOT NULL,
  -- N5/R14: R14 moves read receipts to their own table so `body` cannot be
  -- rewritten. That would break markMessagesAsRead (C :1084) which PATCHes
  -- read_at on this row. The column stays, and immutability of `body` is
  -- achieved instead by a column-level `GRANT UPDATE (read_at)` in
  -- 11_grants.sql — the exact primitive RLS lacks. Same guarantee, no client
  -- change. The policy named `chat_messages_mark_read` finally means what its
  -- name says.
  read_at     timestamptz,
  created_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT chat_messages_sender_role_valid CHECK (              -- M 15:15
    sender_role IS NULL OR sender_role IN ('consumer','courier','merchant','system')
  )
);
CREATE INDEX IF NOT EXISTS chat_messages_order_recent_idx
  ON public.chat_messages(order_id, created_at DESC);

-- ===========================================================================
-- courier_cancellation_log — the ONE table with complete DDL in the corpus
-- (M 09:39-49). Carried over verbatim, plus the CHECK its reason_code lacked.
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.courier_cancellation_log (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  courier_id       uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  order_id         uuid NOT NULL REFERENCES public.orders(id)   ON DELETE CASCADE,
  reason_code      text NOT NULL,
  status_at_cancel order_status NOT NULL,
  created_at       timestamptz NOT NULL DEFAULT now(),
  -- The courier-permitted cancel set. Migration 09's CHECK on `orders`
  -- contained the five COURIER_* codes; RESTAURANT_TOO_LONG_WAIT is added
  -- because TransitionGuard.reassignableReason
  -- (OrderLifecycle.swift:44-47) names it as one of the three reasons a
  -- courier may cite to return an order to the pool. The two sources
  -- disagreed and the Swift guard is the specification.
  CONSTRAINT courier_cancellation_log_reason_valid CHECK (
    reason_code IN ('COURIER_VEHICLE_ISSUE','COURIER_SAFETY_ISSUE',
                    'COURIER_RESTAURANT_CLOSED','COURIER_ITEMS_UNAVAILABLE',
                    'COURIER_NON_RESPONSIVE','RESTAURANT_TOO_LONG_WAIT')
  )
);
CREATE INDEX IF NOT EXISTS courier_cancellation_log_recent_idx
  ON public.courier_cancellation_log(courier_id, created_at DESC);

-- ===========================================================================
-- inventory_movements — the stock ledger. `menu_items.stock_count` is a cached
-- balance of this table, and ravon_inventory_violations() (invariants.sql)
-- asserts the two agree.
--
-- Why a ledger rather than a flag: at 65ad66c three code paths decided, at three
-- different times, who held a unit (create_order at scheduling, the activation
-- sweep, six cancel RPCs), and they disagreed. A scheduled order that was
-- activated never got its units back, and activation clamped a would-be oversell
-- to zero with GREATEST(0, ...). Here every change to a tracked item's stock is
-- a row, and "returned twice" is a UNIQUE violation rather than a bug to find.
--
--   adjust   a merchant or operator edit of stock_count (logged by trigger, 09)
--   reserve  create_order took `-quantity` for an order, at checkout, for both
--            order-now and scheduled orders
--   release  a cancel gave the same units back; at most once per order and item
--
-- `quantity` is the signed delta applied to stock_count. There is no `consume`
-- row: a reservation that is never released is a sale.
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.inventory_movements (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  menu_item_id uuid NOT NULL REFERENCES public.menu_items(id),
  order_id     uuid REFERENCES public.orders(id),
  kind         text NOT NULL CHECK (kind IN ('adjust','reserve','release')),
  quantity     int  NOT NULL,
  created_at   timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT inventory_movements_sign CHECK (
       (kind = 'reserve' AND quantity < 0)
    OR (kind = 'release' AND quantity > 0)
    OR  kind = 'adjust'),
  CONSTRAINT inventory_movements_order_iff_not_adjust CHECK ((kind = 'adjust') = (order_id IS NULL)),
  -- Exactly once. An order reserves an item once (create_order sums duplicate
  -- cart lines first) and releases it at most once. NULL order_id (adjust rows)
  -- is outside the constraint by design.
  CONSTRAINT inventory_movements_once UNIQUE (order_id, menu_item_id, kind)
);
CREATE INDEX IF NOT EXISTS inventory_movements_item_idx ON public.inventory_movements(menu_item_id);

-- ===========================================================================
-- kitchen_slots — how many scheduled orders a restaurant has promised to start
-- in one 15-minute window. `max_concurrent_orders` bounds the live queue for
-- order-now checkouts, but scheduled orders were exempt at checkout and never
-- counted at activation, so 60 pre-orders for 18:00 all went live at 18:00
-- against a capacity of 25.
--
-- A place is taken with a conditional increment,
--   UPDATE ... SET taken = taken + 1 WHERE taken < capacity
-- which is correct even without the restaurant row lock create_order also
-- holds, and the CHECK makes a full slot unrepresentable, not merely unlikely.
-- `capacity` is copied from max_concurrent_orders when the slot is first used;
-- a later change to the restaurant does not resize existing slots.
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.kitchen_slots (
  restaurant_id uuid NOT NULL REFERENCES public.restaurants(id),
  slot_start    timestamptz NOT NULL,
  capacity      int NOT NULL CHECK (capacity > 0),
  taken         int NOT NULL DEFAULT 0,
  PRIMARY KEY (restaurant_id, slot_start),
  CONSTRAINT kitchen_slots_within_capacity CHECK (taken >= 0 AND taken <= capacity)
);

-- One row per scheduled order holding a place. `released_at` is the
-- exactly-once flag: a release flips it from NULL in the same statement that
-- decides whether to give the place back.
CREATE TABLE IF NOT EXISTS public.kitchen_slot_holds (
  order_id      uuid PRIMARY KEY REFERENCES public.orders(id),
  restaurant_id uuid NOT NULL,
  slot_start    timestamptz NOT NULL,
  released_at   timestamptz,
  FOREIGN KEY (restaurant_id, slot_start) REFERENCES public.kitchen_slots(restaurant_id, slot_start)
);
