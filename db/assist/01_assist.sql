-- ============================================================================
-- Ravon Assist: what a merchant support agent may read, and how its one kind
-- of action reaches the ledger.
--
-- Applied after db/schema and db/ledger/schema.sql, in one database:
--
--     ./db/schema/apply.sh -d ravon --local
--     psql -v ON_ERROR_STOP=1 -d ravon -f db/ledger/schema.sql
--     psql -v ON_ERROR_STOP=1 -d ravon -f db/assist/01_assist.sql
--
-- The agent is an untrusted caller. Three rules follow, each enforced here
-- rather than in a prompt:
--
--   1. It reads as the asking merchant. Every view it can see is filtered by
--      row-level security on current_setting('assist.merchant_id'), which the
--      server sets from the merchant's session. No tool takes a merchant id as
--      an argument, so the model cannot ask for someone else's.
--   2. It cannot move money. Its only write is assist_propose(), which inserts
--      a pending row. It has no EXECUTE on ledger_post or assist_approve, and
--      db/assist/tests/test_privileges.py asserts that.
--   3. An approved action posts exactly once. assist_approve() locks the
--      proposal and posts with idempotency key 'assist:<proposal id>', so 50
--      concurrent approvals of one proposal produce one ledger transaction
--      (db/assist/tests/test_approval_race.py).
--
-- Every SECURITY DEFINER function here sets search_path = '' and qualifies
-- every name, which is rule R6 of db/schema/invariants.sql.
--
-- All data this file is tested with is seeded and synthetic (db/assist/seed.py).
-- ============================================================================

BEGIN;

-- ============================================================================
-- Roles
-- ============================================================================
-- assist_view_owner  owns the views in schema `assist`. The RLS policies below
--                    name this role, so a view returns only what the policy
--                    lets its owner see for the current assist.merchant_id.
--                    NOLOGIN, never used directly, and asserted to be neither
--                    superuser, BYPASSRLS, nor the owner of any table.
-- assist_reader      USAGE on schema `assist` and SELECT on its views. Nothing
--                    in `public`.
-- assist_proposer    EXECUTE on assist_propose() and nothing else.
-- assist_approver    a human operator: EXECUTE on assist_approve/assist_reject.
-- assist_agent       the agent process's login. Member of reader and proposer
--                    WITH INHERIT FALSE: it holds no privilege until a tool
--                    runs SET LOCAL ROLE, so each tool runs as exactly one role.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'assist_view_owner') THEN
    CREATE ROLE assist_view_owner NOLOGIN NOSUPERUSER NOBYPASSRLS;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'assist_reader') THEN
    CREATE ROLE assist_reader NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'assist_proposer') THEN
    CREATE ROLE assist_proposer NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'assist_approver') THEN
    CREATE ROLE assist_approver NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'assist_agent') THEN
    CREATE ROLE assist_agent NOLOGIN;
  END IF;
END$$;

GRANT assist_reader   TO assist_agent WITH INHERIT FALSE, SET TRUE;
GRANT assist_proposer TO assist_agent WITH INHERIT FALSE, SET TRUE;

-- ============================================================================
-- Tables
-- ============================================================================

-- The commission a merchant signed for. A settlement that withheld more than
-- this is the "misapplied commission" cause in seed.py.
CREATE TABLE public.merchant_contracts (
  merchant_id    uuid PRIMARY KEY REFERENCES public.profiles(id),
  commission_bps int  NOT NULL CHECK (commission_bps BETWEEN 0 AND 10000),
  currency       char(3) NOT NULL DEFAULT 'TJS' CHECK (currency ~ '^[A-Z]{3}$'),
  updated_at     timestamptz NOT NULL DEFAULT now()
);

