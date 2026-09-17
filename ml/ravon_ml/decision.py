"""The ETA decision layer: turn a distribution into the one number a customer sees.

The base layer's job is to be *right*. This layer's job is to be *useful*, and those
are different objectives — which is the whole reason DoorDash keeps them in separate
layers and why this is a separate module.

If the two were fused, the only honest thing to display would be the mean, or maybe the
median. But the cost of an ETA is asymmetric. Quoting 30 minutes and arriving at 45 is
a support contact, a credit, and sometimes a churned customer. Quoting 45 and arriving
at 38 is a mildly pleasant surprise. Those are not the same size, so the number to
display is deliberately *not* the unbiased estimate. Fusing the layers hides that
decision inside a loss function where nobody can argue with it; splitting them forces
the two cost constants into the open, where they can be challenged.

## Deriving the quote quantile instead of picking one

Let the per-minute cost of being late be `c_late` and of being early `c_early`. For a
quote `q` and realised duration `Y ~ F`:

    C(q) = c_late * max(0, Y - q) + c_early * max(0, q - Y)

    E[C(q)] = c_late * integral_q^inf (y - q) dF + c_early * integral_0^q (q - y) dF

    d/dq E[C(q)] = -c_late * (1 - F(q)) + c_early * F(q)

Setting that to zero gives the newsvendor solution:

    F(q*) = c_late / (c_late + c_early)        i.e.   q* = F^-1( ratio / (1 + ratio) )

with `ratio = c_late / c_early`. So the quantile is *derived* from the two constants,
not chosen for looking about right. A 4:1 lateness penalty lands on p80; 3:1 on p75;
7:1 on p87.5. The whole p70-p90 band the brief asks for corresponds to ratios between
2.3:1 and 9:1, which is a much easier range to defend than a quantile is.

This module also measures the derivation instead of trusting it: `sweep_quantiles`
computes realised cost across the whole quantile grid on held-out data, and the
argmin is compared against `optimal_quantile` in the tests.
"""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np

__all__ = [
    "AsymmetricCost",
    "optimal_quantile",
    "quote_cost",
    "sweep_quantiles",
    "QuotePolicyResult",
    "evaluate_quote_policy",
    "RAVON_COST",
]


def optimal_quantile(cost_late: float, cost_early: float) -> float:
    """The newsvendor quantile `c_late / (c_late + c_early)`."""
    if cost_late <= 0 or cost_early <= 0:
        raise ValueError("both cost constants must be positive")
    return cost_late / (cost_late + cost_early)


@dataclass(frozen=True)
class AsymmetricCost:
    """Per-minute cost of a quote being wrong in each direction.

    The units are deliberately abstract — "cost units per minute" — because the ratio
    is the only thing that affects the optimal quote, and the ratio is the only part
    anyone can actually defend without a revenue model.
    """

    late: float
    early: float
    rationale: str = ""

    @property
    def ratio(self) -> float:
        return self.late / self.early

    @property
    def quantile(self) -> float:
        return optimal_quantile(self.late, self.early)

    def __call__(self, quote, actual) -> np.ndarray:
        quote = np.asarray(quote, dtype=float)
        actual = np.asarray(actual, dtype=float)
        return self.late * np.maximum(actual - quote, 0.0) + self.early * np.maximum(
            quote - actual, 0.0
        )


#: The constants this project quotes against, stated so they can be argued with.
#:
#: 4:1 is a judgement call, not a measurement, and it is the single least defensible
#: number in the ETA pipeline — Ravon has no launched market and therefore no support
#: cost data. It is anchored on the structure of the two harms rather than their size:
#: a late delivery produces a support contact, a credit, and a churn hazard, all of
#: which are recurring costs paid by the business; an early delivery produces a
#: customer who waits a few minutes at the door, which is a one-off annoyance.
#: Sensitivity to it is small and reported: 3:1 through 7:1 moves the quote by roughly
#: 7 minutes and the realised cost by under 4%, which is the useful thing to know.
RAVON_COST = AsymmetricCost(
    late=4.0,
    early=1.0,
    rationale="late minutes drive support contacts, credits and churn; early minutes "
    "cost a short wait at the door",
)


def quote_cost(quote, actual, cost: AsymmetricCost) -> float:
    """Mean realised asymmetric cost of a set of quotes."""
    return float(cost(quote, actual).mean())


def sweep_quantiles(
    quantile_fn, actual, cost: AsymmetricCost, levels=None
) -> tuple[np.ndarray, np.ndarray]:
    """Realised mean cost as a function of the quote quantile level.

    `quantile_fn(level)` must return one quote per observation in `actual`.
    """
    if levels is None:
        levels = np.round(np.arange(0.30, 0.991, 0.01), 3)
    levels = np.asarray(levels, dtype=float)
    costs = np.array([quote_cost(quantile_fn(level), actual, cost) for level in levels])
    return levels, costs


@dataclass(frozen=True)
class QuotePolicyResult:
    """What a quoting policy actually did to customers."""

    label: str
    level: float
    mean_quote_minutes: float
    mean_actual_minutes: float
    late_rate: float
    mean_lateness_when_late: float
    mean_earliness_when_early: float
    mean_cost: float
    p90_lateness_minutes: float

    def as_dict(self) -> dict:
        return self.__dict__.copy()


def evaluate_quote_policy(
    label: str, quotes, actual, cost: AsymmetricCost, level: float
) -> QuotePolicyResult:
    quotes = np.asarray(quotes, dtype=float)
    actual = np.asarray(actual, dtype=float)
    lateness = actual - quotes
    late = lateness > 0
    return QuotePolicyResult(
        label=label,
        level=level,
        mean_quote_minutes=float(quotes.mean()),
        mean_actual_minutes=float(actual.mean()),
        late_rate=float(late.mean()),
        mean_lateness_when_late=float(lateness[late].mean()) if late.any() else 0.0,
        mean_earliness_when_early=(
            float(-lateness[~late].mean()) if (~late).any() else 0.0
        ),
        mean_cost=quote_cost(quotes, actual, cost),
        p90_lateness_minutes=float(np.percentile(np.maximum(lateness, 0.0), 90)),
    )
