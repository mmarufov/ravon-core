# Findings

What was measured, what was surprising, and what these models cannot do.

Every number here is reproduced by `python -m ravon_ml.cli` from the committed dataset
and seed `20260916`, and lands in `reports/metrics.json`. Negative results are in the
main sequence, not an appendix — there are five of them and two changed the design.

---

## 1. The naive baseline reproduces, and the reason it is bad is not the reason you would guess

A naive ETA equal to the generating formula — `quoted_prep + haul_km / 18 km/h` — was
on record at roughly +36 min bias and 51 min sd under realistic latent settings, and
still +24 min with latent state off. Measured on the reference config (240 orders /
180 min / 24 couriers, `OptimalBatchDispatcher`, seeds 1–30):

| latent | bias | sd | n |
|---|---:|---:|---:|
| `.realistic` | **+36.56** | **50.50** | 7,010 |
| `.none` | **+23.45** | 37.90 | 7,200 |

Exact reproduction. The interesting half is the second row: with *every* source of
hidden randomness switched off — no kitchen bias, no prep noise, no courier speed
spread, no traffic — the formula is still 23 minutes short. Mean wait-for-assignment in
that configuration is 29.6 minutes. Delivery time in a supply-constrained marketplace
is mostly **queueing**, and queueing is an emergent property of the arrival process
against the fleet, not a term in any per-order formula. Latent state contributes the
remaining 13 minutes of bias and raises the sd from 37.9 to 50.5.

This is the whole justification for `free_couriers_now`, `pending_now` and
`recent_arrivals_30m` as features. The model's gain over the formula is almost entirely
a congestion model, not a better travel-time model.

**Finding that cost a rewrite:** the regime is sensitive to the *shape* of the config,
not just its load ratio. Holding orders-per-minute-per-courier fixed and stretching the
service day from 180 to 540 minutes keeps the arrival rate identical but raises the sd
from 50 to 82 and drops the assignment rate from 97% to 83% — because the simulator has
no order timeout, so a longer day accumulates a backlog that the 90-minute post-arrival
horizon can no longer drain. The first version of this dataset used a 6-hour day to get
more hours of the day for anomaly segmentation, and it silently made the ETA problem a
different and harder one. The export is now pinned to the reference config.

---

## 2. Probabilistic ETA: what the base layer achieves

140 training days, 60 held-out test days, split by whole day. Splitting on rows would
leak — orders within a day share a courier pool, a traffic phase and a queue.

| model | bias | sd | MAE | CRPS | PIT variance | PIT KS | coverage @ p80 |
|---|---:|---:|---:|---:|---:|---:|---:|
| naive formula | +36.70 | 50.59 | 37.18 | 37.18 | — | — | — |
| naive, debiased | −0.28 | 50.59 | 36.61 | 36.61 | — | — | — |
| unconditional Weibull | +3.06 | 54.27 | 38.26 | 26.70 | 0.0771 | 0.152 | 0.805 |
| **conditional, creation-time** | **−1.01** | **42.53** | **23.55** | **16.42** | 0.0868 | 0.070 | **0.804** |
| conditional, assignment-time | +0.38 | 11.67 | 8.21 | 5.95 | 0.0728 | 0.060 | 0.828 |

Reference points that matter more than the headline:

* **The debiased naive is the honest baseline.** Beating `quoted_prep + travel` is
  trivial — subtract 37 minutes. The debiased version has the same information and no
  bias, and the conditional model still cuts its CRPS by 55.1%.
* **The non-parametric floor is CRPS 26.07** (score the training set's empirical
  distribution against the test set). The unconditional Weibull sits at 26.70, i.e.
  the Weibull family costs almost nothing versus a fully flexible distribution, and the
  conditional model at 16.42 is well below it. If the conditional model had not cleared
  the floor, the conditioning would have been decoration.
* **Calibration alone is not a result, demonstrated concretely.** The unconditional
  model has no features at all and its coverage at p80 is 80.5% — nominally perfect.
  Its CRPS is 63% worse. Anyone quoting a calibration statistic without a sharpness
  statistic is quoting this model.

