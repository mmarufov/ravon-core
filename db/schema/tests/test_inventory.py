"""Stock and kitchen capacity across the whole life of an order.

An order-now checkout decrements stock inside `create_order` while holding the
restaurant and item row locks, and that path already held under a rush (40 of 40
portions sold in 10 of 10 trials, db/rush/RESULTS.md). The defects are all in
the *deferred* path, where one reservation spans three code paths at three
times: scheduled at t0 (`create_order`), activated at t1
(`activate_scheduled_orders`), cancelled at t2 (six cancel RPCs, all through
`ravon_restore_stock`). At 65ad66c those three disagreed about who held a unit:

  * scheduling checked stock but reserved nothing and skipped the capacity check;
  * activation decremented with `GREATEST(0, stock - qty)`, which turns an
    oversell into a silent zero, and never checked capacity;
  * restore skipped every order with `scheduled_for IS NOT NULL`, so an
    activated pre-order never got its units back.

The first three tests below are the regressions. Each fails on 65ad66c
(db/schema/tests/NEGATIVE_CONTROL.md has the output) and passes on the fix.
"""

from __future__ import annotations

import threading

import psycopg
import pytest

from conftest import (CONSUMER, MERCHANT, PLOV, RESTAURANT, SHASHLIK, Rejected,
                      actor, create_order)

LIVE_EXCLUDED = ("scheduled", "rejected", "cancelled", "cancelled_by_customer",
                 "cancelled_by_restaurant", "cancelled_by_system", "cancelled_by_courier")


def scalar(conn: psycopg.Connection, sql: str, *args):
    return conn.execute(sql, args).fetchone()[0]


def stock(conn: psycopg.Connection, item: str = PLOV) -> int:
    return scalar(conn, "SELECT stock_count FROM public.menu_items WHERE id = %s", item)


def live_orders(conn: psycopg.Connection) -> int:
    return scalar(conn, "SELECT count(*) FROM public.orders WHERE status <> ALL(%s::public.order_status[])",
                  list(LIVE_EXCLUDED))


def live_units(conn: psycopg.Connection, item: str = PLOV) -> int:
    return scalar(conn, """
        SELECT coalesce(sum(oi.quantity), 0) FROM public.order_items oi
        JOIN public.orders o ON o.id = oi.order_id
        WHERE oi.menu_item_id = %s AND o.status <> ALL(%s::public.order_status[])""",
                  item, list(LIVE_EXCLUDED))


def schedule_time(conn: psycopg.Connection):
    # Inside create_order's [now()+5min, now()+7d] window, and far enough from a
    # 15-minute boundary that every order in a test lands in one kitchen slot.
    return scalar(conn, """
        SELECT date_bin('15 minutes', now() + interval '30 minutes',
                        timestamptz '2000-01-01 00:00+00') + interval '7 minutes'""")


def activate_due(admin: psycopg.Connection) -> int:
    """Make every scheduled order due, then run the activation sweep as cron would."""
    admin.execute("UPDATE public.orders SET scheduled_for = now() - interval '1 second' "
                  "WHERE status = 'scheduled'")
    return scalar(admin, "SELECT public.activate_scheduled_orders()")


def set_capacity(admin: psycopg.Connection, cap: int | None) -> None:
    admin.execute("UPDATE public.restaurants SET max_concurrent_orders = %s WHERE id = %s",
                  (cap, RESTAURANT))


