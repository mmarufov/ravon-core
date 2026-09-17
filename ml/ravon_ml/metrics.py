"""Scoring rules and calibration diagnostics for probabilistic forecasts.

A point forecast is scored with an error. A *distribution* forecast needs two separate
questions answered, and conflating them is the usual way calibration work goes wrong:

* **Accuracy** — is the predicted distribution close to the realised value?
  Answered by CRPS, which is a proper scoring rule: it is minimised, in expectation, by
  the true conditional distribution and by nothing else. A model cannot game it by
  hedging with a wide distribution.
* **Calibration** — are the predicted probabilities *honest*? Answered by the PIT
  histogram. A model can be well calibrated and useless (predict the unconditional
  distribution for every order) or sharp and badly calibrated. Both numbers are needed.
"""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np
from scipy import special, stats

from .weibull import WeibullParams

__all__ = [
    "crps_weibull",
    "crps_numeric",
    "crps_ensemble",
    "pit_values",
    "PitSummary",
    "summarise_pit",
    "coverage_curve",
    "interval_score",
]


def crps_weibull(params: WeibullParams | list[WeibullParams], y) -> np.ndarray:
    """Closed-form CRPS of a three-parameter Weibull, in the units of `y` (minutes).

    Derivation, so the constants are checkable rather than copied. With
    `z = y - gamma`, `m = lam * Gamma(1 + 1/k)` the mean of the unshifted Weibull, and
    `P` the regularised lower incomplete gamma function:

        CRPS(F, y) = E|X - y| - 0.5 * E|X - X'|
        E|X - y|   = E X + y - 2 * integral_0^y S(x) dx     (for y >= 0)
        integral_0^y S(x) dx = m * P(1/k, (y / lam) ** k)
        E|X - X'|  = 2 * m * (1 - 2 ** (-1/k))

    which collapses to

        CRPS = z + m * (2 ** (-1/k) - 2 * P(1/k, (z / lam) ** k)),   z >= 0
        CRPS = m * 2 ** (-1/k) - z,                                  z <  0

    The `z < 0` branch is not decoration: a fitted location can sit above an unusually
    fast delivery, and without the branch the `(z / lam) ** k` term returns NaN and
    silently poisons the mean score.

    Checked against numerical quadrature in `tests/test_metrics.py`.
    """
    y = np.atleast_1d(np.asarray(y, dtype=float))
    if isinstance(params, WeibullParams):
        k = np.full(y.shape, params.shape)
        lam = np.full(y.shape, params.scale)
        gamma = np.full(y.shape, params.location)
    else:
        k = np.array([p.shape for p in params], dtype=float)
        lam = np.array([p.scale for p in params], dtype=float)
        gamma = np.array([p.location for p in params], dtype=float)
        if k.shape != y.shape:
            raise ValueError(f"params/y length mismatch: {k.shape} vs {y.shape}")

    z = y - gamma
    m = lam * special.gamma(1.0 + 1.0 / k)
    pow_term = np.power(2.0, -1.0 / k)

    safe_z = np.maximum(z, 0.0)
    lower_gamma = special.gammainc(1.0 / k, np.power(safe_z / lam, k))

    positive = z + m * (pow_term - 2.0 * lower_gamma)
    negative = m * pow_term - z
    return np.where(z >= 0.0, positive, negative)


def crps_numeric(cdf, y: float, lo: float, hi: float, n: int = 20001) -> float:
    """CRPS by direct quadrature of `integral (F(x) - 1{x >= y}) ** 2 dx`.

    Slow and only used to prove the closed forms right in tests, which is the point:
    a closed form nobody checked is a closed form nobody should trust.
    """
    grid = np.linspace(lo, hi, n)
    indicator = (grid >= y).astype(float)
    return float(np.trapezoid((np.asarray(cdf(grid)) - indicator) ** 2, grid))


def crps_ensemble(samples: np.ndarray, y: float) -> float:
    """CRPS of an empirical distribution given by `samples`.

    Uses the `E|X - y| - 0.5 E|X - X'|` form with the sorted-sample identity for the
    second term, so it is O(n log n) rather than O(n ** 2). Lets a purely empirical
    baseline — "predict the training distribution, unconditionally" — be scored on the
    same axis as the parametric models.
    """
    samples = np.sort(np.asarray(samples, dtype=float))
    n = samples.size
    term1 = np.abs(samples - y).mean()
    # E|X - X'| for an empirical distribution, via sum_i (2i - n + 1) * x_(i).
    weights = 2.0 * np.arange(n) - n + 1.0
    term2 = 2.0 * float((weights * samples).sum()) / (n * n)
    return float(term1 - 0.5 * term2)