-- One row per action the agent wants taken. Nothing here moves money: the row
-- is evidence plus intent, and only assist_approve() turns it into a posting.
CREATE TABLE public.assist_proposals (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  merchant_id  uuid NOT NULL REFERENCES public.profiles(id),
  -- Both kinds credit the merchant. They differ only in which platform
  -- account pays: revenue for a fee correction, clearing for a refund that
  -- should not have been charged to the merchant.
  kind         text NOT NULL CHECK (kind IN ('commission_correction', 'refund_reversal')),
  -- Capped at 10,000.00 TJS. A support agent has no business proposing more,
  -- and the cap is a constraint so no caller can lift it.
  amount_minor bigint NOT NULL CHECK (amount_minor > 0 AND amount_minor <= 1000000),
  currency     char(3) NOT NULL DEFAULT 'TJS' CHECK (currency ~ '^[A-Z]{3}$'),
  -- The ledger entries that justify the amount. Re-checked at approval.
  entry_ids    bigint[] NOT NULL CHECK (cardinality(entry_ids) BETWEEN 1 AND 50),
  reason       text NOT NULL CHECK (length(reason) BETWEEN 1 AND 2000),
  status       text NOT NULL DEFAULT 'pending'
                 CHECK (status IN ('pending', 'approved', 'rejected')),
  decided_by   text,
  decided_at   timestamptz,
  ledger_tx_id uuid REFERENCES public.ledger_transactions(id),
  created_at   timestamptz NOT NULL DEFAULT now(),
  -- An approved proposal names its posting, and only an approved one does.
  CONSTRAINT assist_proposals_approved_has_tx
    CHECK ((status = 'approved') = (ledger_tx_id IS NOT NULL)),
  CONSTRAINT assist_proposals_decided_has_decider
    CHECK ((status = 'pending') = (decided_by IS NULL))
);

CREATE INDEX assist_proposals_merchant_idx
  ON public.assist_proposals (merchant_id, created_at DESC);

-- ============================================================================
-- Scope
--
-- assist_merchant_id() is the asker. The scope functions turn it into sets of
-- ids, and the RLS policies compare against those sets. They are SECURITY
-- DEFINER so that computing the scope does not itself depend on RLS (orders
-- and restaurants carry their own policies for the app roles).
--
-- An unset or empty setting is NULL, every scope is then empty, and every view
-- returns no rows. tests/test_scope.py checks that this fails closed.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.assist_merchant_id()
RETURNS uuid
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  SELECT nullif(current_setting('assist.merchant_id', true), '')::uuid
$$;

CREATE OR REPLACE FUNCTION public.assist_orders_of(p_merchant uuid)
RETURNS uuid[]
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT COALESCE(array_agg(o.id), '{}')
  FROM public.orders o
  JOIN public.restaurants r ON r.id = o.restaurant_id
  WHERE r.owner_id = p_merchant
$$;

-- A merchant's own accounts: its payable balance and the escrow of each of
-- its orders. Courier payables and other merchants' accounts are never here.
CREATE OR REPLACE FUNCTION public.assist_accounts_of(p_merchant uuid)
RETURNS uuid[]
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT COALESCE(array_agg(a.id), '{}')
  FROM public.ledger_accounts a
  WHERE (a.kind = 'merchant_payable' AND a.owner_id = p_merchant)
     OR (a.kind = 'order_escrow'     AND a.owner_id = ANY (public.assist_orders_of(p_merchant)))
$$;

-- Transactions that touch one of those accounts.
CREATE OR REPLACE FUNCTION public.assist_transactions_of(p_merchant uuid)
RETURNS uuid[]
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT COALESCE(array_agg(DISTINCT e.transaction_id), '{}')
  FROM public.ledger_entries e
  WHERE e.account_id = ANY (public.assist_accounts_of(p_merchant))
$$;

-- The entries a merchant may see and cite: a leg on one of its own accounts,
-- or a platform leg (owner_id IS NULL, e.g. the commission credited to
-- platform_revenue) of a transaction that touches its accounts. Courier legs
-- and other merchants' legs are never in it.
CREATE OR REPLACE FUNCTION public.assist_entries_of(p_merchant uuid)
RETURNS bigint[]
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT COALESCE(array_agg(e.id), '{}')
  FROM public.ledger_entries e
  JOIN public.ledger_accounts a ON a.id = e.account_id
  WHERE e.account_id = ANY (public.assist_accounts_of(p_merchant))
     OR (a.owner_id IS NULL
         AND e.transaction_id = ANY (public.assist_transactions_of(p_merchant)))
$$;

-- What the policies call. Zero-argument, so whoever evaluates a policy can
-- only ever learn the scope of the merchant in its own session. PostgreSQL
-- checks EXECUTE on a policy's functions against the querying role (here
-- assist_reader), so these are granted to it; the *_of(merchant) functions
-- above are granted to no one and are reachable only through these and the
-- definer functions below.
CREATE OR REPLACE FUNCTION public.assist_scope_orders()
RETURNS uuid[] LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$ SELECT public.assist_orders_of(public.assist_merchant_id()) $$;

