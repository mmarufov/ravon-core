-- ============================================================================
-- Ravon double-entry ledger — schema, invariants, and the posting API.
--
-- Target: PostgreSQL 16 (developed against 16 in CI; also runs on 17).
-- Apply to a fresh database as a superuser / database owner:
--
--     psql -v ON_ERROR_STOP=1 -f db/ledger/schema.sql -d ravon_ledger
--
-- ---------------------------------------------------------------------------
-- The one idea this file exists to express
-- ---------------------------------------------------------------------------
-- "Debits equal credits" is enforced *by PostgreSQL*, not by a service. There
-- is no application code path — not a buggy Kotlin handler, not a psql session,
-- not a superuser with a typo — that can commit an unbalanced transaction.
-- The service tier calls ledger_post(); it never writes ledger_entries.
--
-- Everything below is one of six invariants:
--   1. Balanced at COMMIT       — deferred constraint trigger (see comment there)
--   2. One currency per txn     — same deferred trigger
--   3. Entries are immutable    — REVOKE + an unconditional BEFORE UPDATE/DELETE trigger
--   4. No negative balances     — immediate statement trigger on the balance cache
--   5. Cache = truth            — ledger_verify_balances()
--   6. Idempotent posting       — ledger_post(): same key + same fingerprint replays,
--                                 same key + different fingerprint is a 409
-- ============================================================================

BEGIN;

-- ============================================================================
-- Roles
-- ============================================================================
-- ravon_ledger_app  — the service tier (Kotlin). May SELECT, and may call the
--                     posting API. May NOT write any ledger table directly.
-- ravon_ledger_anon — stands in for an untrusted client (the iOS anon role).
--                     Exists so the test suite can prove it cannot reach the
--                     SECURITY DEFINER functions. Granted nothing at all.
--
-- NOLOGIN by default: a deployment attaches its own password/auth. The test
-- harness grants LOGIN explicitly.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ravon_ledger_app') THEN
    CREATE ROLE ravon_ledger_app NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ravon_ledger_anon') THEN
    CREATE ROLE ravon_ledger_anon NOLOGIN;
  END IF;
END$$;

-- ============================================================================
-- Structured errors — the repo's existing RPC convention (see
-- .context/migrations/13_*.sql): RAISE with ERRCODE 'P0001' and a jsonb DETAIL
-- carrying a machine-readable `reason`. The service decodes `reason` and maps
-- `http_status` straight through. Every reason code is listed in
-- db/ledger/HANDOFF-for-kotlin.md.
-- ============================================================================
CREATE OR REPLACE FUNCTION ledger_raise(
  p_reason      text,
  p_http_status int,
  p_detail      jsonb DEFAULT '{}'::jsonb
) RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION '%', lower(p_reason)
    USING ERRCODE = 'P0001',
          DETAIL  = (jsonb_build_object('reason', p_reason, 'http_status', p_http_status)
                     || COALESCE(p_detail, '{}'::jsonb))::text;
END$$;

COMMENT ON FUNCTION ledger_raise(text, int, jsonb) IS
  'Raises the repo-standard structured error: ERRCODE P0001 + DETAIL jsonb with reason/http_status.';

-- ============================================================================
-- Types
-- ============================================================================
CREATE TYPE ledger_direction AS ENUM ('debit', 'credit');

-- Account kinds. The *normal balance* of each kind (whether a debit or a credit
-- increases it) is a property of the kind, not of the row — see
-- ledger_normal_sign(). Keeping it derived rather than stored means the two can
-- never drift.
CREATE TYPE ledger_account_kind AS ENUM (
  'consumer_wallet',    -- liability: refundable credit we hold for a consumer
  'merchant_payable',   -- liability: what we owe a merchant
  'courier_payable',    -- liability: what we owe a courier
  'order_escrow',       -- liability: value held against one order, per order
  'platform_revenue',   -- revenue:   commission and fees we keep
  'platform_rounding',  -- revenue:   remainder minor units from fee splits
  'promo_expense',      -- expense:   cost of promotional credit we issue
  'chargeback_loss',    -- expense:   value a chargeback took from us
  'psp_clearing',       -- asset:     funds held at the payment provider
  'order_receivable'    -- asset:     authorized but not yet captured
);

CREATE TYPE ledger_payout_state AS ENUM ('pending', 'submitted', 'posted', 'failed');

-- Return type of ledger_post(). `replayed` distinguishes "we wrote it now" from
-- "this idempotency key already existed and we returned the original".
CREATE TYPE ledger_post_result AS (
  transaction_id uuid,
  replayed       boolean
);

-- ============================================================================
-- ledger_normal_sign(kind) -> +1 | -1
--
-- Balances are cached as a *signed* value using one uniform convention:
--     debit = +amount, credit = -amount
-- so that SUM(signed) over every entry in the ledger is exactly 0 and the
-- per-transaction sum is exactly 0. That is what makes global conservation a
-- single, cheap query.
--
-- But "is this balance negative?" is not the same question as "is the signed
-- sum negative?". A consumer wallet is a liability: it is funded by credits, so
-- a healthy wallet has a *negative* signed balance. The natural balance is
-- therefore signed * normal_sign, and that is what allow_negative constrains.
-- ============================================================================
CREATE OR REPLACE FUNCTION ledger_normal_sign(p_kind ledger_account_kind)
RETURNS int
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
  SELECT CASE p_kind
           WHEN 'psp_clearing'      THEN  1   -- asset
           WHEN 'order_receivable'  THEN  1   -- asset
           WHEN 'promo_expense'     THEN  1   -- expense
           WHEN 'chargeback_loss'   THEN  1   -- expense
           ELSE -1                            -- liability / revenue
         END
