"""The feature boundary, the derived congestion features, and the split.

Most of this file defends against silent failures — a leaked latent column or a
feature that peeks at the future does not raise, it just produces a wonderful score
that means nothing.
"""

from __future__ import annotations

import numpy as np
import pytest

from ravon_ml.data import (
    FEATURES_AT_ASSIGNMENT,
    FEATURES_AT_CREATION,
    LATENT_COLUMNS,
    OUTCOME_COLUMNS,
    LatentLeakError,
    assert_no_latent_features,
    load_meta,
    restaurant_identity_is_unstable,
    split_by_day,
)


def test_dataset_matches_its_exported_metadata(orders):
    meta = load_meta()
    assert len(orders) == meta["rows"]
    assert orders["day"].nunique() == meta["dayCount"]
    assert int(orders["delivered"].sum()) == meta["deliveredRows"]
    assert orders["restaurant_index"].nunique() == meta["restaurantCount"]


def test_exported_naive_baseline_reproduces_the_published_numbers():
    """The fact on record: naive ETA is about +36 min biased with 51 min sd.

    This is the claim the whole ETA deliverable is measured against, so it is checked
    against the exporter's own reproduction rather than taken on trust.
    """
    checks = {c["label"]: c for c in load_meta()["naiveEtaChecks"]}
    realistic = next(c for label, c in checks.items() if "latent=realistic" in label)
    none = next(c for label, c in checks.items() if "latent=none" in label)
    assert realistic["biasMinutes"] == pytest.approx(36.0, abs=2.0)
    assert realistic["sdMinutes"] == pytest.approx(51.0, abs=2.0)
    # Still badly biased with the latent state switched off, because delivery time is
    # dominated by wait-for-assignment, which is not a term in the generating formula.
    assert none["biasMinutes"] == pytest.approx(24.0, abs=2.0)


def test_latent_columns_are_never_features():
    for column in LATENT_COLUMNS:
        assert column not in FEATURES_AT_CREATION
        assert column not in FEATURES_AT_ASSIGNMENT
    for column in OUTCOME_COLUMNS:
        assert column not in FEATURES_AT_CREATION
        assert column not in FEATURES_AT_ASSIGNMENT


def test_leak_guard_rejects_latent_and_outcome_columns():
    assert_no_latent_features(FEATURES_AT_CREATION)
    assert_no_latent_features(FEATURES_AT_ASSIGNMENT)
    with pytest.raises(LatentLeakError, match="latent_traffic_multiplier"):
        assert_no_latent_features(("haul_km", "latent_traffic_multiplier"))
    with pytest.raises(LatentLeakError, match="total_delivery_minutes"):
        assert_no_latent_features(("haul_km", "total_delivery_minutes"))


def test_wait_to_assign_is_an_assignment_stage_feature_only():
    """It is knowable at assignment and unknowable at creation. Both must hold."""
    assert "wait_to_assign_minutes" not in FEATURES_AT_CREATION
    assert "wait_to_assign_minutes" in FEATURES_AT_ASSIGNMENT


def test_derived_congestion_uses_no_future_information(orders):
    """Recompute the derived features by brute force and confirm they match.

    The fast path uses `searchsorted` on sorted event times. The slow path here is a
    literal count over events with a timestamp at or before the order's creation,
    which is the definition the feature is supposed to have.
    """
    rng = np.random.default_rng(1)
    day = orders[orders["day"] == 3]
    courier_count = load_meta()["courierCount"]
    for index in rng.choice(day.index.to_numpy(), size=25, replace=False):
        row = day.loc[index]
        t = row["created_at_minutes"]
        assigned = day["assigned_at_minutes"]
        delivered = day["delivered_at_minutes"]
        inflight = int(((assigned <= t) & ~(delivered <= t)).sum())
        pending = int(
            ((day["created_at_minutes"] < t) & ~(assigned <= t)).sum()
        )
        recent = int(
            (
                (day["created_at_minutes"] < t)
                & (day["created_at_minutes"] >= t - 30.0)
            ).sum()
        )
        assert row["inflight_now"] == inflight
        assert row["free_couriers_now"] == max(courier_count - inflight, 0)
        assert row["pending_now"] == pending
        assert row["recent_arrivals_30m"] == recent


def test_exported_congestion_columns_are_recorded_at_assignment_not_creation(orders):
    """The simulator's own `*_at_creation` columns are misnamed.

    `MarketplaceSimulator` fills them in inside the assignment loop, so they describe
    the marketplace at the moment a courier was matched. Using them as creation-time
    features leaks the future. This test pins the discrepancy so the day someone fixes
    the simulator, the ML layer is told rather than silently improving.
    """
    delivered = orders[orders["delivered"]]
    disagreement = (
        delivered["pending_orders_at_creation"] != delivered["pending_now"]
    ).mean()
    assert disagreement > 0.5
    assert "pending_orders_at_creation" not in FEATURES_AT_CREATION
    assert "free_couriers_at_creation" not in FEATURES_AT_CREATION


def test_restaurant_identity_is_not_stable_across_days(orders):
    """`restaurant_index` is a per-day label, which is why it is not a feature."""
    check = restaurant_identity_is_unstable(orders)
    assert check.unstable
    assert check.zones_per_restaurant > 1.5
    assert check.between_day_share_of_variance < 0.10


def test_split_is_by_whole_days(orders):
    train, test = split_by_day(orders, train_fraction=0.7)
    assert set(train["day"]).isdisjoint(set(test["day"]))
    assert len(train) + len(test) == len(orders)
    assert train["day"].nunique() == pytest.approx(0.7 * orders["day"].nunique(), abs=1)


def test_naive_eta_is_the_generating_formula(orders):
    expected = orders["quoted_prep_minutes"] + orders["haul_km"] / 18.0 * 60.0
    assert np.allclose(orders["naive_eta_minutes"], expected)
