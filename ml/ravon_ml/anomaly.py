"""Segment-level anomaly detection over simulator days.

Modelled on DoorDash's anomaly platform, which they report finds >60% of all new fraud
trends and cut median time-to-detect from >100 days to under 3. Four ideas carry that
result, and all four are implemented here:

1. **A 21-day baseline, a 7-day gap, and a 1-day test window.**
2. **A dual gate** — a relative Z-score threshold *and* an absolute threshold.
3. **Segmentation** across several dimensions, at singlet and pair level.
4. **Hierarchical clustering** of the segments that fire, so one incident pages once.

## Why the gap window exists

The obvious design is "compare today against the last 28 days". It fails on exactly the
thing you most want to catch: a trend that ramps. If a restaurant has been getting
slower for a week, the last seven days already contain the problem, so they pull the
baseline mean *up* and — worse — the baseline standard deviation *wide*. The Z-score is
a ratio of those two, and a ramping anomaly degrades both terms simultaneously, so the
detector gets quieter precisely as the incident gets worse. The gap holds the baseline
back to a period that predates the trend. `validate_gap_window_matters` measures the
difference rather than asserting it.

## Why the dual gate exists

A Z-score is scale-free, which is its virtue and its failure. On a segment that sees
four orders a day, one slow delivery is a six-sigma event, and a detector that fires on
it is a detector nobody reads. The absolute gate — total excess minutes, or total
excess failed orders — says "and it has to actually matter". Neither gate alone is
usable: the Z-score alone drowns in small segments, the absolute gate alone fires on
every large segment's normal daily wobble.

## Why sigma drops from 6 to 3

DoorDash uses 6 sigma. Copying that number here would be cargo-culting, because the
threshold is not a property of anomalies — it is a property of the **multiple-comparison
burden**, and theirs is four orders of magnitude bigger than ours.

They segment ~30 dimensions at singlet, pair and triplet level, which is on the order
of 10**4 to 10**5 segments, times several metrics, evaluated daily. At 3 sigma
(two-sided p ~ 2.7e-3) that is hundreds of false alarms every day. 6 sigma
(p ~ 2e-9) is what it takes to get that back under one.

This dataset has 3 dimensions at singlet and pair level: `expected_false_alarms_per_day`
computes the exact universe, and it is about 200 tests per metric per day. The
Bonferroni-matched threshold for one expected false alarm per day is around 3.5 sigma,
not 6. Holding 6 here would mean a per-test false-positive rate of 2e-9 against 200
tests — a detector that cannot fire on anything short of a catastrophe, which is the
same as no detector.

The number itself is not the point. The point is that sigma should be *derived from the
test count*, and anyone who copies 6 sigma into a small system has silently turned the
detector off. Measured false-positive rates at sigma = 3 are in FINDINGS.md.
"""

from __future__ import annotations

import itertools
from dataclasses import dataclass, field

import numpy as np
import pandas as pd
from scipy import stats
from scipy.cluster import hierarchy
from scipy.spatial.distance import squareform

__all__ = [
    "Windows",
    "minimum_detectable_effect",
    "DIMENSIONS",
    "Metric",
    "METRICS",
    "segment_daily_metrics",
    "expected_false_alarms_per_day",
    "bonferroni_sigma",
    "detect_day",
    "cluster_anomalies",
    "scan_days",
]

#: Segmentation dimensions. `restaurant_index` and `zone` are partially degenerate —
#: within a single simulator day a restaurant sits in exactly one zone — which is left
#: in deliberately: collapsing redundant segments is the clustering step's job, and
#: seeing it happen is the evidence that the clustering works.
DIMENSIONS = ("restaurant_index", "clock_hour", "zone")


