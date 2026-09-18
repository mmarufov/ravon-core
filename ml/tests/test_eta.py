"""End-to-end claims about the ETA layer, on held-out simulator days.

Numbers in the assertions are loosened from what the pipeline currently measures, so
reasonable retuning does not break the suite, but not so loose that the claim
evaporates. The exact measured values live in `reports/metrics.json`.
"""

from __future__ import annotations

import numpy as np
import pytest

from ravon_ml.data import FEATURES_AT_ASSIGNMENT, FEATURES_AT_CREATION
from ravon_ml.eta import (
    ConditionalWeibullETA,
    PointForecast,
    UnconditionalWeibullETA,
    empirical_crps_floor,
    evaluate,
)


@pytest.fixture(scope="module")
def fitted(split):
    train, test = split
    return {
        "train": train,
        "test": test,
        "creation": ConditionalWeibullETA(features=FEATURES_AT_CREATION).fit(train),
        "assignment": ConditionalWeibullETA(features=FEATURES_AT_ASSIGNMENT).fit(train),
        "unconditional": UnconditionalWeibullETA().fit(train),
        "naive": PointForecast("naive", lambda d: d["naive_eta_minutes"]),
    }


def test_naive_baseline_reproduces_the_published_bias(fitted):
    row = evaluate(fitted["naive"], fitted["test"])
    assert row.bias_minutes == pytest.approx(36.0, abs=2.0)
    assert row.sd_minutes == pytest.approx(51.0, abs=2.0)


def test_conditional_model_is_close_to_unbiased(fitted):
    """The base layer's contract. Deliberately *not* asked to be seldom late — that
    is the decision layer's job and is tested in `test_decision.py`."""
    row = evaluate(fitted["creation"], fitted["test"])
    assert abs(row.bias_minutes) < 3.0


def test_conditional_model_beats_naive_and_debiased_naive_on_crps(fitted):
    """Beating the raw naive formula is easy — subtract 37 minutes. The baseline that
    matters is the *debiased* naive, which has the same information and no bias."""
    train, test = fitted["train"], fitted["test"]
    delivered = train[train["total_delivery_minutes"].notna()]
    offset = float(
        (delivered["total_delivery_minutes"] - delivered["naive_eta_minutes"]).mean()
    )
    debiased = PointForecast("debiased", lambda d: d["naive_eta_minutes"], offset=offset)

    conditional = evaluate(fitted["creation"], test).crps_minutes
    assert conditional < 0.55 * evaluate(fitted["naive"], test).crps_minutes
    assert conditional < 0.55 * evaluate(debiased, test).crps_minutes


def test_conditional_model_beats_the_non_parametric_floor(fitted):
    """The training set's empirical distribution is the honest "no features" bound.

    Falling below it would mean the Weibull family is the wrong shape for this data,
    regardless of how good the conditioning is.
    """
    floor = empirical_crps_floor(fitted["train"], fitted["test"], seed=20260916)
    assert evaluate(fitted["creation"], fitted["test"]).crps_minutes < floor


def test_unconditional_weibull_is_calibrated_and_useless(fitted):
    """The concrete demonstration that calibration alone is not a result.

    It has no features at all, so its CRPS sits at the non-parametric floor, yet its
    coverage curve is not wildly wrong. Anyone quoting a calibration statistic without
    a sharpness statistic is quoting this model.
    """
    row = evaluate(fitted["unconditional"], fitted["test"])
    assert row.coverage_at_p80 == pytest.approx(0.80, abs=0.10)
    assert row.crps_minutes > 1.4 * evaluate(fitted["creation"], fitted["test"]).crps_minutes


def test_coverage_at_the_quoted_quantile_is_close_to_nominal(fitted):
    row = evaluate(fitted["creation"], fitted["test"])
    assert row.coverage_at_p80 == pytest.approx(0.80, abs=0.03)


def test_pit_variance_is_near_uniform(fitted):
    row = evaluate(fitted["creation"], fitted["test"])
    assert row.pit_variance == pytest.approx(1 / 12, rel=0.10)


def test_pit_histogram_is_still_not_exactly_uniform(fitted):
    """An honest negative. The dispersion summary says "well dispersed"; the
    goodness-of-fit test says the PIT is not uniform. Both are true, and reporting
    only the first would be the more flattering half of the story."""
    row = evaluate(fitted["creation"], fitted["test"])
    assert row.pit_chi2_p < 0.01
    assert row.pit_ks < 0.10


def test_assignment_stage_model_is_much_sharper(fitted):
    """Re-quoting once a courier is matched removes most of the remaining uncertainty,
    because wait-for-assignment is then known rather than forecast."""
    creation = evaluate(fitted["creation"], fitted["test"]).crps_minutes
    assignment = evaluate(fitted["assignment"], fitted["test"]).crps_minutes
    assert assignment < 0.5 * creation


def test_interval_regression_generalises_better_than_mle(fitted):
    """DoorDash's claim, measured end-to-end on held-out days rather than repeated.

    Per *cell* the two fits are comparable. The difference shows up in stage 2: an
    unconstrained MLE trades location against scale almost freely, producing a rough
    parameter surface (locations of minus several hours) that the link regression
    cannot follow. Interval regression's bounded location search keeps it smooth.
    """
    train, test = fitted["train"], fitted["test"]
    mle_model = ConditionalWeibullETA(
        features=FEATURES_AT_CREATION, per_cell_fit="mle"
    ).fit(train)
    mle = evaluate(mle_model, test)
    interval = evaluate(fitted["creation"], test)

    assert interval.crps_minutes < mle.crps_minutes
    assert abs(interval.bias_minutes) < abs(mle.bias_minutes)
    # The mechanism, pinned so the explanation cannot drift from the evidence.
    assert mle_model.cell_table_["location"].min() < -50.0
    assert fitted["creation"].cell_table_["location"].min() >= 0.0


def test_model_is_deterministic(split):
    train, test = split
    first = evaluate(ConditionalWeibullETA(features=FEATURES_AT_CREATION).fit(train), test)
    second = evaluate(ConditionalWeibullETA(features=FEATURES_AT_CREATION).fit(train), test)
    assert first.as_dict() == second.as_dict()


def test_predicted_distributions_are_well_formed(fitted):
    params = fitted["creation"].predict_params(fitted["test"].head(500))
    assert all(p.shape > 0 and p.scale > 0 and p.location >= 0 for p in params)
    quantiles = np.array([p.quantile(0.9) for p in params])
    medians = np.array([p.quantile(0.5) for p in params])
    assert np.all(quantiles > medians)
    assert np.all(np.isfinite(quantiles))


def test_fit_refuses_a_feature_set_containing_latent_state():
    from ravon_ml.data import LatentLeakError

    with pytest.raises(LatentLeakError):
        ConditionalWeibullETA(features=("haul_km", "latent_traffic_multiplier"))
