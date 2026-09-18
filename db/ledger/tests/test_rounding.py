"""Rounding exactness.

Splitting an order's value three ways almost never divides evenly. The rule is
that the remainder minor units land in platform_rounding — they are never
dropped, never silently absorbed by whoever is listed first, and never created.
"""

from __future__ import annotations

from uuid import uuid4

import pytest
from hypothesis import given, settings
from hypothesis import strategies as st

from chart import (CURRENCY, courier_payable_for, escrow_for,
                   merchant_payable_for, open_chart)
from ledger_api import (Ledger, LedgerError, authorize_entries,
                        fingerprint_of, settlement_entries)


@st.composite
def weights(draw, min_parts: int = 2, max_parts: int = 5) -> list[int]:
    """Basis-point vectors that sum to exactly 10000."""
    parts = draw(st.integers(min_value=min_parts, max_value=max_parts))
    cuts = sorted(draw(st.lists(st.integers(min_value=0, max_value=10_000),
                                min_size=parts - 1, max_size=parts - 1)))
    bounds = [0, *cuts, 10_000]
    return [bounds[i + 1] - bounds[i] for i in range(parts)]


@settings(max_examples=60, deadline=None)
@given(total=st.integers(min_value=0, max_value=10 ** 12), bps=weights())
def test_a_split_always_sums_back_to_the_original(ledger_db, total: int, bps: list[int]):
    import psycopg
    with psycopg.connect(ledger_db) as conn:
        ledger = Ledger(conn)
        pieces = ledger.split(total, bps)

    assert len(pieces) == len(bps) + 1
    assert sum(pieces) == total, "a split may not create or destroy minor units"
    assert all(p >= 0 for p in pieces)

    *shares, remainder = pieces
    assert shares == [(total * b) // 10_000 for b in bps]
    assert remainder < len(bps), "flooring can lose at most one unit per share"


def test_the_remainder_is_exactly_what_flooring_lost(ledger: Ledger):
    # 10007 split 70/20/10 floors to 7004 + 2001 + 1000 = 10005, losing 2.
    assert ledger.split(10_007, [7000, 2000, 1000]) == [7004, 2001, 1000, 2]


def test_an_exact_split_leaves_no_remainder(ledger: Ledger):
    assert ledger.split(10_000, [7000, 2000, 1000]) == [7000, 2000, 1000, 0]


def test_weights_must_sum_to_one_hundred_percent(ledger: Ledger):
    """A split whose weights do not sum to 10000 is a silent leak of the
    difference. It is an error, not a rounding question."""
    for bad in ([7000, 2000], [7000, 2000, 2000], [0], []):
        with pytest.raises(LedgerError) as exc:
            ledger.split(10_000, bad)
        assert exc.value.reason in {"INVALID_SPLIT_WEIGHTS", "INVALID_SPLIT_TOTAL"}


def test_a_negative_total_cannot_be_split(ledger: Ledger):
    with pytest.raises(LedgerError) as exc:
        ledger.split(-1, [10_000])
    assert exc.value.reason == "INVALID_SPLIT_TOTAL"


@settings(max_examples=25, deadline=None)
@given(total=st.integers(min_value=3, max_value=5_000_000), bps=weights(3, 3))
def test_settling_an_order_conserves_every_minor_unit(ledger_db, total: int, bps: list[int]):
    """The end-to-end claim: fund an order, split it merchant/courier/platform,
    and require the escrow to land on exactly zero with the remainder visible in
    platform_rounding rather than missing."""
    import psycopg
    from conftest import reset_ledger

    with psycopg.connect(ledger_db) as conn:
        reset_ledger(conn)
        ledger = Ledger(conn)
        chart = open_chart(ledger)
        order, merchant_id, courier_id = uuid4(), uuid4(), uuid4()
        escrow = escrow_for(ledger, order)
        merchant = merchant_payable_for(ledger, merchant_id)
        courier = courier_payable_for(ledger, courier_id)

        funding = authorize_entries(chart.receivable, escrow, total, CURRENCY)
        ledger.post(f"auth:{order}", fingerprint_of(funding), "authorize", order, funding)

        merchant_cut, courier_cut, platform_cut, remainder = ledger.split(total, bps)
        assert merchant_cut + courier_cut + platform_cut + remainder == total

        legs = settlement_entries(
            escrow,
            [(merchant, merchant_cut), (courier, courier_cut),
             (chart.revenue, platform_cut), (chart.rounding, remainder)],
            total, CURRENCY)
        ledger.post(f"settle:{order}", fingerprint_of(legs), "settlement", order, legs)

        assert ledger.natural_balance(escrow) == 0, "escrow drained exactly"
        assert ledger.natural_balance(merchant) == merchant_cut
        assert ledger.natural_balance(courier) == courier_cut
        assert ledger.natural_balance(chart.revenue) == platform_cut
        assert ledger.natural_balance(chart.rounding) == remainder
        assert (ledger.natural_balance(merchant) + ledger.natural_balance(courier)
                + ledger.natural_balance(chart.revenue)
                + ledger.natural_balance(chart.rounding)) == total
        assert ledger.verify_balances() == []


def test_the_remainder_really_does_land_in_rounding(ledger: Ledger):
    """A split that loses units to flooring, checked concretely: without the
    rounding leg this posting would be unbalanced by 2 and rejected at COMMIT."""
    chart = open_chart(ledger)
    order, total = uuid4(), 10_007
    escrow = escrow_for(ledger, order)
    merchant = merchant_payable_for(ledger, uuid4())
    courier = courier_payable_for(ledger, uuid4())

    funding = authorize_entries(chart.receivable, escrow, total, CURRENCY)
    ledger.post(f"auth:{order}", fingerprint_of(funding), "authorize", order, funding)

    m, c, p, r = ledger.split(total, [7000, 2000, 1000])
    assert r == 2

    without_remainder = settlement_entries(
        escrow, [(merchant, m), (courier, c), (chart.revenue, p)], total, CURRENCY)
    with pytest.raises(LedgerError) as exc:
        ledger.post(f"bad:{order}", fingerprint_of(without_remainder),
                    "settlement", order, without_remainder)
    assert exc.value.reason == "UNBALANCED_TRANSACTION"
    assert exc.value.detail["delta_minor"] == 2, "the two lost units, named"

    legs = settlement_entries(
        escrow, [(merchant, m), (courier, c), (chart.revenue, p), (chart.rounding, r)],
        total, CURRENCY)
    ledger.post(f"settle:{order}", fingerprint_of(legs), "settlement", order, legs)
    assert ledger.natural_balance(chart.rounding) == 2
    assert ledger.natural_balance(escrow) == 0