@dataclass(frozen=True)
class Windows:
    """Baseline / gap / test day counts, keyed on the *last* day of the test window.

    For a test window ending on day `d`:

        test     = [d - test_days + 1, d]
        gap      = [d - test_days - gap_days + 1, d - test_days]      (never read)
        baseline = [start, d - test_days - gap_days]                  (`baseline_days` long)

    `test_days > 1` is the adaptation this market needs and DoorDash does not. See
    `minimum_detectable_effect`: a one-day test window on a segment with twenty orders
    is sampling-noise-bound, and pooling k days shrinks the noise by sqrt(k) at the
    cost of k days of latency. That trade is the whole design decision.
    """

    baseline_days: int = 21
    gap_days: int = 7
    test_days: int = 1

    @property
    def span(self) -> int:
        return self.baseline_days + self.gap_days + self.test_days

    def test_range(self, test_day: int) -> tuple[int, int]:
        """Inclusive `(first_day, last_day)` of the test window."""
        return test_day - self.test_days + 1, test_day

    def baseline_range(self, test_day: int) -> tuple[int, int]:
        """Inclusive `(first_day, last_day)` of the baseline window."""
        last = test_day - self.test_days - self.gap_days
        return last - self.baseline_days + 1, last


def minimum_detectable_effect(
    per_order_sd: float, orders_per_day: float, sigma: float, test_days: int = 1
) -> float:
    """Smallest shift in a mean metric that clears the Z gate, in metric units.

    `sigma * per_order_sd / sqrt(orders_per_day * test_days)`.

    This is the single most useful number in the whole anomaly module, because it says
    what the detector *cannot* do before anyone runs it. Detection sensitivity on a
    value metric is set by segment volume, not by threshold tuning: at Ravon's
    simulated 20 orders per restaurant per day and a per-order sd of 54 minutes, no
    choice of sigma makes a 10-minute kitchen slowdown visible in a one-day window.
    """
    if orders_per_day <= 0 or test_days <= 0:
        raise ValueError("orders_per_day and test_days must be positive")
    return sigma * per_order_sd / np.sqrt(orders_per_day * test_days)


@dataclass(frozen=True)
class Metric:
    """A per-segment daily quantity plus how to turn a deviation into a real amount.

    `absolute_amount` converts "the rate moved by x" into "and that is y minutes /
    y orders", which is what the absolute gate is allowed to threshold on. Without it
    the absolute gate would be comparing rates, which is the same scale-free mistake
    the Z-score already makes.
    """

    name: str
    #: Column in the daily metrics frame.
    column: str
    #: Column holding the denominator (orders contributing to the metric that day).
    volume_column: str
    #: Human-readable unit of `absolute_amount`.
    unit: str
    #: Minimum absolute amount for the absolute gate to pass.
    absolute_threshold: float
    #: Minimum orders in the test window before a segment is considered at all.
    min_volume: int = 20
    #: True when only an increase is anomalous (slow deliveries, failed orders).
    one_sided: bool = True

    def absolute_amount(self, delta: float, volume: float) -> float:
        return delta * volume


#: The two metrics worth watching in this simulator.
#:
#: `unassigned_rate` stands in for the cancellation rate: an order the dispatcher never
#: matched is the simulator's only failure mode, and it behaves like a cancellation
#: from the customer's side.
METRICS: dict[str, Metric] = {
    "mean_delivery_minutes": Metric(
        name="mean_delivery_minutes",
        column="mean_delivery_minutes",
        volume_column="delivered",
        unit="excess delivery-minutes",
        # 20 orders each 6 minutes late. Below this a segment is wobbling, not broken.
        absolute_threshold=120.0,
        # A restaurant sees ~19 delivered orders a day in this market, so a gate at 20
        # would silently exclude every restaurant singlet — the segments the detector
        # most needs to watch. Set below the smallest segment worth testing, and let
        # `minimum_detectable_effect` rather than the gate express the volume problem.
        min_volume=10,
    ),
    "unassigned_rate": Metric(
        name="unassigned_rate",
        column="unassigned_rate",
        volume_column="orders",
        unit="excess unassigned orders",
        # Five orders that should have been served and were not.
        absolute_threshold=5.0,
    ),
}


def _segment_label(dimensions: tuple[str, ...], values: tuple) -> str:
    return "|".join(f"{d}={v}" for d, v in zip(dimensions, values))