CREATE OR REPLACE FUNCTION public.assist_scope_accounts()
RETURNS uuid[] LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$ SELECT public.assist_accounts_of(public.assist_merchant_id()) $$;

CREATE OR REPLACE FUNCTION public.assist_scope_transactions()
RETURNS uuid[] LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$ SELECT public.assist_transactions_of(public.assist_merchant_id()) $$;

CREATE OR REPLACE FUNCTION public.assist_scope_entries()
RETURNS bigint[] LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$ SELECT public.assist_entries_of(public.assist_merchant_id()) $$;

-- ============================================================================
-- Row-level security
--
-- Policies are written TO assist_view_owner only. Existing roles keep exactly
-- what they had: the app roles from db/schema are named in their own policies,
-- and ravon_ledger_app gets an explicit allow-all SELECT policy because turning
-- RLS on for the ledger tables would otherwise hide every row from it.
--
-- Each policy reads its scope as `x IN (SELECT unnest(...))`, a subplan the
-- planner runs once per statement rather than once per row.
-- ============================================================================
ALTER TABLE public.ledger_accounts     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ledger_transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ledger_entries      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ledger_payouts      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.merchant_contracts  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.assist_proposals    ENABLE ROW LEVEL SECURITY;

CREATE POLICY ledger_app_read ON public.ledger_accounts     FOR SELECT TO ravon_ledger_app USING (true);
CREATE POLICY ledger_app_read ON public.ledger_transactions FOR SELECT TO ravon_ledger_app USING (true);
CREATE POLICY ledger_app_read ON public.ledger_entries      FOR SELECT TO ravon_ledger_app USING (true);
CREATE POLICY ledger_app_read ON public.ledger_payouts      FOR SELECT TO ravon_ledger_app USING (true);

CREATE POLICY assist_scope ON public.ledger_accounts FOR SELECT TO assist_view_owner
  USING (owner_id IS NULL
         OR id IN (SELECT unnest(public.assist_scope_accounts())));
CREATE POLICY assist_scope ON public.ledger_transactions FOR SELECT TO assist_view_owner
  USING (id IN (SELECT unnest(public.assist_scope_transactions())));
CREATE POLICY assist_scope ON public.ledger_entries FOR SELECT TO assist_view_owner
  USING (id IN (SELECT unnest(public.assist_scope_entries())));
CREATE POLICY assist_scope ON public.ledger_payouts FOR SELECT TO assist_view_owner
  USING (payee_account_id IN (SELECT unnest(public.assist_scope_accounts())));
CREATE POLICY assist_scope ON public.orders FOR SELECT TO assist_view_owner
  USING (id IN (SELECT unnest(public.assist_scope_orders())));
CREATE POLICY assist_scope ON public.order_status_history FOR SELECT TO assist_view_owner
  USING (order_id IN (SELECT unnest(public.assist_scope_orders())));
CREATE POLICY assist_scope ON public.courier_cancellation_log FOR SELECT TO assist_view_owner
  USING (order_id IN (SELECT unnest(public.assist_scope_orders())));
CREATE POLICY assist_scope ON public.merchant_contracts FOR SELECT TO assist_view_owner
  USING (merchant_id = public.assist_merchant_id());
CREATE POLICY assist_scope ON public.assist_proposals FOR SELECT TO assist_view_owner
  USING (merchant_id = public.assist_merchant_id());
-- The operator reviewing proposals sees all of them.
CREATE POLICY assist_approver_read ON public.assist_proposals FOR SELECT TO assist_approver
  USING (true);

GRANT USAGE ON SCHEMA public TO assist_view_owner;
GRANT SELECT ON public.ledger_accounts, public.ledger_transactions, public.ledger_entries,
                public.ledger_payouts, public.orders, public.order_status_history,
                public.courier_cancellation_log, public.merchant_contracts,
                public.assist_proposals
  TO assist_view_owner;

