# Federated Umbrella migrations

Apply in numeric order against the Supabase project (`milan` / production).
All migrations are idempotent (use `IF NOT EXISTS` and `CREATE OR REPLACE`).

## Umbrella I — consumer ↔ merchant

```
01_menu_soft_delete_and_category_availability.sql   — soft-delete + category is_available
02_extend_order_items_snapshot.sql                  — itemDescription/itemImageUrl/modifiersSnapshot + ON DELETE SET NULL
03_orderability_function_and_view.sql               — restaurant_within_hours, restaurant_is_orderable, get_restaurant_orderability, restaurants_orderable view
04_create_order_v3_and_validate_cart.sql            — validate_cart RPC + create_order v3 (hours, min_order, structured errors, scheduled_for branch)
05_set_accepting_orders_with_until.sql              — accepting_orders_until column + RPC + auto-resume cron
06_scheduled_orders.sql                             — orders.scheduled_for + 'scheduled' enum value + activate_scheduled_orders cron
07_soft_delete_purge_cron.sql                       — daily 30-day cleanup
```

## Umbrella II — courier hardening (this PR)

```
08_courier_heartbeat_and_sla_columns.sql            — heartbeat / movement / SLA columns + indexes
09_cancellation_reason_code_and_courier_cancel_log.sql — cancelled_by_courier enum + typed reason code + log table + RLS
10_dual_verification_codes_and_delivery_mode.sql    — delivery_verification_code + delivery_mode + delivery_proof_url + trigger updates
11_reassignment_columns.sql                         — orders.reassign_count + excluded_courier_ids
12_tiered_earnings_columns_and_helpers.sql          — courier_earnings tier columns + earnings_tier_for_cancel + insert_courier_earning_for_cancel
13_courier_status_transition_rpcs_v2.sql            — claim/pickup/deliver/arrive_*/cancel_by_consumer v2 + cancel_by_courier + report_problem_post_pickup + courier_explain_delay + reassign_ghosted_order + compute_eta_minutes + update_courier_heartbeat + fetch_available_orders v2
14_courier_escalation_ladder_cron.sql               — run_courier_escalation_ladder + cron (every minute, 3-pass T+0/T+2/T+5 ladder)
15_chat_rls_and_sender_role.sql                     — chat_messages.sender_role + RLS lifecycle gate (5-min INSERT grace, 30-day SELECT)
16_no_show_and_restaurant_delay.sql                 — orders.no_show + restaurant_delay_min + courier_report_customer_no_show + courier_report_restaurant_delay + mark_no_show_deliveries cron
17_system_messages_sender_role_fix.sql              — force sender_role='system' on programmatic chat inserts
```

## Umbrella III — auth overhaul (this PR)

```
18_handle_new_user_trigger.sql                      — server-side profile creation from auth.users.raw_user_meta_data (full_name, role)
19_lock_down_profile_role.sql                       — BEFORE UPDATE trigger blocking self-escalation of profiles.role; closes 2026-03-23 CRITICAL
```

### Dashboard-only changes (not SQL — apply in Supabase dashboard)

These cannot be expressed as migrations. Apply them once in
**Supabase → Authentication** for the production project:

1. **Providers → Email** — enable Email provider; set **Confirm email = ON**;
   set **Secure email change = ON**.
2. **Settings**
   - **OTP Expiry = 600 seconds** (10 minutes).
   - **OTP length = 6**.