---

## 3. Parameter recovery: the validation production cannot run

Because the data is synthetic, the true conditional distribution exists. Generate
20,000 draws from a known three-parameter Weibull and fit it back:

| true `(k, λ, γ)` | recovered | shape error | R² of the log–log fit |
|---|---|---:|---:|
| (1.20, 30, 0) | (1.197, 29.85, 0.00) | −0.27% | 0.99997 |
| (1.80, 45, 8) | (1.808, 45.16, 7.89) | +0.44% | 0.99998 |
| (2.50, 38, 15) | (2.493, 37.97, 14.92) | −0.30% | 0.99988 |
| **(3.37, 40, 12)** | **(3.343, 39.84, 12.17)** | **−0.79%** | 0.99997 |
| (4.20, 55, 20) | (4.118, 54.35, 20.71) | −1.94% | 0.99990 |
| (6.00, 70, 10) | (6.241, 72.60, 7.39) | +4.02% | 0.99994 |

The 3.37 row is DoorDash's published check; they recover 3.22, a −4.5% error, against
our −0.79%. Not a claim of superiority — they are fitting a neural network's output
head on real deliveries and we are fitting one unconditional sample — but it does
establish that the procedure itself is unbiased.

Recovery degrades at high shape (`k = 6` is +4%) for a structural reason worth naming:
a high-`k` Weibull is nearly symmetric and short-tailed, so the usable survival bins
collapse into a narrow band of `log(t − γ)` and the location becomes weakly identified.
Delivery durations sit at `k ≈ 1.5–3`, where recovery is sub-1%.

---

## 4. Interval regression vs MLE: DoorDash's claim is right, for a reason they do not state

Their stated reason for fitting by interval regression rather than maximising the
log-likelihood is that it "greatly reduced overfitting". Rather than repeat it, the
model exposes `per_cell_fit="interval" | "mle"` so the two can be run end to end.

**Per cell, MLE is slightly better.** Across 30 training cells, MLE's worst error in
recovering the cell's own mean is 0.46 min against interval regression's 1.58 min. On
clean synthetic samples at n = 60–400 the two are indistinguishable. Taken alone, this
is a negative result for the claim.

**End to end on held-out days, MLE is much worse:**

| per-cell fit | bias | CRPS | PIT variance | PIT KS |
|---|---:|---:|---:|---:|
| interval regression | −1.01 | **16.42** | 0.0868 | 0.070 |
| maximum likelihood | −9.25 | 22.15 | 0.1039 | 0.179 |

And MLE gets *worse* as cells are added (CRPS 21.59 → 22.15 → 22.92 at 10, 30, 60
cells) while interval regression is flat.

The mechanism is in the second stage, not the first. The three-parameter Weibull
likelihood barely identifies location against scale in a heavy right tail, so an
unconstrained MLE wanders: across 30 cells it returns locations from **−182.2** to
+26.4 minutes, and shapes up to 7.71. Each of those fits the cell fine. But stage two
regresses the fitted parameters on the cell score, and a parameter surface containing a
location of minus three hours is not a surface any smooth link can follow. Interval
regression profiles `γ` over the bounded interval `[0, 0.98 · min(samples)]` and cannot
produce a location that is not a duration, so its parameter trajectories stay smooth —
roughness of the scale trajectory 8.55 against MLE's 18.74.

So the overfitting DoorDash describes is real, but it is overfitting of the *parameter
surface across segments*, not of any individual segment's fit. `test_eta.py` asserts
both the outcome and the mechanism, so the explanation cannot drift from the evidence.

---

## 5. "Ordinary least squares" needed one amendment, and it was worth 4 minutes of bias

The brief — and DoorDash's description — say to solve the log–log survival transform
with ordinary least squares over the histogram buckets. Implemented literally, every
bucket counts the same, so a tail bucket holding three deliveries pulls as hard as a
body bucket holding nine hundred. Measured across 20 training cells:

