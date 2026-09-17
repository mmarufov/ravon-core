"""Three-parameter Weibull fitted by interval regression.

## Why a Weibull

Delivery duration is a positive, right-skewed, hard-floored quantity: it cannot be less
than the time to ride the haul, and it has a long tail made of kitchens that run late
and queues that do not clear. A Weibull with a location shift is the smallest family
that represents all three — floor (`location`), spread (`scale`), tail weight (`shape`).
It is also what DoorDash's NextGen ETA predicts, which makes their published numbers
directly comparable to ours.

## Why interval regression rather than maximum likelihood

The survival function of a shifted Weibull is

    S(t) = exp(-((t - gamma) / lam) ** k)

so

    log(-log S(t)) = k * log(t - gamma) - k * log(lam)

which is *linear* in `log(t - gamma)`. Histogram the realised durations into fixed-width
buckets, read the empirical survival off the histogram, apply that transform, and the
whole fit is one ordinary least squares solve.

DoorDash reports this "greatly reduced overfitting" versus maximising the log-likelihood
directly. Four concrete reasons, all of which apply here:

1. **Binning is the regulariser.** The fit targets ~a dozen bucket survivals, not
   several thousand individual observations, so the effective sample the loss sees is
   coarse on purpose. A single 6-hour delivery nudges one bucket instead of dragging the
   likelihood.
2. **The loss lives on the log-log survival scale**, where the model is linear and the
   residuals are roughly homoscedastic. MLE's loss is dominated by the extreme tail,
   which is exactly where the data is thinnest and the leverage highest.
3. **It is a linear solve.** No optimiser, no starting values, no convergence failures,
   bit-identical across runs — which matters when the repo standard is that every
   number is reproducible from a fixed seed.
4. **It composes.** Fitting per-segment Weibulls by OLS and then regressing the fitted
   parameters on segment features is two linear stages; the MLE equivalent is a nested
   optimisation.

`fit_mle` is provided so the claim can be *tested* rather than repeated — see
`tests/test_weibull.py::test_interval_regression_generalises_at_least_as_well_as_mle`.

## A note on the brief's formula

The brief writes the transform as `log(-log(S(t))) = k(log t - log lam) + gamma`, with
`gamma` as an additive intercept. That is not a location parameter — an additive
constant on the log-log scale is absorbed by `lam` and leaves the distribution's support
starting at zero. The location shift has to go *inside* the log, as above, or a
distribution that cannot produce a delivery faster than 12 minutes is free to. So the
intercept is profiled out: for each candidate `gamma` the inner problem stays exactly
the OLS that DoorDash describes, and an outer one-dimensional search picks `gamma`.
"""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np
from scipy import optimize, stats

__all__ = [
    "WeibullParams",
    "IntervalFit",
    "survival_bins",
    "fit_interval_regression",
    "fit_mle",
]


@dataclass(frozen=True)
class WeibullParams:
    """A three-parameter Weibull: shape `k`, scale `lam`, location `gamma`."""

    shape: float
    scale: float
    location: float = 0.0

    def __post_init__(self) -> None:
        if not (self.shape > 0 and self.scale > 0):
            raise ValueError(f"shape and scale must be positive, got {self}")

    def _z(self, t):
        return np.maximum((np.asarray(t, dtype=float) - self.location), 0.0) / self.scale

    def sf(self, t):
        """Survival function P(T > t)."""
        return np.exp(-self._z(t) ** self.shape)

    def cdf(self, t):
        return 1.0 - self.sf(t)

    def pdf(self, t):
        z = self._z(t)
        with np.errstate(divide="ignore", invalid="ignore"):
            dens = (
                (self.shape / self.scale)
                * np.power(z, self.shape - 1.0)
                * np.exp(-(z**self.shape))
            )
        return np.where(np.asarray(t, dtype=float) > self.location, dens, 0.0)

    def quantile(self, q):
        """Inverse CDF. `q` may be scalar or array."""
        q = np.asarray(q, dtype=float)
        if np.any((q < 0) | (q > 1)):
            raise ValueError("quantile levels must lie in [0, 1]")
        # -log(1 - q) at q = 1 is +inf, which is the correct answer.
        with np.errstate(divide="ignore"):
            return self.location + self.scale * np.power(-np.log1p(-q), 1.0 / self.shape)

    def mean(self) -> float:
        from scipy.special import gamma as gamma_fn

        return float(self.location + self.scale * gamma_fn(1.0 + 1.0 / self.shape))

    def as_tuple(self) -> tuple[float, float, float]:
        return (self.shape, self.scale, self.location)


