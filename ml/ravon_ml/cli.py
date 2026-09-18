"""One command that regenerates every number and every figure in FINDINGS.md.

    python -m ravon_ml.cli            # full run, writes reports/
    python -m ravon_ml.cli --quick    # skip the slow anomaly sweeps

Nothing here samples without a seed, so two runs on the same dataset produce
byte-identical `reports/metrics.json`. That is the repo standard and it is the only
reason any of these numbers are worth quoting.
"""

from __future__ import annotations

import argparse
import json
import time
from pathlib import Path

import numpy as np
import pandas as pd

from . import anomaly as A
from . import injection as I
from . import plots
from .data import (
    FEATURES_AT_ASSIGNMENT,
    FEATURES_AT_CREATION,
    load_meta,
    load_orders,
    restaurant_identity_is_unstable,
)
from .decision import (
    RAVON_COST,
    AsymmetricCost,
    evaluate_quote_policy,
    quote_cost,
    sweep_quantiles,
)
from .eta import (
    ConditionalWeibullETA,
    PointForecast,
    UnconditionalWeibullETA,
    empirical_crps_floor,
    evaluate,
)
from .weibull import fit_interval_regression, fit_mle, survival_bins

REPORTS_DIR = Path(__file__).resolve().parent.parent / "reports"
SEED = 20260916
#: Per-order sd of delivery time, used by the analytic minimum-detectable-effect.
#: Recomputed from the data at run time rather than hard-coded.


def _recovery_check(seed: int = SEED) -> tuple[list[dict], tuple]:
    """Generate from known Weibulls and confirm the fitting procedure recovers them.

    This is the strongest validation available in the whole project and it is
    available only because the data is synthetic: the true parameters exist. DoorDash
    publishes the same check (true k = 3.37 recovered as 3.22); ours is run across a
    grid of shapes rather than a single case.
    """
    rng = np.random.default_rng(seed)
    rows = []
    example = None
    for shape, scale, location in [
        (1.20, 30.0, 0.0),
        (1.80, 45.0, 8.0),
        (2.50, 38.0, 15.0),
        (3.37, 40.0, 12.0),   # DoorDash's published case
        (4.20, 55.0, 20.0),
        (6.00, 70.0, 10.0),
    ]:
        samples = location + scale * rng.weibull(shape, 20_000)
        fit = fit_interval_regression(samples, bin_width=6.0)
        mle = fit_mle(samples)
        rows.append(
            {
                "true_shape": shape,
                "true_scale": scale,
                "true_location": location,
                "fitted_shape": fit.shape,
                "fitted_scale": fit.scale,
                "fitted_location": fit.location,
                "mle_shape": mle.shape,
                "mle_scale": mle.scale,
                "mle_location": mle.location,
                "shape_error_pct": 100 * (fit.shape - shape) / shape,
                "r_squared": fit.r_squared,
                "n_bins": fit.n_bins_used,
            }
        )
        if abs(shape - 3.37) < 1e-9:
            edges, survival, counts = survival_bins(samples, 6.0)
            usable = (edges > fit.location) & (survival > 0) & (survival < 1)
            x = np.log(edges[usable] - fit.location)
            y = np.log(-np.log(survival[usable]))
            fitted_line = fit.shape * (x - np.log(fit.scale))
            example = (x, y, fitted_line)
    return rows, example


def run(quick: bool = False) -> dict:
    started = time.time()
    REPORTS_DIR.mkdir(parents=True, exist_ok=True)
    meta = load_meta()
    df = load_orders()
    train, test = _split(df)
    report: dict = {
        "seed": SEED,
        "dataset": {
            "rows": int(len(df)),
            "days": int(df["day"].nunique()),
            "delivered_rows": int(df["delivered"].sum()),
            "unassigned_rate": float(1 - df["delivered"].mean()),
            "orders_per_day": int(round(len(df) / df["day"].nunique())),
            "restaurants": int(df["restaurant_index"].nunique()),
            "zones": int(df["zone"].nunique()),
            "service_hours": sorted(int(h) for h in df["clock_hour"].unique()),
            "simulator_config": meta,
        },
    }

    stability = restaurant_identity_is_unstable(df)
    report["restaurant_identity"] = {
        "zones_per_restaurant": stability.zones_per_restaurant,
        "between_restaurant_share_of_variance": stability.between_day_share_of_variance,
        "unstable": bool(stability.unstable),
        "note": (
            "MarketplaceSimulator redraws restaurant locations and latent prep bias "
            "every run, so restaurant_index is a per-day label, not a stable entity."
        ),
    }

    report["weibull_recovery"], transform_example = _recovery_check()
    report["eta"] = _eta_section(train, test, report)
    report["decision"] = _decision_section(train, test)
    report["anomaly"] = _anomaly_section(df, quick=quick)

    report["figures"] = _figures(train, test, report, transform_example)

    # Runtime is printed, not written: the committed artefact has to be byte-identical
    # across runs, and a timing is the one thing in here that cannot be.
    out = REPORTS_DIR / "metrics.json"
    out.write_text(json.dumps(report, indent=2, sort_keys=True, default=_json_default))
    print(f"wrote {out} in {time.time() - started:.1f}s")
    return report


