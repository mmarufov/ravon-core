"""Validation by injecting anomalies with known ground truth.

This is the part of the anomaly work that is *better* than what DoorDash publishes,
and the reason is structural rather than clever: they can report that their platform
found 60% of new fraud trends, but they cannot report the denominator, because nobody
knows how many trends there were. Here the denominator is constructed. An anomaly is
put into the data at a known segment, on a known day, at a known magnitude, and the
detector either finds it or does not.

That buys three numbers a production system cannot have:

* **detection rate as a function of magnitude** — the smallest incident worth alerting
  on, measured instead of guessed;
* **detection latency** on a ramping trend — how many days of a slow degradation pass
  before the dual gate fires;
* **a true false-positive rate** — runs on unperturbed days, where any firing is by
  construction a false alarm.

## What the perturbation model is, exactly

Injection is applied to the *exported records*, not inside the Swift simulator, because
`ml/` is required to run with no Swift toolchain. That is a real limitation and it is
worth being precise about what it costs: a perturbation applied in the simulator would
propagate — a slow kitchen holds its courier longer, which delays other orders through
the shared courier pool. Applied to the exported table, the perturbation is confined to
the affected orders and the second-order congestion effect is absent.

The direction of that bias is knowable: post-hoc injection makes the anomaly *smaller
and more localised* than the real thing, so measured detection rates here are a
conservative lower bound on what the same detector would achieve against a
simulator-level perturbation. That is the right direction for a validation to err in.
"""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np
import pandas as pd

from .anomaly import (
    DIMENSIONS,
    METRICS,
    Metric,
    Windows,
    cluster_anomalies,
    detect_day,
    segment_daily_metrics,
)

__all__ = [
    "Injection",
    "inject_slow_restaurant",
    "inject_cancellation_spike",
    "DetectionOutcome",
    "evaluate_detection",
    "magnitude_sweep",
    "detection_latency",
    "false_positive_rate",
    "gap_window_comparison",
]


@dataclass(frozen=True)
class Injection:
    """A perturbation plus the segments that ought to light up because of it."""

    kind: str
    description: str
    affected_days: tuple[int, ...]
    #: Segment labels that are a correct localisation of this incident.
    truth_segments: frozenset[str]
    magnitude: float
    metric: str

    def is_correct(self, segment: str) -> bool:
        return segment in self.truth_segments


def _truth_segments(df: pd.DataFrame, dimension: str, value) -> frozenset[str]:
    """Every segment label that names `dimension=value`, at singlet or pair level.

    A pair segment containing the affected dimension counts as a *correct*
    localisation — narrower than ideal, but it still points the on-call engineer at the
    right restaurant. Grading it a miss would be measuring the ranking, not the
    detection; the ranking is graded separately by `DetectionOutcome.top_is_correct`.

    Built combinatorially from the frame's distinct dimension values rather than by
    re-segmenting, because the magnitude sweeps call this thousands of times.
    """
    base = f"{dimension}={value}"
    labels = {base}
    for other in DIMENSIONS:
        if other == dimension:
            continue
        for other_value in df[other].unique():
            clauses = {dimension: base, other: f"{other}={other_value}"}
            # Labels are emitted in DIMENSIONS order by `segment_daily_metrics`.
            labels.add("|".join(clauses[d] for d in DIMENSIONS if d in clauses))
    return frozenset(labels)


def inject_slow_restaurant(
    df: pd.DataFrame,
    restaurant_index: int,
    days,
    extra_minutes: float,
) -> tuple[pd.DataFrame, Injection]:
    """A kitchen that starts running `extra_minutes` late.

    Adds a constant delay to every delivered order from that restaurant on the given
    days. Constant rather than proportional because that is how a real kitchen
    degradation presents — one broken fryer costs every ticket the same eight minutes,
    regardless of how big the order was.
    """
    days = tuple(int(d) for d in np.atleast_1d(days))
    out = df.copy()
    mask = out["restaurant_index"].eq(restaurant_index) & out["day"].isin(days)
    mask &= out["total_delivery_minutes"].notna()
    out.loc[mask, "total_delivery_minutes"] += extra_minutes
    out.loc[mask, "delivered_at_minutes"] += extra_minutes

    truth = _truth_segments(out, "restaurant_index", restaurant_index)
    return out, Injection(
        kind="slow_restaurant",
        description=(
            f"restaurant {restaurant_index} runs {extra_minutes:.0f} min late on "
            f"day(s) {days[0]}-{days[-1]}"
        ),
        affected_days=days,
        truth_segments=truth,
        magnitude=extra_minutes,
        metric="mean_delivery_minutes",
    )


