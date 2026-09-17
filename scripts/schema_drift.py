#!/usr/bin/env python3
"""Detect drift between the Swift models and the SQL migrations.

## Why

`RavonCore`'s models decode Postgres rows via `CodingKeys`. Those keys must match
columns created across 19 migration files, and **nothing checks that they do**. A
mismatch is not a compile error and not a test failure -- it is a decode crash in a
shipped iOS app, which cannot be hotfixed.

This is a scaled-down version of DoorDash's schema-registry CI gate, whose stated
guarantee is "detection of incompatible schema changes at build time" rather than
"runtime errors from the client application." Four existing test files
(`SoftDeleteCodingTests`, `ReassignmentCodingTests`, `NoShowAndDelayCodingTests`,
`ChatRLSCodingTests`) are hand-written per-migration attempts at this same check; a
generator subsumes the category.

## An honest limitation, stated up front

The migrations are an **incomplete** record of the schema. They were written
incrementally against a live database, so any table or column created through the
Supabase dashboard never appears in a migration file. Evidence: `order_status` has
`ALTER TYPE ... ADD VALUE` statements but no `CREATE TYPE`, so the base enum was
created out-of-band.

So "this Swift key appears in no migration" does **not** prove the column is missing --
it means the column is unverifiable from the repo alone. The tool therefore reports two
tiers and never conflates them:

  * **DRIFT**  -- provable from the repo (e.g. a Swift enum case with no corresponding
                 `ADD VALUE`, where the migration record for that enum *is* complete)
  * **UNVERIFIED** -- a key with no migration evidence either way; needs a live
                 introspection run to resolve

Exit 1 only on DRIFT. UNVERIFIED is reported and counted, never failed on, because
failing the build on an unprovable claim trains people to ignore the gate.
"""
from __future__ import annotations

import pathlib
import re
import sys
from collections import defaultdict

MIGRATIONS = pathlib.Path(".context/migrations")
MODELS = pathlib.Path("Sources/RavonCore/Models")

# `case foo = "bar"` or bare `case foo`
SWIFT_CASE = re.compile(r'^\s*case\s+([A-Za-z_][A-Za-z0-9_]*)\s*(?:=\s*"([^"]+)")?', re.M)
# `enum Name: String` / `public enum Name: String, ...`
SWIFT_ENUM = re.compile(r'^\s*(?:public\s+)?enum\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*String', re.M)


def read_migrations() -> str:
    if not MIGRATIONS.is_dir():
        print(f"error: {MIGRATIONS} not found", file=sys.stderr)
        raise SystemExit(2)
    return "\n".join(
        p.read_text(encoding="utf-8", errors="ignore")
        for p in sorted(MIGRATIONS.glob("*.sql"))
    )


def enum_values(sql: str) -> dict[str, set[str]]:
    """Postgres enum name -> the values the migrations prove exist."""
    values: dict[str, set[str]] = defaultdict(set)
    for name, body in re.findall(
        r"CREATE\s+TYPE\s+(?:public\.)?([a-z_]+)\s+AS\s+ENUM\s*\(([^)]*)\)", sql, re.I
    ):
        values[name] |= set(re.findall(r"'([^']+)'", body))
    for name, value in re.findall(
        r"ALTER\s+TYPE\s+(?:public\.)?([a-z_]+)\s+ADD\s+VALUE\s+'([^']+)'", sql, re.I
    ):
        values[name].add(value)
    return dict(values)


def enum_has_create(sql: str, name: str) -> bool:
    """Only a CREATE TYPE makes the migration record for an enum complete."""
    return bool(re.search(rf"CREATE\s+TYPE\s+(?:public\.)?{name}\s+AS\s+ENUM", sql, re.I))


def sql_identifiers(sql: str) -> set[str]:
    """Every snake_case identifier the migrations mention.

    Deliberately over-broad: any token appearing anywhere in the SQL counts as evidence
    the column exists. A loose filter keeps UNVERIFIED small and honest -- it is better
    to under-report unverified keys than to cry wolf about columns that plainly exist.
    """
    return set(re.findall(r"\b([a-z][a-z0-9]*(?:_[a-z0-9]+)+)\b", sql))


