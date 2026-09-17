# Security by construction — translating the two gstack reports into rebuild invariants

Scope: both files in `.gstack/security-reports/` read in full, all 19 files in
`.context/migrations/`, `Sources/RavonCore/Services/*`, `scripts/scan_secrets.py`,
`.github/workflows/ci.yml`. Every claim below is cited to `file:line`. Where the answer
requires the live database, it is marked **UNKNOWN — needs live introspection** rather than
guessed, because the project is gone.

Both report files and the entire `.context/` tree are **untracked**: `.gitignore:9` ignores
`.context/`, `.gitignore:10` ignores `.gstack/` (verified with `git check-ignore -v`;
`git ls-files .context .gstack` returns nothing). The migrations are not in git history, so
there is no way to recover a version of them from a commit.

---

## 0. Corrections to the brief — read this first

`.context/PROMPT-kotlin-backend.md:186` states: *"Security findings S1/S2/S3 from
`.gstack/security-reports/` were never patched."* That is wrong in four separate ways, and
two of the errors matter more than the original findings.

**C1. S1 was patched, and then re-opened in the same PR by a different mechanism.**
`19_lock_down_profile_role.sql` closes the UPDATE vector the report described
(`19_lock_down_profile_role.sql:34-39`). But `18_handle_new_user_trigger.sql:26` copies
`role` straight out of `auth.users.raw_user_meta_data` into `public.profiles.role`, and
`Sources/RavonCore/Services/AuthService.swift:63-72` supplies it:

```swift
try await client.auth.signUp(
    email: email, password: password,
    data: ["full_name": .string(fullName),
           "role": .string(role.rawValue)]   // ← client picks its own role
)
```

So the outcome the CRITICAL described — *any user becomes a merchant* — survives, and the
new path is **strictly easier** than the one that was closed: it is one unauthenticated
`POST /auth/v1/signup` with the anon key, needs no session, and the privileged value is
written before any trigger can object. See §3 for the full analysis. Saying "never patched"
understates this; the correct statement is "patched at the wrong layer, and the patch's own
PR shipped a better exploit."

**C2. S2 was partially patched — the half that was patched is the half nothing depends on.**
Four migrations were rewritten to key off `restaurants.owner_id`:
`01_menu_soft_delete_and_category_availability.sql:43`, `:64`,
`05_set_accepting_orders_with_until.sql:22`, `15_chat_rls_and_sender_role.sql:54`, `:70`.
But (a) **no migration in 01–19 adds that column** — `grep "ADD COLUMN.*owner" *.sql`
returns nothing, so migrations 01/05/15 reference a column their own migration set never
creates; and (b) the merchant policies on `orders`, `restaurants`, `restaurant_hours`,
`modifier_groups`, `modifier_options` — the ones the exploit scenario actually used — were
never touched. The merchant order-transition path is still a direct table UPDATE
(`Sources/RavonCore/Services/SupabaseService.swift:393-447`), so it still rides entirely on
those unfixed policies.

**C3. S3 was not patched, and provably could not have been from this repo.**
`grep -i "REVOKE" .context/migrations/*.sql` returns **zero matches**. Two of the three
functions named in S3 (`find_nearby_couriers`, `auto_cancel_stale_orders`) exist in no
migration at all — they were dashboard-created, corroborated by
`.context/architecture/12-BACKEND-INVENTORY.md:28`. The third, `fetch_available_orders`, was
re-created at `13_courier_status_transition_rpcs_v2.sql:715` with `CREATE OR REPLACE` at an
unchanged signature — and the migration says so out loud at `:713`
("*We re-create with the same signature; original lives in earlier migration*").
`CREATE OR REPLACE FUNCTION` **preserves the existing ACL**; only `DROP` + `CREATE` resets
it. So the `anon` EXECUTE grant S3 identified survived migration 13 as a direct consequence
of how the migration was written.

**C4. Two findings the brief omits were in fact fixed, so the brief is pessimistic as well as
optimistic in the wrong places.** Report-1 finding 4's secondary claim (*"the cancelOrder
Swift function is broken"*) is fixed — `SupabaseService.swift:632-637` now calls the
`cancel_order_by_consumer` RPC. Report-1 finding 6's client-side code comparison is fixed —
`SupabaseService.swift:456-460` calls `courier_pickup_order`, which compares server-side at
`13_courier_status_transition_rpcs_v2.sql:284`. Note the report's line anchor for finding 6
(`SupabaseService.swift:276-293`) is **stale**: those lines are now `fetchOrders` /
`fetchOrder`.

**C5. The second report's `"critical": 0` is a false negative, not a fix record.**
`2026-04-04-120000.json` ran `scope: "full"`, `phases_run: [0,1,2,3,5,6,7,8,9,10,11,12,13,14]`
and reported `totals.critical = 0`. Migration 19 — the only thing that ever addressed a
CRITICAL — has mtime `May 4 22:15`, a month *after* that run. So all four CRITICALs were
open on 2026-04-04 and the comprehensive run found none of them
(`filter_stats`: 12 scanned, 6 hard-exclusion filtered, 3 confidence-gate filtered).
Its `trend` block compounds this: it claims `resolved: 0, persistent: 0, new: 3,
direction: "first_comprehensive_run"`, yet its findings 1 and 2 are the same two order-UPDATE
policies as report-1 findings 4 and 5 — counted "new" only because the fingerprints differ
(`a01-consumer-order-financial-tampering` → `a01-orders-consumer-update-columns`;
`a01-courier-order-financial-tampering` → `a01-orders-courier-update-unrestricted`).
Fingerprint-keyed trend tracking silently loses persistence across a re-word.
**Rule for the rebuild: a scanner's totals block is never evidence of a fix. Only an
assertion that fails the build is.**

**C6. The brief's own prescription is right but names the wrong primitive.**
`.context/PROMPT-kotlin-backend.md:187` says "no client write policies on `orders` at all."
A policy is only ever reached if the table-level `GRANT` exists. Dropping policies leaves
the grant in place and the next `CREATE POLICY` re-opens the hole. The load-bearing
primitive is the **missing GRANT**, not the missing policy. Same for functions: the Postgres
default is `EXECUTE TO PUBLIC` on every newly created function, so *omitting* a
`GRANT ... TO anon` grants nothing and forbids nothing — see §2.

---

## 1. Complete finding inventory

