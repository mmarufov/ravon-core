"""The ETA base layer: features -> a calibrated Weibull over delivery duration.

## Two layers, kept apart

DoorDash's NextGen ETA separates a **base layer** that produces an unbiased, calibrated
distribution from a **decision layer** that collapses that distribution into the one
number a customer sees. This module is the base layer only. It is scored on CRPS and
PIT — how well it describes reality — and never on "how often were we late", because
optimising the base layer for lateness is exactly the mistake the split exists to
prevent. Lateness is the decision layer's problem; see `ravon_ml.decision`.

## Model structure

No gradient boosting, no neural net. Two linear stages:

1. **Score.** An ordinary least squares mean model maps the feature vector to a single
   expected-duration score. This is only used to *order and group* orders, not as the
   forecast.
2. **Segment, fit, link.** Training orders are cut into quantile cells of that score.
   Each cell's realised durations are histogrammed into 6-minute buckets and fitted by
   the log-log survival OLS in `ravon_ml.weibull`. The resulting per-cell
   `(k, lam, gamma)` triples are then themselves regressed on the cell score, giving a
   smooth, closed-form map from any feature vector to a distribution.

Why this shape rather than a single joint fit: stage 2 is where DoorDash's
"interval regression, not MLE" argument buys something. Each cell gets ~a dozen numbers
to fit three parameters, and the link across cells is a three-coefficient line. The
model has roughly ten degrees of freedom in total, which is why it can be read, argued
with, and checked against the simulator's known latent structure.
"""

from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np
import pandas as pd

from .data import assert_no_latent_features
from .metrics import (
    crps_ensemble,
    crps_weibull,
    pit_values,
    summarise_pit,
)
from .weibull import WeibullParams, fit_interval_regression, fit_mle

__all__ = [
    "ConditionalWeibullETA",
    "UnconditionalWeibullETA",
    "PointForecast",
    "evaluate",
    "EvaluationRow",
    "empirical_crps_floor",
]

TARGET = "total_delivery_minutes"


def _design_matrix(df: pd.DataFrame, features) -> np.ndarray:
    """Feature matrix with an intercept column."""
    x = df[list(features)].to_numpy(dtype=float)
    return np.column_stack([np.ones(len(df)), x])