def swift_models() -> dict[str, list[tuple[str, str]]]:
    """file -> [(swift case name, wire key)] for every CodingKeys block."""
    result: dict[str, list[tuple[str, str]]] = {}
    for path in sorted(MODELS.glob("*.swift")):
        text = path.read_text(encoding="utf-8", errors="ignore")
        keys: list[tuple[str, str]] = []
        # Slice out each `enum CodingKeys ... {` block by brace depth.
        for match in re.finditer(r"enum\s+CodingKeys\s*:\s*String\s*,\s*CodingKey\s*\{", text):
            depth, i = 1, match.end()
            while i < len(text) and depth:
                depth += (text[i] == "{") - (text[i] == "}")
                i += 1
            for name, raw in SWIFT_CASE.findall(text[match.end():i]):
                keys.append((name, raw or name))
        if keys:
            result[path.name] = keys
    return result


def swift_string_enums() -> dict[str, tuple[str, set[str]]]:
    """Swift enum name -> (file, raw values). Skips CodingKeys helper enums."""
    result: dict[str, tuple[str, set[str]]] = {}
    for path in sorted(MODELS.glob("*.swift")):
        text = path.read_text(encoding="utf-8", errors="ignore")
        for match in SWIFT_ENUM.finditer(text):
            name = match.group(1)
            if name == "CodingKeys":
                continue
            depth, i = 0, match.end()
            while i < len(text):
                if text[i] == "{":
                    depth += 1
                elif text[i] == "}":
                    depth -= 1
                    if depth == 0:
                        break
                i += 1
            values = {raw or n for n, raw in SWIFT_CASE.findall(text[match.end():i])}
            if values:
                result[name] = (path.name, values)
    return result


# Swift enum -> Postgres enum. Only pairs listed here are checked; an unmapped Swift
# enum is a client-side concept with no database counterpart.
ENUM_MAP = {
    "OrderStatus": "order_status",
    "UserRole": "user_role",
    "CourierStatus": "courier_status",
    "DeliveryMode": "delivery_mode",
    "ChatRole": "sender_role",
    "RestaurantStatus": "restaurant_status",
}


def main() -> int:
    sql = read_migrations()
    identifiers = sql_identifiers(sql)
    pg_enums = enum_values(sql)
    drift: list[str] = []
    unverified: list[str] = []

    # --- 1. Enum parity -----------------------------------------------------
    for swift_name, (file, swift_values) in swift_string_enums().items():
        pg_name = ENUM_MAP.get(swift_name)
        if pg_name is None:
            continue
        pg_values = pg_enums.get(pg_name, set())
        complete = enum_has_create(sql, pg_name)
        missing = sorted(swift_values - pg_values)
        extra = sorted(pg_values - swift_values)

        if extra:
            drift.append(
                f"DRIFT  {file}: Postgres enum {pg_name} has value(s) "
                f"{extra} that Swift {swift_name} cannot decode -> decode failure on "
                f"any row using them"
            )
        if missing:
            tier = drift if complete else unverified
            label = "DRIFT " if complete else "UNVERIF"
            tier.append(
                f"{label} {file}: Swift {swift_name} declares {missing} not proven by "
                f"any migration for {pg_name}"
                + ("" if complete else "  (no CREATE TYPE -- enum was dashboard-created)")
            )

    # --- 2. CodingKeys without a backing column ----------------------------
    for file, keys in swift_models().items():
        absent = sorted({wire for _, wire in keys if wire not in identifiers and "_" in wire})
        if absent:
            unverified.append(
                f"UNVERIF {file}: wire key(s) {absent} appear in no migration"
            )

    # --- report -------------------------------------------------------------
    print(f"schema drift check: {len(swift_models())} model files, "
          f"{len(list(MIGRATIONS.glob('*.sql')))} migrations\n")
    for line in drift:
        print(f"  {line}")
    if drift and unverified:
        print()
    for line in unverified:
        print(f"  {line}")

    print(f"\n{len(drift)} drift, {len(unverified)} unverified")
    if drift:
        print("\nDrift is provable from the repo and fails the build.", file=sys.stderr)
        return 1
    if unverified:
        print("Unverified findings need a live introspection run; not failing the build.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