$$;

-- ============================================================================
-- Tables
-- ============================================================================

CREATE TABLE ledger_accounts (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  kind           ledger_account_kind NOT NULL,
  -- NULL for platform-level accounts (platform_revenue, platform_rounding,
  -- psp_clearing, ...). Set for per-party accounts: consumer, merchant,
  -- courier, or — for order_escrow — the order itself.
  owner_id       uuid,
  currency       char(3) NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
  allow_negative boolean NOT NULL DEFAULT false,
  created_at     timestamptz NOT NULL DEFAULT now()
);

-- One account per (kind, owner, currency). Two wallets for the same consumer in
-- the same currency is a data bug that silently halves their balance, so it is
-- impossible rather than merely discouraged. Two partial indexes because NULL
-- owner_id does not collide with itself in a plain UNIQUE constraint.
CREATE UNIQUE INDEX ledger_accounts_owned_uniq
  ON ledger_accounts (kind, owner_id, currency) WHERE owner_id IS NOT NULL;
CREATE UNIQUE INDEX ledger_accounts_platform_uniq
  ON ledger_accounts (kind, currency) WHERE owner_id IS NULL;
CREATE INDEX ledger_accounts_owner_idx ON ledger_accounts (owner_id) WHERE owner_id IS NOT NULL;

