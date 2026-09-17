"""Loading and feature construction for the exported simulator dataset.

The dataset is `ml/data/orders.csv.gz`, produced once by `ml/export/export.sh` and
committed. Nothing in this package compiles or imports Swift.

The single most important thing this module does is police the boundary between what a
model is allowed to see and what it is not. Three categories:

* **Observable at creation** — known the instant the customer taps "order". This is the
  only feature set a customer-facing ETA quote may use.
* **Observable at assignment** — adds everything learned once a courier is matched.
  A legitimate second-stage model (DoorDash re-quotes at several lifecycle points), but
  it cannot be compared against a creation-time baseline.
* **Latent** — the simulator's hidden state. Available for *validation only*. A model
  that reads these is measuring nothing.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path

import numpy as np
import pandas as pd

DATA_DIR = Path(__file__).resolve().parent.parent / "data"
ORDERS_PATH = DATA_DIR / "orders.csv.gz"
META_PATH = DATA_DIR / "meta.json"

#: Hidden simulator state. Never a feature. Guarded by `assert_no_latent_features`.
LATENT_COLUMNS = ("latent_traffic_multiplier", "latent_courier_speed_factor")

#: The outcome. Never a feature at any lifecycle stage.
#:
#: `wait_to_assign_minutes` is deliberately *not* here even though it is a component of
#: the outcome: it equals `assigned_at - created_at`, both of which are known the moment
#: a courier is matched. It is unavailable at creation and available at assignment,
#: which is a staging question, not a leakage question — so it lives in
#: `FEATURES_AT_ASSIGNMENT` and is absent from `FEATURES_AT_CREATION`.
OUTCOME_COLUMNS = (
    "total_delivery_minutes",
    "delivered_at_minutes",
)

#: Features a customer-facing quote may use at the moment the order is placed.
#:
#: `restaurant_index` is deliberately absent; see `restaurant_identity_is_unstable()`.
FEATURES_AT_CREATION = (
    "quoted_prep_minutes",
    "haul_km",
    "created_at_minutes",
    "free_couriers_now",
    "inflight_now",
    "pending_now",
    "recent_arrivals_30m",
)

#: Adds what is known once the order has actually been matched to a courier.
FEATURES_AT_ASSIGNMENT = FEATURES_AT_CREATION + (
    "wait_to_assign_minutes",
    "assigned_at_minutes",
)

#: Nominal courier speed used by `DispatchCostModel`. The naive ETA is built from it.
NOMINAL_SPEED_KMH = 18.0


class LatentLeakError(AssertionError):
    """Raised when a latent or outcome column reaches a model's feature set."""


def assert_no_latent_features(feature_names) -> None:
    """Fail loudly if a feature set contains hidden state or the outcome.

    This exists because the failure mode it prevents is silent: a model trained on
    `latent_traffic_multiplier` scores beautifully and means nothing.
    """
    names = set(feature_names)
    leaked = names & (set(LATENT_COLUMNS) | set(OUTCOME_COLUMNS))
    if leaked:
        raise LatentLeakError(
            f"feature set contains latent/outcome columns: {sorted(leaked)}"
        )


def load_meta(path: Path = META_PATH) -> dict:
    """Simulator config and the naive-ETA reproduction numbers, as exported."""
    return json.loads(Path(path).read_text())


def _congestion_at_creation(day_frame: pd.DataFrame, courier_count: int) -> pd.DataFrame:
    """Marketplace load at each order's *creation* instant, rebuilt from the day's log.

    The simulator exports `free_couriers_at_creation` / `pending_orders_at_creation`,
    but — see FINDINGS.md — it fills both in at the moment of *assignment*, not
    creation. Using them to forecast from creation time leaks the future: an order that
    happened to be matched during a calm patch carries a calm-looking "at creation"
    load. So we rebuild the honest versions here, using only events with a timestamp at
    or before the order's own creation time.
    """
    created = np.sort(day_frame["created_at_minutes"].to_numpy())
    assigned = np.sort(day_frame["assigned_at_minutes"].dropna().to_numpy())
    delivered = np.sort(day_frame["delivered_at_minutes"].dropna().to_numpy())

    t = day_frame["created_at_minutes"].to_numpy()
    # `side="left"` so an order does not count itself: strictly-before events only.
    n_created = np.searchsorted(created, t, side="left")
    n_assigned = np.searchsorted(assigned, t, side="right")
    n_delivered = np.searchsorted(delivered, t, side="right")
    n_created_30m_ago = np.searchsorted(created, t - 30.0, side="left")

    inflight = n_assigned - n_delivered
    return pd.DataFrame(
        {
            "inflight_now": inflight,
            "free_couriers_now": np.maximum(courier_count - inflight, 0),
            "pending_now": n_created - n_assigned,
            "recent_arrivals_30m": n_created - n_created_30m_ago,
        },
        index=day_frame.index,
    )


