#!/usr/bin/env bash
# Regenerate ml/data/orders.csv.gz + ml/data/meta.json from the Swift simulator.
#
# This is the ONLY step in the ML layer that needs a Swift toolchain, and its output is
# committed, so nothing downstream ever runs it. Re-run only to regenerate the dataset.
#
#   ./ml/export/export.sh
#
# Deliberately compiles the six self-contained files in Sources/RavonCore/Dispatch/
# directly with swiftc rather than adding an executable target to Package.swift: the
# dispatch sources import nothing but Foundation, and the ML layer has no business
# appearing in the shipped Swift package's manifest.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_DIR="$REPO_ROOT/ml/export/.build"
mkdir -p "$BUILD_DIR"

echo "compiling exporter..."
swiftc -O \
  -o "$BUILD_DIR/export-orders" \
  "$REPO_ROOT"/Sources/RavonCore/Dispatch/*.swift \
  "$REPO_ROOT/ml/export/main.swift"

echo "running..."
"$BUILD_DIR/export-orders" "$REPO_ROOT"

echo "compressing..."
gzip -9 -f "$REPO_ROOT/ml/data/orders.csv"
ls -lh "$REPO_ROOT/ml/data/"