@dataclass(frozen=True)
class IntervalFit:
    """A fit plus the diagnostics needed to decide whether to trust it."""

    params: WeibullParams
    n_samples: int
    n_bins_used: int
    r_squared: float
    sse: float

    @property
    def shape(self) -> float:
        return self.params.shape

    @property
    def scale(self) -> float:
        return self.params.scale

    @property
    def location(self) -> float:
        return self.params.location


def survival_bins(
    samples, bin_width: float = 6.0
) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """Histogram `samples` into fixed-width buckets and return empirical survival.

    Returns `(right_edges, survival, counts)` where `survival[i]` is the fraction of
    samples strictly greater than `right_edges[i]`.

    6 minutes is DoorDash's bucket width and it is not arbitrary: it is coarse enough
    that each bucket holds a usable count at realistic segment sizes, and fine enough
    that a 30-minute delivery and a 45-minute delivery never land together.
    """
    samples = np.asarray(samples, dtype=float)
    samples = samples[np.isfinite(samples)]
    if samples.size == 0:
        raise ValueError("no finite samples")
    if bin_width <= 0:
        raise ValueError("bin_width must be positive")

    lo = np.floor(samples.min() / bin_width) * bin_width
    hi = np.ceil(samples.max() / bin_width) * bin_width
    if hi <= lo:
        hi = lo + bin_width
    edges = np.arange(lo, hi + bin_width / 2, bin_width)
    counts, _ = np.histogram(samples, bins=edges)

    right_edges = edges[1:]
    survival = 1.0 - np.cumsum(counts) / samples.size
    return right_edges, survival, counts


def _bin_weights(survival: np.ndarray, counts: np.ndarray, scheme: str) -> np.ndarray:
    """Least-squares weights for the log-log survival regression.

    Three schemes, all of them least squares — the choice is only about what each
    bucket's residual is worth:

    * ``"none"`` — the literal reading of "ordinary least squares over the buckets".
      Every bucket counts the same, so a tail bucket holding three deliveries pulls as
      hard as a body bucket holding nine hundred. Measurably biased; kept so the
      comparison can be run rather than asserted.
    * ``"count"`` — weight by the number of observations in the bucket. This is
      ordinary least squares over *observations* rather than over buckets, which is
      what "fit the histogram" should have meant all along.
    * ``"delta"`` — the delta-method variance of ``log(-log(S_hat))``. With
      ``Var(S_hat) = S(1 - S) / n``, propagating through the transform gives
      ``Var ~ (1 - S) / (n * S * log(S) ** 2)``, so the weight is its reciprocal.
      This is the statistically correct weighting; whether it beats plain counts on
      this data is an empirical question, answered in FINDINGS.md.
    """
    counts = counts.astype(float)
    if scheme == "none":
        return np.ones_like(survival)
    if scheme == "count":
        return counts
    if scheme == "delta":
        n = counts.sum()
        with np.errstate(divide="ignore", invalid="ignore"):
            variance = (1.0 - survival) / (n * survival * np.log(survival) ** 2)
        weights = np.where(variance > 0, 1.0 / np.maximum(variance, 1e-12), 0.0)
        return weights
    raise ValueError(f"unknown weight scheme {scheme!r}")


