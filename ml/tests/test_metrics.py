"""Scoring rules, checked against things that are independently known.

A closed-form CRPS nobody verified is a closed form nobody should trust, so every
analytic expression here is confirmed against numerical quadrature or against a
distribution whose answer can be worked out by hand.
"""

from __future__ import annotations

import numpy as np
import pytest

from ravon_ml.metrics import (
    UNIFORM_VARIANCE,
    coverage_curve,
    crps_ensemble,
    crps_numeric,
    crps_weibull,
    interval_score,
    pit_values,
    summarise_pit,
)
from ravon_ml.weibull import WeibullParams


@pytest.mark.parametrize("y", [0.5, 5.0, 12.0, 12.0001, 30.0, 52.0, 120.0, 300.0])
def test_closed_form_crps_matches_quadrature(y):
    params = WeibullParams(3.37, 40.0, 12.0)
    analytic = float(crps_weibull(params, y)[0])
    numeric = crps_numeric(params.cdf, y, lo=-50.0, hi=500.0, n=400_001)
    assert analytic == pytest.approx(numeric, abs=2e-3)


def test_crps_below_the_location_uses_the_other_branch():
    """`y < gamma` is a real case: a fitted floor can sit above a fast delivery.

    Without the second branch the `(z / lam) ** k` term is NaN and quietly poisons the
    mean score for the whole evaluation set.
    """
    params = WeibullParams(2.0, 30.0, 20.0)
    scores = crps_weibull(params, [5.0, 10.0, 19.9])
    assert np.all(np.isfinite(scores))
    # Below the floor, CRPS must grow one-for-one as the observation moves away.
    assert scores[0] - scores[1] == pytest.approx(5.0)


def test_crps_of_an_exponential_matches_the_hand_derivable_value():
    """A Weibull with k = 1 is Exponential(1/lam), whose CRPS at y = 0 is lam / 2.

    Worked by hand: `CRPS(F, 0) = E|X| - 0.5 * E|X - X'|`, with `E|X| = lam` and the
    difference of two iid exponentials being Laplace with scale `lam`, so
    `E|X - X'| = lam`. That leaves `lam - lam / 2`.
    """
    lam = 17.0
    assert float(crps_weibull(WeibullParams(1.0, lam, 0.0), 0.0)[0]) == pytest.approx(
        0.5 * lam
    )


def test_crps_is_minimised_by_the_true_distribution():
    """The property that makes CRPS worth using: it is a *proper* scoring rule.

    A model cannot improve its score by widening or narrowing away from the truth, so
    a lower CRPS really is a better description and not a hedging strategy.
    """
    rng = np.random.default_rng(4)
    truth = WeibullParams(2.4, 40.0, 10.0)
    samples = truth.location + truth.scale * rng.weibull(truth.shape, 40_000)
    best = crps_weibull(truth, samples).mean()
    for wrong in (
        WeibullParams(2.4, 30.0, 10.0),   # too narrow
        WeibullParams(2.4, 55.0, 10.0),   # too wide
        WeibullParams(1.4, 40.0, 10.0),   # wrong tail
        WeibullParams(2.4, 40.0, 20.0),   # shifted
    ):
        assert best < crps_weibull(wrong, samples).mean()


def test_point_forecast_crps_equals_absolute_error():
    """A point forecast is a distribution with no spread, so its CRPS is its MAE.

    This is what makes the naive baseline comparable with the probabilistic models on
    one axis instead of two.
    """
    degenerate = WeibullParams(shape=60.0, scale=1e-4, location=42.0)
    for y in (10.0, 42.0, 90.0):
        assert float(crps_weibull(degenerate, y)[0]) == pytest.approx(
            abs(y - 42.0), abs=1e-3
        )


def test_crps_ensemble_matches_quadrature_on_its_own_ecdf():
    rng = np.random.default_rng(5)
    samples = rng.gamma(3.0, 8.0, 3000)
    ecdf = lambda grid: np.searchsorted(np.sort(samples), grid, "right") / samples.size
    for y in (5.0, 24.0, 60.0):
        assert crps_ensemble(samples, y) == pytest.approx(
            crps_numeric(ecdf, y, 0.0, 250.0, 250_001), abs=5e-3
        )


def test_pit_of_the_true_model_is_uniform():
    rng = np.random.default_rng(6)
    truth = WeibullParams(3.37, 40.0, 12.0)
    samples = truth.location + truth.scale * rng.weibull(truth.shape, 50_000)
    summary = summarise_pit(pit_values([truth] * samples.size, samples))
    assert summary.mean == pytest.approx(0.5, abs=0.01)
    assert summary.variance == pytest.approx(UNIFORM_VARIANCE, rel=0.02)
    assert summary.chi2_p_value > 0.01
    assert summary.diagnosis == "well dispersed"


def test_pit_names_under_dispersion():
    """Too-narrow predictions put reality in the tails: U-shaped PIT, variance > 1/12."""
    rng = np.random.default_rng(7)
    truth = WeibullParams(2.0, 40.0, 10.0)
    samples = truth.location + truth.scale * rng.weibull(truth.shape, 40_000)
    too_narrow = WeibullParams(6.0, 34.0, 12.0)
    summary = summarise_pit(pit_values([too_narrow] * samples.size, samples))
    assert summary.variance > UNIFORM_VARIANCE
    assert "under-dispersed" in summary.diagnosis


def test_pit_names_over_dispersion():
    """Too-wide predictions pile reality in the middle: variance < 1/12."""
    rng = np.random.default_rng(8)
    truth = WeibullParams(3.5, 40.0, 10.0)
    samples = truth.location + truth.scale * rng.weibull(truth.shape, 40_000)
    too_wide = WeibullParams(1.1, 46.0, 0.0)
    summary = summarise_pit(pit_values([too_wide] * samples.size, samples))
    assert summary.variance < UNIFORM_VARIANCE
    assert "over-dispersed" in summary.diagnosis


def test_coverage_curve_of_the_true_model_is_the_diagonal():
    rng = np.random.default_rng(9)
    truth = WeibullParams(2.6, 42.0, 11.0)
    samples = truth.location + truth.scale * rng.weibull(truth.shape, 30_000)
    levels, realised = coverage_curve([truth] * samples.size, samples)
    assert np.max(np.abs(realised - levels)) < 0.015


def test_interval_score_penalises_misses_and_rewards_narrowness():
    y = np.array([30.0, 30.0, 30.0])
    tight_and_right = interval_score([25, 25, 25], [35, 35, 35], y, alpha=0.2)
    wide_and_right = interval_score([5, 5, 5], [55, 55, 55], y, alpha=0.2)
    tight_and_wrong = interval_score([40, 40, 40], [50, 50, 50], y, alpha=0.2)
    assert tight_and_right < wide_and_right
    assert tight_and_right < tight_and_wrong


def test_pit_rejects_length_mismatch():
    with pytest.raises(ValueError, match="length mismatch"):
        pit_values([WeibullParams(2.0, 30.0)], [1.0, 2.0])
