"""A stand-in for the external payout provider.

The hand-built suite never models the provider: its tests pass a provider_ref
string in, as if recovery had already asked the provider. A Temporal activity
has to actually call something, and Temporal will call it more than once, so
this fake is a real table in its own database, keyed on request_id.

Being idempotent on request_id is not a courtesy here. It is the property that
makes an at-least-once activity safe, and Temporal does not provide it.
"""

from __future__ import annotations

import psycopg

# Amounts above this are declined, so the workflow's failure branch is reachable.
DECLINE_ABOVE = 1_000_000

SCHEMA = """
CREATE TABLE IF NOT EXISTS provider_payouts (
  request_id   text PRIMARY KEY,
  provider_ref text NOT NULL DEFAULT 'prv_' || gen_random_uuid(),
  amount_minor bigint NOT NULL,
  currency     char(3) NOT NULL,
  calls        int NOT NULL DEFAULT 1
)
"""


def submit(dsn: str, request_id: str, amount_minor: int, currency: str) -> str | None:
    """Pay out once per request_id. Returns the provider's reference, or None if declined."""
    if amount_minor > DECLINE_ABOVE:
        return None
    with psycopg.connect(dsn) as conn:
        row = conn.execute(
            "INSERT INTO provider_payouts (request_id, amount_minor, currency) "
            "VALUES (%s, %s, %s) "
            "ON CONFLICT (request_id) DO UPDATE SET calls = provider_payouts.calls + 1 "
            "RETURNING provider_ref",
            (request_id, amount_minor, currency)).fetchone()
    return row[0]