def segment_daily_metrics(
    df: pd.DataFrame, dimensions: tuple[str, ...] = DIMENSIONS, max_level: int = 2
) -> pd.DataFrame:
    """Daily metric values for every segment, at every level up to `max_level`.

    Returns a long frame with one row per `(segment, day)`.
    """
    if max_level < 1:
        raise ValueError("max_level must be at least 1")
    frames = []
    for level in range(1, max_level + 1):
        for combo in itertools.combinations(dimensions, level):
            keys = list(combo) + ["day"]
            grouped = df.groupby(keys, observed=True).agg(
                orders=("total_delivery_minutes", "size"),
                delivered=("total_delivery_minutes", "count"),
                sum_delivery_minutes=("total_delivery_minutes", "sum"),
            )
            grouped = grouped.reset_index()
            grouped["unassigned"] = grouped["orders"] - grouped["delivered"]
            grouped["unassigned_rate"] = grouped["unassigned"] / grouped["orders"]
            # Segments with no delivered order have no mean; NaN is the honest value
            # and is filtered out by the volume gate downstream.
            with np.errstate(invalid="ignore"):
                grouped["mean_delivery_minutes"] = np.where(
                    grouped["delivered"] > 0,
                    grouped["sum_delivery_minutes"] / grouped["delivered"].replace(0, np.nan),
                    np.nan,
                )
            values = list(zip(*[grouped[c] for c in combo]))
            grouped["segment"] = [_segment_label(combo, v) for v in values]
            grouped["level"] = level
            frames.append(
                grouped[
                    [
                        "segment",
                        "level",
                        "day",
                        "orders",
                        "delivered",
                        "unassigned",
                        "unassigned_rate",
                        "sum_delivery_minutes",
                        "mean_delivery_minutes",
                    ]
                ]
            )
    return pd.concat(frames, ignore_index=True)


def expected_false_alarms_per_day(
    metrics: pd.DataFrame, sigma: float, day: int, windows: Windows = Windows()
) -> float:
    """Tests actually run on `day`, times the one-sided Gaussian tail at `sigma`.

    This is the number that should set `sigma`, and computing it is the argument for
    dropping from 6 to 3 — see the module docstring.
    """
    testable = metrics[metrics["day"] == day]["segment"].nunique()
    return float(testable * stats.norm.sf(sigma))


def bonferroni_sigma(n_tests: int, alarms_per_day: float = 1.0) -> float:
    """Sigma at which `n_tests` independent one-sided tests yield `alarms_per_day`."""
    if n_tests <= 0:
        raise ValueError("n_tests must be positive")
    return float(stats.norm.isf(alarms_per_day / n_tests))


def _pool_test_window(
    metrics: pd.DataFrame, first: int, last: int, metric: Metric
) -> pd.DataFrame:
    """Collapse a multi-day test window into one row per segment.

    Metrics are **pooled over orders**, not averaged over days: summing the numerator
    and the denominator is what actually reduces sampling noise, whereas averaging
    daily means would give a thin day the same weight as a busy one.
    """
    window = metrics[(metrics["day"] >= first) & (metrics["day"] <= last)]
    if window.empty:
        return window
    grouped = window.groupby(["segment", "level"], as_index=False).agg(
        orders=("orders", "sum"),
        delivered=("delivered", "sum"),
        unassigned=("unassigned", "sum"),
        days_present=("day", "nunique"),
        sum_delivery_minutes=("sum_delivery_minutes", "sum"),
    )
    grouped["unassigned_rate"] = grouped["unassigned"] / grouped["orders"]
    grouped["mean_delivery_minutes"] = np.where(
        grouped["delivered"] > 0,
        grouped["sum_delivery_minutes"] / grouped["delivered"].replace(0, np.nan),
        np.nan,
    )
    grouped["day"] = last
    return grouped


