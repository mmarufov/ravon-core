#!/usr/bin/env bash
# Run this suite against db/schema as it was at a given commit.
#
#   RAVON_DSN=postgresql://postgres@127.0.0.1:5437/postgres \
#     db/schema/tests/negative_control.sh 65ad66c
#
# The tests come from the working tree; only the schema under test is old. The
# regressions must FAIL here and pass on the fix. That is the evidence that each
# test detects the defect it names, rather than passing for some other reason.
set -euo pipefail
SHA="${1:?usage: negative_control.sh <sha>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(git -C "$HERE" rev-parse --show-toplevel)"
OUT="$(mktemp -d)"
git -C "$ROOT" archive "$SHA" db/schema | tar -x -C "$OUT"
echo "schema under test: $SHA ($(git -C "$ROOT" rev-parse "$SHA")), extracted to $OUT"
cd "$HERE/.."
RAVON_SCHEMA_DIR="$OUT/db/schema" python -m pytest tests -p no:cacheprovider -rA "${@:2}" || true