def pit_values(params: list[WeibullParams], y) -> np.ndarray:
    """Probability integral transform `u_i = F_i(y_i)`.

    If each `F_i` really is the conditional distribution of `y_i`, the `u_i` are
    uniform on [0, 1]. Any departure from flat is a specific, named defect — see
    `summarise_pit`.
    """
    y = np.asarray(y, dtype=float)
    if len(params) != y.size:
        raise ValueError(f"params/y length mismatch: {len(params)} vs {y.size}")
    k = np.array([p.shape for p in params])
    lam = np.array([p.scale for p in params])
    gamma = np.array([p.location for p in params])
    z = np.maximum(y - gamma, 0.0) / lam
    return 1.0 - np.exp(-(z**k))


@dataclass(frozen=True)
class PitSummary:
    """Calibration verdict with the evidence that produced it."""

    n: int
    mean: float
    variance: float
    ks_statistic: float
    chi2_statistic: float
    chi2_p_value: float
    diagnosis: str
    #: Fraction of observations below the predicted median. 0.5 when unbiased.
    below_median: float


#: Variance of a Uniform(0, 1). The reference a PIT variance is compared against.
UNIFORM_VARIANCE = 1.0 / 12.0


def summarise_pit(u, n_bins: int = 20, dispersion_tolerance: float = 0.06) -> PitSummary:
    """Turn PIT values into a named calibration failure mode.

    The two failure modes, and how to read them off the histogram:

    * **Under-dispersion** — the predicted distributions are too *narrow*. Reality
      lands in the tails more often than the model allows, so the histogram is
      U-shaped: mass piles up near 0 and 1. Variance of the PIT values exceeds 1/12.
      This is the dangerous one: the model claims confidence it has not earned, so a
      p90 quote is late far more than 10% of the time.
    * **Over-dispersion** — the predicted distributions are too *wide*. Reality lands
      near the middle too often, so the histogram has a central hump and variance falls
      below 1/12. Wasteful rather than dangerous: quotes are padded and every ETA reads
      as pessimistic.

    A tilt (mean away from 0.5) is a third, separate defect — bias — and is reported
    alongside rather than folded into the dispersion verdict.
    """
    u = np.asarray(u, dtype=float)
    u = u[np.isfinite(u)]
    if u.size == 0:
        raise ValueError("no finite PIT values")

    counts, _ = np.histogram(u, bins=n_bins, range=(0.0, 1.0))
    expected = u.size / n_bins
    chi2 = float(((counts - expected) ** 2 / expected).sum())
    chi2_p = float(stats.chi2.sf(chi2, df=n_bins - 1))
    ks = float(stats.kstest(u, "uniform").statistic)

    variance = float(u.var(ddof=1))
    relative = (variance - UNIFORM_VARIANCE) / UNIFORM_VARIANCE
    if relative > dispersion_tolerance:
        diagnosis = "under-dispersed (predictive distributions too narrow)"
    elif relative < -dispersion_tolerance:
        diagnosis = "over-dispersed (predictive distributions too wide)"
    else:
        diagnosis = "well dispersed"

    return PitSummary(
        n=int(u.size),
        mean=float(u.mean()),
        variance=variance,
        ks_statistic=ks,
        chi2_statistic=chi2,
        chi2_p_value=chi2_p,
        diagnosis=diagnosis,
        below_median=float((u < 0.5).mean()),
    )


def coverage_curve(
    params: list[WeibullParams], y, levels=None
) -> tuple[np.ndarray, np.ndarray]:
    """Nominal quantile level vs realised coverage — the calibration plot's data.

    Perfect calibration is the identity line. Below it means the model's quantiles are
    too low (it is late more often than it promises).
    """
    if levels is None:
        levels = np.linspace(0.02, 0.98, 49)
    levels = np.asarray(levels, dtype=float)
    y = np.asarray(y, dtype=float)
    realised = np.array(
        [float((y <= np.array([p.quantile(q) for p in params])).mean()) for q in levels]
    )
    return levels, realised


def interval_score(lower, upper, y, alpha: float) -> float:
    """Winkler interval score for a central `1 - alpha` prediction interval.

    Rewards narrow intervals and penalises misses in proportion to how far outside they
    land. Reported alongside CRPS because a customer experiences an ETA as an interval
    promise, not as a density.
    """
    lower = np.asarray(lower, dtype=float)
    upper = np.asarray(upper, dtype=float)
    y = np.asarray(y, dtype=float)
    width = upper - lower
    below = (2.0 / alpha) * np.maximum(lower - y, 0.0)
    above = (2.0 / alpha) * np.maximum(y - upper, 0.0)
    return float((width + below + above).mean())