CREATE TABLE ledger_transactions (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  -- Every transaction names the business event that caused it. A ledger entry
  -- with no provenance cannot be audited, so provenance is NOT NULL.
  business_event_type text NOT NULL CHECK (length(business_event_type) BETWEEN 1 AND 64),
  business_event_id   uuid NOT NULL,
  idempotency_key     text NOT NULL UNIQUE CHECK (length(idempotency_key) BETWEEN 1 AND 255),
  -- Hash of the caller's request body. Same key + different fingerprint means
  -- the caller reused a key for different money: that is a 409, never a replay.
  request_fingerprint text NOT NULL,
  created_at          timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX ledger_transactions_event_idx
  ON ledger_transactions (business_event_type, business_event_id);

CREATE TABLE ledger_entries (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  transaction_id uuid NOT NULL REFERENCES ledger_transactions(id),
  account_id     uuid NOT NULL REFERENCES ledger_accounts(id),
  direction      ledger_direction NOT NULL,
  -- Integer minor units only. No floats anywhere in this schema: binary
  -- floating point cannot represent 0.10, and a ledger that cannot represent
  -- ten cents is not a ledger.
  amount_minor   bigint NOT NULL CHECK (amount_minor > 0),
  -- Currency is on every row, not only on the account, so a mixed-currency
  -- transaction is detectable from the entries alone.
  currency       char(3) NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
  created_at     timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX ledger_entries_transaction_idx ON ledger_entries (transaction_id);
CREATE INDEX ledger_entries_account_idx     ON ledger_entries (account_id);

-- Derived cache. ledger_entries is the source of truth; this table exists only
-- so that reading a balance is O(1) instead of O(entries). It is updated in the
-- same database transaction as the entries by a trigger, so it cannot lag, and
-- ledger_verify_balances() proves that claim rather than assuming it.
CREATE TABLE ledger_balances (
  account_id    uuid PRIMARY KEY REFERENCES ledger_accounts(id),
  balance_minor bigint NOT NULL,   -- signed: debit positive, credit negative
  updated_at    timestamptz NOT NULL DEFAULT now()
);

-- The saga journal for payouts. This is the one table here that is not part of
-- the ledger proper: a payout is create pending -> call the provider -> mark
-- submitted -> post entries, and the crash tests need somewhere to observe a
-- half-finished saga. See HANDOFF-for-kotlin.md: the service may own this state
-- machine instead, but it must derive the ledger idempotency key the same way.
CREATE TABLE ledger_payouts (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  request_id            text NOT NULL UNIQUE,
  payee_account_id      uuid NOT NULL REFERENCES ledger_accounts(id),
  cash_account_id       uuid NOT NULL REFERENCES ledger_accounts(id),
  amount_minor          bigint NOT NULL CHECK (amount_minor > 0),
  currency              char(3) NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
  state                 ledger_payout_state NOT NULL DEFAULT 'pending',
  provider_ref          text,
  failure_reason        text,
  ledger_transaction_id uuid REFERENCES ledger_transactions(id),
  reversal_transaction_id uuid REFERENCES ledger_transactions(id),
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now()
);

-- ============================================================================
-- Observability for the crash tests
--
-- A sequence, deliberately. nextval() is NOT transactional: it survives
-- rollback. That is exactly the property the crash-injection tests need — after
-- killing a backend mid-transaction, every trace of the transaction is gone from
-- the tables, so there would otherwise be no way to distinguish "the deferred
-- trigger never fired" from "it fired and its evidence rolled back too".
-- Reading this counter before and after an aborted transaction answers that.
-- ============================================================================
CREATE SEQUENCE ledger_deferred_check_seq AS bigint START 1 CACHE 1;

CREATE OR REPLACE FUNCTION ledger_deferred_check_count()
RETURNS bigint
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT CASE WHEN is_called THEN last_value ELSE 0 END FROM ledger_deferred_check_seq
$$;

COMMENT ON FUNCTION ledger_deferred_check_count() IS
  'How many times the deferred balance trigger has fired in this database, ever. '
  'Non-transactional (sequence-backed) so it is readable across a rolled-back transaction.';

-- ============================================================================
-- INVARIANT 1 + 2 — balanced, single-currency, at COMMIT
--
-- Why DEFERRABLE INITIALLY DEFERRED, and why it is the whole point:
--
-- A double-entry transaction is only ever balanced once *all* of its legs are
-- in. An immediate (row-level, non-deferred) check would reject the very first
-- INSERT of every legal posting, because at that instant debits != credits. The
-- usual workaround is to check in application code after both legs — which is
-- precisely the code path we are trying to make unnecessary.
--
-- A DEFERRABLE INITIALLY DEFERRED constraint trigger moves the check to COMMIT.
-- Both legs insert freely inside one transaction; at COMMIT, PostgreSQL runs the
-- check, and if debits != credits the COMMIT itself fails and the whole
-- transaction rolls back. There is no window in which an unbalanced posting is
-- visible or durable, and no privilege level at which it can be committed.
--
-- Consequence the service tier must know: ledger_post() returning successfully
-- does NOT mean the posting was valid — COMMIT is where balance is decided. A
-- caller that wants the error earlier can force it with
--     SET CONSTRAINTS ledger_entries_balanced_at_commit IMMEDIATE;
-- This is documented in HANDOFF-for-kotlin.md.
--
-- The trigger is FOR EACH ROW (constraint triggers must be), so an N-leg
-- posting re-runs the aggregate N times at commit. For the 2-7 leg postings this
-- ledger produces that is cheaper than the bookkeeping needed to deduplicate.
-- ============================================================================
CREATE OR REPLACE FUNCTION ledger_assert_transaction_balanced()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_debits    bigint;
  v_credits   bigint;
  v_currencies text[];
BEGIN
  PERFORM nextval('ledger_deferred_check_seq');

  SELECT COALESCE(SUM(amount_minor) FILTER (WHERE direction = 'debit'),  0),
         COALESCE(SUM(amount_minor) FILTER (WHERE direction = 'credit'), 0),
         array_agg(DISTINCT currency)
    INTO v_debits, v_credits, v_currencies
  FROM ledger_entries
  WHERE transaction_id = NEW.transaction_id;

  -- INVARIANT 2: one currency per transaction. Checked first: a cross-currency
  -- posting whose minor units happen to sum to zero is not balanced, it is a
  -- category error, and saying so is more useful than "debits != credits".
  IF array_length(v_currencies, 1) > 1 THEN
    PERFORM ledger_raise('MIXED_CURRENCY_TRANSACTION', 422, jsonb_build_object(
      'transaction_id', NEW.transaction_id,
      'currencies',     to_jsonb(v_currencies)));
  END IF;

  -- INVARIANT 1: debits = credits.
  IF v_debits <> v_credits THEN
    PERFORM ledger_raise('UNBALANCED_TRANSACTION', 422, jsonb_build_object(
      'transaction_id', NEW.transaction_id,
      'debit_minor',    v_debits,
      'credit_minor',   v_credits,
      'delta_minor',    v_debits - v_credits));
  END IF;

  RETURN NULL;
END$$;

-- SECURITY DEFINER on the trigger function above is load-bearing, and the reason
-- is not obvious. A deferred constraint trigger fires at COMMIT, which is
-- *outside* the SECURITY DEFINER context of ledger_post() — so it runs as the
-- session user. A least-privilege application role has no rights on the counter
-- sequence, so without SECURITY DEFINER the check dies with "permission denied"
-- instead of checking anything. Fail-closed, so not a soundness hole, but it
-- would have made the ledger unusable by exactly the role it is designed for.
-- Running the checks as their owner also means the invariant cannot be disabled
-- by taking privileges away from the caller.
CREATE CONSTRAINT TRIGGER ledger_entries_balanced_at_commit
AFTER INSERT ON ledger_entries
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW
EXECUTE FUNCTION ledger_assert_transaction_balanced();

-- A transaction row with no entries at all would trivially satisfy "debits =
-- credits" by vacuity, because the trigger above only fires when entries exist.
-- This closes that hole: also deferred, also checked at COMMIT.
CREATE OR REPLACE FUNCTION ledger_assert_transaction_has_entries()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_count int;
BEGIN
  SELECT count(*) INTO v_count FROM ledger_entries WHERE transaction_id = NEW.id;
  IF v_count < 2 THEN
    PERFORM ledger_raise('DEGENERATE_TRANSACTION', 422, jsonb_build_object(
      'transaction_id', NEW.id,
      'entry_count',    v_count));
  END IF;
  RETURN NULL;
END$$;

CREATE CONSTRAINT TRIGGER ledger_transactions_have_entries_at_commit
AFTER INSERT ON ledger_transactions
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW
EXECUTE FUNCTION ledger_assert_transaction_has_entries();

-- ============================================================================
-- INVARIANT 3 — entries and transactions are immutable
--
-- Belt and braces. The REVOKEs at the bottom of this file stop the application
-- role; this trigger stops everyone else, including the table owner and a
-- superuser with a WHERE clause they will regret. Roles get misconfigured;
-- triggers do not.
--
-- Corrections are reversing entries — a new transaction with the legs swapped —
-- never a mutation. That is what makes the ledger an audit log rather than a
-- table that happens to contain money.
--
-- Known gap, closed by REVOKE rather than by this trigger: TRUNCATE does not
-- fire row-level DELETE triggers. TRUNCATE is revoked below for that reason.
-- ============================================================================
CREATE OR REPLACE FUNCTION ledger_reject_mutation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  PERFORM ledger_raise('LEDGER_IMMUTABLE', 500, jsonb_build_object(
    'table',     TG_TABLE_NAME,
    'operation', TG_OP,
    'hint',      'Ledger history is append-only. Post a reversing transaction instead.'));
  RETURN NULL;
END$$;

CREATE TRIGGER ledger_entries_immutable
BEFORE UPDATE OR DELETE ON ledger_entries
FOR EACH ROW EXECUTE FUNCTION ledger_reject_mutation();

CREATE TRIGGER ledger_transactions_immutable
BEFORE UPDATE OR DELETE ON ledger_transactions
FOR EACH ROW EXECUTE FUNCTION ledger_reject_mutation();

-- ============================================================================
-- INVARIANT 4 — no negative balances, enforced by the balance-cache update
--
-- This is a statement-level AFTER INSERT trigger with a transition table, which
-- gives it three properties worth having:
--
--   * It is impossible to insert entries without updating the cache. The cache
--     cannot drift because nothing can write entries around it.
--   * It sees the whole posting at once, so a transaction that debits an
--     account to zero and credits it back is judged on its net effect, not on a
--     transient intermediate state.
--   * It is IMMEDIATE, not deferred. An over-refund or an over-payout therefore
--     fails at the INSERT, atomically with the entries that caused it — the
--     caller gets NEGATIVE_BALANCE_NOT_ALLOWED with the account and the
--     attempted balance, rather than an opaque failure at COMMIT.
-- ============================================================================
CREATE OR REPLACE FUNCTION ledger_apply_balance_delta()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_bad record;
BEGIN
  -- An entry's currency must match its account's. Caught here rather than by a
  -- constraint because it needs the joined account row.
  SELECT e.account_id, e.currency AS entry_currency, a.currency AS account_currency
    INTO v_bad
  FROM inserted e
  JOIN ledger_accounts a ON a.id = e.account_id
  WHERE e.currency IS DISTINCT FROM a.currency
  LIMIT 1;

  IF FOUND THEN
    PERFORM ledger_raise('CURRENCY_MISMATCH_ACCOUNT', 422, jsonb_build_object(
      'account_id',       v_bad.account_id,
      'entry_currency',   v_bad.entry_currency,
      'account_currency', v_bad.account_currency));
  END IF;

  -- Apply every account's net delta in one upsert. GROUP BY collapses multiple
  -- legs on the same account; ORDER BY account_id makes the row-lock order
  -- deterministic so concurrent postings cannot deadlock against each other.
  INSERT INTO ledger_balances AS b (account_id, balance_minor, updated_at)
  SELECT account_id,
         SUM(CASE WHEN direction = 'debit' THEN amount_minor ELSE -amount_minor END),
         now()
  FROM inserted
  GROUP BY account_id
  ORDER BY account_id
  ON CONFLICT (account_id) DO UPDATE
    SET balance_minor = b.balance_minor + EXCLUDED.balance_minor,
        updated_at    = now();

  -- Natural balance, not signed balance — see ledger_normal_sign().
  SELECT b.account_id, a.kind, b.balance_minor,
         b.balance_minor * ledger_normal_sign(a.kind) AS natural_minor
    INTO v_bad
  FROM ledger_balances b
  JOIN ledger_accounts a ON a.id = b.account_id
  WHERE b.account_id IN (SELECT DISTINCT account_id FROM inserted)
    AND NOT a.allow_negative
    AND b.balance_minor * ledger_normal_sign(a.kind) < 0
  LIMIT 1;

  IF FOUND THEN
    PERFORM ledger_raise('NEGATIVE_BALANCE_NOT_ALLOWED', 409, jsonb_build_object(
      'account_id',            v_bad.account_id,
      'account_kind',          v_bad.kind,
      'attempted_balance_minor', v_bad.natural_minor));
  END IF;

  RETURN NULL;
END$$;

CREATE TRIGGER ledger_entries_apply_balance
AFTER INSERT ON ledger_entries
REFERENCING NEW TABLE AS inserted
FOR EACH STATEMENT
EXECUTE FUNCTION ledger_apply_balance_delta();

-- ============================================================================
-- INVARIANT 5 — cache consistency
--
-- Returns one row per account whose cached balance disagrees with the sum of
-- its entries; an empty result means the cache is exactly the truth. The tests
-- call this after every single operation. In production this is a scheduled job
-- — and a non-empty result there is a page, not a warning.
-- ============================================================================
CREATE OR REPLACE FUNCTION ledger_verify_balances()
RETURNS TABLE (
  account_id    uuid,
  account_kind  ledger_account_kind,
  cached_minor  bigint,
  actual_minor  bigint,
  delta_minor   bigint
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT a.id,
         a.kind,
         COALESCE(b.balance_minor, 0),
         COALESCE(e.summed, 0),
         COALESCE(b.balance_minor, 0) - COALESCE(e.summed, 0)
  FROM ledger_accounts a
  LEFT JOIN ledger_balances b ON b.account_id = a.id
  LEFT JOIN (
    SELECT account_id,
           SUM(CASE WHEN direction = 'debit' THEN amount_minor ELSE -amount_minor END) AS summed
    FROM ledger_entries
    GROUP BY account_id
  ) e ON e.account_id = a.id
  WHERE COALESCE(b.balance_minor, 0) <> COALESCE(e.summed, 0)
$$;

-- Human-readable balances: natural sign, so a funded consumer wallet reads as a
-- positive number rather than as the negative signed sum.
CREATE OR REPLACE VIEW ledger_account_balances AS
SELECT a.id            AS account_id,
       a.kind,
       a.owner_id,
       a.currency,
       a.allow_negative,
       COALESCE(b.balance_minor, 0)                              AS signed_minor,
       COALESCE(b.balance_minor, 0) * ledger_normal_sign(a.kind) AS natural_minor,
       b.updated_at
FROM ledger_accounts a
LEFT JOIN ledger_balances b ON b.account_id = a.id;

-- ============================================================================
-- Exact integer fee splitting
--
-- Splits p_total across weights in basis points. Each share is floor(total*bps
-- /10000); whatever the floors lose is returned as one extra trailing element.
-- The caller posts that remainder to platform_rounding, so the split sums to
-- the original exactly and no minor unit is ever created or destroyed by a
-- division. Returns array_length(p_bps) + 1 elements.
-- ============================================================================
CREATE OR REPLACE FUNCTION ledger_split_minor(p_total bigint, p_bps int[])
RETURNS bigint[]
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_sum_bps   bigint := 0;
  v_allocated bigint := 0;
  v_out       bigint[] := '{}'::bigint[];
  v_share     bigint;
  b           int;
BEGIN
  IF p_total IS NULL OR p_total < 0 OR p_total > 1000000000000000 THEN
    PERFORM ledger_raise('INVALID_SPLIT_TOTAL', 422,
                         jsonb_build_object('total_minor', p_total));
  END IF;

  IF p_bps IS NULL OR COALESCE(array_length(p_bps, 1), 0) = 0 THEN
    PERFORM ledger_raise('INVALID_SPLIT_WEIGHTS', 422,
                         jsonb_build_object('reason_detail', 'weights must be non-empty'));
  END IF;

  FOREACH b IN ARRAY p_bps LOOP
    IF b < 0 THEN
      PERFORM ledger_raise('INVALID_SPLIT_WEIGHTS', 422,
                           jsonb_build_object('reason_detail', 'weights must be non-negative'));
    END IF;
    v_sum_bps := v_sum_bps + b;
  END LOOP;

  IF v_sum_bps <> 10000 THEN
    PERFORM ledger_raise('INVALID_SPLIT_WEIGHTS', 422, jsonb_build_object(
      'reason_detail', 'weights must sum to 10000 basis points',
      'sum_bps',       v_sum_bps));
  END IF;

  FOREACH b IN ARRAY p_bps LOOP
    v_share     := (p_total * b) / 10000;   -- integer division; p_total >= 0 so this is floor
    v_out       := v_out || v_share;
    v_allocated := v_allocated + v_share;
  END LOOP;

  RETURN v_out || (p_total - v_allocated);  -- remainder, always >= 0 and < array_length(p_bps)
END$$;

-- ============================================================================
-- Account opening
--
-- Idempotent by (kind, owner_id, currency): calling it twice returns the same
-- account rather than creating a second one. allow_negative is honoured only on
-- first creation; a later call with a different value returns the existing
-- account unchanged, because silently widening an account's overdraft rule from
-- a retry would be worse than ignoring the argument.
-- ============================================================================
CREATE OR REPLACE FUNCTION ledger_open_account(
  p_kind           ledger_account_kind,
  p_owner_id       uuid,
  p_currency       char(3),
  p_allow_negative boolean DEFAULT false
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_id uuid;
BEGIN
  IF p_currency IS NULL OR upper(p_currency) !~ '^[A-Z]{3}$' THEN
    PERFORM ledger_raise('INVALID_CURRENCY', 422, jsonb_build_object('currency', p_currency));
  END IF;

  INSERT INTO ledger_accounts (kind, owner_id, currency, allow_negative)
  VALUES (p_kind, p_owner_id, upper(p_currency)::char(3), p_allow_negative)
  ON CONFLICT DO NOTHING
  RETURNING id INTO v_id;

  IF v_id IS NULL THEN
    SELECT id INTO v_id
    FROM ledger_accounts
    WHERE kind = p_kind
      AND currency = upper(p_currency)::char(3)
      AND owner_id IS NOT DISTINCT FROM p_owner_id;
  END IF;

  IF v_id IS NULL THEN
    -- Reachable only if a concurrent inserter is still uncommitted and this
    -- session cannot see its row (REPEATABLE READ or higher). Retryable.
    PERFORM ledger_raise('ACCOUNT_RACE_RETRY', 503, jsonb_build_object(
      'kind', p_kind, 'owner_id', p_owner_id, 'currency', p_currency));
  END IF;

  RETURN v_id;
END$$;

-- ============================================================================
-- INVARIANT 6 — ledger_post(): the only way to write the ledger
--
-- Idempotency implements DoorDash's published contract verbatim:
--   * same key + same fingerprint      -> return the existing transaction, write nothing
--   * same key + different fingerprint -> conflict (their API returns HTTP 409)
--   * concurrent callers with the same key -> exactly one writes; the losers
--     serialise behind the winner and then replay its result
--
-- The race is handled by INSERT ... ON CONFLICT DO NOTHING followed by
-- SELECT ... FOR UPDATE. ON CONFLICT DO NOTHING waits on a conflicting
-- *uncommitted* row rather than failing, so by the time it returns no row, the
-- winner has committed and its transaction is visible. FOR UPDATE then pins the
-- row so the fingerprint comparison cannot race a concurrent writer.
--
-- p_entries is a jsonb array of
--     {"account_id": uuid, "direction": "debit"|"credit",
--      "amount_minor": int > 0, "currency": "XXX"}
-- All legs are inserted in ONE statement, which is what lets the statement-level
-- balance trigger see the posting as a unit.
--
-- Requires READ COMMITTED (the PostgreSQL default). See the IDEMPOTENCY_RACE_RETRY
-- branch for what happens otherwise.
-- ============================================================================
CREATE OR REPLACE FUNCTION ledger_post(
  p_idempotency_key     text,
  p_request_fingerprint text,
  p_business_event_type text,
  p_business_event_id   uuid,
  p_entries             jsonb
) RETURNS ledger_post_result
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_tx_id      uuid;
  v_existing   ledger_transactions%ROWTYPE;
  v_bad        jsonb;
  v_unknown    uuid;
  v_leg_count  int;
BEGIN
  IF p_idempotency_key IS NULL OR length(p_idempotency_key) = 0 THEN
    PERFORM ledger_raise('INVALID_IDEMPOTENCY_KEY', 422,
                         jsonb_build_object('reason_detail', 'idempotency key is required'));
  END IF;

  IF p_request_fingerprint IS NULL THEN
    PERFORM ledger_raise('INVALID_FINGERPRINT', 422,
                         jsonb_build_object('reason_detail', 'request fingerprint is required'));
  END IF;

  IF p_entries IS NULL OR jsonb_typeof(p_entries) <> 'array' THEN
    PERFORM ledger_raise('INVALID_ENTRY_SET', 422,
                         jsonb_build_object('reason_detail', 'entries must be a jsonb array'));
  END IF;

  v_leg_count := jsonb_array_length(p_entries);
  IF v_leg_count < 2 THEN
    PERFORM ledger_raise('INVALID_ENTRY_SET', 422, jsonb_build_object(
      'reason_detail', 'a double-entry posting needs at least two legs',
      'leg_count',     v_leg_count));
  END IF;

  -- Validate leg shape before touching any table, so a malformed request is a
  -- 422 with a reason rather than a raw cast error or a constraint violation.
  -- Deliberately cast-free: PostgreSQL does not promise left-to-right evaluation
  -- of an OR chain, so a ::bigint or ::uuid here could raise 22P02/22003 on junk
  -- input before the guard that was meant to reject it ever ran. Everything is
  -- therefore checked as text, by regex.
  SELECT e INTO v_bad
  FROM jsonb_array_elements(p_entries) AS e
  WHERE NOT (e ? 'account_id' AND e ? 'direction' AND e ? 'amount_minor' AND e ? 'currency')
     OR (e->>'direction') NOT IN ('debit', 'credit')
     OR jsonb_typeof(e->'amount_minor') <> 'number'
     OR (e->>'amount_minor') !~ '^[0-9]{1,18}$'   -- integer, non-negative, fits in bigint
     OR (e->>'amount_minor') ~ '^0+$'             -- CHECK (amount_minor > 0)
     OR upper(e->>'currency') !~ '^[A-Z]{3}$'
     OR (e->>'account_id') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  LIMIT 1;

  IF v_bad IS NOT NULL THEN
    PERFORM ledger_raise('INVALID_ENTRY', 422, jsonb_build_object('entry', v_bad));
  END IF;

  SELECT (e->>'account_id')::uuid INTO v_unknown
  FROM jsonb_array_elements(p_entries) AS e
  WHERE NOT EXISTS (SELECT 1 FROM ledger_accounts a WHERE a.id = (e->>'account_id')::uuid)
  LIMIT 1;

  IF v_unknown IS NOT NULL THEN
    PERFORM ledger_raise('UNKNOWN_ACCOUNT', 404, jsonb_build_object('account_id', v_unknown));
  END IF;

  INSERT INTO ledger_transactions
    (business_event_type, business_event_id, idempotency_key, request_fingerprint)
  VALUES
    (p_business_event_type, p_business_event_id, p_idempotency_key, p_request_fingerprint)
  ON CONFLICT (idempotency_key) DO NOTHING
  RETURNING id INTO v_tx_id;

  IF v_tx_id IS NULL THEN
    -- Either the key already existed, or a concurrent caller won the race and
    -- has since committed. Both are replays.
    SELECT * INTO v_existing
    FROM ledger_transactions
    WHERE idempotency_key = p_idempotency_key
    FOR UPDATE;

    IF NOT FOUND THEN
      -- Only reachable above READ COMMITTED: the winner committed after this
      -- snapshot was taken, so its row is invisible here even though the unique
      -- index rejected the insert. Retry the whole transaction.
      PERFORM ledger_raise('IDEMPOTENCY_RACE_RETRY', 503, jsonb_build_object(
        'idempotency_key', p_idempotency_key,
        'hint',            'ledger_post requires READ COMMITTED; retry the transaction'));
    END IF;

    IF v_existing.request_fingerprint IS DISTINCT FROM p_request_fingerprint THEN
      PERFORM ledger_raise('IDEMPOTENCY_KEY_CONFLICT', 409, jsonb_build_object(
        'idempotency_key',      p_idempotency_key,
        'transaction_id',       v_existing.id,
        'stored_fingerprint',   v_existing.request_fingerprint,
        'supplied_fingerprint', p_request_fingerprint));
    END IF;

    RETURN ROW(v_existing.id, true)::ledger_post_result;
  END IF;

  -- One statement: the balance trigger sees the whole posting at once.
  INSERT INTO ledger_entries (transaction_id, account_id, direction, amount_minor, currency)
  SELECT v_tx_id,
         (e->>'account_id')::uuid,
         (e->>'direction')::ledger_direction,
         (e->>'amount_minor')::bigint,
         upper(e->>'currency')::char(3)
  FROM jsonb_array_elements(p_entries) AS e;

  RETURN ROW(v_tx_id, false)::ledger_post_result;
END$$;

COMMENT ON FUNCTION ledger_post(text, text, text, uuid, jsonb) IS
  'The only supported way to write the ledger. Idempotent on p_idempotency_key: '
  'same fingerprint replays, different fingerprint raises IDEMPOTENCY_KEY_CONFLICT (409). '
  'Balance is validated at COMMIT by a deferred constraint trigger, not by this function.';

-- ============================================================================
-- Payout saga — create pending -> call provider -> mark submitted -> post
--
-- Every step is idempotent and every step can be resumed after a crash at any
-- boundary. The ledger effect is keyed on the payout id, so "post the entries"
-- can be attempted any number of times and land exactly once.
-- ============================================================================

-- Step 1. Reserve the payout. No ledger effect yet: no money has moved.
CREATE OR REPLACE FUNCTION ledger_payout_begin(
  p_request_id       text,
  p_payee_account_id uuid,
  p_cash_account_id  uuid,
  p_amount_minor     bigint,
  p_currency         char(3)
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_id uuid;
BEGIN
  IF p_amount_minor IS NULL OR p_amount_minor <= 0 THEN
    PERFORM ledger_raise('INVALID_AMOUNT', 422,
                         jsonb_build_object('amount_minor', p_amount_minor));
  END IF;

  INSERT INTO ledger_payouts
    (request_id, payee_account_id, cash_account_id, amount_minor, currency)
  VALUES
    (p_request_id, p_payee_account_id, p_cash_account_id, p_amount_minor,
     upper(p_currency)::char(3))
  ON CONFLICT (request_id) DO NOTHING
  RETURNING id INTO v_id;

  IF v_id IS NULL THEN
    SELECT id INTO v_id FROM ledger_payouts WHERE request_id = p_request_id FOR UPDATE;
    IF NOT FOUND THEN
      PERFORM ledger_raise('PAYOUT_RACE_RETRY', 503,
                           jsonb_build_object('request_id', p_request_id));
    END IF;
  END IF;

  RETURN v_id;
END$$;

-- Step 3. Record that the external provider accepted the payout. Still no
-- ledger effect: the provider call is the thing that can be lost, so the
-- bookkeeping deliberately trails it.
CREATE OR REPLACE FUNCTION ledger_payout_mark_submitted(
  p_payout_id    uuid,
  p_provider_ref text
) RETURNS ledger_payout_state
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_state ledger_payout_state;
BEGIN
  SELECT state INTO v_state FROM ledger_payouts WHERE id = p_payout_id FOR UPDATE;
  IF NOT FOUND THEN
    PERFORM ledger_raise('PAYOUT_NOT_FOUND', 404,
                         jsonb_build_object('payout_id', p_payout_id));
  END IF;

  IF v_state IN ('submitted', 'posted') THEN
    RETURN v_state;   -- idempotent replay
  END IF;

  IF v_state = 'failed' THEN
    PERFORM ledger_raise('PAYOUT_ALREADY_FAILED', 409,
                         jsonb_build_object('payout_id', p_payout_id));
  END IF;

  UPDATE ledger_payouts
  SET state = 'submitted', provider_ref = p_provider_ref, updated_at = now()
  WHERE id = p_payout_id;

  RETURN 'submitted'::ledger_payout_state;
END$$;

-- Step 4. Post the money movement. Idempotency key is derived from the payout
-- id, so however many times this runs, at most one ledger transaction exists.
CREATE OR REPLACE FUNCTION ledger_payout_post(p_payout_id uuid)
RETURNS ledger_post_result
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  p ledger_payouts%ROWTYPE;
  v_result ledger_post_result;
BEGIN
  SELECT * INTO p FROM ledger_payouts WHERE id = p_payout_id FOR UPDATE;
  IF NOT FOUND THEN
    PERFORM ledger_raise('PAYOUT_NOT_FOUND', 404,
                         jsonb_build_object('payout_id', p_payout_id));
  END IF;

  IF p.state = 'pending' THEN
    PERFORM ledger_raise('PAYOUT_NOT_SUBMITTED', 409, jsonb_build_object(
      'payout_id', p_payout_id,
      'state',     p.state,
      'hint',      'call the provider and ledger_payout_mark_submitted first'));
  END IF;

  IF p.state = 'failed' THEN
    PERFORM ledger_raise('PAYOUT_ALREADY_FAILED', 409,
                         jsonb_build_object('payout_id', p_payout_id));
  END IF;

  -- Debit what we owe the payee, credit the cash it comes out of.
  v_result := ledger_post(
    'payout:' || p_payout_id::text,
    'payout:' || p_payout_id::text || ':' || p.amount_minor::text,
    'payout',
    p_payout_id,
    jsonb_build_array(
      jsonb_build_object('account_id', p.payee_account_id, 'direction', 'debit',
                         'amount_minor', p.amount_minor, 'currency', p.currency),
      jsonb_build_object('account_id', p.cash_account_id, 'direction', 'credit',
                         'amount_minor', p.amount_minor, 'currency', p.currency)));

  UPDATE ledger_payouts
  SET state = 'posted', ledger_transaction_id = v_result.transaction_id, updated_at = now()
  WHERE id = p_payout_id;

  RETURN v_result;
END$$;

-- The provider rejected or reversed the payout.
--   * not yet posted -> mark failed, no ledger effect (nothing was ever recorded)
--   * already posted -> post a REVERSING transaction, never touch the original
CREATE OR REPLACE FUNCTION ledger_payout_fail(
  p_payout_id uuid,
  p_reason    text
) RETURNS ledger_payout_state
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  p ledger_payouts%ROWTYPE;
  v_result ledger_post_result;
BEGIN
  SELECT * INTO p FROM ledger_payouts WHERE id = p_payout_id FOR UPDATE;
  IF NOT FOUND THEN
    PERFORM ledger_raise('PAYOUT_NOT_FOUND', 404,
                         jsonb_build_object('payout_id', p_payout_id));
  END IF;

  IF p.state = 'failed' THEN
    RETURN 'failed'::ledger_payout_state;   -- idempotent replay
  END IF;

  IF p.state = 'posted' THEN
    v_result := ledger_post(
      'payout-reversal:' || p_payout_id::text,
      'payout-reversal:' || p_payout_id::text || ':' || p.amount_minor::text,
      'payout_reversal',
      p_payout_id,
      jsonb_build_array(
        jsonb_build_object('account_id', p.cash_account_id, 'direction', 'debit',
                           'amount_minor', p.amount_minor, 'currency', p.currency),
        jsonb_build_object('account_id', p.payee_account_id, 'direction', 'credit',
                           'amount_minor', p.amount_minor, 'currency', p.currency)));

    UPDATE ledger_payouts
    SET state = 'failed', failure_reason = p_reason,
        reversal_transaction_id = v_result.transaction_id, updated_at = now()
    WHERE id = p_payout_id;
  ELSE
    UPDATE ledger_payouts
    SET state = 'failed', failure_reason = p_reason, updated_at = now()
    WHERE id = p_payout_id;
  END IF;

  RETURN 'failed'::ledger_payout_state;
END$$;

-- The resume path. Given a payout in any state, drive it to a terminal one.
-- p_provider_ref is what the recovery job learned by asking the provider "did
-- you ever see this request?"; NULL means the provider never got it, so the
-- payout failed without a ledger effect.
CREATE OR REPLACE FUNCTION ledger_payout_resume(
  p_payout_id    uuid,
  p_provider_ref text DEFAULT NULL
) RETURNS ledger_payout_state
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_state ledger_payout_state;
BEGIN
  SELECT state INTO v_state FROM ledger_payouts WHERE id = p_payout_id;
  IF NOT FOUND THEN
    PERFORM ledger_raise('PAYOUT_NOT_FOUND', 404,
                         jsonb_build_object('payout_id', p_payout_id));
  END IF;

  IF v_state IN ('failed', 'posted') THEN
    RETURN v_state;
  END IF;

  IF v_state = 'pending' THEN
    IF p_provider_ref IS NULL THEN
      RETURN ledger_payout_fail(p_payout_id, 'provider never received the request');
    END IF;
    PERFORM ledger_payout_mark_submitted(p_payout_id, p_provider_ref);
  END IF;

  PERFORM ledger_payout_post(p_payout_id);
  RETURN 'posted'::ledger_payout_state;
END$$;

-- ============================================================================
-- Grants
--
-- The application role reads the ledger and calls the posting API. It has no
-- INSERT, UPDATE, DELETE or TRUNCATE on any ledger table — including TRUNCATE,
-- which is called out explicitly because TRUNCATE does not fire the row-level
-- immutability trigger and would otherwise be an unguarded way to erase history.
--
-- Note the REVOKE ... FROM PUBLIC on every SECURITY DEFINER function. PostgreSQL
-- grants EXECUTE to PUBLIC by default, so without these lines every role in the
-- database — including an untrusted client role — could post to the ledger.
-- ravon_ledger_anon exists to make that a test rather than a hope.
-- ============================================================================
REVOKE ALL ON ledger_accounts, ledger_transactions, ledger_entries,
                ledger_balances, ledger_payouts
  FROM PUBLIC, ravon_ledger_app, ravon_ledger_anon;

GRANT USAGE ON SCHEMA public TO ravon_ledger_app;

GRANT SELECT ON ledger_accounts, ledger_transactions, ledger_entries,
                ledger_balances, ledger_payouts, ledger_account_balances
  TO ravon_ledger_app;

REVOKE INSERT, UPDATE, DELETE, TRUNCATE
  ON ledger_entries, ledger_transactions, ledger_balances, ledger_accounts, ledger_payouts
  FROM ravon_ledger_app;

REVOKE EXECUTE ON FUNCTION
  ledger_post(text, text, text, uuid, jsonb),
  ledger_open_account(ledger_account_kind, uuid, char, boolean),
  ledger_payout_begin(text, uuid, uuid, bigint, char),
  ledger_payout_mark_submitted(uuid, text),
  ledger_payout_post(uuid),
  ledger_payout_fail(uuid, text),
  ledger_payout_resume(uuid, text),
  ledger_verify_balances(),
  ledger_split_minor(bigint, int[]),
  ledger_raise(text, int, jsonb)
  FROM PUBLIC;

-- ledger_deferred_check_count() is a test/ops diagnostic, not part of the money
-- path; it is SECURITY DEFINER so the app role can read it without USAGE on the
-- underlying sequence (which would also let it skew the counter).
GRANT EXECUTE ON FUNCTION
  ledger_post(text, text, text, uuid, jsonb),
  ledger_open_account(ledger_account_kind, uuid, char, boolean),
  ledger_payout_begin(text, uuid, uuid, bigint, char),
  ledger_payout_mark_submitted(uuid, text),
  ledger_payout_post(uuid),
  ledger_payout_fail(uuid, text),
  ledger_payout_resume(uuid, text),
  ledger_verify_balances(),
  ledger_split_minor(bigint, int[]),
  ledger_normal_sign(ledger_account_kind),
  ledger_deferred_check_count()
  TO ravon_ledger_app;

COMMIT;