def _json_default(value):
    if isinstance(value, (np.integer,)):
        return int(value)
    if isinstance(value, (np.floating,)):
        return float(value)
    if isinstance(value, (np.bool_,)):
        return bool(value)
    raise TypeError(f"not JSON serialisable: {type(value)}")


def _relative(path: Path) -> str:
    """Paths in the committed report must not name anyone's home directory."""
    return str(path.relative_to(REPORTS_DIR.parent))


def _split(df: pd.DataFrame):
    from .data import split_by_day

    return split_by_day(df, train_fraction=0.7)


def _models(train: pd.DataFrame):
    delivered = train[train["total_delivery_minutes"].notna()]
    offset = float(
        (delivered["total_delivery_minutes"] - delivered["naive_eta_minutes"]).mean()
    )
    return {
        "naive-formula": PointForecast(
            "naive-formula (quoted prep + travel)", lambda d: d["naive_eta_minutes"]
        ),
        "naive-debiased": PointForecast(
            f"naive-debiased (+{offset:.1f} min)",
            lambda d: d["naive_eta_minutes"],
            offset=offset,
        ),
        "unconditional-weibull": UnconditionalWeibullETA().fit(train),
        "conditional-weibull-creation": ConditionalWeibullETA(
            features=FEATURES_AT_CREATION
        ).fit(train),
        "conditional-weibull-assignment": ConditionalWeibullETA(
            features=FEATURES_AT_ASSIGNMENT
        ).fit(train),
    }


def _eta_section(train: pd.DataFrame, test: pd.DataFrame, report: dict) -> dict:
    models = _models(train)
    rows = {key: evaluate(model, test).as_dict() for key, model in models.items()}
    creation = models["conditional-weibull-creation"]
    return {
        "train_days": int(train["day"].nunique()),
        "test_days": int(test["day"].nunique()),
        "features_at_creation": list(FEATURES_AT_CREATION),
        "features_at_assignment": list(FEATURES_AT_ASSIGNMENT),
        "models": rows,
        "empirical_crps_floor": empirical_crps_floor(train, test, seed=SEED),
        "crps_reduction_vs_naive_pct": 100
        * (
            1
            - rows["conditional-weibull-creation"]["crps_minutes"]
            / rows["naive-formula"]["crps_minutes"]
        ),
        "cell_table": creation.cell_table_.to_dict(orient="records"),
        "score_coefficients": dict(
            zip(("intercept",) + FEATURES_AT_CREATION, creation.coefficients_.tolist())
        ),
    }


def _decision_section(train: pd.DataFrame, test: pd.DataFrame) -> dict:
    model = ConditionalWeibullETA(features=FEATURES_AT_CREATION).fit(train)
    delivered = test[test["total_delivery_minutes"].notna()]
    y = delivered["total_delivery_minutes"].to_numpy()
    params = model.predict_params(delivered)

    def quantile_fn(level):
        return np.array([p.quantile(level) for p in params])

    sweeps = []
    for ratio in (2.0, 3.0, 4.0, 5.0, 7.0, 9.0):
        cost = AsymmetricCost(late=ratio, early=1.0)
        levels, costs = sweep_quantiles(quantile_fn, y, cost)
        sweeps.append(
            {
                "ratio": ratio,
                "derived": cost.quantile,
                "levels": levels.tolist(),
                "costs": costs.tolist(),
                "empirical_argmin": float(levels[int(np.argmin(costs))]),
                "cost_at_derived": quote_cost(quantile_fn(cost.quantile), y, cost),
                "cost_at_argmin": float(np.min(costs)),
            }
        )

    policies = [
        evaluate_quote_policy(
            "mean of the predictive distribution (unbiased)",
            np.array([p.mean() for p in params]), y, RAVON_COST, 0.5,
        ).as_dict(),
        evaluate_quote_policy(
            "median (p50)", quantile_fn(0.5), y, RAVON_COST, 0.5
        ).as_dict(),
        evaluate_quote_policy(
            f"derived quantile (p{RAVON_COST.quantile * 100:.0f})",
            quantile_fn(RAVON_COST.quantile), y, RAVON_COST, RAVON_COST.quantile,
        ).as_dict(),
        evaluate_quote_policy(
            "p90 (over-cautious)", quantile_fn(0.90), y, RAVON_COST, 0.90
        ).as_dict(),
    ]
    return {
        "cost_constants": {
            "late": RAVON_COST.late,
            "early": RAVON_COST.early,
            "ratio": RAVON_COST.ratio,
            "derived_quantile": RAVON_COST.quantile,
            "rationale": RAVON_COST.rationale,
        },
        "sweeps": [{k: v for k, v in s.items() if k not in ("levels", "costs")}
                   for s in sweeps],
        "_sweeps_full": sweeps,
        "policies": policies,
    }


