# ravon-ml. No Swift toolchain needed for anything but `make dataset`.
PY := .venv/bin/python

.PHONY: help setup test report dataset clean

help:
	@echo "setup    create .venv and install (needs uv)"
	@echo "test     run the test suite"
	@echo "report   regenerate reports/metrics.json and the figures"
	@echo "dataset  re-export data/ from the Swift simulator (needs swiftc)"
	@echo "clean    remove caches and build output"

setup:
	uv venv --python 3.12 .venv
	uv pip install --python $(PY) -e ".[dev]"

test:
	$(PY) -m pytest -q

report:
	$(PY) -m ravon_ml.cli

dataset:
	./export/export.sh

clean:
	rm -rf .pytest_cache ravon_ml/__pycache__ tests/__pycache__ ravon_ml.egg-info export/.build
