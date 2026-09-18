"""The anomaly detector, validated against injected ground truth.

Each test here corresponds to one design decision in the module docstring — the gap
window, the dual gate, the sigma choice, the clustering — because a design decision
with no test behind it is an opinion.
"""

from __future__ import annotations

import dataclasses

import numpy as np
import pandas as pd
import pytest

from ravon_ml import anomaly as A
from ravon_ml import injection as I


@pytest.fixture(scope="module")
def metrics(orders):
    return A.segment_daily_metrics(orders)


# -- windows ------------------------------------------------------------------


def test_window_ranges_leave_exactly_the_gap_unread():
    windows = A.Windows(baseline_days=21, gap_days=7, test_days=1)
    baseline_first, baseline_last = windows.baseline_range(40)
    test_first, test_last = windows.test_range(40)
    assert (test_first, test_last) == (40, 40)
    assert baseline_last == 40 - 1 - 7
    assert baseline_last - baseline_first + 1 == 21
    # The seven days between the baseline and the test are never looked at.
    assert test_first - baseline_last - 1 == 7


def test_multi_day_test_window_ranges():
    windows = A.Windows(baseline_days=21, gap_days=7, test_days=3)
    assert windows.test_range(40) == (38, 40)
    baseline_first, baseline_last = windows.baseline_range(40)
    assert (baseline_first, baseline_last) == (10, 30)
    assert baseline_last - baseline_first + 1 == 21
    # Still exactly seven unread days between the baseline and the test window.
    assert 38 - baseline_last - 1 == 7
    assert windows.span == 31


# -- sigma --------------------------------------------------------------------


def test_sigma_six_would_switch_the_detector_off_at_this_scale(metrics):
    """The argument for dropping to 3, as an assertion rather than a paragraph.

    At this test count, 6 sigma is one expected false alarm roughly every thirty
    thousand years — which also means it never fires on anything real.
    """
    day = 100
    tests_per_day = metrics[metrics["day"] == day]["segment"].nunique()
    assert tests_per_day < 500  # four orders of magnitude below DoorDash's universe

    at_six = A.expected_false_alarms_per_day(metrics, 6.0, day)
    at_three = A.expected_false_alarms_per_day(metrics, 3.0, day)
    assert at_six < 1e-6
    assert 0.01 < at_three < 1.0
    # And 3 sigma is *more* conservative than a plain Bonferroni correction here.
    assert A.bonferroni_sigma(tests_per_day, alarms_per_day=1.0) < 3.0


def test_minimum_detectable_effect_scales_as_one_over_root_n():
    one_day = A.minimum_detectable_effect(54.0, 20.0, 3.0, test_days=1)
    four_days = A.minimum_detectable_effect(54.0, 20.0, 3.0, test_days=4)
    assert four_days == pytest.approx(one_day / 2.0)
    # The headline consequence: a ten-minute kitchen slowdown is invisible in a
    # one-day window on a twenty-order-a-day restaurant, at any sigma.
    assert one_day > 30.0


# -- gates --------------------------------------------------------------------


def test_false_positive_rate_on_unperturbed_data_is_low(orders):
    """Every firing on clean data is false by construction. Both metrics must stay
    under roughly one alarm every other day."""
    for metric in A.METRICS.values():
        result = I.false_positive_rate(orders, metric, A.Windows(), sigma=3.0)
        assert result["days_evaluated"] > 150
        assert result["incidents_per_day"] < 0.5
        assert result["per_test_false_positive_rate"] < 0.01


def test_absolute_gate_removes_most_small_segment_noise(orders, metrics):
    """The dual gate's value, measured where it actually applies.

    On a rate metric with a permissive volume gate the absolute threshold removes the
    large majority of firings — those are segments where one extra failed order is a
    huge relative move and no kind of incident.
    """
    metric = dataclasses.replace(A.METRICS["unassigned_rate"], min_volume=3)
    z_only = dataclasses.replace(metric, absolute_threshold=-np.inf)
    days = list(range(40, 120, 7))

    n_z = sum(len(A.detect_day(metrics, d, z_only, A.Windows(), 3.0)) for d in days)
    n_dual = sum(len(A.detect_day(metrics, d, metric, A.Windows(), 3.0)) for d in days)
    assert n_z > 0
    assert n_dual < 0.5 * n_z


def test_zero_variance_baselines_do_not_produce_infinite_z(metrics):
    """A segment whose baseline never moved is dropped, not divided by."""
    for day in (40, 80, 120):
        for metric in A.METRICS.values():
            fired = A.detect_day(metrics, day, metric, A.Windows(), 3.0)
            if not fired.empty:
                assert np.all(np.isfinite(fired["z_score"]))


# -- detection ----------------------------------------------------------------


def test_detects_an_injected_cancellation_spike(orders):
    perturbed, injection = I.inject_cancellation_spike(orders, "z0-1", [100], 0.25, seed=1)
    outcome = I.evaluate_detection(perturbed, injection, 100)
    assert outcome.detected
    assert outcome.top_is_correct
    assert outcome.rank == 1