def load_orders(
    path: Path = ORDERS_PATH, meta_path: Path = META_PATH
) -> pd.DataFrame:
    """Load the exported orders and attach derived, provably-causal features."""
    meta = load_meta(meta_path)
    df = pd.read_csv(path)

    df["assigned"] = df["assigned_at_minutes"].notna()
    df["delivered"] = df["total_delivery_minutes"].notna()

    # Service day starts late morning; the simulator clock starts at zero.
    df["clock_hour"] = (meta["serviceDayStartHour"] + df["hour_of_day"]).astype(int)

    # Nominal travel time at the dispatcher's assumed speed — the "formula" half of the
    # naive ETA the model has to beat.
    df["nominal_travel_minutes"] = df["haul_km"] / NOMINAL_SPEED_KMH * 60.0
    df["naive_eta_minutes"] = df["quoted_prep_minutes"] + df["nominal_travel_minutes"]

    congestion = (
        df.groupby("day", group_keys=False)[df.columns.tolist()]
        .apply(_congestion_at_creation, courier_count=meta["courierCount"])
        .reindex(df.index)
    )
    df = pd.concat([df, congestion], axis=1)

    # Haul terciles, computed on the whole dataset so bucket edges are a fixed property
    # of the simulator rather than of whichever slice you happen to be looking at.
    df["haul_bucket"] = pd.qcut(
        df["haul_km"], 3, labels=["short", "medium", "long"]
    ).astype(str)

    return df


def split_by_day(
    df: pd.DataFrame, train_fraction: float = 0.7
) -> tuple[pd.DataFrame, pd.DataFrame]:
    """Split train/test by whole simulator days.

    Splitting on rows would leak: orders within a day share a courier pool, a traffic
    phase and a queue, so a random row split lets the model see the same congestion
    episode on both sides of the wall.
    """
    days = np.sort(df["day"].unique())
    cut = int(round(len(days) * train_fraction))
    train_days = set(days[:cut])
    return (
        df[df["day"].isin(train_days)].copy(),
        df[~df["day"].isin(train_days)].copy(),
    )


@dataclass(frozen=True)
class StabilityCheck:
    """Result of `restaurant_identity_is_unstable`."""

    zones_per_restaurant: float
    between_day_share_of_variance: float
    unstable: bool


def restaurant_identity_is_unstable(df: pd.DataFrame) -> StabilityCheck:
    """Is `restaurant_index` a stable entity across simulator days?

    It is not, and this is worth a named function because the brief lists
    `restaurant_index` as a legitimate feature. `MarketplaceSimulator` redraws
    restaurant locations *and* their latent prep bias from the RNG at the top of every
    run, so "restaurant 3" on day 0 and "restaurant 3" on day 1 are different kitchens
    in different places. Two symptoms:

    * a restaurant's geographic zone changes day to day (a fixed kitchen cannot move);
    * almost none of the variance in per-restaurant mean delivery time is *between*
      restaurants — it is all within-restaurant, across days.
    """
    zones_per_restaurant = df.groupby("restaurant_index")["zone"].nunique().mean()

    done = df[df["delivered"]]
    cell = done.groupby(["restaurant_index", "day"])["total_delivery_minutes"].mean()
    per_restaurant = cell.groupby("restaurant_index").mean()
    between = float(per_restaurant.var(ddof=1))
    total = float(cell.var(ddof=1))
    share = between / total if total > 0 else 0.0

    return StabilityCheck(
        zones_per_restaurant=float(zones_per_restaurant),
        between_day_share_of_variance=share,
        unstable=zones_per_restaurant > 1.5 or share < 0.10,
    )
