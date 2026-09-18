# ravon-ml — probabilistic ETA and anomaly detection

Two production-shaped ML systems for the Ravon marketplace, modelled on DoorDash's
published designs and measured against RavonCore's discrete-event simulator.

1. **Probabilistic ETA.** Predicts a three-parameter Weibull over delivery duration,
   fitted by interval regression, scored with CRPS and PIT, and turned into a customer
   quote by a separate decision layer with an explicit asymmetric cost.
2. **Anomaly detection.** A 21-day-baseline / 7-day-gap / 1-day-test scan over segment
   metrics with a dual Z-score + absolute gate, hierarchical clustering of the segments
   that fire, and validation by injecting anomalies whose ground truth is known.

> **Everything here is measured against a simulator, not against real deliveries.**
> Ravon has not launched. There are no real couriers, no real kitchens and no real
> customers in any number on this page. The numbers say the methods are implemented
> correctly and behave as the theory predicts on a world whose generating process is
> known; they say nothing about accuracy in Dushanbe. Where a result depends on a
> quirk of the simulator rather than on the method, [FINDINGS.md](FINDINGS.md) says so.

## Quickstart

```bash
cd ml
uv venv --python 3.12 .venv && uv pip install --python .venv/bin/python -e ".[dev]"

.venv/bin/python -m pytest -q          # 79 tests, ~30s
.venv/bin/python -m ravon_ml.cli       # regenerates reports/, ~40s
```

Or `make setup && make test && make report`.

No Swift toolchain is required. The dataset is committed.

## Headline results

Held out by whole simulator day: 140 training days, 60 test days, 46,329 delivered
orders. CRPS and MAE are in minutes; lower is better. A point forecast's CRPS is its
MAE, which is what makes the two model families comparable on one axis.

| model | bias | sd | MAE | CRPS | PIT |
|---|---:|---:|---:|---:|---|
| naive formula (`quoted_prep + travel`) | **+36.70** | 50.59 | 37.18 | 37.18 | — |
| naive, debiased by the training mean | −0.28 | 50.59 | 36.61 | 36.61 | — |
| unconditional Weibull (no features) | +3.06 | 54.27 | 38.26 | 26.70 | KS 0.152 |
| **conditional Weibull, creation-time** | **−1.01** | **42.53** | **23.55** | **16.42** | KS 0.070 |
| conditional Weibull, assignment-time | +0.38 | 11.67 | 8.21 | 5.95 | KS 0.060 |

* The naive baseline reproduces the number on record — **+36.6 min bias, 50.5 min sd**
  under realistic latent settings, and still **+23.4 min** with the latent state
  switched off, because delivery time is dominated by wait-for-assignment.
* The creation-time model cuts CRPS by **55.8%** against naive and **55.1%** against a
  debiased naive with the same information. It also beats the non-parametric floor
  (the training set's empirical distribution, CRPS 26.07), so the conditioning is
  doing real work rather than the Weibull family flattering itself.
* Coverage at the quoted p80 is **80.4%** against a nominal 80%.

Parameter recovery on data generated from known Weibulls, including DoorDash's
published case:

| true `k` | recovered | error |
|---:|---:|---:|
| 1.20 | 1.197 | −0.27% |
| 2.50 | 2.493 | −0.30% |
| **3.37** | **3.343** | **−0.79%** (DoorDash report 3.22, −4.5%) |
| 6.00 | 6.241 | +4.02% |

Anomaly detection, validated by injection over 172 evaluable test days:

| | |
|---|---|
| False alarms on unperturbed data | 0.20–0.23 clustered incidents/day (per-test rate 0.0027–0.0045) |
| Absolute gate's contribution | removes **85%** of firings on a rate metric with small segments, **0%** on a high-volume value metric |
| Cancellation spike, 3-day window | 100% detected at +20%, 80% at +10%, 30% at +3% |
| Kitchen slowdown, 7-day window | 90% detected at +30 min, 70% at +20 min |
| Kitchen slowdown, 1-day window | 20% detected at +30 min — **the volume wall**, see FINDINGS |

## Layout

```
ml/
  export/main.swift      one-shot dataset exporter (the only Swift here)
  export/export.sh       ./ml/export/export.sh  -> data/orders.csv.gz + data/meta.json
  data/                  committed dataset and simulator metadata
  ravon_ml/
    data.py              loading, derived features, and the latent/outcome leak guard
    weibull.py           3-parameter Weibull + interval-regression fit
    metrics.py           CRPS (closed form), PIT, coverage, interval score
    eta.py               the base layer: features -> a calibrated distribution
    decision.py          the decision layer: distribution -> the quoted number
    anomaly.py           windows, dual gate, segmentation, clustering
    injection.py         known-ground-truth perturbations and the validation harness
    plots.py             the committed figures
    cli.py               one command that regenerates every number in FINDINGS.md
  reports/               metrics.json + four figures, all committed
  tests/                 79 tests; every docstring claim has one behind it
```

## The dataset

`data/orders.csv.gz` — 48,000 orders across 200 simulated service days, exported once
from `Sources/RavonCore/Dispatch/MarketplaceSimulator.swift` with
`LatentVariability.realistic`.

The export config is pinned to **240 orders / 180 minutes / 24 couriers, dispatched by
`OptimalBatchDispatcher`**, because that is the configuration that produced the
published naive-ETA baseline. Changing any of the three moves the congestion regime:
the simulator drains its backlog during a 90-minute post-arrival horizon, so a longer
service day accumulates queue and the standard deviation roughly doubles.

Columns fall into three classes and the boundary is enforced in code by
`data.assert_no_latent_features`, which raises rather than warns:

* **observable at creation** — `quoted_prep_minutes`, `haul_km`, `created_at_minutes`,
  and four congestion features rebuilt from the day's event log;
* **observable at assignment** — adds `wait_to_assign_minutes`, `assigned_at_minutes`;
* **latent** — `latent_traffic_multiplier`, `latent_courier_speed_factor`. Validation
  only. A model that reads these re-derives the generating equation, scores R² ≈ 1, and
  measures nothing.

Two of the columns the brief lists as legitimate features are not used, for reasons
measured rather than assumed — `restaurant_index` carries no transferable signal, and
the simulator's `*_at_creation` congestion columns are recorded at *assignment*. Both
are in [FINDINGS.md](FINDINGS.md).

To regenerate (requires Swift, and nothing downstream does):

```bash
./ml/export/export.sh
```

## Reproducibility

Every number in `reports/metrics.json` comes from a fixed seed (`20260916`) and a
committed dataset. The Weibull fit is a linear solve with a deterministic bounded
search — no optimiser restarts, no random initialisation — so two runs are identical.
`tests/test_eta.py::test_model_is_deterministic` asserts it.

## What this cannot tell you

* **Nothing about real-world accuracy.** See the note at the top.
* **Nothing about a market with different economics.** The decision layer's 4:1
  lateness ratio is a judgement call with no support-cost data behind it. Its
  sensitivity is reported; its correctness is not established.
* **Nothing about detecting small incidents at Ravon's scale.** The anomaly detector's
  sensitivity is bounded by segment volume, and at 20 orders per restaurant per day
  that bound is roughly 37 minutes in a one-day window. No threshold tuning moves it.
