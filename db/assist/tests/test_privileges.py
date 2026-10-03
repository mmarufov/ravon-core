"""The agent cannot move money, and cannot read past its merchant.

Each assertion is a query over the catalog, so one helper,
forbidden_privileges(), lists every violation. The negative controls grant one
forbidden privilege inside a rolled-back transaction and check the helper sees
it: a privilege check nobody has watched fail proves nothing.
"""

from __future__ import annotations

import psycopg
import pytest

AGENT_ROLES = ("assist_agent", "assist_reader", "assist_proposer")

# Functions that move money or decide proposals. None of them may be
# executable by any role the agent can become.
MONEY_FUNCTIONS = (
    "public.ledger_post(text, text, text, uuid, jsonb)",
    "public.ledger_open_account(ledger_account_kind, uuid, char, boolean)",
    "public.ledger_payout_begin(text, uuid, uuid, bigint, char)",
    "public.ledger_payout_mark_submitted(uuid, text)",
    "public.ledger_payout_post(uuid)",
    "public.ledger_payout_fail(uuid, ledger_payout_verdict, text)",
    "public.ledger_payout_resume(uuid, text, ledger_payout_verdict)",
    "public.assist_approve(uuid, text)",
    "public.assist_reject(uuid, text)",
)

FORBIDDEN_SQL = """
WITH roles(r) AS (SELECT unnest(%(roles)s::text[])),
fns(f) AS (SELECT unnest(%(fns)s::text[])::regprocedure)
-- 1. no agent role may execute a money function
SELECT format('%%s can EXECUTE %%s', r, f::text)
FROM roles, fns WHERE has_function_privilege(r, f, 'EXECUTE')
UNION ALL
-- 2. no agent role may write any table, anywhere
SELECT format('%%s can %%s %%I.%%I', r, p, n.nspname, c.relname)
FROM roles, pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace,
     unnest(ARRAY['INSERT','UPDATE','DELETE','TRUNCATE']) p
WHERE c.relkind IN ('r','p','v') AND n.nspname IN ('public','assist','auth')
  AND has_table_privilege(r, c.oid, p)
UNION ALL
-- 3. no agent role may read a base table in public: reads go through views
SELECT format('%%s can SELECT public.%%I', r, c.relname)
FROM roles, pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public' AND c.relkind IN ('r','p','v')
  AND has_table_privilege(r, c.oid, 'SELECT')
UNION ALL
-- 4. the login role itself holds nothing until it SETs a role
SELECT 'assist_agent inherits ' || b.rolname
FROM pg_auth_members m JOIN pg_roles a ON a.oid = m.member JOIN pg_roles b ON b.oid = m.roleid
WHERE a.rolname = 'assist_agent' AND m.inherit_option
UNION ALL
-- 5. the view owner cannot bypass RLS and owns no table, or the views would leak
SELECT 'assist_view_owner is superuser or BYPASSRLS'
FROM pg_roles WHERE rolname = 'assist_view_owner' AND (rolsuper OR rolbypassrls)
UNION ALL
SELECT 'assist_view_owner owns table ' || c.relname
FROM pg_class c WHERE c.relkind IN ('r','p') AND pg_get_userbyid(c.relowner) = 'assist_view_owner'
UNION ALL
-- 6. every assist definer function: empty search_path, no PUBLIC or anon EXECUTE
SELECT format('%%s: %%s', p.oid::regprocedure, problem)
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace,
     LATERAL (VALUES
       (CASE WHEN NOT EXISTS (SELECT 1 FROM unnest(COALESCE(p.proconfig, '{}')) cfg
                              WHERE cfg IN ('search_path=', 'search_path=""'))
             THEN 'search_path not empty' END),
       (CASE WHEN has_function_privilege('anon', p.oid, 'EXECUTE') THEN 'anon can EXECUTE' END),
       (CASE WHEN has_function_privilege('authenticated', p.oid, 'EXECUTE')
             THEN 'authenticated can EXECUTE' END)) v(problem)
WHERE n.nspname = 'public' AND p.proname LIKE 'assist\\_%%' AND p.prosecdef AND problem IS NOT NULL
UNION ALL
-- 7. the app's client roles cannot see the assist schema at all
SELECT r || ' has USAGE on schema assist'
FROM unnest(ARRAY['anon','authenticated']) r WHERE has_schema_privilege(r, 'assist', 'USAGE')
"""


def forbidden_privileges(conn: psycopg.Connection) -> list[str]:
    with conn.cursor() as cur:
        cur.execute(FORBIDDEN_SQL, {"roles": list(AGENT_ROLES), "fns": list(MONEY_FUNCTIONS)})
        return [r[0] for r in cur.fetchall()]


def test_no_agent_role_holds_a_forbidden_privilege(admin):
    assert forbidden_privileges(admin) == []


@pytest.mark.parametrize("grant, expected", [
    ("GRANT EXECUTE ON FUNCTION public.ledger_post(text, text, text, uuid, jsonb) TO assist_reader",
     "assist_reader can EXECUTE ledger_post"),
    ("GRANT EXECUTE ON FUNCTION public.assist_approve(uuid, text) TO assist_proposer",
     "assist_proposer can EXECUTE assist_approve"),
    ("GRANT INSERT ON public.assist_proposals TO assist_reader",
     "assist_reader can INSERT public.assist_proposals"),
    ("GRANT SELECT ON public.ledger_entries TO assist_reader",
     "assist_reader can SELECT public.ledger_entries"),
    ("ALTER ROLE assist_view_owner BYPASSRLS",
     "assist_view_owner is superuser or BYPASSRLS"),
    ("GRANT assist_reader TO assist_agent WITH INHERIT TRUE",
     "assist_agent inherits assist_reader"),
])
def test_negative_control_each_forbidden_grant_is_detected(dsn, grant, expected):
    with psycopg.connect(dsn) as conn:
        conn.execute(grant)
        found = forbidden_privileges(conn)
        conn.rollback()
    assert any(expected in f for f in found), found


def test_agent_login_cannot_read_anything_without_set_role(agent_dsn):
    with psycopg.connect(agent_dsn) as conn:
        with pytest.raises(psycopg.errors.InsufficientPrivilege):
            conn.execute("SELECT count(*) FROM assist.entries")


@pytest.mark.parametrize("role", ["assist_reader", "assist_proposer"])
def test_agent_cannot_call_ledger_post_under_either_role(agent_dsn, cases, role):
    merchant = next(iter(cases.values()))["merchant_id"]
    with psycopg.connect(agent_dsn) as conn:
        conn.execute(f"SET ROLE {role}")
        conn.execute("SELECT set_config('assist.merchant_id', %s, false)", (merchant,))
        with pytest.raises(psycopg.errors.InsufficientPrivilege):
            conn.execute("SELECT public.ledger_post('assist:rogue', 'x', 'assist_rogue', "
                         "gen_random_uuid(), '[]'::jsonb)")


@pytest.mark.parametrize("role", ["assist_reader", "assist_proposer"])
def test_agent_cannot_approve_its_own_proposal(agent_dsn, role):
    with psycopg.connect(agent_dsn) as conn:
        conn.execute(f"SET ROLE {role}")
        with pytest.raises(psycopg.errors.InsufficientPrivilege):
            conn.execute("SELECT public.assist_approve(gen_random_uuid(), 'agent')")


def test_agent_cannot_become_the_approver(agent_dsn):
    with psycopg.connect(agent_dsn) as conn:
        with pytest.raises(psycopg.errors.InsufficientPrivilege):
            conn.execute("SET ROLE assist_approver")
