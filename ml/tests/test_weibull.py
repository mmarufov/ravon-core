"""The parameter-recovery check, and the claims made about the fitting procedure.

Every assertion here is about something the code *claims* in a docstring. A claim in a
comment that no test defends is a claim the next person has to re-verify by hand.
"""

from __future__ import annotations

import numpy as np
import pytest

from ravon_ml.metrics import crps_weibull
from ravon_ml.weibull import (
    WeibullParams,
    fit_interval_regression,
    survival_bins,
)

#: Shape, scale, location triples spanning the range delivery durations produce.
#: 3.37 is the case DoorDash publishes (they recover 3.22, a 4.5% error).
KNOWN_PARAMETERS = [
    (1.20, 30.0, 0.0),
    (1.80, 45.0, 8.0),
    (2.50, 38.0, 15.0),
    (3.37, 40.0, 12.0),
    (4.20, 55.0, 20.0),
    (6.00, 70.0, 10.0),
]


def sample(shape, scale, location, n=20_000, seed=20260916):
    rng = np.random.default_rng(seed)
    return location + scale * rng.weibull(shape, n)


@pytest.mark.parametrize("shape,scale,location", KNOWN_PARAMETERS)
def test_recovers_known_parameters(shape, scale, location):
    """Generate from a known Weibull; confirm interval regression finds it again.

    This is the validation a production ETA system cannot run, because production
    never knows the true conditional distribution. It is the strongest evidence
    available that the fit is doing what the docstring says.
    """
    fit = fit_interval_regression(sample(shape, scale, location), bin_width=6.0)
    assert fit.shape == pytest.approx(shape, rel=0.05)
    assert fit.scale == pytest.approx(scale, rel=0.05)
    assert fit.location == pytest.approx(location, abs=0.06 * scale)
    # The log-log transform is exactly linear for a true Weibull, so a poor R^2 means
    # the bucketing or the location search is broken, not that the data is awkward.
    assert fit.r_squared > 0.99


def test_doordash_published_case():
    """Their published check: true k = 3.37, predicted 3.22. Ours should be no worse."""
    fit = fit_interval_regression(sample(3.37, 40.0, 12.0))
    assert abs(fit.shape - 3.37) < abs(3.22 - 3.37)


def test_count_weighting_beats_unweighted_on_mean_recovery():
    """Weighting buckets by their observation count is not a detail.

    Unweighted OLS lets a tail bucket holding a handful of deliveries pull as hard as
    a body bucket holding hundreds, which biases the fitted mean upwards. Measured on
    the real segments this is a ~4 minute bias; here it is reproduced on synthetic
    data where the true mean is known exactly.
    """
    shape, scale, location = 1.8, 45.0, 8.0
    samples = sample(shape, scale, location)
    truth = WeibullParams(shape, scale, location).mean()

    weighted = fit_interval_regression(samples, weights="count").params.mean()
    unweighted = fit_interval_regression(samples, weights="none").params.mean()
    assert abs(weighted - truth) < abs(unweighted - truth)


def test_location_is_inside_the_log_not_an_additive_intercept():
    """A fitted three-parameter Weibull must not put mass below its location.

    The brief writes the transform with `gamma` as an additive intercept, which would
    leave the support starting at zero. The implementation profiles a real location
    shift instead, so a distribution fitted to data with a 20-minute floor assigns
    zero probability below 20 minutes.
    """
    fit = fit_interval_regression(sample(2.5, 38.0, 15.0))
    assert fit.location > 10.0
    assert fit.params.cdf(fit.location - 1e-9) == 0.0
    assert fit.params.sf(fit.location) == 1.0


def test_interval_regression_cannot_produce_a_nonsense_location():
    """The bounded location search is what keeps the parameter surface usable.

    An unconstrained three-parameter Weibull MLE trades location against scale almost
    freely — the two are close to unidentified in a heavy right tail — and on real
    segments it returns locations of minus several hours, which is not a duration.
    Interval regression profiles `gamma` over `[0, 0.98 * min(samples)]`, so it
    cannot. That bound is the whole reason the fitted parameters vary smoothly enough
    across segments for a link regression to generalise; the end-to-end consequence is
    measured in `test_eta.py`.
    """
    rng = np.random.default_rng(11)
    # A heavy-tailed, mildly misspecified sample: a Weibull body with a lognormal tail,
    # which is what a congested marketplace actually produces.
    body = 12.0 + 30.0 * rng.weibull(1.7, 900)
    tail = 12.0 + rng.lognormal(4.2, 0.6, 100)
    samples = np.concatenate([body, tail])

    fit = fit_interval_regression(samples)
    assert 0.0 <= fit.location <= samples.min()
    assert 0.5 < fit.shape < 20.0


def test_survival_bins_are_monotone_and_start_below_one():
    edges, survival, counts = survival_bins(sample(2.0, 30.0, 5.0), bin_width=6.0)
    assert counts.sum() == 20_000
    assert np.all(np.diff(survival) <= 1e-12)
    assert survival[0] < 1.0
    assert survival[-1] == pytest.approx(0.0)


def test_quantile_inverts_cdf():
    params = WeibullParams(2.3, 41.0, 9.0)
    for level in (0.05, 0.25, 0.5, 0.8, 0.95):
        assert params.cdf(params.quantile(level)) == pytest.approx(level)


def test_refuses_tiny_samples():
    with pytest.raises(ValueError, match="at least 10 samples"):
        fit_interval_regression([1.0, 2.0, 3.0])


def test_fit_is_deterministic():
    """No seed, no optimiser restarts: the same input must give the same answer."""
    samples = sample(2.0, 35.0, 6.0)
    first = fit_interval_regression(samples).params.as_tuple()
    second = fit_interval_regression(samples).params.as_tuple()
    assert first == second


def test_fitted_distribution_beats_a_misspecified_one_on_crps():
    """Sanity: CRPS must actually prefer the right distribution."""
    samples = sample(2.5, 38.0, 15.0)
    good = fit_interval_regression(samples).params
    bad = WeibullParams(1.0, 80.0, 0.0)
    assert crps_weibull(good, samples).mean() < crps_weibull(bad, samples).mean()