def rush_scheduled(dsn: str, n: int, sched) -> tuple[int, dict[str, int]]:
    """n consumers press 'order' for one plov at the same instant, all scheduled."""
    conns = [actor(dsn, CONSUMER) for _ in range(n)]
    barrier = threading.Barrier(n)
    results: list[str] = [""] * n

    def one(i: int) -> None:
        barrier.wait()
        try:
            create_order(conns[i], [(PLOV, 1)], sched)
            results[i] = "ok"
        except Rejected as r:
            results[i] = r.reason or r.sqlstate

    threads = [threading.Thread(target=one, args=(i,)) for i in range(n)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    for c in conns:
        c.close()
    tally: dict[str, int] = {}
    for r in results:
        tally[r] = tally.get(r, 0) + 1
    return tally.get("ok", 0), tally


# ---------------------------------------------------------------------------
# Regression 1: 60 pre-orders, 40 portions, a kitchen that cooks 25 at a time.
# At 65ad66c all 60 were accepted and all 60 went live, with stock_count 0.
# ---------------------------------------------------------------------------
def test_sixty_scheduled_preorders_cannot_all_go_live_for_forty_portions_and_capacity_25(db):
    with psycopg.connect(db, autocommit=True) as admin:
        assert stock(admin) == 40
        assert scalar(admin, "SELECT max_concurrent_orders FROM public.restaurants WHERE id = %s",
                      RESTAURANT) == 25
        sched = schedule_time(admin)

        accepted, tally = rush_scheduled(db, 60, sched)
        went_live = activate_due(admin)

        assert live_units(admin) <= 40, f"{live_units(admin)} live plov units for 40 portions ({tally})"
        assert live_orders(admin) <= 25, f"{live_orders(admin)} live orders for a capacity of 25 ({tally})"
        # And exactly at the binding limit, not merely under it: the kitchen slot
        # (25) binds before the stock (40), and nothing that was accepted is lost.
        assert accepted == 25 and went_live == 25, tally
        assert tally.get("OVERLOADED") == 35, tally
        assert stock(admin) + live_units(admin) == 40


def test_sixty_scheduled_preorders_for_forty_portions_sell_exactly_forty(db):
    """Stock alone, with no capacity limit: the reservation, not the slot, binds."""
    with psycopg.connect(db, autocommit=True) as admin:
        set_capacity(admin, None)
        sched = schedule_time(admin)

        accepted, tally = rush_scheduled(db, 60, sched)
        went_live = activate_due(admin)

        assert live_units(admin) <= 40, f"{live_units(admin)} live plov units for 40 portions ({tally})"
        assert accepted == 40 and went_live == 40, tally
        assert tally.get("INSUFFICIENT_STOCK") == 20, tally
        assert stock(admin) == 0


# ---------------------------------------------------------------------------
# Regression 2: cancelling an activated pre-order returns its stock, once.
# At 65ad66c: stock 40, 10 scheduled, activated -> 30, cancel 3 -> still 30.
# The order-now control gave 33.
# ---------------------------------------------------------------------------
def test_cancelling_an_activated_scheduled_order_restores_its_stock_exactly_once(db):
    with psycopg.connect(db, autocommit=True) as admin, actor(db, CONSUMER) as consumer:
        set_capacity(admin, None)
        sched = schedule_time(admin)
        ids = [create_order(consumer, [(PLOV, 1)], sched) for _ in range(10)]
        assert activate_due(admin) == 10
        assert stock(admin) == 30

        for oid in ids[:3]:
            consumer.execute("SELECT public.cancel_order_by_consumer(%s, 'test')", (oid,))
        assert stock(admin) == 33, "an activated pre-order's units were not returned"

        # Exactly once: a second restore for an already-restored order is a no-op.
        for oid in ids[:3]:
            admin.execute("SELECT public.ravon_restore_stock(%s)", (oid,))
        assert stock(admin) == 33, "a second restore returned the same units again"


def test_order_now_control_cancel_restores_stock(db):
    """The control from the probe: order-now orders always restored correctly."""
    with psycopg.connect(db, autocommit=True) as admin, actor(db, CONSUMER) as consumer:
        set_capacity(admin, None)
        ids = [create_order(consumer, [(PLOV, 1)]) for _ in range(10)]
        assert stock(admin) == 30
        for oid in ids[:3]:
            consumer.execute("SELECT public.cancel_order_by_consumer(%s, 'test')", (oid,))
        assert stock(admin) == 33


def test_cancelling_a_scheduled_order_before_activation_ends_where_it_should(db):
    """Not a regression at 65ad66c (nothing was held, so nothing leaked), kept so
    the reservation cannot introduce one: cancel-before-activation must release."""
    with psycopg.connect(db, autocommit=True) as admin, actor(db, CONSUMER) as consumer:
        set_capacity(admin, None)
        sched = schedule_time(admin)
        ids = [create_order(consumer, [(PLOV, 1)], sched) for _ in range(10)]
        for oid in ids[:3]:
            consumer.execute("SELECT public.cancel_order_by_consumer(%s, 'test')", (oid,))
        assert activate_due(admin) == 7
        assert stock(admin) == 33
        assert live_units(admin) == 7


# ---------------------------------------------------------------------------
# Regression 3: one item on two cart lines. The consumer app sends split lines
# when an item has two different modifier sets (ConfirmOrderViewModel.swift:50).
# At 65ad66c 2 + 2 against a stock of 3 passed the per-line check and then hit
# the CHECK constraint: SQLSTATE 23514, which the app cannot decode.
# ---------------------------------------------------------------------------
def test_duplicate_cart_lines_are_summed_and_refused_with_a_typed_error(db):
    with psycopg.connect(db, autocommit=True) as admin, actor(db, CONSUMER) as consumer:
        admin.execute("UPDATE public.menu_items SET stock_count = 3 WHERE id = %s", (PLOV,))
        with pytest.raises(Rejected) as e:
            create_order(consumer, [(PLOV, 2), (PLOV, 2)])
        assert e.value.sqlstate == "P0001", f"untyped refusal: {e.value}"
        assert e.value.reason == "INSUFFICIENT_STOCK"
        assert e.value.detail.get("have") == 3
        assert stock(admin) == 3

        # And two lines that do fit are one reservation of the sum.
        create_order(consumer, [(PLOV, 1), (PLOV, 2)])
        assert stock(admin) == 0


def test_validate_cart_sums_duplicate_lines_too(db):
    with psycopg.connect(db, autocommit=True) as admin, actor(db, CONSUMER) as consumer:
        admin.execute("UPDATE public.menu_items SET stock_count = 3 WHERE id = %s", (PLOV,))
        out = scalar(consumer, "SELECT public.validate_cart(%s, %s::jsonb)", RESTAURANT,
                     '[{"menu_item_id":"%s","quantity":2},{"menu_item_id":"%s","quantity":2}]'
                     % (PLOV, PLOV))
        assert out["orderable"] is False
        assert {i["status"] for i in out["items"]} == {"INSUFFICIENT_STOCK"}


# ---------------------------------------------------------------------------
# The ledger behind the fix. These do not exist at 65ad66c.
# ---------------------------------------------------------------------------
def violations(conn: psycopg.Connection) -> list[tuple[str, str]]:
    return conn.execute("SELECT check_name, detail FROM public.ravon_inventory_violations()").fetchall()


def test_a_full_lifecycle_leaves_the_stock_ledger_balanced(db):
    with psycopg.connect(db, autocommit=True) as admin, actor(db, CONSUMER) as consumer, \
            actor(db, MERCHANT) as merchant:
        sched = schedule_time(admin)
        now_ids = [create_order(consumer, [(PLOV, 2), (SHASHLIK, 1)]) for _ in range(3)]
        pre_ids = [create_order(consumer, [(PLOV, 1), (PLOV, 1)], sched) for _ in range(4)]
        merchant.execute("SELECT public.merchant_reject_order(%s, 'test')", (now_ids[0],))
        merchant.execute("SELECT public.merchant_accept_order(%s, 20)", (now_ids[1],))
        merchant.execute("SELECT public.merchant_cancel_order(%s, 'RESTAURANT_OUT_OF_ITEMS')",
                         (now_ids[1],))
        consumer.execute("SELECT public.cancel_order_by_consumer(%s, 'test')", (pre_ids[0],))
        activate_due(admin)
        consumer.execute("SELECT public.cancel_order_by_consumer(%s, 'test')", (pre_ids[1],))
        # A merchant restock is an adjustment, not a hole in the ledger.
        merchant.execute("UPDATE public.menu_items SET stock_count = stock_count + 5 WHERE id = %s",
                         (PLOV,))

        assert violations(admin) == []
        # 40 - 3*2 + 2*2 (reject, merchant cancel) - 4*2 + 2*2 (two pre-order cancels) + 5
        assert stock(admin) == 40 - 6 + 4 - 8 + 4 + 5
        assert stock(admin, SHASHLIK) == 30 - 3 + 2


def test_the_conservation_check_catches_a_decrement_that_bypasses_the_ledger(db):
    """Negative control for the checker. A checker that has never failed proves
    nothing, so each check below is shown failing on a deliberately corrupted
    database. This one is the GREATEST(0, ...) shape: stock moved, no movement."""
    with psycopg.connect(db, autocommit=True) as admin, actor(db, CONSUMER) as consumer:
        create_order(consumer, [(PLOV, 2)])
        assert violations(admin) == []
        with admin.transaction():
            admin.execute("SELECT set_config('ravon.inventory_op', 'order', true)")
            admin.execute("UPDATE public.menu_items SET stock_count = GREATEST(0, stock_count - 50) "
                          "WHERE id = %s", (PLOV,))
        assert "stock_equals_ledger" in {name for name, _ in violations(admin)}


def test_the_conservation_check_catches_a_cancel_that_never_restored(db):
    with psycopg.connect(db, autocommit=True) as admin, actor(db, CONSUMER) as consumer:
        oid = create_order(consumer, [(PLOV, 2)])
        # A cancel path that forgot ravon_restore_stock: the transition is legal,
        # the units are simply never returned.
        with admin.transaction():
            admin.execute("SELECT public.ravon_set_actor('consumer', 'cancel_order_by_consumer')")
            admin.execute("UPDATE public.orders SET status = 'cancelled_by_customer' WHERE id = %s", (oid,))
        assert "cancelled_order_released" in {name for name, _ in violations(admin)}

        admin.execute("SELECT public.ravon_restore_stock(%s)", (oid,))
        assert violations(admin) == []


def test_returning_units_twice_is_a_constraint_violation_not_a_bug_to_detect(db):
    with psycopg.connect(db, autocommit=True) as admin, actor(db, CONSUMER) as consumer:
        oid = create_order(consumer, [(PLOV, 2)])
        consumer.execute("SELECT public.cancel_order_by_consumer(%s, 'test')", (oid,))
        with pytest.raises(psycopg.errors.UniqueViolation):
            admin.execute("INSERT INTO public.inventory_movements(menu_item_id, order_id, kind, quantity) "
                          "VALUES (%s, %s, 'release', 2)", (PLOV, oid))


def test_a_full_kitchen_slot_refuses_the_26th_preorder_and_frees_on_cancel(db):
    with psycopg.connect(db, autocommit=True) as admin, actor(db, CONSUMER) as consumer:
        sched = schedule_time(admin)
        ids = [create_order(consumer, [(PLOV, 1)], sched) for _ in range(25)]
        with pytest.raises(Rejected) as e:
            create_order(consumer, [(PLOV, 1)], sched)
        assert e.value.reason == "OVERLOADED"
        # The next slot is a different slot.
        create_order(consumer, [(PLOV, 1)],
                     scalar(admin, "SELECT %s::timestamptz + interval '15 minutes'", sched))

        consumer.execute("SELECT public.cancel_order_by_consumer(%s, 'test')", (ids[0],))
        create_order(consumer, [(PLOV, 1)], sched)
        # Releasing the same slot twice does not free a second place.
        admin.execute("SELECT public.ravon_restore_stock(%s)", (ids[0],))
        with pytest.raises(Rejected):
            create_order(consumer, [(PLOV, 1)], sched)
        assert violations(admin) == []