def detect_day(
    metrics: pd.DataFrame,
    day: int,
    metric: Metric,
    windows: Windows = Windows(),
    sigma: float = 3.0,
    min_baseline_days: int = 10,
    return_all: bool = False,
) -> pd.DataFrame:
    """Run the dual gate over every segment for the test window ending on `day`.

    Returns the segments that passed **both** gates, with the evidence for each.
    With `return_all=True`, returns every *testable* segment instead, carrying a
    `fired` column — which is what lets a validation harness ask "was the signal too
    small, or did the gates throw it away?".
    """
    baseline_first, baseline_last = windows.baseline_range(day)
    test_first, test_last = windows.test_range(day)
    baseline = metrics[
        (metrics["day"] >= baseline_first) & (metrics["day"] <= baseline_last)
    ]
    test = _pool_test_window(metrics, test_first, test_last, metric)
    if test.empty or baseline.empty:
        return _empty_anomaly_frame()

    stats_by_segment = (
        baseline.groupby("segment")[metric.column]
        .agg(baseline_mean="mean", baseline_std=lambda s: s.std(ddof=1), baseline_n="count")
        .reset_index()
    )
    joined = test.merge(stats_by_segment, on="segment", how="inner")
    joined = joined[joined["baseline_n"] >= min_baseline_days]
    # The volume gate applies to the pooled window, so a longer window lets thinner
    # segments in — which is the point of running one.
    joined = joined[joined[metric.volume_column] >= metric.min_volume * windows.test_days]
    joined = joined[joined[metric.column].notna() & joined["baseline_mean"].notna()]
    # A segment whose baseline never moved has no scale to measure against. Rather
    # than divide by zero (infinite Z on any deviation, the classic small-segment
    # false positive) it is dropped.
    joined = joined[joined["baseline_std"] > 1e-9]
    if joined.empty:
        return _empty_anomaly_frame()

    # The baseline std is the std of a *single day's* metric. The test statistic is
    # pooled over `test_days` days, so its standard error is smaller by sqrt(k).
    # Omitting this correction is the standard way a multi-day window ends up
    # under-powered: the effect is averaged down but the yardstick is not.
    standard_error = joined["baseline_std"] / np.sqrt(windows.test_days)

    delta = joined[metric.column] - joined["baseline_mean"]
    joined = joined.assign(
        delta=delta,
        z_score=delta / standard_error,
        rel_amt=delta / joined["baseline_mean"].replace(0, np.nan),
        abs_anom_amt=metric.absolute_amount(delta, joined[metric.volume_column]),
    )
    if metric.one_sided:
        gate_z = joined["z_score"] >= sigma
        gate_abs = joined["abs_anom_amt"] >= metric.absolute_threshold
    else:
        gate_z = joined["z_score"].abs() >= sigma
        gate_abs = joined["abs_anom_amt"].abs() >= metric.absolute_threshold

    joined = joined.assign(fired=gate_z & gate_abs)
    fired = joined if return_all else joined[joined["fired"]].copy()
    if fired.empty:
        return _empty_anomaly_frame()
    fired = fired.copy()

    # DoorDash's ranking. The `level ** 1.2` divisor is what makes a one-dimensional
    # description outrank a two-dimensional one explaining the same excess: given the
    # choice between "restaurant 3 is slow" and "restaurant 3 at 12:00 is slow", the
    # on-call engineer wants the first at the top of the page.
    fired["score"] = (
        fired["abs_anom_amt"].abs() * fired["rel_amt"].abs() / fired["level"] ** 1.2
    )
    fired["metric"] = metric.name
    fired["test_day"] = day
    fired["test_first_day"] = test_first
    fired["baseline_first_day"] = baseline_first
    fired["baseline_last_day"] = baseline_last
    return fired.sort_values("score", ascending=False).reset_index(drop=True)


def _empty_anomaly_frame() -> pd.DataFrame:
    return pd.DataFrame(
        columns=[
            "segment", "level", "day", "orders", "delivered", "unassigned",
            "unassigned_rate", "sum_delivery_minutes", "mean_delivery_minutes",
            "days_present", "baseline_mean",
            "baseline_std", "baseline_n", "delta", "z_score", "rel_amt",
            "abs_anom_amt", "score", "fired", "metric", "test_day", "test_first_day",
            "baseline_first_day", "baseline_last_day",
        ]
    )