| bucket weighting | mean in-cell bias | mean abs bias | in-sample CRPS |
|---|---:|---:|---:|
| unweighted (literal) | **+3.91 min** | 5.88 | 15.37 |
| by observation count (default) | **−0.40 min** | **0.54** | **14.52** |
| delta-method variance | −0.63 min | 0.63 | 14.60 |

Count weighting is ordinary least squares over *observations* rather than over buckets,
which is what "fit the histogram" should have meant. It is the default. The
statistically principled delta-method weights — reciprocal of
`Var(log(−log Ŝ)) ≈ (1−S) / (n S log²S)` — are very slightly worse, which is mildly
surprising and probably reflects that the delta approximation is poor in the deep tail
where `S → 0`. All three recover known parameters equally well (k = 3.37 → 3.357,
3.350, 3.349), so the difference is entirely about the *mean* of the fitted
distribution, not its shape.

---

## 6. The calibration summary is flattering, and the histogram says so

`PIT variance 0.0868` against an ideal `1/12 = 0.0833` earns the creation-time model
the verdict "well dispersed". The chi-square test on the same PIT values returns
`p < 0.001`. Both are true and the second is the more honest one.

`reports/pit_histogram.png` shows what the variance statistic cannot: a mild leftward
tilt (PIT mean 0.477, so the model over-predicts the body of the distribution by a
minute or so) and a visible spike at `u ≈ 1` — about 8% of held-out orders land above
the model's 95th percentile. Those are the deliveries that waited three hours for a
courier. The Weibull's right tail is not heavy enough for a saturated marketplace.

This is reported rather than fixed, because the fix is not a distributional one: the
extreme tail here is orders that queue behind a fleet that has run out of couriers, and
the honest model of that is a queueing model, not a fatter tail. `reports/calibration.png`
shows the practical consequence is small — realised coverage is within 0.07 of nominal
everywhere and crosses zero error at almost exactly p80, which is where the decision
layer quotes.

The two failure modes, named as the brief asks: **under-dispersion** (predictions too
narrow, reality in the tails, U-shaped PIT, variance > 1/12) is the dangerous one,
because a p90 quote is then late far more than 10% of the time. **Over-dispersion**
(predictions too wide, central hump, variance < 1/12) is merely wasteful. Ours is
marginally under-dispersed at 0.0868, i.e. +4% on the ideal variance — inside the
±6% tolerance, and in the dangerous direction, which is why coverage is checked
separately at the quantile that is actually quoted.

---

## 7. Two of the brief's "legitimate features" are not usable, and neither failure is visible from the column names

**`restaurant_index` carries no transferable signal.** `MarketplaceSimulator` redraws
restaurant locations *and* their latent prep bias from the RNG at the top of every run,
so "restaurant 3" on day 0 and day 1 are different kitchens in different places. Two
measurements: each restaurant index appears in all 4 geographic zones across the 200
days (a fixed kitchen cannot move), and **0.38%** of the variance in per-restaurant-day
mean delivery time is *between* restaurants — the other 99.62% is within-restaurant,
across days. Training on it would fit 12 coefficients to noise. It is excluded, and
`data.restaurant_identity_is_unstable()` exists so the day the simulator gains stable
restaurants, the ML layer is told rather than silently improving.

**The simulator's congestion columns are recorded at the wrong time.**
`OrderRecord.freeCouriersAtCreation` and `pendingOrdersAtCreation` are named for order
creation but assigned inside the simulator's *assignment* loop
(`MarketplaceSimulator.swift`), so they describe the marketplace at the moment a courier
was matched — often an hour later. They disagree with the true creation-time value on
more than half of delivered orders. Using them to forecast from creation time leaks the
future: an order matched during a calm patch carries a calm-looking "at creation" load.

The four congestion features the model actually uses are rebuilt in
`data._congestion_at_creation` from the day's event log, counting only events with a
timestamp at or before the order's own creation. `test_data.py` re-derives them by
brute force on a random sample and pins the discrepancy with the exported columns.

---

## 8. Censoring: 3.5% of orders are missing from every number above

1,671 of 48,000 orders are never assigned and therefore never delivered. They have no
duration, so they are absent from training *and* from evaluation. They are not a random
sample — they are the orders the dispatcher could not serve, which is to say the worst
ones. Every ETA metric on this page is conditioned on "the order eventually arrived",
and the true unconditional distribution has a tail this model has never seen.

