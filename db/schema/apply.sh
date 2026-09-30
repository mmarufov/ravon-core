#!/usr/bin/env bash
# Apply the Ravon schema in order, then assert the invariants.
#
#   ./db/schema/apply.sh "postgresql://..."           # remote (Supabase)
#   ./db/schema/apply.sh -d ravon_local --local       # local, with the auth shim
#
# --local first applies db/schema/local/00_auth_shim.sql, which stands in for the
# `auth` schema, auth.uid(), the anon/authenticated roles and storage.buckets
# that Supabase provides natively. Never apply that file to Supabase.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL=0
PSQL_ARGS=()
for a in "$@"; do
  if [[ "$a" == "--local" ]]; then LOCAL=1; else PSQL_ARGS+=("$a"); fi
done

run() { psql "${PSQL_ARGS[@]}" -v ON_ERROR_STOP=1 -q -f "$1"; }

FILES=(
  00_prelude.sql
  01_types.sql
  02_tables.sql
  03_lifecycle.sql
  04_orderability.sql
  05_order_create.sql
  06_merchant_rpcs.sql
  07_courier_rpcs.sql
  08_consumer_support_rpcs.sql
  09_triggers.sql
  10_courier_reports.sql
  11_rls.sql
  # 12 LAST on purpose: the deny-by-default REVOKE only writes a non-NULL ACL
  # against objects that already exist. See the header of 12_grants.sql.
  12_grants.sql
  13_realtime_storage.sql
)

if [[ $LOCAL -eq 1 ]]; then
  echo "  + local/00_auth_shim.sql"
  run "$HERE/local/00_auth_shim.sql"
fi

for f in "${FILES[@]}"; do
  echo "  + $f"
  run "$HERE/$f"
done

echo "  = invariants.sql"
psql "${PSQL_ARGS[@]}" -v ON_ERROR_STOP=1 -f "$HERE/invariants.sql" 2>&1 | grep -E 'NOTICE|ERROR' || true
