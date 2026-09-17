"""Thin Python client for the ledger's SQL API.

Deliberately thin. Every rule in the test suite goes through ledger_post(), the
same entry point the Kotlin service will use, so that a passing test says
something about the database rather than about this file. The only functions
here that do not map 1:1 onto a SQL function are the flow helpers at the bottom,
which just assemble entry lists.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from typing import Any, Iterable, Sequence
from uuid import UUID, uuid4

import psycopg


class LedgerError(Exception):
    """A structured error raised by the schema.

    The schema follows the repo's RPC convention: SQLSTATE P0001 with a jsonb
    DETAIL carrying `reason` and `http_status`. Anything else (a raw constraint
    violation, a permission error) surfaces with reason=None so a test that
    expected a clean reason fails loudly instead of matching by accident.
    """

    def __init__(self, reason: str | None, http_status: int | None,
                 detail: dict[str, Any], sqlstate: str | None, message: str):
        super().__init__(f"{reason or sqlstate}: {message}")
        self.reason = reason
        self.http_status = http_status
        self.detail = detail
        self.sqlstate = sqlstate

    @classmethod
    def from_psycopg(cls, exc: psycopg.Error) -> "LedgerError":
        detail: dict[str, Any] = {}
        raw = exc.diag.message_detail if exc.diag else None
        if raw:
            try:
                parsed = json.loads(raw)
                if isinstance(parsed, dict):
                    detail = parsed
            except (ValueError, TypeError):
                detail = {"raw": raw}
        return cls(
            reason=detail.get("reason"),
            http_status=detail.get("http_status"),
            detail=detail,
            sqlstate=exc.diag.sqlstate if exc.diag else None,
            message=str(exc).strip().splitlines()[0] if str(exc).strip() else "",
        )


@dataclass(frozen=True)
class Entry:
    account_id: UUID
    direction: str          # 'debit' | 'credit'
    amount_minor: int
    currency: str

    def as_json(self) -> dict[str, Any]:
        return {
            "account_id": str(self.account_id),
            "direction": self.direction,
            "amount_minor": self.amount_minor,
            "currency": self.currency,
        }

    @property
    def signed(self) -> int:
        return self.amount_minor if self.direction == "debit" else -self.amount_minor


def debit(account_id: UUID, amount: int, currency: str) -> Entry:
    return Entry(account_id, "debit", amount, currency)


def credit(account_id: UUID, amount: int, currency: str) -> Entry:
    return Entry(account_id, "credit", amount, currency)


@dataclass(frozen=True)
class PostResult:
    transaction_id: UUID
    replayed: bool


class Ledger:
    """Wraps one psycopg connection with autocommit off.

    Each call is its own database transaction and ends in COMMIT, because COMMIT
    is where the deferred balance check runs — a helper that left transactions
    open would silently skip the invariant it exists to exercise.
    """

    def __init__(self, conn: psycopg.Connection):
        self.conn = conn
        self.conn.autocommit = False

    # -- plumbing ---------------------------------------------------------

    def _commit(self) -> None:
        try:
            self.conn.commit()
        except psycopg.Error as exc:            # deferred trigger fired at COMMIT
            self.conn.rollback()
            raise LedgerError.from_psycopg(exc) from exc

    def _abort(self) -> None:
        try:
            self.conn.rollback()
        except psycopg.Error:
            pass

    def query(self, sql: str, params: Sequence[Any] = ()) -> list[tuple]:
        with self.conn.cursor() as cur:
            cur.execute(sql, params)
            rows = cur.fetchall()
        self._commit()
        return rows

    def scalar(self, sql: str, params: Sequence[Any] = ()) -> Any:
        rows = self.query(sql, params)
        return rows[0][0] if rows else None

    # -- the API ----------------------------------------------------------

    def open_account(self, kind: str, owner_id: UUID | None, currency: str,
                     allow_negative: bool = False) -> UUID:
        try:
            with self.conn.cursor() as cur:
                cur.execute(
                    "SELECT ledger_open_account(%s::ledger_account_kind, %s::uuid, %s::char(3), %s)",
                    (kind, owner_id, currency, allow_negative),
                )
                account_id = cur.fetchone()[0]
        except psycopg.Error as exc:
            self._abort()
            raise LedgerError.from_psycopg(exc) from exc
        self._commit()
        return account_id

    def post(self, idempotency_key: str, fingerprint: str, event_type: str,
             event_id: UUID, entries: Iterable[Entry]) -> PostResult:
        payload = json.dumps([e.as_json() for e in entries])
        try:
            with self.conn.cursor() as cur:
                cur.execute(
                    "SELECT transaction_id, replayed FROM ledger_post(%s, %s, %s, %s::uuid, %s::jsonb)",
                    (idempotency_key, fingerprint, event_type, event_id, payload),
                )
                tx_id, replayed = cur.fetchone()
        except psycopg.Error as exc:
            self._abort()
            raise LedgerError.from_psycopg(exc) from exc
        self._commit()                          # balance is decided here, not above
        return PostResult(tx_id, replayed)

    def split(self, total: int, bps: Sequence[int]) -> list[int]:
        return self.scalar("SELECT ledger_split_minor(%s::bigint, %s::int[])",
                           (total, list(bps)))

    def verify_balances(self) -> list[tuple]:
        return self.query("SELECT * FROM ledger_verify_balances()")

    def deferred_check_count(self) -> int:
        return self.scalar("SELECT ledger_deferred_check_count()")

    def signed_balance(self, account_id: UUID) -> int:
        return self.scalar(
            "SELECT COALESCE((SELECT balance_minor FROM ledger_balances WHERE account_id = %s), 0)",
            (account_id,),
        )

    def natural_balance(self, account_id: UUID) -> int:
        return self.scalar(
            "SELECT natural_minor FROM ledger_account_balances WHERE account_id = %s",
            (account_id,),
        )

    # -- payout saga ------------------------------------------------------

    def payout_begin(self, request_id: str, payee: UUID, cash: UUID,
                     amount: int, currency: str) -> UUID:
        return self._call_one(
            "SELECT ledger_payout_begin(%s, %s::uuid, %s::uuid, %s::bigint, %s::char(3))",
            (request_id, payee, cash, amount, currency))

    def payout_mark_submitted(self, payout_id: UUID, provider_ref: str) -> str:
        return self._call_one(
            "SELECT ledger_payout_mark_submitted(%s::uuid, %s)", (payout_id, provider_ref))

    def payout_post(self, payout_id: UUID) -> PostResult:
        row = self._call_row(
            "SELECT transaction_id, replayed FROM ledger_payout_post(%s::uuid)", (payout_id,))
        return PostResult(row[0], row[1])

    def payout_fail(self, payout_id: UUID, reason: str) -> str:
        return self._call_one("SELECT ledger_payout_fail(%s::uuid, %s)", (payout_id, reason))

    def payout_resume(self, payout_id: UUID, provider_ref: str | None = None) -> str:
        return self._call_one(
            "SELECT ledger_payout_resume(%s::uuid, %s)", (payout_id, provider_ref))

    def payout_state(self, payout_id: UUID) -> str:
        return self.scalar("SELECT state FROM ledger_payouts WHERE id = %s", (payout_id,))

    def _call_row(self, sql: str, params: Sequence[Any]) -> tuple:
        try:
            with self.conn.cursor() as cur:
                cur.execute(sql, params)
                row = cur.fetchone()
        except psycopg.Error as exc:
            self._abort()
            raise LedgerError.from_psycopg(exc) from exc
        self._commit()
        return row

    def _call_one(self, sql: str, params: Sequence[Any]) -> Any:
        return self._call_row(sql, params)[0]


# ---------------------------------------------------------------------------
# Flow helpers — pure entry-list assembly, no database access.
#
# These live in the test harness rather than in SQL on purpose. The database's
# job is to make an unbalanced or over-drawing posting impossible; deciding that
# a capture is "debit clearing, credit receivable" is the service's job, and the
# Kotlin service will own exactly these shapes. Keeping them here keeps the
# schema free of business policy.
# ---------------------------------------------------------------------------

def authorize_entries(receivable: UUID, escrow: UUID, amount: int, cur: str) -> list[Entry]:
    """We now hold a claim on the consumer, and the order's value sits in escrow."""
    return [debit(receivable, amount, cur), credit(escrow, amount, cur)]


