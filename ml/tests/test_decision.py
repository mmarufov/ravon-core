"""The decision layer: that the derived quantile is genuinely the optimal one."""

from __future__ import annotations

import numpy as np
import pytest

from ravon_ml.data import FEATURES_AT_CREATION
from ravon_ml.decision import (
    RAVON_COST,
    AsymmetricCost,
    evaluate_quote_policy,
    optimal_quantile,
    quote_cost,
    sweep_quantiles,
)
from ravon_ml.eta import ConditionalWeibullETA
from ravon_ml.weibull import WeibullParams


def test_newsvendor_formula():
    assert optimal_quantile(4.0, 1.0) == pytest.approx(0.80)
    assert optimal_quantile(3.0, 1.0) == pytest.approx(0.75)
    assert optimal_quantile(1.0, 1.0) == pytest.approx(0.50)
    with pytest.raises(ValueError):
        optimal_quantile(0.0, 1.0)


def test_ravon_cost_lands_inside_the_band_the_brief_asks_for():
    assert 0.70 <= RAVON_COST.quantile <= 0.90


def test_derived_quantile_minimises_cost_on_a_known_distribution():
    """With one known distribution and enough samples, the argmin must be exact.

    This isolates the derivation from any modelling error: if the newsvendor quantile
    is right, it is right here to three decimal places.
    """
    rng = np.random.default_rng(3)
    truth = WeibullParams(2.4, 40.0, 10.0)
    y = truth.location + truth.scale * rng.weibull(truth.shape, 200_000)
    for ratio in (2.0, 4.0, 9.0):
        cost = AsymmetricCost(late=ratio, early=1.0)
        levels, costs = sweep_quantiles(
            lambda level: np.full(y.size, truth.quantile(level)),
            y, cost, levels=np.round(np.arange(0.40, 0.981, 0.005), 3),
        )
        assert levels[int(np.argmin(costs))] == pytest.approx(cost.quantile, abs=0.01)


def test_derived_quantile_is_near_optimal_on_the_real_model(split):
    """On the fitted model the derived quantile need not be the *exact* argmin — the
    model is imperfect — but the cost penalty for using it must be negligible."""
    train, test = split
    model = ConditionalWeibullETA(features=FEATURES_AT_CREATION).fit(train)
    delivered = test[test["total_delivery_minutes"].notna()]
    y = delivered["total_delivery_minutes"].to_numpy()
    params = model.predict_params(delivered)

    def quantile_fn(level):
        return np.array([p.quantile(level) for p in params])

    for ratio in (2.0, 3.0, 4.0, 5.0, 7.0, 9.0):
        cost = AsymmetricCost(late=ratio, early=1.0)
        levels, costs = sweep_quantiles(quantile_fn, y, cost)
        at_derived = quote_cost(quantile_fn(cost.quantile), y, cost)
        assert at_derived <= 1.02 * float(np.min(costs))


def test_quoting_the_derived_quantile_beats_quoting_the_unbiased_mean(split):
    """The reason the two layers are separate, stated as a test.

    The mean is the right *estimate* and the wrong *quote*: it is late about 40% of
    the time, which under an asymmetric cost is expensive.
    """
    train, test = split
    model = ConditionalWeibullETA(features=FEATURES_AT_CREATION).fit(train)
    delivered = test[test["total_delivery_minutes"].notna()]
    y = delivered["total_delivery_minutes"].to_numpy()
    params = model.predict_params(delivered)

    mean_quote = np.array([p.mean() for p in params])
    derived_quote = np.array([p.quantile(RAVON_COST.quantile) for p in params])

    mean_policy = evaluate_quote_policy("mean", mean_quote, y, RAVON_COST, 0.5)
    derived_policy = evaluate_quote_policy(
        "derived", derived_quote, y, RAVON_COST, RAVON_COST.quantile
    )
    assert derived_policy.mean_cost < mean_policy.mean_cost
    assert derived_policy.late_rate < 0.5 * mean_policy.late_rate
    # And the quote is deliberately pessimistic — that is the intended behaviour.
    assert derived_policy.mean_quote_minutes > derived_policy.mean_actual_minutes


def test_cost_is_asymmetric_in_the_stated_direction():
    cost = AsymmetricCost(late=4.0, early=1.0)
    ten_late = float(cost(quote=30.0, actual=40.0))
    ten_early = float(cost(quote=40.0, actual=30.0))
    assert ten_late == pytest.approx(4.0 * ten_early)


def test_overcautious_quoting_is_also_a_mistake(split):
    """p90 is not "safer" — it is a different, also-wrong point on the same curve."""
    train, test = split
    model = ConditionalWeibullETA(features=FEATURES_AT_CREATION).fit(train)
    delivered = test[test["total_delivery_minutes"].notna()]
    y = delivered["total_delivery_minutes"].to_numpy()
    params = model.predict_params(delivered)
    derived = quote_cost(
        np.array([p.quantile(RAVON_COST.quantile) for p in params]), y, RAVON_COST
    )
    p90 = quote_cost(np.array([p.quantile(0.90) for p in params]), y, RAVON_COST)
    assert derived < p90
