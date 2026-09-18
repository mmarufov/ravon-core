"""Who can reach the ledger.

CLAUDE.md records that previous security reports on this project flagged
anon-callable SECURITY DEFINER RPCs and over-broad UPDATE policies. Those are
exactly the two ways a ledger like this one gets compromised, so both are tests
rather than review items.
"""

from __future__ import annotations

import json
from uuid import uuid4

import psycopg
import pytest

from chart import CURRENCY, escrow_for, open_chart
from ledger_api import Ledger, LedgerError, authorize_entries, fingerprint_of

SERVICE_FUNCTIONS = [
    "ledger_post",
    "ledger_open_account",
    "ledger_payout_begin",
    "ledger_payout_mark_submitted",
    "ledger_payout_post",
    "ledger_payout_fail",
    "ledger_payout_resume",
]


def _post_sql(entries) -> tuple[str, tuple]:
    return (
        "SELECT transaction_id, replayed FROM ledger_post(%s, %s, 'authorize', %s::uuid, %s::jsonb)",
        (f"k:{uuid4()}", fingerprint_of(entries), uuid4(),
         json.dumps([e.as_json() for e in entries])),
    )


def test_service_role_can_post_through_the_api(ledger: Ledger, app_dsn: str):
    chart = open_chart(ledger)
    escrow = escrow_for(ledger, uuid4())
    entries = authorize_entries(chart.receivable, escrow, 5000, CURRENCY)

    with psycopg.connect(app_dsn) as conn, conn.cursor() as cur:
        cur.execute(*_post_sql(entries))
        tx_id, replayed = cur.fetchone()
        conn.commit()

    assert tx_id is not None and replayed is False
    assert ledger.natural_balance(escrow) == 5000


def test_the_invariant_still_holds_for_the_service_role(ledger: Ledger, app_dsn: str):
    """A deferred constraint trigger fires at COMMIT, which is outside the
    SECURITY DEFINER context of ledger_post — so it runs as the *session* user.
    If the check needed privileges the service role lacks, it would fail with
    "permission denied" instead of validating. It must produce the real error."""
    chart = open_chart(ledger)
    escrow = escrow_for(ledger, uuid4())
    entries = authorize_entries(chart.receivable, escrow, 5000, CURRENCY)
    entries[1] = entries[1].__class__(escrow, "credit", 4999, CURRENCY)

    with psycopg.connect(app_dsn) as conn:
        with conn.cursor() as cur:
            cur.execute(*_post_sql(entries))
        with pytest.raises(psycopg.Error) as exc:
            conn.commit()
        conn.rollback()

    assert LedgerError.from_psycopg(exc.value).reason == "UNBALANCED_TRANSACTION"


@pytest.mark.parametrize("statement", [
    "INSERT INTO ledger_entries (transaction_id, account_id, direction, amount_minor, currency)"
    " VALUES (gen_random_uuid(), gen_random_uuid(), 'debit', 1, 'TJS')",
    "UPDATE ledger_entries SET amount_minor = 1",
    "DELETE FROM ledger_entries",
    "TRUNCATE ledger_entries",
    "UPDATE ledger_transactions SET request_fingerprint = 'x'",
    "UPDATE ledger_balances SET balance_minor = 0",
    "INSERT INTO ledger_accounts (kind, currency) VALUES ('platform_revenue', 'USD')",
])
def test_service_role_cannot_write_any_ledger_table_directly(app_dsn: str, statement: str):
    """"must not: write ledger_entries directly" is enforced, not documented."""
    with psycopg.connect(app_dsn) as conn:
        with pytest.raises(psycopg.errors.InsufficientPrivilege):
            with conn.cursor() as cur:
                cur.execute(statement)
        conn.rollback()


def test_untrusted_client_role_cannot_execute_the_posting_api(anon_dsn: str):
    """PostgreSQL grants EXECUTE to PUBLIC by default. Without the explicit
    REVOKE ... FROM PUBLIC in schema.sql, every one of these SECURITY DEFINER
    functions would be callable by an untrusted client role — which is the
    finding shape CLAUDE.md warns about."""
    with psycopg.connect(anon_dsn) as conn, conn.cursor() as cur:
        cur.execute("""
            SELECT p.proname, has_function_privilege(current_user, p.oid, 'EXECUTE')
            FROM pg_proc p
            JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = 'public' AND p.proname = ANY(%s)
        """, (SERVICE_FUNCTIONS,))
        privileges = dict(cur.fetchall())

    assert privileges, "expected to find the service functions"
    assert set(privileges) == set(SERVICE_FUNCTIONS), \
        f"missing from pg_proc: {set(SERVICE_FUNCTIONS) - set(privileges)}"
    assert not any(privileges.values()), \
        f"executable by the untrusted role: {[k for k, v in privileges.items() if v]}"


def test_untrusted_client_role_is_actually_refused_at_call_time(anon_dsn: str):
    """The privilege bit above is the mechanism; this is the behaviour."""
    with psycopg.connect(anon_dsn) as conn:
        with pytest.raises(psycopg.errors.InsufficientPrivilege):
            with conn.cursor() as cur:
                cur.execute(
                    "SELECT transaction_id FROM ledger_post(%s, 'fp', 'x', %s::uuid, '[]'::jsonb)",
                    (f"k:{uuid4()}", uuid4()))
        conn.rollback()


def test_untrusted_client_role_cannot_read_the_ledger(anon_dsn: str):
    for table in ("ledger_accounts", "ledger_entries", "ledger_transactions",
                  "ledger_balances", "ledger_payouts"):
        with psycopg.connect(anon_dsn) as conn:
            with pytest.raises(psycopg.errors.InsufficientPrivilege):
                with conn.cursor() as cur:
                    cur.execute(f"SELECT * FROM {table}")
            conn.rollback()


def test_no_ledger_function_is_executable_by_public(ledger: Ledger):
    """Catches a future function added without the REVOKE, which is the exact
    shape of the finding in .gstack/security-reports."""
    leaked = ledger.query("""
        SELECT p.proname
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname LIKE 'ledger\\_%'
          AND p.prosecdef
          AND has_function_privilege('public', p.oid, 'EXECUTE')
    """)
    assert leaked == [], f"SECURITY DEFINER functions executable by PUBLIC: {leaked}"


def test_every_security_definer_function_pins_its_search_path(ledger: Ledger):
    """A SECURITY DEFINER function without a pinned search_path is a privilege
    escalation: the caller controls which schema its unqualified names resolve
    to."""
    unpinned = ledger.query("""
        SELECT p.proname
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname LIKE 'ledger\\_%'
          AND p.prosecdef
          AND NOT EXISTS (
            SELECT 1 FROM unnest(COALESCE(p.proconfig, '{}')) cfg
            WHERE cfg LIKE 'search\\_path=%'
          )
    """)
    assert unpinned == [], f"SECURITY DEFINER without SET search_path: {unpinned}"