Nine findings across the two reports. `S1`–`S6` = `2026-03-23-214500.json` findings 1–6
(this is the numbering the brief's "S1/S2/S3" refers to; report-2 findings are `T1`–`T3`).

### S1 — CRITICAL — `profiles` role self-escalation
- **Fingerprint** `a01-profiles-role-self-escalation`, confidence 9, "independently verified".
- **Object**: `profiles` UPDATE policy (name not recorded).
- **Mechanism**: policy asserts `auth.uid() = id` with no column restriction. Postgres RLS
  cannot restrict columns, so `PATCH /rest/v1/profiles?id=eq.<self>` with `{"role":"merchant"}`
  passes. Every merchant policy then applies.
- **Patched?** **Partially, then re-opened.** `19_lock_down_profile_role.sql:34-39` adds a
  `BEFORE UPDATE` trigger raising `42501` when `NEW.role IS DISTINCT FROM OLD.role`, gated
  `WHEN (auth.uid() IS NOT NULL AND auth.uid() = OLD.id)`. This does close the PATCH vector.
  It does not close the signup vector (§3), and it has two structural weaknesses:
  1. **The trigger is fail-open on cross-row updates.** The `WHEN` clause requires
     `auth.uid() = OLD.id`. Any path that lets a caller update *someone else's* profile row
     skips the trigger entirely and can change `role` freely. Whether such a policy existed
     is **UNKNOWN — needs live introspection**, but report-1 finding 2 establishes that
     merchant policies were written as bare `role = 'merchant'` checks, so the shape is not
     hypothetical.
  2. **Its stated rationale is factually wrong.** `19_lock_down_profile_role.sql:9-11` claims
     "*RPCs running with elevated privileges execute with `auth.uid() = NULL`*". `SECURITY
     DEFINER` changes `current_user`; it does not reset the `request.jwt.claims` GUC that
     `auth.uid()` reads. Inside a SECURITY DEFINER RPC invoked by a user, `auth.uid()` is
     still that user. The error happens to fail *safe* here (more rows covered than intended)
     but it is the kind of belief that produces an unsafe design next time.

### S2 — CRITICAL — merchant horizontal escalation, no ownership check
- **Fingerprint** `a01-merchant-horizontal-escalation-no-ownership`, confidence 9.
- **Object**: 11 policies across 8 tables — `restaurants`, `menu_items`, `orders`,
  `restaurant_hours`, `modifier_groups`, `modifier_options` (report names 6 explicitly).
- **Mechanism**: policies check `profiles.role = 'merchant'` and nothing else; the report
  states `restaurants` had **no `owner_id`/`merchant_id` column at all**. Any merchant reads
  competitors' orders with customer PII, rewrites their prices, and shuts off their order
  acceptance.
- **Patched?** **Partially — see C2.** Four call sites switched to `owner_id = auth.uid()`;
  the column is created by no tracked migration; the `orders`/`restaurants` merchant policies
  were never rewritten; `SupabaseService.swift:393-447` (accept/prepare/reject/ready) and
  `:641-658` (`assignCourier`) still write `orders` directly and therefore still depend on
  them. `assignCourier` is the sharpest surviving case: it sets an arbitrary `courier_id`, and
  a courier cannot use it (the courier policy's `USING auth.uid() = courier_id` fails on a
  row where `courier_id IS NULL`), so it works *only* for the actor whose policy has no
  ownership check.

### S3 — CRITICAL — anon-callable SECURITY DEFINER RPCs
- **Fingerprint** `a01-anon-security-definer-rpc-access`, confidence **10**, "independently
  verified (10/10)" — the highest-confidence finding in either report.
- **Objects**: `find_nearby_couriers`, `fetch_available_orders`, `auto_cancel_stale_orders`.
- **Mechanism**: `EXECUTE` granted to `anon`; `SECURITY DEFINER` bypasses RLS; no
  `auth.uid()` check inside. Anyone holding the anon key (extractable from any of the three
  iOS binaries) gets live courier GPS, consumer home addresses out of
  `delivery_address_snapshot`, and can cancel pending orders.
- **Patched?** **No — see C3.** Zero REVOKEs exist. Two of the three functions are not in the
  repo. The third survived by `CREATE OR REPLACE`.
- **What makes it worse than the report says**: `fetch_available_orders` v2 returns
  `SETOF orders` (`13:719`) — *every column*, which by migration 10 includes
  `verification_code` and `delivery_verification_code`. It has no `auth.uid() IS NULL` gate
  and no role check. Its only caller-dependent predicate is
  `NOT (auth.uid() = ANY(COALESCE(o.excluded_courier_ids, ARRAY[]::uuid[])))` (`13:730`).
  For an anon caller `auth.uid()` is NULL, and `NULL = ANY(ARRAY[]::uuid[])` evaluates to
  **false** (not NULL) on an empty array, so `NOT false` = true. Precise blast radius: **an
  unauthenticated caller receives every unclaimed order that has never been reassigned, with
  both verification codes and the consumer's address snapshot.** Orders with a non-empty
  `excluded_courier_ids` array evaluate to NULL and are filtered out — which is the only
  reason the leak is not total.

### S4 — CRITICAL — consumer can zero out order totals
- **Fingerprint** `a01-consumer-order-financial-tampering`, confidence 9, "self-verified".
- **Object**: `orders` UPDATE policy "Consumers can cancel own orders".
- **Mechanism**: `WITH CHECK (auth.uid() = user_id AND status IN ('created','accepted'))`
  validates a *value*, not a *column set*. `PATCH` with `{"subtotal":0,"delivery_fee":0,
  "total":0}` leaves `status` untouched, so the check passes.
- **Patched?** **The client path was; the hole was not.** `cancelOrder` now uses the RPC
  (`SupabaseService.swift:632-637`), so the report's secondary complaint is fixed. No
  migration drops or narrows the policy, and no migration revokes `UPDATE ON orders` from
  `authenticated`. Re-found 12 days later as **T1**.

### S5 — HIGH — courier can inflate tips and totals
- **Fingerprint** `a01-courier-order-financial-tampering`, confidence 9.
- **Object**: `orders` UPDATE policy "Couriers can update assigned orders"
  (`qual` and `with_check` both bare `auth.uid() = courier_id`).
- **Mechanism**: no column restriction → `tip_amount`, `delivery_fee`, `total`, `subtotal`
  writable; the `create_courier_earning` trigger then computes earnings from the tampered
  values.
- **Patched?** **No.** Every *courier* transition did move to an RPC
  (`13:741-752`; Swift `:451-460`, `:759-770`), which removes the app's *need* for the
  policy — but the policy and the underlying grant were never removed, so the direct REST
  path is untouched. Re-found as **T2**, which adds that `status` is writable too, so a
  courier can jump straight to `delivered` and skip pickup.

### S6 — HIGH — verification code is client-side and courier-readable
- **Fingerprint** `a04-verification-code-client-side-bypass`, confidence 9, "self-verified".
- **Object**: `SupabaseService.swift:276-293` (anchor now stale) + `orders.verification_code`.
- **Mechanism**: three parts. (a) compare client-side; (b) the code is in the courier's
  SELECT projection; (c) `random()`, 4 digits.
- **Patched?** **One of three.** (a) is fixed: `courier_pickup_order` compares server-side
  (`13:284`). (b) is **not** fixed — the courier still reads the code, via
  `fetch_available_orders` returning `SETOF orders` (`13:719`) and via
  `fetchAvailableOrders()` doing a bare `select("*, …")` on `orders`
  (`SupabaseService.swift:773-781`). (c) is **not** fixed —
  `10_dual_verification_codes_and_delivery_mode.sql:38` and `:41` still read
  `lpad(floor(random() * 9000 + 1000)::text, 4, '0')`, and migration 10 *added a second*
  code on the same basis. **A secret the challenged party can read is not a secret**, so
  moving the comparison server-side without removing the code from the courier's projection
  changes nothing about the attack.

### T1 — HIGH — consumer order financial fields (re-find of S4)
`a01-orders-consumer-update-columns`. Verification note is the strongest evidence in either
report: *"independently verified via live pg_policies query — WITH CHECK only validates
status column, not total/subtotal/delivery_fee"*. Widens the affected status set to
`created, accepted, preparing, ready, assigned, courier_arrived_restaurant`. Not patched.

### T2 — HIGH — courier can modify any column (re-find of S5)
`a01-orders-courier-update-unrestricted`. *"independently verified via live pg_policies
query — WITH CHECK only validates courier_id, no column or status restrictions."*
Not patched.

### T3 — MEDIUM — storage buckets have no size or MIME limits
- **Object**: `storage.buckets` rows `restaurant-images`, `menu-item-images`; both
  `file_size_limit IS NULL` and `allowed_mime_types IS NULL`, verified by live query.
- **Mechanism**: the only validation is client-side (`SupabaseService.swift:1429-1444`:
  5 MB + an extension allowlist), bypassable by calling the Storage API directly.
- **Patched?** **No**, and the finding is **incomplete**: there is a **third** bucket,
  `delivery-proofs` (`SupabaseService.swift:623`), with a client-only 500 KB check at `:620`
  and a comment at `:617` conceding "*server-side check is added in v2*". Neither report
  covers it.

---

## 2. New findings — defects in the catalogued objects that neither report reached

These matter more than the nine above, because the rebuild will be graded on whether the
*class* is impossible, not whether the nine instances are gone.

### N1 — `reassign_ghosted_order(uuid)` has no authorization check whatsoever — CRITICAL
`13_courier_status_transition_rpcs_v2.sql:651-709` is `SECURITY DEFINER` (`:654`), granted
to `authenticated` (`:751`), takes only `p_order_id`, and contains **no `auth.uid()`
reference at all**. Any authenticated user (a freshly-signed-up consumer) can, for any order
in `assigned` or `courier_arrived_restaurant`: strip its `courier_id` (`:689`), mint a
partial earning against the evicted courier (`:670-672`), add that courier to
`excluded_courier_ids` (`:700`), and increment `reassign_count`. **Three calls** trip `:677`
and the order becomes `cancelled_by_system` (`:679`). This is a one-line-per-order denial of
service against the entire marketplace, requiring nothing but a free account. It is a
strictly worse version of the S3 `auto_cancel_stale_orders` concern and no report found it.

### N2 — `insert_courier_earning_for_cancel` takes an unbounded tier override — CRITICAL if reachable
`12_tiered_earnings_columns_and_helpers.sql:61-101`, `SECURITY DEFINER` (`:70`), no
`auth.uid()` reference. Parameters include `p_tier_override int` (`:66`) and
`p_earning_type_override text` (`:67`), and `:84` computes
`v_amount := round((v_delivery_fee * v_tier / 100.0)::numeric, 2)` with no bound on
`v_tier`. `p_tier_override = 1000000` mints a million-fold payout. `:94` even makes it
idempotent-by-overwrite (`ON CONFLICT (order_id) DO UPDATE`), so it cleanly rewrites an
existing earning rather than erroring.
Migration 12 grants only `earnings_tier_for_cancel` and `earning_type_for_status` (`:103-104`)
— but **omitting a GRANT does not deny access**: Postgres grants `EXECUTE` to `PUBLIC` on
every newly created function by default, and Supabase's bootstrap additionally runs
`ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON FUNCTIONS TO anon, authenticated`.
Whether either applied to this function in the deleted project is
**UNKNOWN — needs live introspection**; what is certain from the files is that nothing in
migrations 01–19 revokes it. **This is the single strongest argument for rule R6 below:** the
codebase's entire access-control model for functions is "we only wrote the GRANTs we meant,"
which is not an access-control model.

### N3 — `activate_scheduled_order(uuid)` has no authorization check — HIGH
`06_scheduled_orders.sql:21-83`, `SECURITY DEFINER` (`:24`), granted to `authenticated`
(`:107`), no `auth.uid()` reference. Any authenticated user can force-activate any other
user's scheduled order — decrementing the restaurant's stock at `:77` — or, when the
restaurant is closed at the scheduled time, force it to `cancelled_by_system` (`:41-44`).
Scheduled orders are exactly the rows nobody is watching.

### N4 — cron sweep functions are exposed as client RPCs — HIGH
`run_courier_escalation_ladder()` granted to `authenticated` at
`14_courier_escalation_ladder_cron.sql:114` and re-granted at
`17_system_messages_sender_role_fix.sql:284`; `mark_no_show_deliveries()` granted at
`16_no_show_and_restaurant_delay.sql:138`. Both are whole-table sweeps that write `orders`,
`chat_messages`, `courier_locations` and `profiles.is_suspended_until`
(`17:103`) for rows the caller has no relationship to. Their SLA predicates make them
mostly idempotent, which limits the damage — but a batch job's authorization model should
not be "the WHERE clause happens to be narrow." Same class as S3's
`auto_cancel_stale_orders`, and the S3 recommendation ("should be service_role only") was
never generalised to the other sweeps.

### N5 — `chat_messages` UPDATE policy permits body rewriting — HIGH
`15_chat_rls_and_sender_role.sql:80-97`. The policy is named `chat_messages_mark_read` and
the comment at `:79` says "*only mark messages NOT sent by self as read (set read_at)*" —
but `USING` and `WITH CHECK` assert only `sender_id <> auth.uid()` plus order
participation. **No column restriction.** A courier can rewrite the consumer's message
`body`, or set `sender_role`, on any message in any order they are party to. `body` is the
dispute evidence. This is the same defect class as S4/S5/T1/T2 on a table neither report
examined, and the policy's own name asserts a guarantee it does not implement.

### N6 — photo proof of delivery is validated by string length — HIGH
`13_courier_status_transition_rpcs_v2.sql:412`:
`IF p_delivery_proof_url IS NULL OR length(p_delivery_proof_url) < 4 THEN … MISSING_PROOF_IMAGE`.
For `delivery_mode = 'leave_at_door'` this is the *entire* proof requirement. A courier
calls `courier_deliver_order(order_id, NULL, 'xxxx')`, the order becomes `delivered`
(`:419`), and the `create_courier_earning` trigger pays full fare — with no photo uploaded
and nothing having been delivered. Nothing binds the string to an object that exists in the
bucket, to this order, or to this courier. The uploader (`SupabaseService.swift:618-628`)
returns a path and the comment at `:625-626` concedes the bucket's access model is unfinished.

### N7 — `create_order` snapshots any address it is handed — HIGH
`04_create_order_v3_and_validate_cart.sql:202`:
`SELECT to_jsonb(a.*) INTO addr_snapshot FROM addresses a WHERE a.id = p_address_id;`
inside a `SECURITY DEFINER` function (`:136`), so RLS on `addresses` does not apply. There
is **no ownership predicate** and no `NOT FOUND` handling. Anyone who learns another user's
address UUID gets that user's full address row — street, apartment, coordinates,
`default_delivery_mode` — snapshotted into their own order at `:246` and readable back
through their own orders SELECT policy. A bogus UUID silently produces an order with a NULL
address snapshot. This is the same PII class S3 flagged, reachable by an authenticated user
without touching any anon grant.

### N8 — no quantity or money domain constraints anywhere — HIGH
`grep -i "CHECK (\|ADD CONSTRAINT" .context/migrations/*.sql` yields exactly five
constraints: `cancellation_reason_code_valid` (09:20), `courier_earnings_type_valid`
(12:27), `chat_messages_sender_role_valid` (15:15), `addresses_delivery_mode_valid` (10:20),
`orders_delivery_mode_valid` (10:29). **There is no `CHECK (quantity > 0)` on
`order_items`, no non-negativity check on `subtotal`/`total`/`delivery_fee`/`tip_amount`,
and no constraint tying `total` to its components.** `create_order` accumulates
`subtotal := subtotal + (mi.price * rec.quantity)` at `04:227` with no sign check and
decrements stock by the same quantity at `04:268`. A cart mixing a large positive line with
a negative line of a cheap item clears the `min_order_amount` gate at `04:230` while
producing a payable subtotal far below the goods ordered — and the negative line *increases*
the restaurant's stock. This is why S4/S5/T1/T2 are data-model findings rather than policy
findings: even with perfect write policies, the *server's own* order-creation path cannot
produce a wrong total only by accident, not by construction.

### N9 — verification codes are `random()`, 4 digits, unlimited attempts
`10:38`, `10:41`. S6's recommendation 3 was never applied. `random()` is a seeded PRNG, not
a CSPRNG. 9,000 values. Nothing in any migration caps attempts, and `courier_pickup_order`
(`13:258`) / `courier_deliver_order` (`13:374`) can be called in a loop. The length is not
the defect; the **absent attempt counter** is.

### N10 — `restaurants_orderable` is an RLS-bypassing view granted to `anon`
`03_orderability_function_and_view.sql:73-77` creates `SELECT r.*` over `restaurants` with
**no `WITH (security_invoker = true)`**, and `:79` runs
`GRANT SELECT ON restaurants_orderable TO authenticated, anon`. A view without
`security_invoker` executes with the *view owner's* privileges, so RLS on `restaurants` does
not apply through it, and `r.*` means every column. Any holder of the anon key reads every
column of every active restaurant row. Migration 03 also grants three `SECURITY DEFINER`
functions to `anon` explicitly (`:152-154`) — these are *additional* anon-reachable
SECURITY DEFINER functions that S3 did not enumerate.

### N11 — `search_path = public` in every SECURITY DEFINER function is hijackable
Every definer function sets `SET search_path = public` (or `public, extensions` —
`13:24`, `13:81`, `13:723`). If `authenticated` holds `CREATE ON SCHEMA public` — which
Supabase's bootstrap `GRANT ALL ON SCHEMA public TO anon, authenticated` would provide — a
user can create a function or operator in `public` that an unqualified reference inside a
definer function resolves to, executing attacker code as the function owner. Whether that
grant existed is **UNKNOWN — needs live introspection**. The migrations' own hardening note
(`.context/migrations/README.md:138-141`) shows the author treated `search_path` as a
lint item to satisfy (`function_search_path_mutable`) rather than as a privilege boundary;
setting it to `public` satisfies the linter and preserves the hijack.

### N12 — the CI secret scanner cannot see a current-format Supabase secret key
`scripts/scan_secrets.py` matches two patterns: a JWT shape (`:25`) and `sbp_[A-Za-z0-9]{40}`
(`:27`). `grep "sb_secret\|sb_publishable" scripts/scan_secrets.py` returns nothing across
all 117 lines. Supabase's current API keys are `sb_publishable_…` / `sb_secret_…` — **not
JWTs** — so a leaked `sb_secret_` key passes the `Secret scan` CI job (`.github/workflows/ci.yml:83-94`)
clean. The docstring at `:25` also asserts "*Supabase anon/service keys are always HS256
JWTs*", which is false: signing is ES256 over a published JWKS (verified live this session).
The regex tolerates the alg error, but the missing key format is a live gap in the one CI
gate that exists for exactly this.

---

## 3. Focus question: is `role` still read from user metadata? (migrations 18 / 19)

**No, migration 19 does not close it.** Full chain, each link cited:

1. `AuthService.signUp` sends `data: ["role": .string(role.rawValue)]`
   (`Sources/RavonCore/Services/AuthService.swift:63-72`). GoTrue writes `data` verbatim
   into `auth.users.raw_user_meta_data`.
2. `18_handle_new_user_trigger.sql:36-38` fires `AFTER INSERT ON auth.users`.
3. `18_handle_new_user_trigger.sql:26`:
   `COALESCE((NEW.raw_user_meta_data->>'role')::user_role, 'consumer'::user_role)`
   — the client-supplied string is cast and inserted into `public.profiles.role`.
4. `19_lock_down_profile_role.sql:35-39` only guards `BEFORE UPDATE`. An INSERT by the
   trigger is not an UPDATE, and the trigger's `WHEN (auth.uid() = OLD.id)` would not fire
   during the auth-row insert anyway.
5. `AuthService.loadUserRole()` (`:41-54`) then reads `profiles.role` and the apps gate on
   it. The app faithfully trusts a database column that faithfully trusts the signup payload.

The exploit is `POST /auth/v1/signup` with the anon key and
`{"email":…,"password":…,"data":{"role":"merchant"}}` — reachable from curl, no session, no
app. Migration 19 relocated S1 from "escalate after signup" to "declare at signup," which is
cheaper for the attacker. The 19-vs-18 pairing is the cleanest possible illustration of the
project's own thesis at `.context/architecture/`: *every fleet bug is an unenforced
contract.* The contract "a user does not choose their own role" was written in a comment
(`18:9-11` describes the metadata read approvingly) and enforced nowhere.

Two second-order consequences worth carrying into the rebuild:

- **`role` also lands in the JWT.** GoTrue mirrors `raw_user_meta_data` into the access
  token's `user_metadata` claim, and `PUT /auth/v1/user` with `{"data":{"role":…}}` lets the
  user rewrite it at any time. Nothing in this repo reads it — verified:
  `grep "auth.jwt\|user_metadata\|app_metadata" .context/migrations/*.sql Sources/ Tests/`
  matches only migration 18's own comments and body. That is luck, not design. In the
  Kotlin service it must be structurally impossible (rule R18).
- **Migration 19 also blocks legitimate demotion.** Because the trigger fires for *any*
  owner-initiated role change and there is no admin surface in the fleet, a user who
  signed up as `merchant` by mistake cannot be corrected through the app. A security control
  with no authorized-exception path gets disabled under operational pressure.

---

## 4. Focus question: which catalogued functions would an unauthenticated PostgREST caller reach?

The honest answer has two layers, and the second is the one that matters.

**Layer 1 — explicit `anon` grants (verifiable from the files).** Four objects, all in
migration 03:

| Object | Grant | Definer? | What an anon caller gets |
|---|---|---|---|
| `restaurants_orderable` (view) | `03:79` | owner-privileged, no `security_invoker` (`03:73`) | every column of every `active` restaurant, RLS bypassed (N10) |
| `restaurant_within_hours(uuid,timestamptz)` | `03:152` | `03:13` | probe any restaurant's open/closed state; oracle over `restaurant_hours` |
| `restaurant_is_orderable(uuid,timestamptz)` | `03:153` | `03:62` | same, plus `is_accepting_orders` |
| `get_restaurant_orderability(uuid,timestamptz)` | `03:154` | `03:90` | structured reason + `accepting_orders_until` for any restaurant |

Plus the three S3 functions whose grants are not in the repo: `find_nearby_couriers` (live
courier GPS), `fetch_available_orders` (see the precise NULL-semantics analysis in §1/S3 —
every never-reassigned unclaimed order, with both verification codes and the consumer's
address snapshot), `auto_cancel_stale_orders` (cancel pending orders).

**Layer 2 — the default-privilege problem, which is the real finding.** Postgres grants
`EXECUTE` to `PUBLIC` on every newly created function; Supabase's bootstrap additionally
sets `ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON FUNCTIONS TO anon,
authenticated`. **Zero REVOKE statements exist in migrations 01–19.** Therefore the
migrations provide no evidence that *any* of the ~34 functions was unreachable by `anon`,
and the `GRANT ... TO authenticated` lines throughout are decorative — they grant a
privilege the role would have had anyway and restrict nothing.

Ranked by what an anon caller could do if Layer 2 held (all `SECURITY DEFINER`, all
RLS-bypassing):

1. `insert_courier_earning_for_cancel` (`12:61`) — mint arbitrary money (N2).
2. `reassign_ghosted_order` (`13:651`) — destroy any active order in 3 calls (N1).
3. `activate_scheduled_order` (`06:21`) — activate or cancel anyone's scheduled order (N3).
4. `run_courier_escalation_ladder` (`14:18`, `17:18`) / `mark_no_show_deliveries` (`16:49`) /
   `activate_scheduled_orders` (`06:86`) — drive the marketplace's batch state machine (N4).
5. `fetch_available_orders` (`13:715`) — bulk PII + verification codes.
6. `compute_eta_minutes` (`13:19`) — confirms a courier is assigned and leaks distance, i.e.
   a coarse locator for any order id.
7. `validate_cart` (`04:6`) / `create_order` (`04:127`) — `create_order` inserts
   `user_id = auth.uid()`, which is NULL for anon; whether that fails depends on whether
   `orders.user_id` is `NOT NULL` — **UNKNOWN — needs live introspection**. If nullable, anon
   creates ownerless orders. `04:202` additionally leaks any address row (N7).
8. `set_accepting_orders` (`05:7`) — safe, and instructive: it is the **one** function in the
   set with a real ownership check (`05:20-27`), which is why it resists anon.
9. `earnings_tier_for_cancel`, `earning_type_for_status` (`12:35`, `12:47`) — pure functions,
   harmless.
10. `handle_new_user` (`18:15`), `profiles_block_role_change` (`19:18`),
    `generate_verification_code` (`10:34`), `set_chat_sender_role` (`15:23`),
    `sync_order_delivery_mode_from_address` (`10:55`) — return `trigger`; a direct call errors
    out. Not a vector.

The correct conclusion is not "revoke these seven." It is: **reachability must be a property
of the schema, not of a per-function grant audit that a future `CREATE FUNCTION` silently
defeats.** That is R6 and R7.

---

## 5. Focus question: over-broad UPDATE on `orders`

Four of the nine findings (S4, S5, T1, T2) are one defect: `orders` has table-level
`UPDATE` granted to `authenticated`, and both RLS policies constrain *which rows* without
constraining *which columns*. Postgres RLS has no column dimension — a `WITH CHECK` can only
assert a predicate over the candidate row — so **no policy rewrite can fix this.** T1's
verification note names it exactly: *"WITH CHECK only validates status column, not
total/subtotal/delivery_fee."*

The three real remedies, in increasing strength:

1. `REVOKE UPDATE (total, subtotal, delivery_fee, tip_amount) ON orders FROM authenticated`
   — column-level revoke, which is the mechanism RLS lacks. Nothing in 01–19 does this.
2. `REVOKE UPDATE ON orders FROM anon, authenticated` entirely, with every transition
   behind a definer RPC. Migration 13 built the RPCs (`:741-752`) and Swift adopted them for
   consumer and courier — but the grant was never withdrawn, so the RPCs became an
   *additional* path rather than the *only* path, and the merchant path
   (`SupabaseService.swift:393-447`, `:641-658`) never migrated at all.
3. Make the money columns unwritable by anyone, including the server — a generated column.
   That is R3, and it is the only version that survives a mistake in the Kotlin service.

The general lesson, stated so it transfers: **an RLS policy is a row filter. Any invariant
about columns, sums, or transitions must live in a GRANT, a CHECK, a generated column, or a
constraint trigger.** Every one of the nine findings except S3 and T3 is an instance of
writing a column invariant into a row filter.

---

## 6. Focus question: the anon key vs the `service_role` key

`CLAUDE.md` already states the policy correctly, and RavonCore complies: there are no
credentials in the package (`grep "eyJ\|supabase.co\|service_role" Sources/ Package.swift`
matches only the doc-comment placeholders at `RavonConfig.swift:16-17`), config is injected
via `RavonCore.configure()` (`RavonConfig.swift:20-24`), and `.gitignore:19-30` blocks
`.env`, `Secrets.*`, `*.local.xcconfig` and `*service_role*`.

The framing that should carry into the rebuild:

- **The anon / publishable key is public client config, not a secret.** It is in three App
  Store binaries. Rotating it costs three releases and buys nothing. Therefore **every
  policy, grant and RPC reachable with it must be safe against direct API access with no
  app involved** — which is precisely the assumption S3, T1 and T2 all found violated (each
  exploit scenario begins "extract the anon key from the binary"). Treating it as a secret is
  the error that makes S3 feel survivable.
- **The `service_role` / `sb_secret_` key is a different kind of object.** It bypasses RLS
  by design and is a bearer token: it carries no network binding, so a copy in a log line, a
  crash report, a CI artifact or an agent transcript is full database access. It must exist
  only in the Kotlin service's runtime environment. It must never be used *by* the Kotlin
  service to reach PostgREST either (see §7) — a dedicated Postgres role is strictly
  better, because it supports column-level grants and network pinning, which a
  `service_role` key cannot express at all.
- **Enforcement gap to close (N12):** extend `scripts/scan_secrets.py` with
  `sb_secret_[A-Za-z0-9]{20,}` (fail) and `sb_publishable_[A-Za-z0-9]{20,}` (allow, so the
  distinction is asserted rather than assumed), keep the JWT `role`-claim decode for legacy
  keys, and correct the HS256 docstring at `:25`.
- **JWT revocation lag is ~20 minutes** (10 min Supabase edge JWKS cache + up to 10 min
  client-lib cache, verified live this session). So a suspended courier's token keeps
  verifying. The Kotlin interceptor must therefore treat a valid signature as *identity
  only* and re-check authorization state (suspension, role, ownership) from the database on
  every privileged call. This is R18, and it also fixes the class that
  `profiles.is_suspended_until` (`08:38`) currently addresses only inside individual RPCs
  (`13:96`, `13:169`).

---

## 7. By-construction rules for the rebuild

Each rule states the invariant, what makes it hold, and which findings become
unexpressible. "CI assertion" means the missing 6th job in §8.

### Access reachability

**R1 — Role is never client input.**
`profiles.role` (or its Kotlin-side equivalent) is writable only by an operator role. No
trigger anywhere reads `raw_user_meta_data` or `user_metadata`. Merchant and courier roles
require an approved application row, not a signup field.
*Enforced by*: (a) **missing GRANT** — `REVOKE INSERT ON profiles FROM anon, authenticated`
and no `UPDATE (role)` column grant to any client role; (b) **CI assertion** —
`has_table_privilege('authenticated','profiles','INSERT')` is false,
`has_column_privilege('authenticated','profiles','role','UPDATE')` is false, and no row in
`pg_proc` has a body matching `raw_user_meta_data|user_metadata`; (c) **Kotlin type** — the
JWT interceptor returns `Principal(userId: UserId)` with **no role field**; a `Role` is
obtainable only from `RoleRepository.load(userId)`. A developer cannot accidentally trust a
claim that the principal type does not carry.
*Kills*: S1, and the §3 relocation of it.

**R2 — Clients hold no write privilege on transactional tables.**
`orders`, `order_items`, `order_status_history`, `courier_earnings`, `ledger_entries` grant
`INSERT`/`UPDATE`/`DELETE` to **no** client role. RLS on those tables governs reads only and
becomes defence-in-depth, exactly as `.context/PROMPT-kotlin-backend.md:56` intends.
*Enforced by*: **missing GRANT**, plus **CI assertion** that
`has_table_privilege('{anon,authenticated}', t, '{INSERT,UPDATE,DELETE}')` is false for every
table on a checked-in list. A future `CREATE POLICY` then cannot re-open anything, because
there is no grant for the policy to qualify.
*Kills*: S4, S5, T1, T2 — and makes the C6 distinction structural.

**R3 — Every SECURITY DEFINER function is unreachable by default.**
Baseline in the first schema file:
```sql
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC, anon, authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC, anon, authenticated;
```
then grant per-function from a checked-in allowlist.
*Enforced by*: **CI assertion** iterating `pg_proc` — for every function with
`prosecdef = true`, `has_function_privilege('anon', oid, 'EXECUTE')` must be false unless the
`schema/anon-executable.allow` file names it; the file must be reviewed like code. This is
the one rule that would have prevented S3, N1, N2, N3 and N4 simultaneously, and the only one
that survives someone adding a function next year.

**R4 — Business logic is not in a PostgREST-exposed schema.**
Client-readable views live in `api`; all tables and functions live in `app`. PostgREST is
configured `db-schemas = api` only.
*Enforced by*: **CI assertion** that every object in `api` is on the allowlist and that no
object in `api` has `prosecdef = true`. Reachability becomes schema membership — a property
you cannot forget to revoke.

**R5 — Views never bypass RLS.**
Every view in `api` is created `WITH (security_invoker = true)`.
*Enforced by*: **CI assertion** over `pg_class` where `relkind = 'v'` — fail if
`reloptions` lacks `security_invoker=true`.
*Kills*: N10.

**R6 — Definer functions cannot be search-path-hijacked.**
`REVOKE CREATE ON SCHEMA public FROM PUBLIC, anon, authenticated;` and every remaining
definer function declares `SET search_path = ''` with fully-qualified identifiers.
*Enforced by*: **missing GRANT** + **CI assertion** that no `prosecdef` function has a
`proconfig` search_path containing `public`.
*Kills*: N11.

### Data-model impossibility

**R7 — Money is derived, not supplied.**
`total` is `GENERATED ALWAYS AS (subtotal + delivery_fee + tip_amount) STORED`, plus
`CHECK (subtotal >= 0 AND delivery_fee >= 0 AND tip_amount >= 0)`. Money is stored in minor
units as `bigint`, never `numeric`/`double`.
*Enforced by*: **generated column + CHECK constraint**. A generated column is unwritable by
*every* role including the Kotlin service, so a bug in the service cannot desynchronise a
total. Postgres rejects the write; there is nothing to test.
*Kills*: the financial half of S4, S5, T1, T2 permanently — even if R2 is ever weakened.

**R8 — Quantity and price have domains.**
`CHECK (quantity > 0 AND quantity <= 99)`, `CHECK (unit_price_minor >= 0)`,
`total_price_minor GENERATED ALWAYS AS (unit_price_minor * quantity) STORED`.
*Enforced by*: **CHECK constraint** + **Kotlin type** — `@JvmInline value class Quantity(val v: Int) { init { require(v in 1..99) } }`, so a negative quantity is unconstructible before it reaches SQL.
*Kills*: N8.

**R9 — Ownership is a foreign key, not a policy clause.**
`restaurants.owner_id uuid NOT NULL REFERENCES profiles(id)` declared in `CREATE TABLE`, so
no migration can reference a column that does not exist (the C2 failure).
*Enforced by*: **NOT NULL FK** + **Kotlin type** — `requireRestaurantOwnership(principal, id)`
returns an `OwnedRestaurantId` value class, and every merchant repository method accepts only
`OwnedRestaurantId`, never a bare `UUID`. A missing ownership check becomes a compile error
rather than a policy review.
*Kills*: S2, and the `assignCourier` / `get_merchant_stats(p_restaurant_id)` shape where a
client-supplied restaurant id is trusted.

**R10 — Address ownership is proven before an order exists.**
The order service resolves `addresses WHERE id = ? AND user_id = ?` and builds the snapshot
from the returned row; `orders.delivery_address_snapshot` is `NOT NULL`.
*Enforced by*: **NOT NULL column** + **Kotlin type** (`OwnedAddress`, returned only by the
resolver). An unresolvable or foreign address cannot produce an order at all, rather than
producing one with a NULL or stolen snapshot.
*Kills*: N7.

**R11 — Money is a double-entry ledger, append-only.**
`ledger_entries(transaction_id, account, amount_minor, …)` with
`CREATE CONSTRAINT TRIGGER … DEFERRABLE INITIALLY DEFERRED` asserting
`sum(amount_minor) = 0` per `transaction_id` at COMMIT. Courier earnings are entries, not a
mutable `total_earned`. **No tier-override parameter exists** — the tier is a row in a
lookup table keyed by `status_at_event`, and the payout is computed from an immutable
`delivery_fee_minor` snapshot.
*Enforced by*: **constraint trigger** + **missing GRANT** (`UPDATE`/`DELETE` on
`ledger_entries` revoked from *every* role including the Kotlin role) + **CI assertion** that
`has_table_privilege(<kotlin role>,'ledger_entries','UPDATE')` is false.
*Kills*: N2 — an unbounded multiplier has nowhere to be passed, and an over-credit would
fail the zero-sum assertion at COMMIT even if it were.

**R12 — Codes are hashed, CSPRNG, and attempt-capped.**
Store `pickup_code_hash` / `delivery_code_hash` only; generate with `SecureRandom` in Kotlin
(or `gen_random_bytes`); 6 digits; `CHECK (code_attempts <= 5)` with a hard lock.
*Enforced by*: **CHECK constraint** + **Kotlin type** (`VerificationCode` with a redacting
`toString()`, no accessor on any read path) + **CI assertion** that no view in `api` projects
a column matching `%code%`.
*Kills*: S6 and N9 completely. The courier cannot read the code because the plaintext does
not exist server-side; brute force is capped at 5 rather than 9,000.

**R13 — Proof of delivery is a verified object.**
`delivery_proof_id uuid REFERENCES delivery_proofs(id)`, and a `delivery_proofs` row is
written only after the service has confirmed the object exists, is under the size limit and
has an image content-type. `CHECK (delivery_mode <> 'leave_at_door' OR delivery_proof_id IS NOT NULL)`.
*Enforced by*: **FK + CHECK**. `length(url) >= 4` becomes unexpressible — there is no string
column to measure.
*Kills*: N6.

**R14 — Chat is append-only; read receipts are a separate table.**
`chat_messages` grants `INSERT` and `SELECT` only; `read_at` moves to
`chat_message_reads(message_id, reader_id, read_at)` with `INSERT` only.
*Enforced by*: **missing GRANT**. Body immutability stops depending on a policy whose name
(`chat_messages_mark_read`) already misdescribes it.
*Kills*: N5.

**R15 — Storage limits live on the bucket.**
Every bucket is created with explicit `file_size_limit` and `allowed_mime_types`; client
roles hold no direct insert privilege, and uploads pass through the service which validates
magic bytes rather than the filename extension.
*Enforced by*: **CI assertion** —
`SELECT count(*) FROM storage.buckets WHERE file_size_limit IS NULL OR allowed_mime_types IS NULL`
must be 0 — plus **missing GRANT** on `storage.objects`.
*Kills*: T3, including the third bucket (`delivery-proofs`) the finding missed.

### Operational

**R16 — Batch work runs as a role clients cannot assume.**
Sweeps (escalation ladder, no-show, scheduled activation, purge) live in the Kotlin
scheduler or in `pg_cron` under a dedicated `ravon_cron` role, and their functions are not
in the exposed schema.
*Enforced by*: R3 + R4 + **CI assertion** that no function matching
`%ladder%|%sweep%|mark_no_show%|activate_scheduled_orders|auto_cancel%` is EXECUTEable by
`anon` or `authenticated`.
*Kills*: N1, N3, N4, and S3's `auto_cancel_stale_orders`.

**R17 — Key classes are distinct types and CI-enforced.**
`PublishableKey` and `SecretKey` are separate Kotlin/Swift types; the client-facing HTTP
client accepts only `PublishableKey`. `scripts/scan_secrets.py` gains `sb_secret_` (fail)
and `sb_publishable_` (allow) patterns.
*Enforced by*: **Kotlin/Swift type** + the existing **CI secret-scan job**.
*Kills*: N12.

**R18 — Nothing trusts a claim the user can write.**
The interceptor verifies the ES256 signature against the cached JWKS, checks `iss`/`aud`/`exp`,
extracts **only** `sub`, and loads all authorization state from the database on every
privileged call — because JWT revocation lags ~20 minutes.
*Enforced by*: **Kotlin type** (R1's `Principal`) + an ArchUnit/CI rule that the auth package
contains no reference to `user_metadata` or `app_metadata`.
*Kills*: the §3 second-order risk and the suspension-lag gap.

---

## 8. The missing CI job

The repo has five CI jobs (`.github/workflows/ci.yml`): build/test, lifecycle invariants,
dispatch simulation, schema drift, secret scan. **None asserts anything about grants,
policies or constraints** — which is why nine findings across two reports produced one
migration. Add a sixth:

```
db-invariants:
  services: postgres:16
  steps:
    - apply schema/*.sql in order
    - psql -v ON_ERROR_STOP=1 -f schema/invariants.sql
```

`schema/invariants.sql` is a flat list of assertions (pgTAP, or `DO $$ … RAISE EXCEPTION`),
each mapped to a rule above:

- no `INSERT`/`UPDATE`/`DELETE` privilege for `anon`/`authenticated` on any table in
  `schema/client-readonly.list` (R2)
- `has_column_privilege('authenticated','profiles','role','UPDATE')` is false (R1)
- no `pg_proc` body matches `raw_user_meta_data|user_metadata` (R1)
- for every `prosecdef` function, `has_function_privilege('anon', oid, 'EXECUTE')` is false
  unless allowlisted (R3)
- no object in schema `api` is `prosecdef`; every `relkind='v'` has `security_invoker=true` (R4, R5)
- no `prosecdef` function has `public` in its `proconfig` search_path (R6)
- `orders.total_minor` is `attgenerated = 's'` (R7)
- the five domain CHECKs of R8/R12/R13 exist by name
- the ledger zero-sum constraint trigger exists and is `DEFERRABLE INITIALLY DEFERRED` (R11)
- `restaurants.owner_id` is `NOT NULL` with an FK (R9)
- no `storage.buckets` row has a NULL `file_size_limit` or `allowed_mime_types` (R15)
- the Kotlin role holds none of the forbidden privileges in §9

Because the database is gone, this job is **cheap to make true from day one and expensive to
retrofit** — which is the entire argument for doing it now. It also converts the §0/C5
lesson into machinery: a fix is proven by an assertion that fails without it, never by a
scanner's totals block.

---

## 9. The Kotlin service's Postgres role — explicit grant list

Connect as a dedicated role, **not** with the `service_role` JWT or an `sb_secret_` key
through PostgREST. Reasons: a `service_role` key bypasses RLS wholesale and has no
column-level granularity, it is a bearer token with no network binding (so a log line is a
full compromise), and it cannot be constrained by `pg_hba`. A Postgres role gives
column-level grants, network pinning and per-role connection limits.

```sql
CREATE ROLE ravon_app LOGIN PASSWORD :'pw'
  NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS NOINHERIT
  CONNECTION LIMIT 40;
```

### MUST be granted

| Privilege | Object | Why |
|---|---|---|
| `CONNECT` | `DATABASE ravon` | — |
| `USAGE` | `SCHEMA app` | business schema; **not** `CREATE` |
| `SELECT` | `app.restaurants`, `restaurant_hours`, `menu_items`, `menu_categories`, `modifier_groups`, `modifier_options`, `addresses`, `profiles`, `orders`, `order_items`, `courier_locations`, `courier_cancellation_log`, `ledger_entries` | reads for every service |
| `INSERT` | `app.orders`, `order_items`, `order_status_history`, `ledger_entries`, `courier_cancellation_log`, `chat_messages`, `delivery_proofs`, `chat_message_reads` | the write paths it owns |
| `UPDATE (status, courier_id, claimed_at, accepted_at, picked_up_at, delivered_at, cancelled_at, cancelled_by, cancellation_reason_code, expected_action_by, eta_minutes, reassign_count, excluded_courier_ids, no_show, no_show_started_at, restaurant_delay_min, delivery_proof_id)` | `app.orders` | **column-level**, enumerated. `total_minor` is generated (R7) and cannot appear here even by mistake |
| `UPDATE (stock_count)` | `app.menu_items` | order creation decrements stock |
| `UPDATE (is_suspended_until)` | `app.profiles` | courier suspension — **note the absence of `role`** |
| `INSERT`, `UPDATE (latitude, longitude, geog, heading, speed, accuracy_meters, is_online, current_order_id, last_updated, last_heartbeat_at, last_moved_at, ghost_strikes, strikes_reset_at)` | `app.courier_locations` | heartbeat |
| `USAGE` | sequences behind the above tables | — |
| `EXECUTE` | the (ideally empty) allowlist of remaining SQL functions | — |

### MUST NOT be granted

| Forbidden | Why it matters here |
|---|---|
| `SUPERUSER`, `BYPASSRLS`, `CREATEDB`, `CREATEROLE`, `REPLICATION` | `BYPASSRLS` specifically would silently void every client-side policy the design depends on |
| membership in `postgres`, `supabase_admin`, `service_role`, `authenticator` | `NOINHERIT` plus no `GRANT role TO ravon_app`; otherwise a `SET ROLE` reintroduces everything |
| `CREATE ON SCHEMA app` / `public` | with `CREATE` the service could add a SECURITY DEFINER function and escalate past its own grant list (R6) |
| `UPDATE (role)` on `profiles` | role changes belong to a separate `ravon_admin` role with its own audit trail (R1). This single omitted column grant is what makes S1 unexpressible |
| `UPDATE`, `DELETE` on `ledger_entries` | append-only money; the zero-sum trigger is meaningless if history is mutable (R11) |
| `UPDATE`, `DELETE` on `order_status_history`, `chat_messages` | audit trail and dispute evidence must be immutable (N5) |
| `DELETE` on `orders`, `order_items`, `profiles`, `addresses`, `restaurants`, `menu_items` | soft-delete only, so a bug destroys no history |
| `TRUNCATE` on anything | not needed at runtime, unrecoverable when wrong |
| any privilege on `SCHEMA auth` | the service must never read or write `auth.users`; identity comes from the verified JWT's `sub` (R18). This is what makes the §3 metadata chain unreconstructable |
| write privileges on `storage.objects` / `storage.buckets` | uploads go through the Storage API with bucket-level limits (R15) |
| any privilege on `SCHEMA cron`, `extensions` | scheduling is the scheduler's job, not the request path's (R16) |
| `SELECT` on any `*_code_hash` column beyond the single verify path | column-level grant, so a read path cannot accidentally project it (R12) |

Two additional constraints on the role, both cheap and both CI-assertable:
`pg_hba`/network policy restricts `ravon_app` to the service's subnet so a leaked password is
not remotely usable; and a separate read-only role (`ravon_ro`, `SELECT`-only, `NOBYPASSRLS`)
is used for analytics and the simulator so nothing exploratory holds a write grant.

---

## 10. Unknowables — do not let anyone fill these in from memory

- The **actual text of every RLS policy**. Both reports quote fragments; no migration in
  01–19 creates a policy on `orders`, `profiles`, `restaurants`, `addresses`,
  `courier_locations`, `courier_earnings`, `order_items` or `order_status_history`.
  **UNKNOWN — needs live introspection**, and the database is gone, so the reports' quoted
  fragments are now the only record.
- Whether `restaurants.owner_id` ever existed. Used at `01:43`, `01:64`, `05:22`, `15:54`,
  `15:70`; created nowhere. **UNKNOWN.**
- The definitions of `find_nearby_couriers`, `auto_cancel_stale_orders`, `get_merchant_stats`,
  `add_tip`, `create_courier_earning`, `cleanup_cancelled_order`. All referenced; none in the
  repo (corroborated by `.context/architecture/12-BACKEND-INVENTORY.md:28`). **UNKNOWN.**
- Whether `ALTER DEFAULT PRIVILEGES … GRANT ALL ON FUNCTIONS TO anon, authenticated` and
  `GRANT ALL ON SCHEMA public TO anon, authenticated` were in effect. Determines whether §4
  Layer 2 was real. **UNKNOWN** — which is exactly why R3 must be a build assertion rather
  than an audit.
- Whether `orders.user_id` was `NOT NULL` (decides whether anon could have created orders via
  `create_order`). **UNKNOWN.**
- Whether any policy allowed updating another user's `profiles` row, which would make
  migration 19's trigger fail open on cross-row updates. **UNKNOWN.**