def inject_cancellation_spike(
    df: pd.DataFrame,
    zone: str,
    days,
    extra_rate: float,
    seed: int = 0,
) -> tuple[pd.DataFrame, Injection]:
    """A zone where a fraction of orders suddenly fail to be served.

    Implemented by taking orders that *were* delivered and marking them unassigned:
    no courier, no delivery, no duration. That is what the simulator's own failure mode
    looks like, so the injected rows are indistinguishable in shape from natural ones.
    """
    days = tuple(int(d) for d in np.atleast_1d(days))
    if not 0.0 < extra_rate <= 1.0:
        raise ValueError("extra_rate must lie in (0, 1]")
    rng = np.random.default_rng(seed)
    out = df.copy()

    eligible = out.index[
        out["zone"].eq(zone) & out["day"].isin(days) & out["delivered"]
    ]
    n_flip = int(round(len(eligible) * extra_rate))
    if n_flip > 0:
        chosen = rng.choice(eligible.to_numpy(), size=n_flip, replace=False)
        out.loc[chosen, ["assigned_at_minutes", "delivered_at_minutes",
                         "wait_to_assign_minutes", "total_delivery_minutes"]] = np.nan
        out.loc[chosen, ["assigned", "delivered"]] = False

    truth = _truth_segments(out, "zone", zone)
    return out, Injection(
        kind="cancellation_spike",
        description=(
            f"zone {zone} loses {extra_rate:.0%} of its orders on day(s) "
            f"{days[0]}-{days[-1]}"
        ),
        affected_days=days,
        truth_segments=truth,
        magnitude=extra_rate,
        metric="unassigned_rate",
    )


@dataclass(frozen=True)
class DetectionOutcome:
    """Did the detector find the injected incident, and how prominently?"""

    detected: bool
    #: 1-based rank of the first correct cluster, or None when nothing correct fired.
    rank: int | None
    #: Rank of the correct cluster among clusters, where 1 is the top of the page.
    n_clusters: int
    #: True when the top-ranked cluster's representative is a correct localisation.
    top_is_correct: bool
    #: Whether the representative was the exact singlet rather than a pair.
    representative: str | None
    #: Largest Z-score among all firing segments, correct or not.
    max_z: float | None
    #: Z-score of the injected segment itself, whether or not it cleared the gates.
    #: This is the diagnostic that separates "the signal was too small" from "the
    #: signal was there and the gates or the ranking lost it".
    truth_z: float | None = None
    truth_passed_z_gate: bool = False
    truth_passed_abs_gate: bool = False


def evaluate_detection(
    df: pd.DataFrame,
    injection: Injection,
    test_day: int,
    windows: Windows = Windows(),
    sigma: float = 3.0,
    metric: Metric | None = None,
) -> DetectionOutcome:
    """Run the full pipeline — segment, dual gate, cluster — and grade the result."""
    metric = metric or METRICS[injection.metric]
    metrics = segment_daily_metrics(df)
    scored = detect_day(metrics, test_day, metric, windows, sigma, return_all=True)
    truth_z, truth_z_gate, truth_abs_gate = _truth_diagnostics(
        scored, injection, metric, sigma
    )
    anomalies = scored[scored["fired"]].drop(columns=["fired"]) if not scored.empty else scored
    if anomalies.empty:
        return DetectionOutcome(
            False, None, 0, False, None, None, truth_z, truth_z_gate, truth_abs_gate
        )

    clusters = cluster_anomalies(df[df["day"] == test_day], anomalies)
    rank = None
    for position, cluster in enumerate(clusters, start=1):
        if any(injection.is_correct(member) for member in cluster.members):
            rank = position
            break
    top = clusters[0]
    return DetectionOutcome(
        detected=rank is not None,
        rank=rank,
        n_clusters=len(clusters),
        top_is_correct=injection.is_correct(top.representative),
        representative=top.representative,
        max_z=float(anomalies["z_score"].max()),
        truth_z=truth_z,
        truth_passed_z_gate=truth_z_gate,
        truth_passed_abs_gate=truth_abs_gate,
    )


def _truth_diagnostics(
    scored: pd.DataFrame, injection: Injection, metric: Metric, sigma: float
) -> tuple[float | None, bool, bool]:
    """Z-score and gate outcomes for the *singlet* naming the injected entity."""
    if scored.empty:
        return None, False, False
    singlets = scored[
        scored["segment"].isin(injection.truth_segments) & scored["level"].eq(1)
    ]
    if singlets.empty:
        return None, False, False
    row = singlets.loc[singlets["z_score"].idxmax()]
    return (
        float(row["z_score"]),
        bool(row["z_score"] >= sigma),
        bool(row["abs_anom_amt"] >= metric.absolute_threshold),
    )