def _anomaly_section(df: pd.DataFrame, quick: bool) -> dict:
    metrics = A.segment_daily_metrics(df)
    day = int(np.sort(df["day"].unique())[len(df["day"].unique()) // 2])
    tests_per_day = int(metrics[metrics["day"] == day]["segment"].nunique())
    per_order_sd = float(df["total_delivery_minutes"].std(ddof=1))

    section: dict = {
        "dimensions": list(A.DIMENSIONS),
        "segments": {
            "total": int(metrics["segment"].nunique()),
            "by_level": metrics.groupby("level")["segment"].nunique().to_dict(),
            "testable_on_a_typical_day": tests_per_day,
        },
        "sigma": {
            "chosen": 3.0,
            "doordash": 6.0,
            "tests_per_day": tests_per_day,
            "bonferroni_sigma_for_one_alarm_per_day": A.bonferroni_sigma(tests_per_day),
            "expected_false_alarms_per_day": {
                str(s): A.expected_false_alarms_per_day(metrics, s, day)
                for s in (3.0, 3.5, 4.0, 6.0)
            },
        },
        "per_order_sd_minutes": per_order_sd,
        "minimum_detectable_effect": _mde_table(metrics, per_order_sd),
        "false_positive_rate": [
            I.false_positive_rate(df, metric, A.Windows(), 3.0)
            for metric in A.METRICS.values()
        ],
        "dual_gate": _dual_gate_table(df, metrics),
    }
    if quick:
        return section

    test_days = [40, 55, 70, 85, 100, 115, 130, 145, 160, 175]
    section["injection_slow_restaurant"] = []
    for k in (1, 3, 7):
        windows = A.Windows(test_days=k)
        sweep = I.magnitude_sweep(
            df,
            lambda frame, day, magnitude, k=k: I.inject_slow_restaurant(
                frame, 3, list(range(day - k + 1, day + 1)), magnitude
            ),
            magnitudes=[8, 12, 16, 20, 25, 30],
            test_days=test_days,
            windows=windows,
        )
        grouped = sweep.groupby("magnitude").agg(
            detection_rate=("detected", "mean"),
            top_is_correct=("top_is_correct", "mean"),
            mean_truth_z=("truth_z", "mean"),
        )
        section["injection_slow_restaurant"].append(
            {"test_days": k, "rows": grouped.reset_index().to_dict(orient="records")}
        )

    section["injection_cancellation_spike"] = []
    for k in (1, 3):
        windows = A.Windows(test_days=k)
        sweep = I.magnitude_sweep(
            df,
            lambda frame, day, magnitude, k=k: I.inject_cancellation_spike(
                frame, "z0-1", list(range(day - k + 1, day + 1)), magnitude, seed=day
            ),
            magnitudes=[0.03, 0.05, 0.08, 0.10, 0.15, 0.20],
            test_days=test_days,
            windows=windows,
        )
        grouped = sweep.groupby("magnitude").agg(
            detection_rate=("detected", "mean"),
            top_is_correct=("top_is_correct", "mean"),
            mean_truth_z=("truth_z", "mean"),
        )
        section["injection_cancellation_spike"].append(
            {"test_days": k, "rows": grouped.reset_index().to_dict(orient="records")}
        )

    section["gap_window"] = _gap_window(df)
    return section


def _mde_table(metrics: pd.DataFrame, per_order_sd: float) -> list[dict]:
    rows = []
    singlets = metrics[metrics["level"] == 1].copy()
    singlets["dimension"] = singlets["segment"].str.split("=").str[0]
    for dimension, group in singlets.groupby("dimension"):
        orders_per_day = float(group["orders"].mean())
        rows.append(
            {
                "label": dimension,
                "orders_per_day": orders_per_day,
                "test_days": [1, 3, 7, 14],
                "mde": [
                    A.minimum_detectable_effect(per_order_sd, orders_per_day, 3.0, k)
                    for k in (1, 3, 7, 14)
                ],
            }
        )
    return rows


def _dual_gate_table(df: pd.DataFrame, metrics: pd.DataFrame) -> list[dict]:
    """How many firings the absolute gate removes, per metric and per volume gate.

    The claim under test is "the dual gate is what kills false positives". It is only
    half true here, and the half that is false is worth reporting: see FINDINGS.md.
    """
    import dataclasses

    windows = A.Windows()
    all_days = np.sort(df["day"].unique())
    days = [int(d) for d in all_days if windows.baseline_range(int(d))[0] >= all_days.min()]

    rows = []
    for metric in A.METRICS.values():
        for min_volume in (metric.min_volume, 3):
            scoped = dataclasses.replace(metric, min_volume=min_volume)
            z_only = dataclasses.replace(scoped, absolute_threshold=-np.inf)
            n_z = sum(len(A.detect_day(metrics, d, z_only, windows, 3.0)) for d in days)
            n_dual = sum(len(A.detect_day(metrics, d, scoped, windows, 3.0)) for d in days)
            rows.append(
                {
                    "metric": metric.name,
                    "min_volume": min_volume,
                    "absolute_threshold": metric.absolute_threshold,
                    "z_gate_only_per_day": n_z / len(days),
                    "dual_gate_per_day": n_dual / len(days),
                    "removed_by_absolute_gate_pct": (
                        100 * (1 - n_dual / n_z) if n_z else 0.0
                    ),
                }
            )
    return rows


def _gap_window(df: pd.DataFrame) -> dict:
    schedule = [0.006 * (i + 1) for i in range(20)]
    injector = lambda frame, day, magnitude: I.inject_cancellation_spike(  # noqa: E731
        frame, "z0-1", [day], magnitude, seed=day
    )
    histories = {}
    for label, windows in (
        ("21-day baseline, 7-day gap", A.Windows(21, 7, 3)),
        ("28-day baseline, no gap", A.Windows(28, 0, 3)),
    ):
        result = I.detection_latency(df, injector, 50, 20, schedule, windows, 3.0)
        histories[label] = result["history"].assign(latency_days=result["latency_days"])

    late = {
        label: float(frame[frame["days_elapsed"] >= 12]["truth_z"].mean())
        for label, frame in histories.items()
    }
    return {
        "ramp": "zone z0-1 cancellation rate ramps 0.6% -> 12% over 20 days",
        "first_detection_day": {
            label: (None if pd.isna(frame["latency_days"].iloc[0])
                    else int(frame["latency_days"].iloc[0]))
            for label, frame in histories.items()
        },
        "mean_truth_z_after_12_days": late,
        "detections_after_12_days": {
            label: int(frame[frame["days_elapsed"] >= 12]["detected"].sum())
            for label, frame in histories.items()
        },
        "history": {label: frame.to_dict(orient="records")
                    for label, frame in histories.items()},
        "_frames": histories,
    }


def _figures(train, test, report: dict, transform_example) -> dict:
    models = _models(train)
    delivered = test[test["total_delivery_minutes"].notna()]
    y = delivered["total_delivery_minutes"].to_numpy()
    distributions = [
        ("unconditional Weibull", models["unconditional-weibull"].predict_params(delivered)),
        ("conditional, creation-time", models["conditional-weibull-creation"].predict_params(delivered)),
        ("conditional, assignment-time", models["conditional-weibull-assignment"].predict_params(delivered)),
    ]

    figures = {
        "pit_histogram": _relative(plots.pit_histogram(distributions, y)),
        "calibration": _relative(plots.calibration_plot(distributions, y)),
        "weibull_recovery": _relative(
            plots.recovery_plot(report["weibull_recovery"], transform_example)
        ),
        "quantile_cost": _relative(
            plots.quantile_cost_plot(
                [
                    {"ratio": s["ratio"], "derived": s["derived"],
                     "levels": np.array(s["levels"]), "costs": np.array(s["costs"])}
                    for s in report["decision"]["_sweeps_full"]
                ]
            )
        ),
    }

    anomaly = report["anomaly"]
    if "injection_slow_restaurant" in anomaly:
        sweeps = [
            {
                "test_days": block["test_days"],
                "magnitudes": [r["magnitude"] for r in block["rows"]],
                "detection_rate": [r["detection_rate"] for r in block["rows"]],
            }
            for block in anomaly["injection_slow_restaurant"]
        ]
        figures["anomaly_detection"] = _relative(
            plots.anomaly_plot(sweeps, anomaly["gap_window"]["_frames"],
                               anomaly["minimum_detectable_effect"])
        )
        del anomaly["gap_window"]["_frames"]
    del report["decision"]["_sweeps_full"]
    return figures


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--quick", action="store_true",
                        help="skip the injection sweeps (about 60s of the run)")
    args = parser.parse_args(argv)
    run(quick=args.quick)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