@dataclass
class ConditionalWeibullETA:
    """Feature-conditional three-parameter Weibull, fitted by interval regression."""

    features: tuple[str, ...]
    n_cells: int = 30
    bin_width: float = 6.0
    #: Below this, a cell is dropped from the link regression rather than fitted badly.
    min_cell_samples: int = 200
    #: `"interval"` (DoorDash's log-log survival OLS) or `"mle"`. Switchable so the
    #: claim that interval regression generalises better can be *measured* on this
    #: data rather than inherited from their blog post. It does not, here; see
    #: FINDINGS.md.
    per_cell_fit: str = "interval"

    coefficients_: np.ndarray | None = field(default=None, init=False)
    cell_table_: pd.DataFrame | None = field(default=None, init=False)
    link_: dict[str, np.ndarray] = field(default_factory=dict, init=False)
    score_mean_: float = field(default=0.0, init=False)
    score_std_: float = field(default=1.0, init=False)

    def __post_init__(self) -> None:
        assert_no_latent_features(self.features)

    # -- stage 1 -----------------------------------------------------------------

    def _score(self, df: pd.DataFrame) -> np.ndarray:
        assert self.coefficients_ is not None, "model is not fitted"
        raw = _design_matrix(df, self.features) @ self.coefficients_
        return (raw - self.score_mean_) / self.score_std_

    # -- fitting -----------------------------------------------------------------

    def fit(self, train: pd.DataFrame) -> "ConditionalWeibullETA":
        train = train[train[TARGET].notna()]
        if len(train) < self.n_cells * self.min_cell_samples:
            raise ValueError(
                f"{len(train)} training rows cannot support {self.n_cells} cells of "
                f"at least {self.min_cell_samples}"
            )

        design = _design_matrix(train, self.features)
        y = train[TARGET].to_numpy(dtype=float)
        self.coefficients_ = np.linalg.lstsq(design, y, rcond=None)[0]

        raw = design @ self.coefficients_
        self.score_mean_ = float(raw.mean())
        self.score_std_ = float(raw.std(ddof=1)) or 1.0
        score = (raw - self.score_mean_) / self.score_std_

        # Quantile cells. `duplicates="drop"` guards against a degenerate score.
        cells = pd.qcut(score, self.n_cells, labels=False, duplicates="drop")

        rows = []
        for cell in np.unique(cells):
            mask = cells == cell
            if mask.sum() < self.min_cell_samples:
                continue
            if self.per_cell_fit == "interval":
                fit = fit_interval_regression(y[mask], bin_width=self.bin_width)
                params, r_squared = fit.params, fit.r_squared
            elif self.per_cell_fit == "mle":
                params, r_squared = fit_mle(y[mask]), float("nan")
            else:
                raise ValueError(f"unknown per_cell_fit {self.per_cell_fit!r}")
            rows.append(
                {
                    "cell": int(cell),
                    "n": int(mask.sum()),
                    "score": float(score[mask].mean()),
                    "shape": params.shape,
                    "scale": params.scale,
                    "location": params.location,
                    "r_squared": r_squared,
                    "mean_actual": float(y[mask].mean()),
                }
            )
        if len(rows) < 4:
            raise ValueError(f"only {len(rows)} usable cells; cannot fit the link")
        self.cell_table_ = pd.DataFrame(rows)

        # -- stage 2: link the fitted parameters to the score ------------------
        #
        # `shape` and `scale` go through a log link so predictions stay positive for
        # any score, including scores outside the training range. `location` is linear
        # and clipped at zero at predict time: it is a duration floor in minutes, and a
        # negative floor is meaningless rather than merely unlikely.
        s = self.cell_table_["score"].to_numpy()
        basis = np.column_stack([np.ones(len(s)), s, s**2])
        for name, values, transform in (
            ("shape", self.cell_table_["shape"].to_numpy(), np.log),
            ("scale", self.cell_table_["scale"].to_numpy(), np.log),
            ("location", self.cell_table_["location"].to_numpy(), None),
        ):
            target = transform(values) if transform is not None else values
            self.link_[name] = np.linalg.lstsq(basis, target, rcond=None)[0]
        return self

    # -- prediction --------------------------------------------------------------

    def predict_params(self, df: pd.DataFrame) -> list[WeibullParams]:
        score = self._score(df)
        basis = np.column_stack([np.ones(len(score)), score, score**2])
        shape = np.exp(basis @ self.link_["shape"])
        scale = np.exp(basis @ self.link_["scale"])
        location = np.maximum(basis @ self.link_["location"], 0.0)

        # Guard rails, hit only when a test score falls outside the fitted range and
        # the quadratic link extrapolates somewhere silly.
        shape = np.clip(shape, 0.5, 20.0)
        scale = np.clip(scale, 1e-3, 1e4)
        return [
            WeibullParams(shape=float(k), scale=float(l), location=float(g))
            for k, l, g in zip(shape, scale, location)
        ]

    def predict_quantile(self, df: pd.DataFrame, level: float) -> np.ndarray:
        return np.array([p.quantile(level) for p in self.predict_params(df)])

    @property
    def name(self) -> str:
        suffix = "" if self.per_cell_fit == "interval" else f"/{self.per_cell_fit}"
        return f"conditional-weibull[{len(self.features)}f{suffix}]"


@dataclass
class UnconditionalWeibullETA:
    """One Weibull for every order. The floor a conditional model must clear.

    Worth keeping visible: this model is perfectly calibrated by construction on data
    drawn from the same distribution, and completely uninformative. It is the concrete
    demonstration that calibration alone is not a result.
    """

    bin_width: float = 6.0
    params_: WeibullParams | None = field(default=None, init=False)

    def fit(self, train: pd.DataFrame) -> "UnconditionalWeibullETA":
        y = train[TARGET].dropna().to_numpy(dtype=float)
        self.params_ = fit_interval_regression(y, bin_width=self.bin_width).params
        return self

    def predict_params(self, df: pd.DataFrame) -> list[WeibullParams]:
        assert self.params_ is not None, "model is not fitted"
        return [self.params_] * len(df)

    @property
    def name(self) -> str:
        return "unconditional-weibull"