The correct treatment is survival analysis with right-censoring, which the Weibull
family supports natively — the likelihood contribution of a censored observation is
`S(t)` rather than `f(t)`, and the interval-regression form extends to it cleanly since
the survival curve is what is being fitted anyway. It is not implemented here. Doing it
properly needs a censoring *time* per unserved order, and the simulator does not have
order timeouts, so an unassigned order is pending forever rather than censored at a
definite horizon. That is a simulator change, and `Sources/` is out of scope for this
work.

---

## 9. Decision layer: the quantile is derived, and the derivation is correct

With `c_late` and `c_early` the per-minute costs of a quote being wrong in each
direction, `dE[C(q)]/dq = c_early·F(q) − c_late·(1−F(q))`, so the optimal quote is the
newsvendor quantile `F⁻¹(c_late / (c_late + c_early))`. Swept against realised cost on
held-out days:

| late:early | derived q* | empirical argmin | cost at derived | cost at argmin | penalty |
|---:|---:|---:|---:|---:|---:|
| 2:1 | 0.667 | 0.61 | 34.82 | 34.51 | +0.88% |
| 3:1 | 0.750 | 0.72 | 42.78 | 42.65 | +0.30% |
| **4:1** | **0.800** | **0.79** | **48.89** | **48.87** | **+0.04%** |
| 5:1 | 0.833 | 0.84 | 53.87 | 53.87 | +0.00% |
| 7:1 | 0.875 | 0.90 | 61.73 | 61.52 | +0.35% |
| 9:1 | 0.900 | 0.93 | 67.91 | 67.29 | +0.91% |

The derived quantile is never more than 0.91% above the empirically optimal cost, and
at the ratio actually used it is within 0.04%. The whole p70–p90 band the brief asks
about corresponds to ratios from 2.3:1 to 9:1, which is a far easier thing to defend
than a quantile is.

What quoting p80 instead of the unbiased estimate does:

| policy | mean quote | late rate | p90 lateness | mean cost |
|---|---:|---:|---:|---:|
| mean of the predictive distribution | 68.4 min | 40.3% | 38.4 min | 57.37 |
| median | 65.7 min | 43.1% | 43.1 min | 60.14 |
| **derived p80** | **89.8 min** | **19.6%** | **14.4 min** | **48.89** |
| p90 | 103.3 min | 12.4% | 4.0 min | 51.94 |

This is the concrete argument for splitting the layers. The mean is the right
*estimate* and the wrong *quote* — it is late 40% of the time. And p90 is not "safer":
it is 6% more expensive than p80, just on the other side. Fusing the layers would bury
both facts inside a loss function.

The 4:1 constant is the weakest number in the ETA pipeline and is labelled as such in
`decision.RAVON_COST`. There is no support-cost data behind it because there is no
launched market. Moving it from 3:1 to 7:1 shifts the quote by about 14 minutes and the
realised cost by under 4%.

---

## 10. Anomaly detection: σ = 6 → 3, derived rather than copied

DoorDash use 6σ. Copying that here would have switched the detector off. The threshold
is a property of the **multiple-comparison burden**, not of anomalies, and theirs is
four orders of magnitude larger.

Three dimensions (restaurant, hour-of-day, zone) at singlet and pair level give **115
segments**, of which **79** clear the volume gate on a typical day. Expected false
alarms per day from the Gaussian tail alone:

| σ | expected false alarms/day |
|---:|---:|
| 3.0 | 0.107 |
| 3.5 | 0.018 |
| 4.0 | 0.0025 |
| 6.0 | 0.000000078 |

At 6σ that is one false alarm roughly every 35,000 years — and a detector that cannot
fire on noise also cannot fire on anything short of a catastrophe. A plain Bonferroni
correction for one expected false alarm per day gives **σ = 2.24** here, so 3.0 is
already about a 10× safety margin over the nominal requirement. DoorDash need 6 because
~30 dimensions with triplets is 10⁴–10⁵ segments; at 3σ that is hundreds of pages a day.