3. **Email Templates** — rewrite both templates in Russian and replace any
   `{{ .ConfirmationURL }}` with `{{ .Token }}`. The Swift app collects the
   6-digit code in-app, so users never click a link in the email. This avoids
   email-prefetch link invalidation entirely.

   - **Confirm signup**
     - Subject: `Код подтверждения Ravon`
     - Body (HTML):
       ```html
       <h2>Подтверждение почты</h2>
       <p>Здравствуйте! Введите этот код в приложении Ravon, чтобы завершить регистрацию:</p>
       <p style="font-size:32px;letter-spacing:6px;font-weight:700;margin:24px 0;">{{ .Token }}</p>
       <p>Код действует 10 минут. Если вы не создавали аккаунт — просто проигнорируйте это письмо.</p>
       ```
   - **Reset password**
     - Subject: `Сброс пароля Ravon`
     - Body (HTML):
       ```html
       <h2>Сброс пароля</h2>
       <p>Введите этот код в приложении Ravon, чтобы установить новый пароль:</p>
       <p style="font-size:32px;letter-spacing:6px;font-weight:700;margin:24px 0;">{{ .Token }}</p>
       <p>Код действует 10 минут. Если вы не запрашивали сброс — просто проигнорируйте это письмо.</p>
       ```

4. **Password requirements** — minimum length **8**, require letters + numbers.
5. **Rate limits** — leave defaults (30 emails/hour/IP). Tighten only if abuse
   appears in `auth.audit_log_entries`.

After applying these in the dashboard, sign-up flow is:

```
auth.signUp(...) ─▶ (no session yet)
   │ Supabase emails 6-digit code via "Confirm signup" template
   ▼
auth.verifyOTP(type: .signup, token: "123456") ─▶ session established
   │ on auth.users INSERT, handle_new_user trigger created the profile row
```

## How to apply

```
mcp__supabase__apply_migration  name="08_courier_heartbeat..."  query=<SQL>
```

Or paste each file into the SQL editor in order.

## Verification queries

```sql
-- A. Tier table
SELECT
  earnings_tier_for_cancel('assigned'::order_status),                  -- 25
  earnings_tier_for_cancel('courier_arrived_restaurant'::order_status),-- 50
  earnings_tier_for_cancel('picked_up'::order_status),                 -- 100
  earnings_tier_for_cancel('ready'::order_status);                     -- 0

-- B. Escalation ladder fires (synthetic — set expected_action_by 6 min ago)
UPDATE orders SET expected_action_by = now() - interval '6 minutes' WHERE id = '<order-uuid>';
SELECT run_courier_escalation_ladder();
SELECT status, cancellation_reason_code, courier_no_show_warned_at,
       courier_no_show_escalated_at, reassign_count
FROM orders WHERE id = '<order-uuid>';

-- C. Heartbeat + ETA computation
SELECT update_courier_heartbeat(38.5598, 68.7870, 12.5, 0, 8.0);
SELECT eta_minutes, expected_action_by FROM orders WHERE id = '<order-uuid>';

-- D. Suspension after 3 strikes
UPDATE courier_locations SET ghost_strikes = 3, strikes_reset_at = now()
WHERE courier_id = '<courier-uuid>';
-- Next ghost cycle suspends; verify:
SELECT is_suspended_until FROM profiles WHERE id = '<courier-uuid>';

-- E. Chat post-delivery grace + 30-day window (run as the order participant)
INSERT INTO chat_messages(order_id, sender_id, body)
VALUES ('<order-uuid>', auth.uid(), 'follow-up'); -- works ≤5 min after delivered
-- After 5+ min: same INSERT fails with RLS rejection.
SELECT count(*) FROM chat_messages WHERE order_id = '<order-uuid>'; -- still readable

-- F. Photo proof
SELECT courier_deliver_order('<order-uuid>', NULL, '<order-uuid>/<courier-uuid>-1234.jpg');
```

## Hardening notes

After applying 08–16, run `SELECT * FROM cron.job` to confirm both
`courier_escalation_ladder` and `mark_no_show_deliveries` show `* * * * *`.

Functions added without explicit `search_path` at create time (helpers like
`earnings_tier_for_cancel`, `set_chat_sender_role`) were tightened
post-migration with `ALTER FUNCTION ... SET search_path = public` to satisfy
the security advisor's `function_search_path_mutable` lint.
