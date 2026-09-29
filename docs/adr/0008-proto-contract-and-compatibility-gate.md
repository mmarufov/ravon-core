# 0008 — The `.proto` files are the contract, and a gate enforces it

**Status:** Accepted · 2026-09-29
**Scope:** `proto/`, `.github/workflows/ci.yml` (`proto-contract`), `services/proto`

## Context

Ravon's clients are three shipped iOS apps. They have **no forced-upgrade mechanism** —
an old build keeps calling the server for as long as it stays installed. That single fact
decides most of this ADR.

Before now the client/server contract was Swift `CodingKeys` matched by hand against SQL
column names, with `scripts/schema_drift.py` trying to catch the mismatches after the
fact. That tool is worth keeping, but it is a *detector*, and it was itself blind to 14%
of the schema until recently. A detector that runs after you have written the mismatch is
strictly weaker than a representation in which the mismatch is unwriteable.

## Decision

**`proto/` at the repository root is the single source of truth for every cross-process
type**, and CI runs `buf lint` plus `buf breaking` against `main` on every PR.

Layout is `ravon/<module>/v1/`, with shared types in `ravon/common/v1/`. `OrderStatus`
has 17 values and will be used by two modules; duplicating it is precisely how the
8-edge divergence between `OrderLifecycle.swift` and migrations 13/14/16 happened.

Breaking category is **`FILE`** — the strictest useful setting. It rejects field
renumbering, deleting or retyping a field, renaming an enum value, removing an RPC, and
moving a message between files. Adding fields, RPCs and enum values stays allowed.

### The v1 → v2 rule

Never, unless a field's *meaning* changes. Because clients cannot be forced to upgrade,
the day a `v2` exists `v1` must be served alongside it indefinitely. The gate's purpose is
to make sure that day never arrives by accident rather than to make it convenient.

## Three decisions inside the contract worth their own note

**Money is `int64` minor units**, not `double` and not `google.type.Money`. This is not
stylistic. The fleet's current `Double` path *silently destroys stored money*: the
merchant price editor seeds from `String(Int(item.price))` and posts the field back
unconditionally, so an item stored at 99.50 becomes 99.00 the moment a merchant opens the
sheet to toggle availability and saves — and because every money input is a `.numberPad`
with no decimal separator, they cannot type the 50 diram back. `google.type.Money` loses
for the same class of reason: its units/nanos split invites the same rounding divergence
the fleet already has three versions of.

**Errors are `Reason` + `ErrorDetail`, carried in `google.rpc.Status.details`.** The
enum is the 29 distinct `DETAIL.reason` strings the SQL layer raises, with three fixes:
the two spellings of cancel-after-pickup collapse into one; `RESTAURANT_CLOSED` splits
out its row-not-found case (`04_create_order_v3…:153` conflates "no such restaurant" with
"closed"); and the tip and stock reasons the Swift decoder never covered are added. The
structured fields matter more than the enum: the old decoder regex-matched
`"reason":"([A-Z_]+)"` and discarded every sibling key, which is why the consumer's
entirely reasonable ask — "tell me the tip cap so I can show it" — was unimplementable.

**`now` is a request field on `Assign`, not the server clock.** The cost model is a pure
function of `(couriers, orders, now)`. Making the clock explicit means any production
assignment can be replayed exactly; a server-read clock would make that impossible, and
reproducibility is the property the whole dispatch verification rests on.

## Proof the gate works

A gate nobody has watched fail should not be trusted. This repository has direct evidence
for that: the `schema-drift` CI job was structurally incapable of passing from the day it
was written — it read a gitignored directory — and nobody noticed for months because CI
had never run at all.

So, measured against `HEAD` with `buf` 1.73.0:

| Change | Result |
|---|---|
| unchanged | exit **0** |
| renumber `Assignment.cost_minutes` 3 → 7 | exit **100**, `Previously present field "3" with name "cost_minutes" on message "Assignment" was deleted.` |
| delete `OrderOffer.haul_km` | exit **100**, field-deleted error |
| **add** `OrderOffer.pickup_note = 8` | exit **0** — additive changes stay allowed |

Exit 100 is what makes the CI step fail; a gate that printed warnings and exited 0 would
be decorative.

## Consequences

- Generated Kotlin is built by Gradle rather than committed, because the JVM build always
  has the toolchain. The **Swift** side will check its generated code in, so `protoc`
  never enters three Xcode builds — see ADR 0009.
- `buf` becomes a CI dependency. Mitigated by `bufbuild/buf-action`, which pins and
  installs it.
- On the PR that introduces `proto/` there is no baseline on `main`, so the breaking step
  reports a notice and skips. Every subsequent PR is checked. This is stated explicitly in
  the workflow rather than left as a silent pass.

## Alternatives considered

**A checked-in JSON Schema or OpenAPI document.** Rejected: neither generates a typed
Swift client, and the problem being solved is precisely hand-maintained client types.

**BSR (Buf Schema Registry) as the breaking baseline.** Rejected for now: one repo, one
source of truth, no hosted dependency, and `--against '.git#branch=main'` makes the diff
reviewable in the PR that causes it. Worth revisiting if a second repo ever consumes the
contract.

**Custom `ServiceOptions` declaring timeouts and retry policy in the `.proto`,** read by
the client via reflection — a real DoorDash pattern, proposed in
`10-POLYGLOT-RESTRUCTURE.md`. Rejected as premature: one service, three clients that all
share one Swift wrapper, so the timeouts already live in one place. Revisit when a second
client language appears.