**Measured** false-alarm rates on unperturbed data, over 172 evaluable days and 13,474
tests, where every firing is false by construction:

| metric | segment firings/day | clustered incidents/day | per-test rate |
|---|---:|---:|---:|
| mean delivery minutes | 0.215 | 0.198 | 0.0027 |
| unassigned rate | 0.349 | 0.227 | 0.0045 |

Both are 2–3× the Gaussian prediction of 0.00135, which is itself a finding: these
metrics are heavier-tailed than Gaussian. A binomial variance floor on the baseline
standard deviation was tried as a fix for the rate metric and changed nothing (60
firings before and after) — the empirical baseline spread already exceeds the sampling
noise, so the excess is genuine over-dispersion in the simulator, largely from
restaurant identity being redrawn daily (see §7), not a detector defect.

---

## 11. The dual gate matters, but not where the received wisdom puts it

"A Z-score alone fires constantly on small segments, so the absolute gate is what kills
false positives." Measured over 172 days:

| metric | min volume | Z-gate only | dual gate | removed by absolute gate |
|---|---:|---:|---:|---:|
| mean delivery minutes | 10 | 0.215/day | 0.215/day | **0%** |
| mean delivery minutes | 3 | 0.750/day | 0.744/day | 0.8% |
| unassigned rate | 20 | 0.802/day | 0.349/day | **57%** |
| unassigned rate | 3 | 2.750/day | 0.401/day | **85%** |

The claim is true, and specifically true for **rate metrics on small segments**, where
one extra failed order out of five is a huge relative move and no kind of incident. On
a value metric it is a no-op at this scale, because a mean-of-minutes segment that
clears the volume gate at all has already accumulated enough excess minutes to clear
the absolute one. Shipping the absolute gate is still right — it is nearly free and it
is the thing standing between the system and an 85% false-positive rate the day someone
lowers the volume gate — but reporting it as "the dual gate cut our false positives"
without saying which metric would be overclaiming.

---

## 12. The volume wall: the most useful number is the one that says what cannot be done

Detection sensitivity on a mean metric is `σ · s / √(n · k)` — per-order standard
deviation `s`, segment volume `n` per day, `k`-day test window. With `s = 54.5` min:

| segment | orders/day | 1-day | 3-day | 7-day | 14-day |
|---|---:|---:|---:|---:|---:|
| restaurant | 20.0 | **36.5 min** | 21.1 | 13.8 | 9.8 |
| zone | 62.3 | 20.7 | 12.0 | 7.8 | 5.5 |
| hour of day | 80.0 | 18.3 | 10.5 | 6.9 | 4.9 |

At Ravon's simulated volume, **no choice of σ makes a 10-minute kitchen slowdown
visible in a one-day window.** That is not a tuning problem; it is arithmetic. The
detector was originally built with DoorDash's 1-day test window and appeared broken —
+30 min injected slowdowns detected 20% of the time. They were not broken; they were
below the noise floor.

The adaptation a small market actually needs is a **longer test window**, trading
detection latency for sensitivity at `√k`. Measured by injection over 10 test days:

Kitchen slowdown (`restaurant 3`, constant extra minutes):

| test window | +8 | +12 | +16 | +20 | +25 | +30 |
|---|---:|---:|---:|---:|---:|---:|
| 1 day | 0% | 0% | 0% | 0% | 20% | 20% |
| 3 days | 10% | 10% | 10% | 30% | 40% | 70% |
| **7 days** | 30% | 30% | 40% | **70%** | **90%** | **90%** |

Cancellation spike (`zone z0-1`, fraction of orders lost):

| test window | +3% | +5% | +8% | +10% | +15% | +20% |
|---|---:|---:|---:|---:|---:|---:|
| 1 day | 0% | 10% | 10% | 20% | 40% | 60% |
| **3 days** | 30% | 50% | 60% | **80%** | **90%** | **100%** |

The rate metric works at a 1-day window where the value metric does not, because a
cancellation spike moves its metric by several baseline standard deviations while a
10-minute slowdown moves a 54-minute-sd mean by a fraction of one.