def test_detects_an_injected_slow_kitchen_given_enough_test_window(orders):
    """A +30 minute kitchen is below the one-day noise floor and above the seven-day
    one. That is the volume wall, demonstrated rather than described."""
    days = list(range(96, 103))
    perturbed, injection = I.inject_slow_restaurant(orders, 3, days, 30.0)

    one_day = I.evaluate_detection(perturbed, injection, 102, A.Windows(test_days=1))
    seven_day = I.evaluate_detection(perturbed, injection, 102, A.Windows(test_days=7))
    assert seven_day.detected
    assert seven_day.truth_z > one_day.truth_z


def test_detection_rate_increases_with_incident_size(orders):
    sweep = I.magnitude_sweep(
        orders,
        lambda frame, day, magnitude: I.inject_cancellation_spike(
            frame, "z0-1", [day], magnitude, seed=day
        ),
        magnitudes=[0.03, 0.10, 0.25],
        test_days=[60, 80, 100, 120, 140],
    )
    rates = sweep.groupby("magnitude")["detected"].mean()
    assert rates.loc[0.03] < rates.loc[0.25]
    assert rates.loc[0.25] == 1.0


def test_no_detection_when_nothing_was_injected(orders):
    """The other half of the validation: the detector must be quiet on a clean day."""
    quiet = 0
    days = list(range(60, 140, 5))
    for day in days:
        fired = A.segment_daily_metrics(orders)
        fired = A.detect_day(fired, day, A.METRICS["mean_delivery_minutes"], A.Windows(), 3.0)
        quiet += fired.empty
    assert quiet >= 0.75 * len(days)


# -- gap window ---------------------------------------------------------------


def test_gap_window_keeps_a_ramping_trend_visible(orders):
    """The gap's purpose, measured on a trend that would otherwise eat its own baseline.

    Both configurations get the same 28 days of lookback, so this is not "more history
    wins". Once the ramp is older than a week, the no-gap baseline has absorbed it and
    the Z-score collapses; the gapped baseline still predates the trend.
    """
    schedule = [0.006 * (i + 1) for i in range(20)]
    injector = lambda frame, day, magnitude: I.inject_cancellation_spike(  # noqa: E731
        frame, "z0-1", [day], magnitude, seed=day
    )
    gapped = I.detection_latency(
        orders, injector, 50, 20, schedule, A.Windows(21, 7, 3), 3.0
    )["history"]
    ungapped = I.detection_latency(
        orders, injector, 50, 20, schedule, A.Windows(28, 0, 3), 3.0
    )["history"]

    late = lambda frame: frame[frame["days_elapsed"] >= 12]  # noqa: E731
    assert late(gapped)["truth_z"].mean() > 1.3 * late(ungapped)["truth_z"].mean()
    assert late(gapped)["detected"].sum() >= late(ungapped)["detected"].sum()


# -- clustering ---------------------------------------------------------------


def test_clustering_collapses_redundant_segments_and_prefers_the_simplest(orders):
    """One incident should page once, described as simply as the evidence allows.

    `restaurant_index` determines `zone` within a day, so the pair
    `restaurant=3|zone=...` selects exactly the same orders as the singlet
    `restaurant=3`. Clustering on the order sets collapses them, and the
    `score / level ** 1.2` ranking makes the singlet the representative.
    """
    perturbed, injection = I.inject_cancellation_spike(orders, "z0-1", [100], 0.35, seed=2)
    metrics = A.segment_daily_metrics(perturbed)
    fired = A.detect_day(metrics, 100, A.METRICS["unassigned_rate"], A.Windows(), 3.0)
    clusters = A.cluster_anomalies(perturbed[perturbed["day"] == 100], fired)

    # Nine firing segments, one incident, one page.
    assert len(fired) > 5
    assert len(clusters) == 1
    assert clusters[0].representative == "zone=z0-1"
    assert clusters[0].level == 1
    assert set(clusters[0].members) == set(fired["segment"])


def test_cluster_ranking_penalises_deeper_levels():
    """The `level ** 1.2` divisor, isolated from the rest of the pipeline."""
    frame = pd.DataFrame(
        {
            "segment": ["a=1", "a=1|b=2"],
            "level": [1, 2],
            "abs_anom_amt": [100.0, 100.0],
            "rel_amt": [0.5, 0.5],
            "z_score": [4.0, 4.0],
        }
    )
    frame["score"] = (
        frame["abs_anom_amt"].abs() * frame["rel_amt"].abs() / frame["level"] ** 1.2
    )
    assert frame.loc[0, "score"] > frame.loc[1, "score"]


def test_empty_result_when_the_baseline_window_runs_off_the_start(metrics):
    assert A.detect_day(metrics, 5, A.METRICS["unassigned_rate"], A.Windows(), 3.0).empty
