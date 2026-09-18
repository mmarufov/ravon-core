"""Shared fixtures. The dataset is loaded once per session — it is 48,000 rows and
every test wants the same one."""

from __future__ import annotations

import pytest

from ravon_ml.data import load_orders, split_by_day


@pytest.fixture(scope="session")
def orders():
    return load_orders()


@pytest.fixture(scope="session")
def split(orders):
    return split_by_day(orders, train_fraction=0.7)