Two caveats on these numbers. Injection is applied to the *exported records*, not
inside the Swift simulator, because `ml/` is required to run without a Swift toolchain.
A simulator-level perturbation would propagate — a slow kitchen holds its courier
longer, delaying other orders through the shared pool — so the injected anomalies here
are smaller and more localised than the real thing, and these detection rates are a
conservative lower bound. And the sweeps use 10 test days per magnitude, so each cell
is ±15pp of binomial noise.

---

## 13. The gap window: it does not speed up detection, it stops detection from decaying

The 7-day gap between baseline and test exists so a slowly-ramping trend does not
pollute its own baseline. Measured on a cancellation rate ramping from 0.6% to 12% over
20 days in zone `z0-1`, comparing 21-day baseline + 7-day gap against 28-day baseline
with no gap — same total lookback, so this is not "more history wins":

| | 21+7 gap | 28+0 no gap |
|---|---:|---:|
| First detection | day 9 | day 9 |
| Mean Z of the affected segment, days 12–20 | **5.56** | 3.29 |
| Detections, days 12–20 | 8 of 9 | 6 of 9 |

The result is not what the usual framing suggests. **First** detection is identical —
early in a ramp the baseline has not been contaminated yet, so the gap buys nothing.
What the gap buys is that the detector stays lit. Once the trend is older than a week,
the no-gap baseline has absorbed it into both its mean and its standard deviation, and
the Z-score collapses by 41% exactly as the incident gets worse. `reports/anomaly_detection.png`,
middle panel, is the clearest picture of it: the two curves track each other for eleven
days and then separate.

So the honest statement of the gap's value is "it prevents a long-running incident from
going quiet", not "it detects trends sooner".

---

## 14. Clustering: average linkage was wrong, and the injection test is what caught it

Anomalous segments overlap — a broken zone lights up the zone singlet, every restaurant
inside it, and every hour-of-day slice of it. One incident, nine pages.

The first implementation used Jaccard distance with average linkage, which left a single
injected incident split across **five** clusters. Two problems, both found by the
ground-truth test rather than by reading the code:

* **Jaccard punishes containment.** `clock_hour=12|zone=z0-1` is a strict subset of
  `zone=z0-1`, but their Jaccard is about ⅓ — low enough to look unrelated. The right
  similarity for a hierarchy is the **overlap coefficient**, `|A∩B| / min(|A|,|B|)`,
  which is 1.0 for any subset relationship.
* **Average linkage breaks the chain.** Two sibling restaurants inside the same failing
  zone have zero overlap with *each other*, so their average distance to the parent
  exceeds the cut even though each is fully contained in it. **Single linkage** recovers
  the connected component of the containment graph, which is the actual object of
  interest.

With overlap + single linkage the same injection produces **9 firing segments → 1
cluster**, represented by `zone=z0-1`. The representative is the highest-scoring member
and the DoorDash ranking `abs_anom_amt · rel_amt / level^1.2` divides by depth, so the
simplest sufficient description wins — "zone z0-1 is failing", not "zone z0-1 at 12:00
is failing". That is what an on-call engineer should read first.

---

## 15. What these models cannot do

* **Predict real delivery times.** Nothing here has seen a real delivery.
* **Forecast the tail of a saturated market.** ~8% of held-out orders exceed the
  model's p95. Those are queueing events, and a Weibull over duration is the wrong
  object for them; a queueing model is the right one.
* **Say anything about orders that never arrive.** 3.5% of orders are censored out of
  every metric on this page (§8).
* **Learn per-restaurant effects.** Not a model limitation — the simulator does not have
  persistent restaurants (§7). On real data this would be one of the strongest features
  available, and its absence is the largest single gap between this and a deployable
  ETA model.
* **Detect small incidents at Ravon's scale.** Bounded at ~37 minutes for a restaurant
  in a one-day window, by arithmetic (§12).
* **Justify its own cost constants.** The 4:1 lateness ratio is an assumption. The
  machinery that turns it into a quote is validated; the constant is not.