def capture_entries(clearing: UUID, receivable: UUID, amount: int, cur: str) -> list[Entry]:
    """The claim becomes real money at the payment provider. Escrow is untouched."""
    return [debit(clearing, amount, cur), credit(receivable, amount, cur)]


def tip_entries(clearing: UUID, escrow: UUID, amount: int, cur: str) -> list[Entry]:
    return [debit(clearing, amount, cur), credit(escrow, amount, cur)]


def wallet_spend_entries(wallet: UUID, escrow: UUID, amount: int, cur: str) -> list[Entry]:
    return [debit(wallet, amount, cur), credit(escrow, amount, cur)]


def refund_entries(escrow: UUID, clearing: UUID, amount: int, cur: str) -> list[Entry]:
    """Refunds drain escrow. That is what makes over-refunding structurally
    impossible rather than merely checked: escrow is allow_negative = false."""
    return [debit(escrow, amount, cur), credit(clearing, amount, cur)]


def promo_entries(promo_expense: UUID, wallet: UUID, amount: int, cur: str) -> list[Entry]:
    return [debit(promo_expense, amount, cur), credit(wallet, amount, cur)]


def chargeback_entries(loss: UUID, clearing: UUID, amount: int, cur: str) -> list[Entry]:
    return [debit(loss, amount, cur), credit(clearing, amount, cur)]


def chargeback_reversal_entries(clearing: UUID, loss: UUID, amount: int, cur: str) -> list[Entry]:
    return [debit(clearing, amount, cur), credit(loss, amount, cur)]


def adjust_entries(revenue: UUID, merchant: UUID, delta: int, cur: str) -> list[Entry]:
    """A post-capture correction between the platform's share and the merchant's.
    Never a mutation of the original transaction — always a new balanced one."""
    if delta >= 0:
        return [debit(revenue, delta, cur), credit(merchant, delta, cur)]
    return [debit(merchant, -delta, cur), credit(revenue, -delta, cur)]


def settlement_entries(escrow: UUID, shares: Sequence[tuple[UUID, int]],
                       amount: int, cur: str) -> list[Entry]:
    """Drain `amount` out of escrow into the split accounts.

    Shares with a zero amount are dropped, because amount_minor > 0 is a column
    constraint: a ledger entry for nothing is not a fact about money.
    """
    legs = [debit(escrow, amount, cur)]
    legs += [credit(acct, share, cur) for acct, share in shares if share > 0]
    return legs


def fingerprint_of(entries: Iterable[Entry]) -> str:
    """Stand-in for the service's request hash. Order-independent, so that two
    postings that move the same money are the same request."""
    return "|".join(sorted(
        f"{e.account_id}:{e.direction}:{e.amount_minor}:{e.currency}" for e in entries))


def new_key(prefix: str) -> str:
    return f"{prefix}:{uuid4()}"