-- ============================================================================
-- Views: everything the read tools can see
--
-- In their own schema, owned by assist_view_owner, and deliberately NOT
-- security_invoker. db/schema rule R5 requires security_invoker on views in
-- `public` because a view owned by the table owner skips RLS (finding N10).
-- These are owned by a role that owns no table and cannot bypass RLS, so the
-- policies above apply to every read, and the reader needs no grant on any
-- base table, which a security_invoker view would require. test_privileges.py
-- asserts both properties of the owner.
--
-- security_barrier keeps a caller-supplied WHERE clause from running before
-- the policy filter.
--
-- effect_minor is the one number a claim is checked against: the entry's
-- effect on its own account in that account's natural sign. Positive means the
-- account grew (the merchant is owed more, escrow received money), negative
-- means it shrank (a payout or a charge left the merchant's balance).
-- ============================================================================
CREATE SCHEMA assist;
ALTER SCHEMA assist OWNER TO assist_view_owner;

CREATE VIEW assist.entries WITH (security_barrier) AS
SELECT e.id                  AS entry_id,
       e.transaction_id,
       t.business_event_type AS event_type,
       t.business_event_id   AS event_id,
       a.kind                AS account_kind,
       CASE WHEN a.kind = 'order_escrow' THEN a.owner_id END AS order_id,
       e.direction,
       e.amount_minor,
       (CASE WHEN e.direction = 'debit' THEN e.amount_minor ELSE -e.amount_minor END)
         * public.ledger_normal_sign(a.kind) AS effect_minor,
       e.currency,
       e.created_at
FROM public.ledger_entries e
JOIN public.ledger_accounts a     ON a.id = e.account_id
JOIN public.ledger_transactions t ON t.id = e.transaction_id;

CREATE VIEW assist.payouts WITH (security_barrier) AS
SELECT p.id AS payout_id, p.state::text AS state, p.amount_minor, p.currency, p.provider_ref,
       p.failure_verdict::text AS failure_verdict, p.ledger_transaction_id,
       p.created_at, p.updated_at
FROM public.ledger_payouts p;

-- Money columns are numeric(10,2) on orders (02_tables.sql); converted here so
-- the agent sees one unit everywhere. customer_note is written by the
-- consumer, which is why two seeded cases carry a prompt injection in it.
CREATE VIEW assist.orders WITH (security_barrier) AS
SELECT o.id AS order_id, o.status::text AS status,
       (o.subtotal     * 100)::bigint AS subtotal_minor,
       (o.delivery_fee * 100)::bigint AS delivery_fee_minor,
       (o.tip_amount   * 100)::bigint AS tip_minor,
       (o.total        * 100)::bigint AS total_minor,
       o.reassign_count, o.notes AS customer_note,
       o.created_at, o.delivered_at
FROM public.orders o;

-- Status changes (appended by trigger, 09_triggers.sql) and courier cancels,
-- interleaved. Courier ids are left out: the merchant needs the reason, not
-- the person.
CREATE VIEW assist.order_history WITH (security_barrier) AS
SELECT h.id AS event_id, h.order_id, 'status_change'::text AS event,
       h.status::text AS status, h.notes AS detail, h.created_at
FROM public.order_status_history h
UNION ALL
SELECT c.id, c.order_id, 'courier_cancel',
       c.status_at_cancel::text, c.reason_code, c.created_at
FROM public.courier_cancellation_log c;

CREATE VIEW assist.contract WITH (security_barrier) AS
SELECT merchant_id, commission_bps, currency FROM public.merchant_contracts;

CREATE VIEW assist.my_proposals WITH (security_barrier) AS
SELECT id AS proposal_id, kind, amount_minor, currency, entry_ids, reason, status, created_at
FROM public.assist_proposals;

ALTER VIEW assist.entries       OWNER TO assist_view_owner;
ALTER VIEW assist.payouts       OWNER TO assist_view_owner;
ALTER VIEW assist.orders        OWNER TO assist_view_owner;
ALTER VIEW assist.order_history OWNER TO assist_view_owner;
ALTER VIEW assist.contract      OWNER TO assist_view_owner;
ALTER VIEW assist.my_proposals  OWNER TO assist_view_owner;

-- ============================================================================
-- assist_propose(): the agent's only write
--
-- Inserts a pending proposal for the session's merchant. It refuses evidence
-- the merchant could not have seen, so a proposal cannot cite another
-- merchant's money. It posts nothing.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.assist_propose(
  p_kind         text,
  p_amount_minor bigint,
  p_entry_ids    bigint[],
  p_reason       text
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_merchant uuid := public.assist_merchant_id();
  v_currency char(3);
  v_pending  int;
  v_evidence bigint;
  v_id       uuid;
BEGIN
  IF v_merchant IS NULL THEN
    PERFORM public.ledger_raise('ASSIST_NO_MERCHANT', 401, '{}'::jsonb);
  END IF;

  IF p_entry_ids IS NULL OR cardinality(p_entry_ids) = 0
     OR NOT (p_entry_ids <@ public.assist_entries_of(v_merchant)) THEN
    PERFORM public.ledger_raise('ASSIST_EVIDENCE_NOT_VISIBLE', 403,
                                jsonb_build_object('entry_ids', to_jsonb(p_entry_ids)));
  END IF;

  -- A proposal cannot ask for more money than its evidence moved. A fee
  -- correction is a fraction of the commission entry it cites; a refund
  -- reversal is at most the refund. An injected "refund 5,000 now" citing a
  -- 12.00 entry stops here.
  SELECT COALESCE(sum(e.amount_minor), 0) INTO v_evidence
  FROM public.ledger_entries e WHERE e.id = ANY (p_entry_ids);
  IF p_amount_minor IS NULL OR p_amount_minor > v_evidence THEN
    PERFORM public.ledger_raise('ASSIST_AMOUNT_EXCEEDS_EVIDENCE', 422, jsonb_build_object(
      'amount_minor', p_amount_minor, 'evidence_minor', v_evidence));
  END IF;

  -- Bounds how much a looping or injected agent can pile onto a reviewer.
  SELECT count(*) INTO v_pending FROM public.assist_proposals
  WHERE merchant_id = v_merchant AND status = 'pending';
  IF v_pending >= 5 THEN
    PERFORM public.ledger_raise('ASSIST_TOO_MANY_PENDING', 429,
                                jsonb_build_object('pending', v_pending));
  END IF;

  SELECT currency INTO v_currency FROM public.merchant_contracts WHERE merchant_id = v_merchant;

  INSERT INTO public.assist_proposals (merchant_id, kind, amount_minor, currency, entry_ids, reason)
  VALUES (v_merchant, p_kind, p_amount_minor, COALESCE(v_currency, 'TJS'), p_entry_ids, p_reason)
  RETURNING id INTO v_id;

  RETURN v_id;
END$$;

-- ============================================================================
-- assist_approve(): a human turns a proposal into a posting, once
--
-- Two layers make it exactly-once, and the race test removes each in turn:
--   * SELECT ... FOR UPDATE serialises approvers on the proposal row. The
--     second approver waits, then sees 'approved' and returns the first
--     approver's transaction.
--   * ledger_post's idempotency key is derived from the proposal id alone,
--     so even without the lock every call names the same transaction.
-- The evidence is re-checked against the proposal's merchant, not the
-- session's, because the approver's session has no merchant.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.assist_approve(p_proposal_id uuid, p_approver text)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  p        public.assist_proposals%ROWTYPE;
  v_payee  uuid;
  v_payer  uuid;
  v_result public.ledger_post_result;
BEGIN
  IF p_approver IS NULL OR length(trim(p_approver)) = 0 THEN
    PERFORM public.ledger_raise('ASSIST_APPROVER_REQUIRED', 422, '{}'::jsonb);
  END IF;

  SELECT * INTO p FROM public.assist_proposals WHERE id = p_proposal_id FOR UPDATE;
  IF NOT FOUND THEN
    PERFORM public.ledger_raise('ASSIST_PROPOSAL_NOT_FOUND', 404,
                                jsonb_build_object('proposal_id', p_proposal_id));
  END IF;

  IF p.status = 'approved' THEN
    RETURN p.ledger_tx_id;   -- a second click: same answer, nothing new posted
  END IF;
  IF p.status = 'rejected' THEN
    PERFORM public.ledger_raise('ASSIST_PROPOSAL_REJECTED', 409,
                                jsonb_build_object('proposal_id', p_proposal_id));
  END IF;

  IF NOT (p.entry_ids <@ public.assist_entries_of(p.merchant_id)) THEN
    PERFORM public.ledger_raise('ASSIST_EVIDENCE_NOT_VISIBLE', 403,
                                jsonb_build_object('proposal_id', p_proposal_id));
  END IF;

  v_payee := public.ledger_open_account('merchant_payable', p.merchant_id, p.currency);
  v_payer := CASE p.kind
               WHEN 'commission_correction'
                 THEN public.ledger_open_account('platform_revenue', NULL, p.currency, true)
               WHEN 'refund_reversal'
                 THEN public.ledger_open_account('psp_clearing', NULL, p.currency, true)
             END;

  v_result := public.ledger_post(
    'assist:' || p.id::text,
    'assist:' || p.id::text || ':' || p.kind || ':' || p.amount_minor::text,
    'assist_' || p.kind,
    p.id,
    jsonb_build_array(
      jsonb_build_object('account_id', v_payer, 'direction', 'debit',
                         'amount_minor', p.amount_minor, 'currency', p.currency),
      jsonb_build_object('account_id', v_payee, 'direction', 'credit',
                         'amount_minor', p.amount_minor, 'currency', p.currency)));

  UPDATE public.assist_proposals
  SET status = 'approved', decided_by = p_approver, decided_at = now(),
      ledger_tx_id = v_result.transaction_id
  WHERE id = p.id;

  RETURN v_result.transaction_id;
END$$;

CREATE OR REPLACE FUNCTION public.assist_reject(p_proposal_id uuid, p_approver text)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_status text;
BEGIN
  IF p_approver IS NULL OR length(trim(p_approver)) = 0 THEN
    PERFORM public.ledger_raise('ASSIST_APPROVER_REQUIRED', 422, '{}'::jsonb);
  END IF;
  SELECT status INTO v_status FROM public.assist_proposals WHERE id = p_proposal_id FOR UPDATE;
  IF NOT FOUND THEN
    PERFORM public.ledger_raise('ASSIST_PROPOSAL_NOT_FOUND', 404,
                                jsonb_build_object('proposal_id', p_proposal_id));
  END IF;
  IF v_status = 'approved' THEN
    PERFORM public.ledger_raise('ASSIST_PROPOSAL_ALREADY_APPROVED', 409,
                                jsonb_build_object('proposal_id', p_proposal_id));
  END IF;
  UPDATE public.assist_proposals
  SET status = 'rejected', decided_by = p_approver, decided_at = now()
  WHERE id = p_proposal_id AND status = 'pending';
  RETURN 'rejected';
END$$;

-- ============================================================================
-- Grants
--
-- PostgreSQL grants EXECUTE to PUBLIC on every new function, so each one is
-- revoked first and granted back to exactly the role that needs it. The
-- *_of(merchant) functions take a merchant id, so a role that could call them
-- could enumerate any merchant's ids; they are granted to no one.
-- ============================================================================
REVOKE ALL ON public.merchant_contracts, public.assist_proposals FROM PUBLIC;
REVOKE ALL ON SCHEMA assist FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION
  public.assist_merchant_id(),
  public.assist_scope_orders(),
  public.assist_scope_accounts(),
  public.assist_scope_transactions(),
  public.assist_scope_entries(),
  public.assist_orders_of(uuid),
  public.assist_accounts_of(uuid),
  public.assist_transactions_of(uuid),
  public.assist_entries_of(uuid),
  public.assist_propose(text, bigint, bigint[], text),
  public.assist_approve(uuid, text),
  public.assist_reject(uuid, text)
  FROM PUBLIC;

GRANT EXECUTE ON FUNCTION
  public.assist_merchant_id(),
  public.assist_scope_orders(),
  public.assist_scope_accounts(),
  public.assist_scope_transactions(),
  public.assist_scope_entries()
  TO assist_view_owner, assist_reader;

GRANT USAGE ON SCHEMA assist TO assist_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA assist TO assist_reader;

GRANT USAGE ON SCHEMA public TO assist_proposer, assist_approver;
GRANT EXECUTE ON FUNCTION public.assist_propose(text, bigint, bigint[], text) TO assist_proposer;

GRANT EXECUTE ON FUNCTION public.assist_approve(uuid, text), public.assist_reject(uuid, text)
  TO assist_approver;
GRANT SELECT ON public.assist_proposals TO assist_approver;

COMMIT;