def _segment_masks(df_day: pd.DataFrame, segments) -> dict[str, np.ndarray]:
    """Boolean mask over the test day's orders for each segment label."""
    masks = {}
    for segment in segments:
        mask = np.ones(len(df_day), dtype=bool)
        for clause in segment.split("|"):
            dimension, value = clause.split("=", 1)
            column = df_day[dimension]
            mask &= column.astype(str).to_numpy() == value
        masks[segment] = mask
    return masks


@dataclass
class AnomalyCluster:
    """A group of segments that describe the same underlying incident."""

    cluster_id: int
    representative: str
    level: int
    score: float
    members: list[str] = field(default_factory=list)
    total_abs_amount: float = 0.0
    max_z: float = 0.0

    def as_dict(self) -> dict:
        return {
            "cluster_id": self.cluster_id,
            "representative": self.representative,
            "level": self.level,
            "score": self.score,
            "members": self.members,
            "total_abs_amount": self.total_abs_amount,
            "max_z": self.max_z,
        }


def cluster_anomalies(
    orders_on_day: pd.DataFrame,
    anomalies: pd.DataFrame,
    overlap_threshold: float = 0.5,
) -> list[AnomalyCluster]:
    """Collapse overlapping anomalous segments into one incident each.

    Distance is Jaccard on the *sets of orders each segment selects on the test day*,
    not on the segment labels — two labels that happen to pick the same orders are the
    same finding regardless of how they are spelled. Agglomerative average linkage,
    cut at `overlap_threshold`.

    The representative of a cluster is its highest-scoring member, and since the score
    divides by `level ** 1.2`, that is biased towards the simplest description.
    """
    if anomalies.empty:
        return []
    segments = list(anomalies["segment"])
    if len(segments) == 1:
        row = anomalies.iloc[0]
        return [
            AnomalyCluster(
                cluster_id=0,
                representative=row["segment"],
                level=int(row["level"]),
                score=float(row["score"]),
                members=[row["segment"]],
                total_abs_amount=float(row["abs_anom_amt"]),
                max_z=float(row["z_score"]),
            )
        ]

    masks = _segment_masks(orders_on_day, segments)
    n = len(segments)
    distance = np.zeros((n, n))
    for i in range(n):
        for j in range(i + 1, n):
            a, b = masks[segments[i]], masks[segments[j]]
            union = np.logical_or(a, b).sum()
            jaccard = (np.logical_and(a, b).sum() / union) if union else 0.0
            distance[i, j] = distance[j, i] = 1.0 - jaccard

    linkage = hierarchy.linkage(squareform(distance, checks=False), method="average")
    labels = hierarchy.fcluster(linkage, t=overlap_threshold, criterion="distance")

    clusters = []
    for cluster_id in np.unique(labels):
        members = anomalies[labels == cluster_id].sort_values("score", ascending=False)
        top = members.iloc[0]
        clusters.append(
            AnomalyCluster(
                cluster_id=int(cluster_id),
                representative=top["segment"],
                level=int(top["level"]),
                score=float(top["score"]),
                members=list(members["segment"]),
                total_abs_amount=float(members["abs_anom_amt"].sum()),
                max_z=float(members["z_score"].max()),
            )
        )
    return sorted(clusters, key=lambda c: c.score, reverse=True)


def scan_days(
    metrics: pd.DataFrame,
    metric: Metric,
    days=None,
    windows: Windows = Windows(),
    sigma: float = 3.0,
) -> pd.DataFrame:
    """Run `detect_day` across every day with a complete baseline window."""
    all_days = np.sort(metrics["day"].unique())
    if days is None:
        days = [d for d in all_days if windows.baseline_range(d)[0] >= all_days.min()]
    results = [detect_day(metrics, int(d), metric, windows, sigma) for d in days]
    results = [r for r in results if not r.empty]
    if not results:
        return _empty_anomaly_frame()
    return pd.concat(results, ignore_index=True)