@dataclass
class PointForecast:
    """A deterministic ETA, scored on the same axis as the distributions.

    A point forecast is a distribution with all its mass in one place, and the CRPS of
    a point mass at `q` is exactly `|q - y|`. So a point model's CRPS *is* its mean
    absolute error, and the comparison against a probabilistic model is apples to
    apples rather than a category error.
    """

    label: str
    #: Called with the evaluation frame, returns the predicted minutes.
    predictor: object
    #: Added to every prediction. Used for the debiased-naive baseline.
    offset: float = 0.0

    def predict(self, df: pd.DataFrame) -> np.ndarray:
        return np.asarray(self.predictor(df), dtype=float) + self.offset

    @property
    def name(self) -> str:
        return self.label


@dataclass(frozen=True)
class EvaluationRow:
    """Everything worth knowing about one model on one held-out set."""

    model: str
    n: int
    bias_minutes: float
    sd_minutes: float
    mae_minutes: float
    crps_minutes: float
    pit_diagnosis: str | None
    pit_variance: float | None
    pit_mean: float | None
    #: Kolmogorov-Smirnov statistic of the PIT values against Uniform(0, 1), and the
    #: chi-square p-value of the 20-bin histogram. Reported because the variance-based
    #: `pit_diagnosis` only sees dispersion: a histogram can have textbook variance and
    #: still be visibly tilted or spiked, and these two numbers catch that.
    pit_ks: float | None
    pit_chi2_p: float | None
    coverage_at_p80: float | None

    def as_dict(self) -> dict:
        return {
            "model": self.model,
            "n": self.n,
            "bias_minutes": self.bias_minutes,
            "sd_minutes": self.sd_minutes,
            "mae_minutes": self.mae_minutes,
            "crps_minutes": self.crps_minutes,
            "pit_diagnosis": self.pit_diagnosis,
            "pit_variance": self.pit_variance,
            "pit_mean": self.pit_mean,
            "pit_ks": self.pit_ks,
            "pit_chi2_p": self.pit_chi2_p,
            "coverage_at_p80": self.coverage_at_p80,
        }


def evaluate(model, test: pd.DataFrame) -> EvaluationRow:
    """Score any of the model types above on a held-out frame.

    `bias` and `sd` are computed against the distribution's **mean** for probabilistic
    models, because "unbiased" is a statement about the first moment. Reporting them
    against the median instead would make an asymmetric distribution look biased when
    it is not.
    """
    test = test[test[TARGET].notna()]
    y = test[TARGET].to_numpy(dtype=float)

    if isinstance(model, PointForecast):
        predicted = model.predict(test)
        errors = y - predicted
        return EvaluationRow(
            model=model.name,
            n=len(y),
            bias_minutes=float(errors.mean()),
            sd_minutes=float(errors.std(ddof=1)),
            mae_minutes=float(np.abs(errors).mean()),
            crps_minutes=float(np.abs(errors).mean()),
            pit_diagnosis=None,
            pit_variance=None,
            pit_mean=None,
            pit_ks=None,
            pit_chi2_p=None,
            coverage_at_p80=None,
        )

    params = model.predict_params(test)
    predicted = np.array([p.mean() for p in params])
    errors = y - predicted
    u = pit_values(params, y)
    pit = summarise_pit(u)
    p80 = np.array([p.quantile(0.80) for p in params])

    return EvaluationRow(
        model=model.name,
        n=len(y),
        bias_minutes=float(errors.mean()),
        sd_minutes=float(errors.std(ddof=1)),
        mae_minutes=float(np.abs(errors).mean()),
        crps_minutes=float(crps_weibull(params, y).mean()),
        pit_diagnosis=pit.diagnosis,
        pit_variance=pit.variance,
        pit_mean=pit.mean,
        pit_ks=pit.ks_statistic,
        pit_chi2_p=pit.chi2_p_value,
        coverage_at_p80=float((y <= p80).mean()),
    )


def empirical_crps_floor(train: pd.DataFrame, test: pd.DataFrame, n_sample: int = 4000,
                         seed: int = 0) -> float:
    """CRPS of the training *empirical* distribution, as a non-parametric reference.

    If the fitted Weibull cannot beat this, the parametric family is the wrong one.
    Subsampled because the ensemble CRPS is O(n log n) per observation.
    """
    rng = np.random.default_rng(seed)
    pool = train[TARGET].dropna().to_numpy(dtype=float)
    pool = rng.choice(pool, size=min(n_sample, pool.size), replace=False)
    y = test[TARGET].dropna().to_numpy(dtype=float)
    y = rng.choice(y, size=min(n_sample, y.size), replace=False)
    return float(np.mean([crps_ensemble(pool, value) for value in y]))