def _ols_for_location(
    right_edges: np.ndarray,
    survival: np.ndarray,
    counts: np.ndarray,
    location: float,
    weights_scheme: str,
) -> tuple[float, float, float, float, int] | None:
    """Inner OLS of the log-log survival transform at a fixed `location`.

    Returns `(shape, scale, sse, r_squared, n_bins)` or None if the bin set is too thin.
    """
    usable = (right_edges > location) & (survival > 0.0) & (survival < 1.0)
    if usable.sum() < 3:
        return None

    x = np.log(right_edges[usable] - location)
    y = np.log(-np.log(survival[usable]))
    w = _bin_weights(survival[usable], counts[usable], weights_scheme)
    if not np.all(np.isfinite(x)) or not np.all(np.isfinite(y)) or w.sum() <= 0:
        return None

    # Weighted (or plain) least squares for y = shape * x + intercept.
    sw = w.sum()
    mx = (w * x).sum() / sw
    my = (w * y).sum() / sw
    sxx = (w * (x - mx) ** 2).sum()
    if sxx <= 0:
        return None
    shape = (w * (x - mx) * (y - my)).sum() / sxx
    if not (shape > 0) or not np.isfinite(shape):
        return None
    intercept = my - shape * mx

    residuals = y - (shape * x + intercept)
    sse = float((w * residuals**2).sum())
    sst = float((w * (y - my) ** 2).sum())
    r_squared = 1.0 - sse / sst if sst > 0 else 0.0

    # intercept = -shape * log(scale)
    scale = float(np.exp(-intercept / shape))
    if not np.isfinite(scale) or scale <= 0:
        return None
    return float(shape), scale, sse, float(r_squared), int(usable.sum())


def fit_interval_regression(
    samples,
    bin_width: float = 6.0,
    fit_location: bool = True,
    weights: str = "count",
    location_grid_size: int = 40,
) -> IntervalFit:
    """Fit a shifted Weibull by OLS on the log-log survival transform.

    `weights` selects the least-squares weighting; see `_bin_weights`. The default,
    `"count"`, is ordinary least squares over observations and is what the rest of the
    package uses.

    `fit_location=False` pins `gamma = 0`, which is the exact two-parameter form and the
    literal reading of DoorDash's transform. `fit_location=True` profiles `gamma` out
    with a coarse grid plus a bounded golden-section refinement — deterministic, so the
    result is reproducible without a seed.
    """
    samples = np.asarray(samples, dtype=float)
    samples = samples[np.isfinite(samples)]
    if samples.size < 10:
        raise ValueError(f"need at least 10 samples to fit, got {samples.size}")

    right_edges, survival, counts = survival_bins(samples, bin_width)

    def solve(location: float):
        return _ols_for_location(right_edges, survival, counts, location, weights)

    best_location = 0.0
    best = solve(0.0)

    if fit_location:
        # The location cannot exceed the smallest observation. Stop just short of it:
        # at gamma == min(samples) the first bin collapses and the fit degenerates.
        upper = float(samples.min()) * 0.98
        if upper > 0:
            grid = np.linspace(0.0, upper, location_grid_size)
            scored = [(g, solve(g)) for g in grid]
            scored = [(g, r) for g, r in scored if r is not None]
            if scored:
                best_location, best = min(scored, key=lambda gr: gr[1][2])
                # Golden-section refine inside the bracketing grid cell.
                step = upper / (location_grid_size - 1)
                lo = max(0.0, best_location - step)
                hi = min(upper, best_location + step)
                if hi > lo:

                    def objective(g: float) -> float:
                        r = solve(g)
                        return np.inf if r is None else r[2]

                    refined = optimize.minimize_scalar(
                        objective, bounds=(lo, hi), method="bounded",
                        options={"xatol": 1e-4},
                    )
                    r = solve(float(refined.x))
                    if r is not None and r[2] <= best[2]:
                        best_location, best = float(refined.x), r

    if best is None:
        raise ValueError(
            "interval regression failed: fewer than 3 usable survival bins. "
            "Widen bin_width or pool more samples."
        )

    shape, scale, sse, r_squared, n_bins = best
    return IntervalFit(
        params=WeibullParams(shape=shape, scale=scale, location=best_location),
        n_samples=int(samples.size),
        n_bins_used=n_bins,
        r_squared=r_squared,
        sse=sse,
    )


def fit_mle(samples, fit_location: bool = True) -> WeibullParams:
    """Maximum-likelihood fit, for comparison against interval regression only."""
    samples = np.asarray(samples, dtype=float)
    samples = samples[np.isfinite(samples)]
    if fit_location:
        shape, loc, scale = stats.weibull_min.fit(samples)
    else:
        shape, loc, scale = stats.weibull_min.fit(samples, floc=0.0)
    return WeibullParams(shape=float(shape), scale=float(scale), location=float(loc))
