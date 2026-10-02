#!/usr/bin/env bash
# Regenerate ml/data/orders.csv.gz + ml/data/meta.json from the Swift simulator.
#
# This is the ONLY step in the ML layer that needs a Swift toolchain, and its output is
# committed, so nothing downstream ever runs it. Re-run only to regenerate the dataset.
#
#   ./ml/export/export.sh
#
# The Swift simulator was deleted from Sources/RavonCore/Dispatch/ in #12, once the Kotlin
# port in services/dispatch reproduced it bit-for-bit. The dataset came from the Swift
# original, so this compiles those six files as of SIMULATOR_REV, read out of git history
# (a shallow clone will not have it). They are compiled directly with swiftc rather than
# as an executable target in Package.swift: they import nothing but Foundation, and the
# ML layer has no business appearing in the shipped Swift package's manifest.
#
# Checked 2026-10-02: the output is byte-identical to the committed data/orders.csv.gz
# (compared decompressed) and data/meta.json.
set -euo pipefail

# The last commit on main that has the Swift simulator (#11); main.swift was written
# against it.
SIMULATOR_REV=38f29c9ff608018d2c0a286bc4c7e1d85857ba2e

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_DIR="$REPO_ROOT/ml/export/.build"
SRC_DIR="$BUILD_DIR/src"

if ! git -C "$REPO_ROOT" cat-file -e "$SIMULATOR_REV^{commit}" 2>/dev/null; then
  echo "commit $SIMULATOR_REV is not in this clone; run 'git fetch --unshallow' first" >&2
  exit 1
fi

rm -rf "$SRC_DIR"
mkdir -p "$SRC_DIR"
echo "extracting the Swift simulator at ${SIMULATOR_REV:0:7}..."
git -C "$REPO_ROOT" archive "$SIMULATOR_REV" Sources/RavonCore/Dispatch | tar -x -C "$SRC_DIR"

echo "compiling exporter..."
swiftc -O \
  -o "$BUILD_DIR/export-orders" \
  "$SRC_DIR"/Sources/RavonCore/Dispatch/*.swift \
  "$REPO_ROOT/ml/export/main.swift"

echo "running..."
"$BUILD_DIR/export-orders" "$REPO_ROOT"

echo "compressing..."
gzip -9 -f "$REPO_ROOT/ml/data/orders.csv"
ls -lh "$REPO_ROOT/ml/data/"