def magnitude_sweep(
    df: pd.DataFrame,
    injector,
    magnitudes,
    test_days,
    windows: Windows = Windows(),
    sigma: float = 3.0,
) -> pd.DataFrame:
    """Detection rate versus incident size, averaged over several test days.

    `injector(df, day, magnitude)` must return `(perturbed_frame, Injection)`.
    """
    rows = []
    for magnitude in magnitudes:
        for day in test_days:
            perturbed, injection = injector(df, day, magnitude)
            outcome = evaluate_detection(perturbed, injection, day, windows, sigma)
            rows.append(
                {
                    "magnitude": magnitude,
                    "test_day": day,
                    "detected": outcome.detected,
                    "rank": outcome.rank,
                    "top_is_correct": outcome.top_is_correct,
                    "n_clusters": outcome.n_clusters,
                    "max_z": outcome.max_z,
                    "truth_z": outcome.truth_z,
                }
            )
    return pd.DataFrame(rows)


def detection_latency(
    df: pd.DataFrame,
    injector,
    start_day: int,
    n_days: int,
    magnitude_schedule,
    windows: Windows = Windows(),
    sigma: float = 3.0,
) -> dict:
    """Days from the start of a ramping incident until the detector fires.

    The incident is applied cumulatively: by day `start_day + i` the perturbation has
    been in the data for `i + 1` days at the magnitudes given by `magnitude_schedule`.
    This is the case the gap window exists for — every elapsed day of the ramp is a day
    that would otherwise contaminate the baseline.
    """
    magnitudes = list(magnitude_schedule)
    if len(magnitudes) < n_days:
        raise ValueError("magnitude_schedule shorter than n_days")

    perturbed = df
    history = []
    latency = None
    for offset in range(n_days):
        day = start_day + offset
        perturbed, injection = injector(perturbed, day, magnitudes[offset])
        outcome = evaluate_detection(perturbed, injection, day, windows, sigma)
        history.append(
            {
                "day": day,
                "days_elapsed": offset + 1,
                "magnitude": magnitudes[offset],
                "detected": outcome.detected,
                "rank": outcome.rank,
                "max_z": outcome.max_z,
                "truth_z": outcome.truth_z,
            }
        )
        if outcome.detected and latency is None:
            latency = offset + 1
    return {"latency_days": latency, "history": pd.DataFrame(history)}


def false_positive_rate(
    df: pd.DataFrame,
    metric: Metric,
    windows: Windows = Windows(),
    sigma: float = 3.0,
) -> dict:
    """Firings per day on unperturbed data, where every firing is by definition false.

    Reported both as raw segment firings and as *clustered incidents*, because the
    second is what an on-call engineer is actually paged for and the first
    systematically overstates the noise.
    """
    metrics = segment_daily_metrics(df)
    all_days = np.sort(df["day"].unique())
    days = [int(d) for d in all_days if windows.baseline_range(int(d))[0] >= all_days.min()]

    firings = 0
    incidents = 0
    tests = 0
    for day in days:
        anomalies = detect_day(metrics, day, metric, windows, sigma)
        day_metrics = metrics[metrics["day"] == day]
        tests += day_metrics["segment"].nunique()
        firings += len(anomalies)
        if not anomalies.empty:
            incidents += len(cluster_anomalies(df[df["day"] == day], anomalies))

    return {
        "metric": metric.name,
        "sigma": sigma,
        "days_evaluated": len(days),
        "tests_run": tests,
        "segment_firings": firings,
        "segment_firings_per_day": firings / len(days) if days else 0.0,
        "clustered_incidents": incidents,
        "incidents_per_day": incidents / len(days) if days else 0.0,
        "per_test_false_positive_rate": firings / tests if tests else 0.0,
    }


def gap_window_comparison(
    df: pd.DataFrame,
    injector,
    start_day: int,
    n_days: int,
    magnitude_schedule,
    sigma: float = 3.0,
) -> pd.DataFrame:
    """The gap window's value, measured: 7-day gap versus no gap, on the same ramp.

    Both configurations get the same total lookback so the comparison is not just
    "more history wins": 21 baseline + 7 gap against 28 baseline + 0 gap.
    """
    configurations = {
        "gap=7 (21-day baseline, 7-day gap)": Windows(baseline_days=21, gap_days=7),
        "gap=0 (28-day baseline, no gap)": Windows(baseline_days=28, gap_days=0),
    }
    rows = []
    for label, windows in configurations.items():
        result = detection_latency(
            df, injector, start_day, n_days, magnitude_schedule, windows, sigma
        )
        history = result["history"]
        history = history.assign(configuration=label, latency_days=result["latency_days"])
        rows.append(history)
    return pd.concat(rows, ignore_index=True)
