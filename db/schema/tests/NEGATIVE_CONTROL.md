# Negative control: the same tests, the schema from before the fix

Each regression test must fail on the code it claims to catch and pass on the fix.
Otherwise it could be passing for some other reason. The tests come from the working
tree; only the schema under test changes.

Local, 2026-09-30, Apple M5 Pro, PostgreSQL 17.10 (Homebrew) on 127.0.0.1:5437, Python
3.12.13, psycopg 3.3.6. Tests and fix at `c227e6f`.

## On 65ad66c: 10 failed, 2 passed, 1 xfailed

```
$ RAVON_DSN=postgresql://postgres@127.0.0.1:5437/postgres db/schema/tests/negative_control.sh 65ad66c
PASSED tests/test_inventory.py::test_order_now_control_cancel_restores_stock
PASSED tests/test_inventory.py::test_cancelling_a_scheduled_order_before_activation_ends_where_it_should
XFAIL tests/test_inventory.py::test_a_preorder_at_a_closed_restaurant_does_not_block_every_other_activation - scheduled -> cancelled_by_system is not a declared edge, so the sweep's closed-restaurant branch aborts the whole sweep
FAILED tests/test_inventory.py::test_sixty_scheduled_preorders_cannot_all_go_live_for_forty_portions_and_capacity_25
FAILED tests/test_inventory.py::test_sixty_scheduled_preorders_for_forty_portions_sell_exactly_forty
FAILED tests/test_inventory.py::test_cancelling_an_activated_scheduled_order_restores_its_stock_exactly_once
FAILED tests/test_inventory.py::test_duplicate_cart_lines_are_summed_and_refused_with_a_typed_error
FAILED tests/test_inventory.py::test_validate_cart_sums_duplicate_lines_too
FAILED tests/test_inventory.py::test_a_full_lifecycle_leaves_the_stock_ledger_balanced
FAILED tests/test_inventory.py::test_the_conservation_check_catches_a_decrement_that_bypasses_the_ledger
FAILED tests/test_inventory.py::test_the_conservation_check_catches_a_cancel_that_never_restored
FAILED tests/test_inventory.py::test_returning_units_twice_is_a_constraint_violation_not_a_bug_to_detect
FAILED tests/test_inventory.py::test_a_full_kitchen_slot_refuses_the_26th_preorder_and_frees_on_cancel
10 failed, 2 passed, 1 xfailed in 2.65s
```

Why each failed, from the same output:

```
E           AssertionError: 60 live plov units for 40 portions ({'ok': 60})
E           assert 60 <= 40
E           AssertionError: 60 live plov units for 40 portions ({'ok': 60})
E           assert 60 <= 40
E           AssertionError: an activated pre-order's units were not returned
E           assert 30 == 33
E           AssertionError: untyped refusal: 23514 new row for relation "menu_items" violates check constraint "menu_items_stock_count_check" {}
E           assert '23514' == 'P0001'
E           assert True is False
E           psycopg.errors.UndefinedFunction: function public.ravon_inventory_violations() does not exist
E           psycopg.errors.UndefinedFunction: function public.ravon_inventory_violations() does not exist
E           psycopg.errors.UndefinedFunction: function public.ravon_inventory_violations() does not exist
E           psycopg.errors.UndefinedTable: relation "public.inventory_movements" does not exist
E           Failed: DID NOT RAISE Rejected
```

- The three regressions fail for exactly the reason they name: **60 live plov units for
  40 portions** (twice, with and without the capacity of 25), **30 == 33** (an activated
  pre-order's units never came back), and **SQLSTATE 23514** instead of `P0001` for
  duplicate lines. `validate_cart` said `orderable: true` for 2 + 2 against 3.
- Four fail because the objects they test (`ravon_inventory_violations`,
  `inventory_movements`) do not exist on 65ad66c. The fifth, the kitchen-slot test,
  fails because the 26th pre-order for one slot was accepted.
- The two that pass are controls, and must pass on both: the order-now cancel restock
  (always correct), and cancel-before-activation (correct on 65ad66c by accident, since
  nothing had been taken).
- The xfail is F4 in `db/rush/FINDINGS.md`, present on both.

## On the fix: 12 passed, 1 xfailed

```
$ cd db/schema && RAVON_DSN=postgresql://postgres@127.0.0.1:5437/postgres python -m pytest tests -p no:cacheprovider -rA
PASSED tests/test_inventory.py::test_sixty_scheduled_preorders_cannot_all_go_live_for_forty_portions_and_capacity_25
PASSED tests/test_inventory.py::test_sixty_scheduled_preorders_for_forty_portions_sell_exactly_forty
PASSED tests/test_inventory.py::test_cancelling_an_activated_scheduled_order_restores_its_stock_exactly_once
PASSED tests/test_inventory.py::test_order_now_control_cancel_restores_stock
PASSED tests/test_inventory.py::test_cancelling_a_scheduled_order_before_activation_ends_where_it_should
PASSED tests/test_inventory.py::test_duplicate_cart_lines_are_summed_and_refused_with_a_typed_error
PASSED tests/test_inventory.py::test_validate_cart_sums_duplicate_lines_too
PASSED tests/test_inventory.py::test_a_full_lifecycle_leaves_the_stock_ledger_balanced
PASSED tests/test_inventory.py::test_the_conservation_check_catches_a_decrement_that_bypasses_the_ledger
PASSED tests/test_inventory.py::test_the_conservation_check_catches_a_cancel_that_never_restored
PASSED tests/test_inventory.py::test_returning_units_twice_is_a_constraint_violation_not_a_bug_to_detect
PASSED tests/test_inventory.py::test_a_full_kitchen_slot_refuses_the_26th_preorder_and_frees_on_cancel
XFAIL tests/test_inventory.py::test_a_preorder_at_a_closed_restaurant_does_not_block_every_other_activation - scheduled -> cancelled_by_system is not a declared edge, so the sweep's closed-restaurant branch aborts the whole sweep
12 passed, 1 xfailed in 2.85s
```

The same suite runs in CI, in the `rush-invariants` job.

## The clamp check in `invariants.sql`

Applied the fixed schema (`invariants.sql`: "all invariants hold"), then replaced
`activate_scheduled_orders` with its 65ad66c body, which contains the
`GREATEST(0, mi.stock_count - oi.quantity)` clamp, and re-ran `invariants.sql`:

```
psql:db/schema/invariants.sql:382: ERROR:  STOCK: GREATEST(0, stock_count ...) clamp in: activate_scheduled_orders
```

## The conservation checker

Its own negative controls are tests in the suite above, each run on a deliberately
corrupted database: a decrement that bypasses the ledger
(`test_the_conservation_check_catches_a_decrement_that_bypasses_the_ledger`), a cancel
that never restored (`..._catches_a_cancel_that_never_restored`), and a second release,
which is a unique violation rather than something to detect
(`test_returning_units_twice_is_a_constraint_violation_not_a_bug_to_detect`).
