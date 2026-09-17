# Dispatch engine — portable specification, verified empirically

**Target:** a Kotlin reimplementation that (a) serves the `Assign` RPC, (b) carries the
simulator across as its test harness, (c) can be held to the numbers the Swift version
produces today.

**Source of record (all paths absolute):**

| File | Lines | mtime (2026-09-16) |
|---|---|---|
| `/Users/mmarufov/conductor/workspaces/ravon-core/bucharest/Sources/RavonCore/Dispatch/Geo.swift` | 30 | 00:33 |
| `…/Dispatch/HungarianSolver.swift` | 118 | 00:33 |
| `…/Dispatch/Dispatcher.swift` | 214 | 00:34 |
| `…/Dispatch/DispatchZone.swift` | 116 | 11:29 |
| `…/Dispatch/SwitchbackExperiment.swift` | 275 | 11:28 |
| `…/Dispatch/MarketplaceSimulator.swift` | 455 | 11:40 |
| **total** | **1208** | — |

Tests: `…/Tests/RavonCoreTests/HungarianSolverTests.swift` (146 lines, 7 tests, mtime 00:34),
`…/DispatchSimulationTests.swift` (**mtime 16:54 — edited by a concurrent agent during this
pass**, 7 tests), `…/SwitchbackExperimentTests.swift` (158 lines, 7 tests, mtime 11:30).
All three are **untracked** in git, as is `Sources/RavonCore/Dispatch/`.

## 0. Method — what was read vs what was executed

Everything below marked **[measured]** was produced by compiling the six source files
verbatim (`swiftc -O`, Apple Swift 6.3.3, arm64-apple-macosx26.0) together with a probe
`main.swift` and running the binary. Probe sources and outputs are retained:

- `/Users/mmarufov/conductor/workspaces/ravon-core/bucharest/.context/research/_scratch/ds2/main.swift` + `run1.txt` — effect size vs bias per division, naive-design repeat runs, block-lag instrumentation, solver matrix shapes, attribution, golden vectors
- `…/_scratch/ds2/p2/main.swift` + `out.txt` — arm-hash structure, decision-time counterfactual, arm balance
- `…/_scratch/ds2/p3/main.swift` + `out1.txt`/`out2.txt`/`out3.txt` — cross-process determinism, epoch-mismatch trap, solver edge cases, cost-model golden values
- `…/_scratch/ds2/p5/main.swift` — matched-subset delivery comparison, p95 tail, solver performance
- `…/_scratch/ds2/p6/main.swift` — a **Kotlin-portable reimplementation of world generation** proved bit-identical to the Swift simulator

Pre-existing probes from an earlier pass (read, re-run, and built on, not duplicated):
`…/_scratch/dispatch-spec/{rng,tie,det,bench,zoned,sb,perturb}/` and
`…/_scratch/dispatch-baseline-seeds-1-30.json`.

Prior research read and built on: `arch-docs-constraints.md` §3–§4 (provenance of the
measured numbers and the harness interface) and `app-courier-constraints.md` §1 (the offer
feed the service must replace). Corrections to both are in §12.

---

## 1. Executive answer, up front

1. **The solver is fully portable and bit-reproducible.** Jonker–Volgenant/Hungarian with
   potentials, deterministic, ties broken by lowest column index. A Kotlin port with the
   same loop order produces **identical** assignments for identical input matrices.
   Verified against a 2000-matrix fingerprint (§3.6).
2. **The *simulator* is portable in principle and fragile in practice.** Its RNG is
   SplitMix64 — trivially portable — but every draw goes through Swift stdlib's
   `Double.random`/`Int.random` mapping, which is **three different algorithms** depending
   on the range type (§6.3). I reimplemented all of them from portable primitives and
   proved the whole world-generation path bit-identical over 30 seeds × 240 orders
   (§6.4). **[measured]** So the RNG is *not* the port risk people assume.
3. **The real port risk is `libm`.** Perturbing Haversine by `×(1 + 1e-15)` (≈4.5 ulp, the
   size of a `sin`/`atan2` difference between Darwin libm and JVM `Math`) changes
   `ordersAssigned` on **11 of 30 seeds**, by up to ±2 orders. **[measured, §9.1]** The
   30-seed baseline JSON is therefore **not** a bit-for-bit acceptance oracle, contrary to
   the comment at the top of `…/_scratch/main.swift`. Mitigation in §9.1.
4. **The headline `+44.6%` is not lookahead.** A courier-centric greedy with **no
   bipartite lookahead at all** captures `+43.4%` of the `+44.4%`; the Hungarian adds
   `+0.7%`. **[measured, §5.4]** The win is the *order-selection policy* (cost-minimising
   instead of strict FCFS), and the source comments attribute it to the wrong mechanism.
5. **`ZonedDispatcher` at 3×3 destroys the simulated marketplace** — mean 13.4 of 240
   orders assigned, 7.1 of 12 couriers idle all shift. **[measured, §5.3]** The
   "10× bias collapse" headline is the *treatment effect* collapsing by 10×, not the
   estimator improving: relative bias `|bias|/|truth|` is **1.06 at 1×1 and 1.72 at 3×3**
   — it gets *worse*. **[measured, §8.3]** In all three partitions the bias exceeds the
   effect being measured.
6. **The switchback is not randomised.** `cellArm` is a deterministic alternating
   crossover: the 3×3 arm pattern in block *b* is the exact complement of block *b+1* in
   **0 violations out of 904,500 cells** tested, and only **3 distinct patterns** occur
   across 100,000 even blocks. **[measured, §7.3]** Effective randomisation units ≈ 1
   (one pattern per salt), not zones × blocks.
7. **`ArmAssignment.naiveOrderLevel` is not reproducible across processes** — it hashes
   `UUID()`, which is *not* seeded. Same binary, same seed, two runs: naive bias
   `−2.33` vs `−0.67` vs `+0.79`. **[measured, §7.4]** One shipped test depends on it.

---

## 2. `Geo.swift` — geodesy

### 2.1 Public API

```swift
public struct GeoPoint: Sendable, Hashable, Codable {
    public let latitude: Double
    public let longitude: Double
    public init(latitude: Double, longitude: Double)
    public func distanceKm(to other: GeoPoint) -> Double
}
```

Kotlin: `data class GeoPoint(val latitude: Double, val longitude: Double)`. `Codable`
synthesises keys `latitude`/`longitude` — wire names to preserve if it is ever serialised.

### 2.2 Algorithm (`Geo.swift:19-29`)

Haversine, **`earthRadiusKm = 6371.0088`** (`Geo.swift:20` — the IUGG mean radius, not
6371.0):

```
dLat = (lat2 - lat1) * π/180
dLon = (lon2 - lon1) * π/180
a    = sin²(dLat/2) + sin²(dLon/2)·cos(lat1·π/180)·cos(lat2·π/180)
d    = 2 · 6371.0088 · atan2(√a, √(1-a))
```

Note the exact expression form: `sin(x/2)*sin(x/2)`, not `pow(sin(x/2), 2)`, and
`atan2(sqrt(a), sqrt(1-a))` rather than `asin(sqrt(a))`. Both matter for bit-exactness;
reproduce the expression literally.

Units: km. Symmetric. Zero for identical points. No altitude, no road network, no
one-way streets — pure great-circle.

The doc comment (`Geo.swift:15-18`) states the design reason: planar approximation would be
fine in absolute terms but dispatch compares costs *between* candidate pairs, so an
inconsistent bias would silently reorder the matching.

### 2.3 Golden values **[measured]**

| pair | km |
|---|---|
| (38.5598, 68.7870) → (40.2833, 69.6222) [Dushanbe→Khujand] | `204.62980642732833` (bits `0x406994275FCF05F2`) |
| (38.5598, 68.7870) → (38.60, 68.82) | `5.3112916195781148` |
| identical points | `0` exactly |

---

## 3. `HungarianSolver.swift` — the matcher

### 3.1 Public API

```swift
public enum HungarianSolver {
    public static let forbidden = 1e9
    public static func solve(cost: [[Double]]) -> [Int?]
    public static func totalCost(of assignment: [Int?], cost: [[Double]]) -> Double
}
```

`cost[i][j]` = cost of assigning **row i (courier)** to **column j (order)**.
Return: `assignment[i]` = matched column or `nil`.

### 3.2 Variant

Jonker–Volgenant form of the Hungarian algorithm with dual potentials — the classic
"e-maxx" shortest-augmenting-path formulation. One row is added to the alternating tree
per outer iteration; the tree is grown by repeated Dijkstra-style relaxation over reduced
costs `c[i][j] − u[i] − v[j]`; potentials are shifted by `delta` at each expansion so the
tightest edge becomes tight. Complexity `O(n²m)` with `n` = rows, `m` = padded columns.
The complexity claim is a source comment (`HungarianSolver.swift:4`), not measured; the
*optimality* is measured against brute force.

State (`HungarianSolver.swift:49-52`), all 1-indexed with index 0 as a sentinel:
- `u[0…n]` row potentials, `v[0…m]` column potentials
- `p[j]` = row currently matched to column `j`; `p[0]` is the scratch slot holding the row being inserted
- `way[j]` = predecessor column on the alternating path

Loop structure, verbatim semantics (`HungarianSolver.swift:54-95`):

```
for i in 1...n:
    p[0] = i;  j0 = 0
    minv[0…m] = +∞;  used[0…m] = false
    repeat:
        used[j0] = true;  i0 = p[j0];  delta = +∞;  j1 = 0
        for j in 1...m where !used[j]:
            cur = matrix[i0][j] - u[i0] - v[j]
            if cur < minv[j]:  minv[j] = cur;  way[j] = j0
            if minv[j] < delta:  delta = minv[j];  j1 = j
        for j in 0...m:
            if used[j]:  u[p[j]] += delta;  v[j] -= delta
            else:        minv[j] -= delta
        j0 = j1
    while p[j0] != 0
    repeat:  j1 = way[j0];  p[j0] = p[j1];  j0 = j1  while j0 != 0
```

Then extraction (`:97-105`): walk `j = 1…m`, take `row = p[j]`; skip if
`row < 1 || row > rowCount` (dummy row 0), skip if `column >= columnCount` (dummy column),
skip if `cost[row-1][column] >= forbidden`; else `result[row-1] = column`.

### 3.3 Rectangular padding — exact rule

`HungarianSolver.swift:33-45`. The algorithm requires `rows ≤ columns`.

```
paddedColumns = max(rowCount, columnCount)
matrix[i+1][j+1] = (j < columnCount) ? cost[i][j] : 0        for i in 0..<rowCount, j in 0..<paddedColumns
```

- Dummy columns carry **cost 0**, not `+∞` and not `forbidden`.
- Rows are **never** padded. If `rows > columns`, the surplus rows are absorbed by the
  zero-cost dummies and returned as `nil`.
- Zero-cost dummies interact with the negative real costs the model can produce (§4.4):
  a row whose only real option costs `+3` will *prefer* a dummy (0) and come back `nil`
  only if that is globally cheaper. **This is correct behaviour for surplus couriers but is
  a semantic the port must not "improve".** Verified: `[[5.0],[3.0],[9.0]]` → `[nil, 0, nil]`
  — the cheapest row takes the only real column. **[measured]**

`guard rowCount > 0, let firstRow = cost.first, !firstRow.isEmpty else { return [] }`
(`:30`). Consequences, both verified **[measured]**:
- `solve([])` → `[]` (count 0)
- `solve([[]])` → `[]` (count **0**, not 1) — **the return length does not equal `rowCount`
  for a 1×0 input.** Callers that zip the result with the courier array will silently
  under-iterate. `HungarianSolverTests.swift:131-134` asserts only `isEmpty`, so the
  inconsistency is enshrined.
- **A ragged matrix traps** (`exit 133`, index-out-of-range at `:43`). The doc comment
  says "Must be rectangular" (`:22`); there is no `precondition`. A Kotlin port over
  `Array<DoubleArray>` should either validate or use a flat `DoubleArray` + stride.

### 3.4 Infeasible pairs — encoding

`public static let forbidden = 1e9` (`:17`). A forbidden pair is a **finite large cost**,
not `+∞` and not a null.

Three places enforce it:
1. `DispatchCostModel.cost` returns exactly `1e9` for excluded/out-of-range pairs (`Dispatcher.swift:107-111`).
2. `HungarianSolver.solve` drops any selected pair with `cost >= forbidden` at extraction (`:103`).
3. `OptimalBatchDispatcher` re-checks `cost < forbidden` after solving (`Dispatcher.swift:203`).

**The property this buys, and its precondition.** The solver minimises total cost *including*
`1e9` entries, then discards them. It therefore maximises the number of feasible pairs
**only if** every real cost satisfies `|c| ≪ 1e9 / min(n,m)`. With the shipped cost model
real costs lie in roughly `[−50, +95]` minutes (§4.4), so for any plausible batch the
`k·1e9` term dominates and the solver does maximise feasible cardinality first. **That
invariant is load-bearing and undocumented.** If a Kotlin port ever scales the cost to,
say, seconds × 10⁶, it silently breaks.

Verified consequences **[measured]**:
- `[[1e9, 4], [2, 1e9]]` → `[1, 0]` — feasible pairs chosen.
- `[[1e9, 1e9], [1, 2]]` → `[nil, 0]` — a fully forbidden row comes back `nil`.
- `[[1e9]]` → `[nil]` — better to leave the order unassigned than dispatch a banned courier (`HungarianSolverTests.swift:127-128`).
- `[[5, 1e9], [1, 1e8]]` → `[0, 1]`, total `1.00000005e8`. **A cost of `1e8` is "merely expensive" and *is* assigned.** `forbidden` is a threshold, not a magnitude — any value below `1e9` is dispatchable.

### 3.5 Exact tie-breaking rule

Two strict comparisons decide everything (`HungarianSolver.swift:68` and `:72`):

```
if cur < minv[j]   { minv[j] = cur; way[j] = j0 }   // strict — first j0 to achieve the min keeps the predecessor
if minv[j] < delta { delta = minv[j]; j1 = j }      // strict — lowest column index j wins a tie on delta
```

Because the inner loop scans `j = 1…m` ascending and both comparisons are strict `<`:

> **Tie-break rule: among columns achieving the minimum reduced cost, the one with the
> lowest column index wins; among tree columns achieving the same `minv`, the predecessor
> recorded is the earliest `j0` that achieved it.**

Rows are processed in ascending index order `i = 1…n`, so earlier rows are inserted first
and their choices constrain later rows.

Observed consequences **[measured]**:

| matrix | result | reading |
|---|---|---|
| `[[1,1],[1,1]]` | `[0, 1]` | identity on the diagonal |
| `[[5,5,5],[5,5,5],[5,5,5]]` | `[0, 1, 2]` | identity |
| `[[2,2,2]]` | `[0]` | lowest column |
| `[[2],[2],[2]]` | `[nil, nil, 0]` | **the *last* row wins**, not the first |
| `[[3],[3]]` | `[nil, 0]` | last row again |
| `[[1,3],[1,3]]` | `[0, 1]` | |
| `[[-5,-1],[-1,-5]]` | `[0, 1]` | negatives handled |

The "last row wins a tie for a scarce column" behaviour falls out of the augmentation
order (each new row steals the column and pushes the previous occupant onto a dummy). It
is stable and reproducible but **not** the rule anyone would guess, and it is what makes
naïve "port and compare" fail if the loop bounds are changed.

### 3.6 Determinism verdict

**Deterministic. A Kotlin port can produce IDENTICAL assignments** for identical input
matrices, provided it preserves: 1-based indexing with the 0 sentinel, ascending `j` scan,
both strict `<` comparisons, the `for j in 0...m` potential update including `j = 0`, and
the extraction order `j = 1…m`.

Acceptance oracle **[measured]**: over 2000 random matrices (rows 1…8 × cols 1…8, costs
`Double.random(in: -10...10)` from SplitMix64 state 99, ties and negatives present), the
FNV-1a fingerprint of the concatenated assignment vector (`nil` encoded as `-1`) is

```
0x67C6ECE6FD13637C
```

Reproducing that constant in Kotlin proves solver + RNG mapping together. Probe:
`…/_scratch/dispatch-spec/tie/main.swift`.

### 3.7 Performance **[measured]** (`-O`, arm64, cold)

| rows × cols | time | matched |
|---|---|---|
| 12 × 120 | 0.01 ms | 12 |
| 50 × 500 | 0.11 ms | 50 |
| 100 × 1000 | 0.37 ms | 100 |
| 200 × 2000 | 1.56 ms | 200 |
| 500 × 500 | 12.15 ms | 500 |

Inside the simulator (seed 7, 12 couriers) the shapes actually seen are **rows mean 1.45,
max 12; columns mean 76.9, max 120**, over 143 solver invocations; only **7 invocations
(4.9%)** had `rows > cols` and needed dummy-column padding. **[measured]** So the padding
branch is barely exercised by the existing tests — a port bug there would not be caught.

Budget conclusion: the solver is free at any realistic Dushanbe scale. A per-zone
sub-10 ms assignment tick is comfortable even at 200 couriers × 2000 orders.

---

## 4. `Dispatcher.swift` — types, cost model, two dispatchers

### 4.1 Input/output types

```swift
public struct DispatchCourier: Sendable, Identifiable, Hashable {
    public let id: UUID
    public let location: GeoPoint
    public let idleSince: Date          // last delivery finished, or came online
    public let excludedOrderIDs: Set<UUID>
    public init(id:location:idleSince:excludedOrderIDs: = [])
}

public struct DispatchOrder: Sendable, Identifiable, Hashable {
    public let id: UUID
    public let pickup: GeoPoint
    public let dropoff: GeoPoint
    public let readyAt: Date            // kitchen's QUOTED ready time
    public let createdAt: Date
    public let excludedCourierIDs: Set<UUID>
    public init(id:pickup:dropoff:readyAt:createdAt:excludedCourierIDs: = [])
}

public struct Assignment: Sendable, Hashable {
    public let courierID: UUID
    public let orderID: UUID
    public let cost: Double             // minutes, can be negative
}

public protocol Dispatcher: Sendable {
    var name: String { get }
    func assign(couriers: [DispatchCourier], orders: [DispatchOrder], now: Date) -> [Assignment]
}
```

**Exclusion is bidirectional and both directions are checked.** `courier.excludedOrderIDs`
and `order.excludedCourierIDs` are independent sets; either one forbids the pair
(`Dispatcher.swift:107-108`). Today only the order→courier direction has a database home
(`orders.excluded_courier_ids uuid[]`, `db/migrations/11_reassignment_columns.sql:6`);
the courier→order direction has no persistence anywhere.

**`Dispatcher` is a protocol, not a sealed hierarchy, and two of the four conformances are
decorators** (`ZonedDispatcher` over `any Dispatcher`, `ExperimentDispatcher` over two).
A Kotlin `sealed interface` would break the composition that makes the experiment study
cheap. Use a plain `fun interface`/`interface`.

### 4.2 `DispatchCostModel` — every term, weight, unit

```swift
public struct DispatchCostModel: Sendable {
    public var averageSpeedKmh: Double          = 18
    public var maxAssignmentRadiusKm: Double    = 8
    public var orderAgeCreditPerMinute: Double  = 1.5
    public var courierIdleCreditPerMinute: Double = 0.4
    public var maxCreditMinutes: Double         = 25
    public static let distanceOnly = DispatchCostModel(orderAgeCreditPerMinute: 0, courierIdleCreditPerMinute: 0)
    public func travelMinutes(km: Double) -> Double   // km / kmh * 60; +∞ if speed <= 0
    public func cost(courier:order:now:) -> Double
}
```

`cost` (`Dispatcher.swift:106-131`), in evaluation order:

| step | expression | unit | notes |
|---|---|---|---|
| 1 | `courier.excludedOrderIDs.contains(order.id)` → `1e9` | — | hard gate |
| 2 | `order.excludedCourierIDs.contains(courier.id)` → `1e9` | — | hard gate |
| 3 | `toPickupKm = courier.location.distanceKm(to: order.pickup)`; `> 8` → `1e9` | km | **strict `>`**; exactly 8.0 km is allowed |
| 4 | `toPickup = toPickupKm / 18 * 60` | min | 3.3333… min/km |
| 5 | `deliveryLeg = distanceKm(pickup→dropoff) / 18 * 60` | min | same nominal speed |
| 6 | `arrival = now + toPickup·60`; `waitAtRestaurant = max(0, (order.readyAt − arrival)/60)` | min | courier idling at the counter |
| 7 | `orderAgeMinutes = max(0, (now − order.createdAt)/60)` | min | |
| 8 | `courierIdleMinutes = max(0, (now − courier.idleSince)/60)` | min | |
| 9 | `urgencyCredit  = min(orderAgeMinutes × 1.5, 25)` | min | capped **independently** |
| 10 | `fairnessCredit = min(courierIdleMinutes × 0.4, 25)` | min | capped **independently** |
| **=** | `toPickup + waitAtRestaurant + deliveryLeg − urgencyCredit − fairnessCredit` | **min** | may be negative |

Everything is in **minutes**. There is no money term, no courier rating, no batching
(order-stacking) term, no traffic term, no vehicle type. The only geometry is two
great-circle legs; the return trip is not modelled.

Saturation points worth knowing: urgency saturates at **16⅔ min** of order age; fairness
saturates at **62.5 min** of courier idleness. Once both are saturated the pair costs
`travel − 50`, i.e. a courier idle for an hour looking at an order 20 minutes old gets a
50-minute head start over a fresh pair — which is larger than the entire travel term can
ever be inside an 8 km radius (26.67 min). **The credits can therefore dominate geometry
entirely.**

`distanceOnly` is declared for use as the experiment control (`Dispatcher.swift:91-95`) and
is referenced **nowhere else in `Sources/` or `Tests/`**. I ran it: seed 42, 12 couriers,
`optimal-batch` assigns **157** with `distanceOnly` vs **162** with credits; gini **0.026**
vs **0.063**; greedy is **115 either way** (its per-order argmin is unaffected by the
order-age credit, which is constant across couriers for a given order). **[measured]** So
the credits buy +5 orders and *worsen* the fairness metric they were introduced to
improve — the opposite of the story in `05-DISPATCH-ENGINE.md:30-35`.

Golden cost values **[measured]**, courier at (38.5598, 68.7870), `now = 1_700_000_000`:

| scenario | cost (min) |
|---|---|
| same point, ready now, new order, idle 0 | `0` |
| same point, ready in 30 min | `30` |
| same point, order age 60 min | `-25` |
| same point, courier idle 120 min | `-25` |
| both credits saturated | `-50` |
| pickup 5.311 km away, 2.98 km haul, ready now | `27.113113080604059` |
| pickup ~9 km away | `1000000000` |
| `travelMinutes(1)` / `travelMinutes(8)` | `3.333333333333333` / `26.666666666666664` |

### 4.3 `GreedyDispatcher` — `name = "greedy-fcfs"`

`Dispatcher.swift:145-174`. Algorithm:

```
available = couriers                                  (input order preserved)
for order in orders.sorted(by: createdAt ascending):  (Swift sort — unstable, but keys are distinct)
    best = argmin over available of cost(courier, order, now), skipping cost >= 1e9
           ties: FIRST index wins (strict `<` at :164)
    if none: order waits (no assignment emitted)
    else: remove that courier from `available` and emit Assignment(courier, order, bestCost)
```

Each courier serves at most one order per tick; each order at most one courier. Emission
order = order-creation order.

**What it claims to be vs what it is.** The doc comment (`:139-144`) says this models
production "faithfully". It does not: production has no cost model at all — the SQL is a
radius filter plus `ORDER BY created_at` and the courier self-selects
(`app-courier-constraints.md` §1). `GreedyDispatcher` defaults to the *same credit-bearing*
cost model as the optimiser (`:149`), which makes it a cleaner experiment (one independent
variable) but means "+44.6% vs what Ravon does today" is not the comparison being run. The
honest framing is "+44.6% from changing order selection, holding the cost model constant".

### 4.4 `OptimalBatchDispatcher` — `name = "optimal-batch"`

`Dispatcher.swift:181-213`.

```
guard couriers and orders both non-empty
matrix[i][j] = costModel.cost(couriers[i], orders[j], now)      // rows = couriers, cols = orders
matching = HungarianSolver.solve(cost: matrix)
for (i, j) in matching.enumerated() where j != nil && matrix[i][j] < 1e9:
    emit Assignment(couriers[i].id, orders[j].id, matrix[i][j])
```

Emission order = courier input order. **Orders are NOT sorted here** — column index is the
caller's array order, which inside the simulator is `orders.indices.filter{…}`, i.e.
created-at ascending. A Kotlin port that reorders the order array changes tie outcomes.

---

## 5. `DispatchZone.swift` — partitioning

### 5.1 Public API

```swift
public struct DispatchZone: Sendable, Hashable, Codable, CustomStringConvertible {
    public let row: Int
    public let column: Int
    public var description: String { "z\(row)-\(column)" }
}

public struct ZoneGrid: Sendable {
    public let center: GeoPoint
    public let radiusKm: Double
    public let divisions: Int                     // init clamps to max(1, divisions), default 3
    public func zone(for point: GeoPoint) -> DispatchZone
    public var allZones: [DispatchZone]           // row-major, divisions² entries
}

public struct ZonedDispatcher: Dispatcher {
    public let name: String                       // "zoned[\(base.name)]"
    public let base: any Dispatcher
    public let grid: ZoneGrid
}
```

### 5.2 Partitioning rule and parameters (`DispatchZone.swift:44-62`)

```
latSpanDegrees = radiusKm / 111.0
cosLat         = cos(center.latitude · π/180)
lonSpanDegrees = radiusKm / (111.0 · (|cosLat| < 1e-9 ? 1 : cosLat))

latFraction = (lat - (center.lat - latSpan)) / (2·latSpan)
lonFraction = (lon - (center.lon - lonSpan)) / (2·lonSpan)
bucket(f)   = clamp(floor(f · divisions), 0, divisions - 1)
zone        = DispatchZone(row: bucket(latFraction), column: bucket(lonFraction))
```

- The bounding box is a **square in degrees**, side `2·radiusKm` in each axis — so
  `radiusKm` is a half-width, not a radius: the box is `2r × 2r` km and *circumscribes*
  the `r`-km disk. With `radiusKm = 6` and `divisions = 3` each zone is **4 km × 4 km**.
- `111.0` km/degree is hardcoded — not derived from `earthRadiusKm` (which would give
  111.1949). The zone grid and the distance function use **inconsistent** earth models.
- Longitude scaling uses `cos(center.latitude)`, evaluated once at the grid's centre, not
  per point.
- Out-of-box points **clamp** into the edge zone; there is no "outside" zone. `(89, 179)`
  → `z2-2`, `(-89, -179)` → `z0-0`. **[measured]** Cyclic longitude is not handled:
  a point at longitude `-179` clamps to column 0 rather than wrapping.
- `divisions = 1` makes `ZonedDispatcher` an identity decorator over `base`.
- Golden: for `center = (38.5598, 68.7870)`, `r = 6`, `divisions = 3` — `zone(center) = z1-1`,
  `zone(38.60, 68.82) = z2-2`. **[measured]**

`allZones` is row-major: `z0-0, z0-1, z0-2, z1-0, …` **[measured]**.

### 5.3 `ZonedDispatcher.assign` (`DispatchZone.swift:101-115`)

```
couriersByZone = group(couriers) by grid.zone(for: courier.location)
ordersByZone   = group(orders)   by grid.zone(for: order.pickup)
for (zone, zoneOrders) in ordersByZone:                 // Dictionary order — unstable
    guard couriersByZone[zone] non-empty
    result += base.assign(couriers: thatZone's couriers, orders: zoneOrders, now: now)
```

Two properties to carry over:
- **Order zone = pickup zone**, courier zone = current location zone. Dropoff is irrelevant
  to zoning.
- A zone with orders but no couriers is skipped entirely — an order 200 m across a boundary
  from an idle courier is never offered to them.

Iteration order over the Swift `Dictionary` is unstable across processes, but zones
partition both sides disjointly, so the *set* of assignments is invariant and only the
`[Assignment]` array order varies. Verified: two separate processes produce a byte-identical
`zoned-optimal` fingerprint, and `SWIFT_DETERMINISTIC_HASHING=1` changes nothing. **[measured]**
A Kotlin port must nevertheless treat `[Assignment]` order as meaningless (and must iterate
zones in a fixed order if cross-zone spillover is ever added).

### 5.4 The measured cost of partitioning **[measured]** — seeds 1…12, 12 couriers, 240 orders

| divisions | zoned-greedy assigned | zoned-optimal assigned | couriers idle all shift |
|---|---|---|---|
| 1 (identity) | 114.8 / 240 | 164.0 / 240 | 0.0 / 12 |
| 2 (2×2, 6 km cells) | 58.5 / 240 | 69.3 / 240 | 3.1 / 12 |
| 3 (3×3, 4 km cells) | **7.8 / 240** | **12.5 / 240** | **7.2 / 12** |

Seeds 1…20 agree (8.8 / 13.4 assigned at 3×3, 7.1 idle).

Mechanism, verified: restaurants are drawn within `cityRadiusKm × 0.5 = 3 km` of centre, so
at 3×3 essentially all pickups land in two zones (seed 7: `z1-1 = 201` orders, `z0-1 = 39`,
zero in the other seven). Couriers are drawn uniformly over the 6 km disk and, after each
delivery, are **teleported to the dropoff** and never move again unless assigned
(`MarketplaceSimulator.swift:382`). The fleet therefore drains out of the two restaurant
zones and stays out. Seed 7, 3×3: `jobsPerCourier = [0,0,0,0,0,0,1,1,0,0,1,0]` — **3 jobs
in a 4½-hour simulated shift.**

> **This is the single most important caveat on §7–§8. Every switchback number measured at
> `divisions: 3` describes a marketplace that has effectively stopped functioning.**

---

## 6. `MarketplaceSimulator.swift` — the harness

### 6.1 Public API

```swift
public struct MarketplaceSimulator: Sendable {
    struct SeededRNG: RandomNumberGenerator { … }        // INTERNAL — not public
    public struct LatentVariability: Sendable { … }       // 5 fields; .none, .realistic
    public struct Config: Sendable { … }                  // 9 fields
    public struct OrderRecord: Sendable, Hashable { … }    // 12 stored + 3 computed
    public struct Result: Sendable { … }                   // 12 stored + 2 computed
    public static func run(config: Config, dispatcher: any Dispatcher) -> Result
}
```

`Config` (`:99-119`) defaults: `seed = 42`, `courierCount = 12`, `orderCount = 240`,
`durationMinutes = 180`, `dispatchIntervalSeconds = 30`,
`cityCenter = GeoPoint(38.5598, 68.7870)`, `cityRadiusKm = 6`, `prepMinutesRange = 8...25`,
`latent = .none`.

`LatentVariability` (`:42-83`): `restaurantPrepBiasSigmaMinutes`, `prepNoiseSigmaMinutes`,
`courierSpeedSpread`, `trafficAmplitude`, `trafficPeriodMinutes = 90`.
`.none = (0,0,0,0)`; `.realistic = (4, 3, 0.30, 0.35)`. **Every dispatch test uses `.none`.**

### 6.2 Latent state — what the world knows and the model must not

Four hidden quantities (`:28-41` explains the rationale: without them, any predictive model
just re-derives the generating equation and scores R²≈1):

| latent | scope | drawn as | used where |
|---|---|---|---|
| `restaurantPrepBias[r]` | per restaurant, persistent | `Gaussian(0, σ_bias)` | added to every order's true prep (`:299`) |
| per-order prep noise | per order | `Gaussian(0, σ_noise)` | `:300` |
| `speedFactor[c]` | per courier, persistent | `max(0.3, Gaussian(1, σ_speed))` | divides travel time (`:368`) |
| `trafficMultiplier(t)` | city-wide, time-varying | `1 + A·(1 − cos(2πt/P))/2`, `A = amplitude`, `P = 90 min` | multiplies travel time (`:368`) |

Observable vs latent split on `OrderRecord`:
- **observable** (legitimate features): `restaurantIndex`, `haulKm`, `quotedPrepMinutes`,
  `freeCouriersAtCreation`, `pendingOrdersAtCreation`, `hourOfDay`
- **latent truth** (validation only): `latentTrafficMultiplier`, `latentCourierSpeedFactor`
- **outcomes**: `createdAtMinutes`, `assignedAtMinutes?`, `deliveredAtMinutes?`

**Three defects in this split, all verified:**
1. `freeCouriersAtCreation` and `pendingOrdersAtCreation` are named "at creation" but are
   assigned `freeIndices.count` / `pendingIndices.count` **at the assignment tick**
   (`:380-381`), which is on average 47–86 simulated minutes later. They are therefore
   *post-treatment* variables and using them as features leaks the label. Orders never
   assigned keep the initialiser default `0` (`:222-223`), which is not a missing-value
   marker — it is a plausible value.
2. `hourOfDay = (createdAtMinutes / 60) mod 24` (`:142`), and `createdAtMinutes ∈ [0, 180]`,
   so `hourOfDay ∈ [0, 3)` always. It is not a time of day.
3. `quotedPrepMinutes = quotedReadyAt − createdAt` (`:446`) — a lossy float round-trip of
   the drawn value. Max observed deviation from the drawn `quotedPrep`: **1.42e-14**
   **[measured]**. A port must reproduce the *subtraction*, not store the draw.

### 6.3 The RNG — **PORT RISK, with the exact recipe**

`MarketplaceSimulator.SeededRNG` (`:16-26`) is **SplitMix64**, seeded with the raw seed
(no scrambling):

```
state += 0x9E3779B97F4A7C15
z = state
z = (z xor (z ushr 30)) * 0xBF58476D1CE4E5B9
z = (z xor (z ushr 27)) * 0x94D049BB133111EB
return z xor (z ushr 31)
```

It is **not** `SystemRandomNumberGenerator` (the doc comment at `:14-15` says so explicitly),
and it is **not** an LCG or xorshift. Golden raw stream, `seed = 42` **[measured]**:
`0xBDD732262FEB6E95, 0x28EFE333B266F103, 0x47526757130F9F52, 0x581CE1FF0E4AE394, 0x09BC585A244823F2`.

**The risk is not SplitMix64 — it is the four different stdlib range mappings layered on
top of it.** Verified bit-for-bit against the real stdlib over 6 seeds × 20,000 draws × 6
draw kinds (probe `…/_scratch/dispatch-spec/rng/main.swift`, result `true`):

**(a) `RandomNumberGenerator.next(upperBound:)` — Lemire "nearly divisionless":**
```
fun bounded(ub: ULong): ULong {
    var r = next(); var (hi, lo) = mulFullWidth(r, ub)
    if (lo < ub) { val t = (0UL - ub) % ub; while (lo < t) { r = next(); (hi, lo) = mulFullWidth(r, ub) } }
    return hi
}
```

**(b) `Double.random(in: lo...hi)` — ClosedRange, uses Lemire with `ub = 2^53 + 1`:**
```
rand = bounded((1UL shl 53) + 1UL)
if (rand == (1UL shl 53)) return hi           // the closed endpoint
return (hi - lo) * (rand.toDouble() * 0x1p-53) + lo     // ulpOfOne/2 == 2^-53
```
Rejection threshold `t = 9007199254738945`, i.e. rejection probability ≈ `4.883e-4`
**[measured]** — roughly 1 draw in 2048 consumes a second `next()`. **A port that skips the
rejection loop desynchronises after ~2000 draws.**

**(c) `Double.random(in: lo..<hi)` — Range, does NOT use Lemire; it masks:**
```
do { rand = next() and ((1UL shl 53) - 1UL); r = (hi - lo) * (rand.toDouble() * 0x1p-53) + lo } while (r == hi)
return r
```
The asymmetry between (b) and (c) is real Swift stdlib behaviour and was verified
bit-for-bit. Getting it backwards is the single easiest way to produce a port that "looks
right" and diverges.

**(d) `Int.random(in: lo..<hi)`:** `Int(lo.toULong() + bounded((hi - lo).toULong()))`.
**`Int.random(in: lo...hi)`** (used only in tests): same with `ub = delta + 1`, with a
special case returning raw `next()` when `delta == ULong.MAX`.

Golden derived values, `seed = 42` **[measured]**:
- `Double.random(in: 0...1)` × 5 → `0.74156487877182342, 0.1599103928769201, 0.27860113025513877, 0.34419071652363753, 0.038030168540246212` (bit patterns `0x3FE7BAE644C5FD6E, 0x3FC477F199D93378, 0x3FD1D499D5C4C3E8, 0x3FD607387FC392B8, 0x3FA378B0B4489040`)
- `Double.random(in: 0..<2π)` × 3 → `4.5545033701893196, 3.1195048189344305, 3.6135526258340613`
- `Int.random(in: 0..<6)` × 10 → `[4, 0, 1, 2, 0, 5, 1, 4, 2, 3]`
- `Int.random(in: 1...5)` × 10 → `[4, 1, 2, 2, 1, 5, 2, 5, 2, 4]`

**The exact draw order in `run(config:dispatcher:)`.** Swift evaluates initialiser arguments
left to right, which pins the interleaving:

```
restaurantCount = max(3, courierCount / 2)                       // 12 couriers -> 6
1) for each of restaurantCount:  randomPoint(center, cityRadiusKm * 0.5)      -> closed(0,1), halfOpen(0,2π)
2) for each of restaurantCount:  gaussian(0, σ_prepBias)                       -> 2× closed(0,1)  [ZERO draws if σ == 0]
3) for each of courierCount:     randomPoint(center, cityRadiusKm)             -> closed(0,1), halfOpen(0,2π)
                                 gaussian(1, σ_speed)                          -> 2× closed(0,1)  [ZERO if σ == 0]
4) for each of orderCount:       Int.random(in: 0..<restaurantCount)           -> bounded(restaurantCount)
                                 Double.random(in: 0...durationMinutes)        -> closed
                                 Double.random(in: prepMinutesRange)           -> closed
                                 gaussian(0, σ_prepNoise)                      -> 2× closed(0,1)  [ZERO if σ == 0]
                                 randomPoint(center, cityRadiusKm)  [dropoff]  -> closed, halfOpen
5) orders.sort { createdAt ascending }                                          // no draws
```

**`gaussian` short-circuits on `σ <= 0` and consumes no randomness** (`:246`). With the
default `latent: .none` that removes `2·(restaurantCount + courierCount + orderCount)` draws
from the stream. A port that always draws two uniforms produces a completely different world.

`randomPoint` (`:230-242`): `distance = radiusKm · √U`, `bearing = U[0, 2π)`,
`Δlat = distance/111`, `Δlon = distance/(111·cos(centerLat))` (guard `cosLat == 0 → 1`),
result `(lat + Δlat·sin(bearing), lon + Δlon·cos(bearing))`. Note `sin` on latitude and
`cos` on longitude — the reverse of the usual convention, and area-uniform because of the
`√`.

`gaussian` (`:245-250`): Box–Muller, **cosine branch only** (the sine half is discarded):
`mean + σ·√(−2·ln(max(U₁, 1e-12)))·cos(2π·U₂)`.

`trafficMultiplier` (`:255-260`): `1` if `amplitude <= 0`, else
`1 + A·(1 − cos(2π·minute/P))/2` — so it is ≥ 1 ("slower than nominal"), minimum at
`minute = 0`, period `P = 90 min` by default.

### 6.4 Portability verdict for the simulator **[measured]**

I reimplemented steps 1–5 above using **only** the portable primitives in §6.3 (probe
`…/_scratch/ds2/p6/main.swift`) and compared against the real simulator's `OrderRecord`s:

- `latent: .none`, seeds 1…30 × 240 orders: `restaurantIndex`, `createdAtMinutes`,
  `pickup.latitude`, `pickup.longitude` and `haulKm` all **bit-for-bit identical**
  (`quotedPrepMinutes` matches to 1.42e-14 for the round-trip reason in §6.2).
- `latent: .realistic`, seeds 1…10: **bit-for-bit identical**.

> **Conclusion: the 30-seed regression baseline CAN transfer to Kotlin at the level of the
> generated world. It cannot transfer at the level of `ordersAssigned` — see §9.1.**

### 6.5 The event loop — there are no events

Despite the doc comment "discrete-event simulation" (`:3`), this is a **fixed-step tick
loop**, not an event queue (`:319-390`):

```
epoch = Date(timeIntervalSince1970: 1_700_000_000)      // hardcoded; must match SwitchbackExperiment's
step  = dispatchIntervalSeconds / 60                    // 0.5 simulated minutes
horizon = durationMinutes + 90                          // 270 min by default
now = 0.0
while now <= horizon:
    pending = indices where assignedAt == nil && createdAt <= now      // ALL of them, unbounded age
    free    = indices where busyUntil <= now
    if both non-empty:
        build DispatchCourier[] from `free` (idleSince = epoch + idleSince·60)
        build DispatchOrder[]  from `pending` (readyAt = epoch + quotedReadyAt·60 — the QUOTE)
        for each Assignment returned:
            re-validate: courier exists, order exists, order unassigned, courier.busyUntil <= now
            traffic = trafficMultiplier(now); speed = courier.speedFactor
            actual(km) = travelMinutes(km) · traffic / speed        // costModel is a LOCAL DispatchCostModel() at :314
            arriveAt = now + actual(toPickupKm)
            departAt = max(arriveAt, order.trueReadyAt)              // the TRUTH, not the quote
            deliverAt = departAt + actual(legKm)
            order.assignedAt = now; order.deliveredAt = deliverAt
            courier.location = order.dropoff        // teleport, at assignment time
            courier.busyUntil = deliverAt; courier.idleSince = deliverAt
            courier.jobsCompleted += 1; courier.travelKm += toPickupKm + legKm
    now += step
```

Semantics a port must preserve, each non-obvious:
- **There is only one event type: the dispatch tick.** No arrival events, no completion
  events, no cancellations, no courier going offline, no order expiry, no reassignment.
  `DispatchCourier.excludedOrderIDs` is plumbed through (`:335`) but `SimCourier.excluded`
  is **never written** — declines are not simulated at all.
- The courier **teleports to the dropoff at assignment time**, so mid-delivery position is
  never modelled and the next tick already sees them at the destination.
- `travelKm` is charged as `toPickup + leg` with **no repositioning leg**.
- The dispatcher plans with `readyAt = quotedReadyAt`; the world resolves with `trueReadyAt`.
  With `latent: .none` these are equal, so **no test exercises the quote/truth divergence.**
- The simulator's own `DispatchCostModel()` at `:314` is a fresh default instance. A
  dispatcher configured with a different `averageSpeedKmh` plans at its speed but the world
  still moves at 18 km/h. Silent, and the only place a cost-model knob is duplicated.
- `now <= horizon` with float accumulation `now += 0.5` — exact in binary for 0.5, so the
  tick count is deterministic (541 ticks for the default config).
- The **90-minute drain tail** is load-bearing: seed 7, greedy assigns 118 orders of which
  **37 (31%)** are assigned after the 180-minute arrival window closed; optimal assigns 171
  of which **51 (30%)** are. **[measured]** A third of the throughput metric comes from a
  period with zero new demand, which no production market has.
- `orders.firstIndex(where: id ==)` / `couriers.firstIndex(where:)` inside the assignment
  loop (`:353-354`) are O(n) scans — O(orders × assignments) per tick. Port with maps.

### 6.6 Metrics — exact definitions

```
ordersOffered           = orders.count                                  (always == orderCount)
ordersAssigned          = count(assignedAt != nil)
ordersNeverAssigned     = ordersOffered - ordersAssigned
meanWaitToAssignMinutes = mean over ASSIGNED of (assignedAt - createdAt)
p95WaitToAssignMinutes  = sorted(waits)[clamp(round((n-1) · 0.95), 0, n-1)]   // .rounded() = half-away-from-zero
meanDeliveryMinutes     = mean over ASSIGNED of (deliveredAt - createdAt)
totalCourierTravelKm    = Σ courier.travelKm
jobsPerCourier          = [courier.jobsCompleted] in courier array order
giniCoefficient         = Σᵢ (2(i+1) - n - 1) · vᵢ  /  (n · Σvᵢ)      over v = sorted(jobs) ascending, 0 if n <= 1 or Σ == 0
couriersWithNoWork      = count(jobs == 0)
assignmentRate          = ordersAssigned / ordersOffered
```

`meanWaitToAssignMinutes`, `p95…` and `meanDeliveryMinutes` are all **conditioned on being
assigned**. Comparing them between two dispatchers with different assignment rates is a
composition comparison, not a like-for-like one — see §8.2.

### 6.7 Cross-process determinism **[measured]**

Same binary, two processes, seed 7, 12 couriers:

| run | greedy | optimal | zoned-optimal (3×3) |
|---|---|---|---|
| assigned | 118 | 171 | 3 |
| meanDelivery | 118.08044674322686 | 67.016318358307174 | 38.320569793058361 |
| travelKm | 1001.2958891357051 | 1003.5587579147009 | 25.77712310861758 |
| FNV-1a(records) | `0x49078F7A57DF8236` | `0x161E17C2DF9176D1` | `0x73DF8E889838A7CD` |

Byte-identical across processes and under `SWIFT_DETERMINISTIC_HASHING=1`. **The one
exception is `naiveBias`** (§7.4).

---

## 7. `SwitchbackExperiment.swift` — the experiment harness

### 7.1 Public API (the interface the port must preserve)

```swift
public enum ExperimentArm: String, Sendable, CaseIterable { case control, treatment }

public struct ArmAssignment: Sendable {
    public let name: String
    public init(name: String,
                assign: @escaping @Sendable (DispatchOrder) -> ExperimentArm,
                assignRecord: @escaping @Sendable (MarketplaceSimulator.OrderRecord) -> ExperimentArm)
    public func arm(for order: DispatchOrder) -> ExperimentArm
    public func arm(for record: MarketplaceSimulator.OrderRecord) -> ExperimentArm
    public static func naiveOrderLevel(salt: UInt64 = 1) -> ArmAssignment           // "naive-order-level-ab"
    public static func switchback(grid: ZoneGrid, blockMinutes: Double,
                                  epoch: Date, salt: UInt64 = 1) -> ArmAssignment   // "switchback-zone-x-timeblock"
}

public struct ExperimentDispatcher: Dispatcher {          // name = "experiment[<assignment.name>]"
    public init(control: any Dispatcher, treatment: any Dispatcher, assignment: ArmAssignment)
}

public struct SwitchbackExperiment: Sendable {
    public struct ArmMetrics: Sendable { public let orders, assigned: Int; public let meanDeliveryMinutes: Double
                                        public var assignmentRate: Double }
    public struct DesignResult: Sendable { public let designName: String; public let control, treatment: ArmMetrics
                                           public var estimatedLiftPoints: Double
                                           public var estimatedDeliveryDeltaMinutes: Double }
    public struct Report: Sendable { public let groundTruthLiftPoints, groundTruthDeliveryDeltaMinutes: Double
                                     public let designs: [DesignResult]
                                     public func biasPoints(for designName: String) -> Double?
                                     public var summary: String }
    public static func run(config: MarketplaceSimulator.Config,
                           control: any Dispatcher, treatment: any Dispatcher,
                           zoneDivisions: Int = 3, blockMinutes: Double = 30) -> Report
}
```

**The dual `arm(for:)` overload is the load-bearing part of the interface.** Arm assignment
must be a *pure function of the order*, computable both during dispatch (from
`DispatchOrder`) and afterwards (from `OrderRecord`), so per-arm metrics can be recomputed
post hoc instead of being threaded through the simulation. `ExperimentDispatcher` uses the
first; `SwitchbackExperiment.metrics` uses the second (`:216`).

### 7.2 What `run` does (`:230-274`)

```
fullControl   = MarketplaceSimulator.run(config, control)        // ground truth arm A
fullTreatment = MarketplaceSimulator.run(config, treatment)      // ground truth arm B, SAME seed
truthLift     = (fullTreatment.assignRate - fullControl.assignRate) · 100     // percentage POINTS
truthDelivery = fullTreatment.meanDeliveryMinutes - fullControl.meanDeliveryMinutes

epoch = Date(timeIntervalSince1970: 1_700_000_000)               // must equal the simulator's
grid  = ZoneGrid(config.cityCenter, config.cityRadiusKm, zoneDivisions)
designs = [ naiveOrderLevel(salt: config.seed),
            switchback(grid, blockMinutes, epoch, salt: config.seed) ]
for each design:
    mixed = MarketplaceSimulator.run(config, ExperimentDispatcher(control, treatment, design))
    per-arm metrics recomputed from mixed.orderRecords via design.arm(for: record)
bias(design) = design.estimatedLiftPoints - truthLift
```

So **four full simulations per `run` call**: 2 ground truth + 2 mixed. The
`SwitchbackExperimentTests` helper runs this per seed per division, i.e.
`test_zonePartitioningCollapsesExperimentBias` alone drives **96 simulations**.

`ExperimentDispatcher.assign` (`:118-148`):

```
treated    = orders where arm == .treatment            (input order preserved)
controlled = orders where arm == .control
treatmentFirst = Int(now.timeIntervalSince1970 / 60) % 2 == 0
remaining = couriers
run(first arm):  assignments = dispatcher.assign(remaining, subset, now)
                 remaining -= couriers consumed
run(second arm): same over what is left
```

Both arms draw from **one courier pool** — the interference under study. The priority flip
is by **integer minute**, and with `dispatchIntervalSeconds = 30` and an epoch at `:20`
seconds past the minute, `treatmentFirst` alternates **every two ticks**, not every tick:
`false,false,true,true,false,false,…` **[measured]**.

`zoneDivisions` on `run` is used **only** to build the arm-assignment grid. The
`ZonedDispatcher`s passed as `control`/`treatment` carry their own grids. The two can
disagree and nothing checks it.

### 7.3 The arm hashes — **structural defect, verified**

**`switchback` cell key** (`:77-86`): `(zone.row, zone.column, block)` where
`block = floor((order.createdAt − epoch)/60 / blockMinutes)`, folded with an FNV-style
step plus a xorshift:

```
hash = salt + 0x9E3779B97F4A7C15
for v in [row, column, block]:  hash = (hash xor v) * 0x100000001B3;  hash = hash xor (hash ushr 29)
arm = if (hash % 2 == 0) control else treatment
```

Measured properties **[measured]**:

| probe | result |
|---|---|
| does `row` change the arm? | yes, in 47,760 / 91,840 probes (so it is not ignored) |
| is arm `== f(col parity, block parity)`? | no — 410,624 / 839,516 mismatches |
| **is block `b`'s 3×3 pattern the exact complement of block `b+1`'s?** | **yes — 0 violations in 904,500 cells** (201 salts × 500 block pairs × 9 cells) |
| distinct 3×3 patterns over blocks `0…99,999`, salt 1 | **6** total: **3** in even blocks, **3** in odd blocks, the two sets exact complements |
| distinct block-0 3×3 patterns over 5001 salts | 187 of 512 possible |

Why: `0x100000001B3 = 2^40 + 435` is odd, so flipping `block`'s low bit flips the product's
low bit; the `hash ^= hash >> 29` step only disturbs that when a carry propagates from bits
0–8 all the way to bit 29 (probability ≈ `2^-20`). Hence near-perfect complementarity.

> **Consequence: this is not a switchback. It is a deterministic ABAB crossover with one
> pattern draw per salt.** Effective randomisation units ≈ 1, not `zones × blocks` (54 for
> the shipped 3×3 × 6-block configuration). There is no randomisation distribution, so no
> randomisation-inference standard error is computable, and any confound with a 60-minute
> period is perfectly aliased with the treatment. The premise stated at
> `SwitchbackExperiment.swift:14-17` and `08-EXPERIMENT-DESIGN-STUDY.md:18-24` — "randomise
> the algorithm over (zone × time block) cells" — is not what the code does.

**`naiveOrderLevel` hash** (`:51-59`) reduces to **one bit of the UUID's sixteen LSBs**.
Proven exactly over 200,000 random UUIDs × random salts **[measured]**:

```
arm == control  ⟺  parity(salt + 0x9E3779B97F4A7C15) XOR (XOR of the low bit of each of the 16 UUID bytes) == 0
```

The FNV multiplier is odd, so the multiply cannot mix anything into bit 0; there is no
xorshift on this path. 112 of the UUID's 128 bits are discarded, and any two ids differing
only in non-LSB bits land in the same arm. Fine for `UUID()` v4; **broken for v7/sequential
ids**, which is what a production experiment framework would be handed.

The trailing `hash.multipliedReportingOverflow(by: 1).partialValue % 2` (`:58`) is a no-op
multiply by 1 — dead code; drop it in the port.

**The epoch trap [measured].** `assign(for: DispatchOrder)` computes the block from
`order.createdAt.timeIntervalSince(epoch)`; `assign(for: OrderRecord)` uses
`record.createdAtMinutes` directly (`:90` vs `:95`), which is minutes since the
*simulator's* hardcoded `1_700_000_000`. They agree **only** when the caller passes exactly
that epoch:

| epoch passed to `.switchback(epoch:)` | orders where `arm(order) != arm(record)` |
|---|---|
| `1_700_000_000` (matching) | **0 / 240** |
| off by 15 minutes | 85 / 240 |
| `1970` | 118 / 240 |

A mismatch silently splits the *dispatch-time* arms from the *measurement-time* arms and
the report becomes meaningless with no error. `SwitchbackExperiment.run` hardcodes the
right value (`:245`), so the shipped path is safe and the trap is latent. In the port,
`blockIndex` must take a single canonical clock, not two.

### 7.4 `naiveOrderLevel` is not reproducible — **PORT RISK**

`UUID()` uses the system CSPRNG, **not** `SeededRNG` (`MarketplaceSimulator.swift:279, 303`).
Order ids are therefore fresh on every run, so anything keyed on them is nondeterministic.

Same binary, same seed 7, three separate processes **[measured]**:

| quantity | run 1 | run 2 | run 3 (`SWIFT_DETERMINISTIC_HASHING=1`) |
|---|---|---|---|
| `switchbackBias` | `-2.4390243902439024` | `-2.4390243902439024` | `-2.4390243902439024` |
| `naiveBias` | `-2.3255813953488373` | `-0.66964285714285721` | `+0.79188663517643798` |

Mean `|bias|` over seeds 1…12, eight repeats in one process, 3×3 **[measured]**:
`2.828, 2.960, 3.866, 2.846, 3.890, 2.758, 2.508, 2.665` — while `switchback` returns
`2.344` every single time. At `divisions: 1`, four repeats: `16.24, 18.29, 22.77, 16.78`
(and an earlier pass recorded `17.53` and `30.83` on the same code).

`test_switchbackAndNaiveAreComparableOnceZoned` (`SwitchbackExperimentTests.swift:81`)
asserts `naive < 6` and `max/min < 3.0`. Observed range `2.51…3.89` against a `6` ceiling
and observed ratios `1.07…1.66` against a `3.0` ceiling — so it passes today with ~1.5×
headroom, but it is a **genuinely flaky test**: its measured quantity is not a function of
its inputs. Fix in the port: seed the order ids (derive them from `SeededRNG`, e.g. a
UUIDv4-shaped value filled from `next()`), which also makes the naive design's 16-LSB
parity hash deterministic.

### 7.5 What the switchback actually achieves temporally **[measured]**

Because `block` is derived from **order creation time** but dispatch happens whenever a
courier frees up, arms are not temporally separated at all. Seed 7, `blockMinutes = 30`:

| | `divisions: 1` | `divisions: 3` |
|---|---|---|
| dispatch ticks with **both** arms pending | **114 / 126 (90.5%)** | 479 / 539 (88.9%) |
| (tick, zone) cells with both arms pending | 114 / 126 (90.5%) | 947 / 1069 (88.6%) |
| orders assigned in the same 30-min block they were created in | 32 / 143 (22.4%) | 3 / 3 (the degenerate case, §5.4) |
| mean block lag between creation and assignment | **2.27 blocks** (max 8) | 0 |

So in ~90% of decisions the two algorithms are competing for the same couriers in the same
cell at the same instant — exactly what the switchback is supposed to prevent.

**I tested the obvious fix and it is not one.** Keying the block on **decision time** (`now`)
instead of `createdAt`, everything else held constant, makes the bias *worse*
**[measured, seeds 1…12]**:

| divisions | truth lift | bias, block from `createdAt` (as shipped) | bias, block from decision time |
|---|---|---|---|
| 1 | +20.52 pts | 21.95 | **24.88** |
| 2 | +4.51 pts | 8.53 | **11.25** |
| 3 | +1.98 pts | 2.34 | **3.23** |

Reported as an honest negative: the `createdAt`-vs-`now` choice is *not* the cause of the
bias. The cause is that both arms share one courier pool, which is the point of the study.

### 7.6 Arm balance **[measured]**

`test_armAssignmentIsRoughlyBalanced` asserts treated share `= 0.5 ± 0.20`. Actual, 3×3:

| seed | switchback treated share | naive treated share |
|---|---|---|
| 42 | 0.471 | 0.479 |
| 5 | 0.496 | 0.525 |
| 7 | 0.487 | 0.496 |

Comfortably inside a band 40× wider than the deviation. The test cannot fail short of a
gross bug.

---

## 8. Numeric claims ledger — prose vs the assertion, with what each floor actually pins

All measurements below are mine, re-run from the current sources **[measured]**; the
30-seed table is in `…/_scratch/dispatch-spec/bench/out.txt` and
`…/_scratch/dispatch-baseline-seeds-1-30.json`.

### 8.1 `ordersAssigned`: +42% / +44.6%

`DispatchSimulationTests.swift:34-36` (current text, file was edited at 16:54 during this pass):

```
/// Under supply constraint the win must be substantial, not noise. Measured at
/// +44.6% mean across 30 seeds (min +29.9%, optimal wins 30/30); asserted at 0.35 so
/// cost-model tuning cannot cause spurious failures while still defending the claim.
```

`DispatchSimulationTests.swift:48`:

```swift
XCTAssertGreaterThanOrEqual(mean, 0.35, "mean improvement collapsed to \(mean * 100)%")
```

- **Measured:** mean `+44.59%`, min `+29.92%`, max `+53.85%`, pooled `3434 → 4957` = `+44.35%`, strict wins `30/30`, ties `0`.
- **Floor pinned:** `mean >= 0.35`. A regression from 44.6% to 35.0% passes. Previously the
  floor was `0.20` with a `+42%` comment; a concurrent agent tightened it to `0.35` and
  corrected the comment while this pass was running.
- **`.context/architecture/05-DISPATCH-ENGINE.md:65` still says `+42.2% mean (min +30.2%, max +55.2%)`** — stale
  against the current code on all three figures.
- **`30/30`:** `test_optimalDispatchNeverLosesToGreedy` (`:22-32`) asserts
  `XCTAssertGreaterThanOrEqual` — i.e. "never loses". The strict `30/30 wins` claim is true
  in measurement but is **not** the assertion; a tie on every seed would pass.

### 8.2 `meanDeliveryMinutes`: −45%

- **No test asserts it.** `meanDeliveryMinutes` appears in the dispatch suite exactly once,
  at `DispatchSimulationTests.swift:99`, inside `test_simulationIsReproducible`, comparing
  two runs of the *same* seed to `1e-12`. No greedy-vs-optimal delivery-time assertion exists.
- **Measured, as reported:** greedy `118.49` min vs optimal `64.81` min = **`−45.31%`**
  (matching the doc's `−44.6%` to within a percentage point).
- **Measured, like-for-like:** restricted to the orders assigned under **both** dispatchers
  (matched by generation index, n = **81 / 240**): greedy `111.99` min vs optimal `69.19` min
  = **`−38.22%`**. The remaining 7 points of the headline are composition — optimal assigns
  84 more orders and those extra orders are served fast.
- **Tail latency is essentially unimproved:** `p95WaitToAssignMinutes` greedy `175.57` vs
  optimal `169.60` = **`−3.40%`**, and optimal's p95 is **worse on 13 of 30 seeds**. The
  cost model's stated purpose includes bounding tail latency
  (`Dispatcher.swift:54-61`: "an old order keeps losing to newer ones … tail latency"). It
  does not deliver that, and nothing tests it.

### 8.3 `totalCourierTravelKm`: −1.4%

`DispatchSimulationTests.swift:63-66`:

```swift
XCTAssertLessThan(
    optimal.totalCourierTravelKm, greedy.totalCourierTravelKm * 1.10,
    "seed \(seed): optimal drove \(optimal.totalCourierTravelKm) km vs greedy \(greedy.totalCourierTravelKm)"
)
```
seeds `1...10` only (`:54`).

- **Measured:** 30 seeds mean `−1.06%` (min `−4.22%`, max `+2.13%`); the 10 seeds the test
  actually covers: mean `−0.78%`, worst `+1.87%`.
- **Floor pinned:** optimal may drive up to **+10% more**. The doc's "on the same fuel"
  (`05:77`) and `10-POLYGLOT-RESTRUCTURE.md:121`'s "1.4% *less* courier travel" are not
  protected, and `−1.4%` is not the measured value for either window.
- The concurrent edit at `DispatchSimulationTests.swift:58-62` has already replaced the
  `-1.4%` comment with the measured spread and the reason the 10% headroom is needed. `05`
  has not been updated.

### 8.4 Supply sweep

`test_advantageVanishesWhenCouriersAreAbundant` (`:74-90`):

```swift
XCTAssertGreaterThan(scarceGain, 20, "expected a large gain when couriers are scarce")
XCTAssertEqual(abundantOptimal.ordersAssigned, abundantGreedy.ordersAssigned,
               "with surplus couriers both strategies should saturate demand")
```

- **Measured, seed 42:** 6 couriers `63 → 100` (gain `+37`, `+58.7%`); 12 couriers
  `115 → 162` (`+40.9%`); 24 couriers `234 → 240` (`+2.6%`); 48 couriers `240 → 240` (`0.0%`).
- **Floor pinned:** `scarceGain > 20` **orders** (absolute, not a percentage) — a 21-order
  gain passes. The 48-courier equality is **exactly** pinned and is the strongest-guarded
  number in the whole suite; it is the caveat, not the headline.
- `05:73-74`'s single-run seed-42 figures (`greedy 121/240, 115.3 min, 981.8 km`;
  `optimal 164/240, 67.3 min, 980.8 km`) do not reproduce: I measure
  `greedy 115/240, 114.6 min, 988.3 km` and `optimal 162/240, 67.7 min, 997.8 km`.
  `05:85-88`'s sweep (`61→101`, `121→164`, `238→240`) likewise does not reproduce.
  Stale, consistent with the cost model having been tuned after `05` was written.

### 8.5 Solver correctness

`HungarianSolverTests.swift:57-73` — `test_matchesBruteForceOptimum_onRandomMatrices`:

```swift
var rng = SeededRNG(state: 0xD15A7C4)
for trial in 0..<300 {
    let rows = Int.random(in: 1...5, using: &rng)
    let columns = Int.random(in: rows...6, using: &rng)
    …
    XCTAssertEqual(solved, optimal, accuracy: 1e-9, …)
}
```

- **Exactly as documented.** 300 trials, integer costs `0...50`, exhaustive permutation
  oracle at `:19-41`, equality to `1e-9`.
- **Coverage gap:** `columns` is drawn from `rows...6`, so **`columns >= rows` always** —
  the brute-force test **never exercises the `rows > columns` padding path**. That path is
  covered only by `test_surplusRowsAreUnmatched` (`:102`, a single hand-written 3×1 case)
  and by 4.9% of in-simulator invocations. It is the least-tested code in the file and the
  most likely place a port diverges.
- `test_matchingIsAValidPermutation` (`:76-98`) uses `rows 1...6 × columns 1...6` (200
  trials) and does assert the cardinality property in both directions (`:92-96`), but not
  optimality.
- `forbidden` semantics: `:117-129`. Haversine: `:137-145`,
  `XCTAssertEqual(distance, 205, accuracy: 15)` — my measurement `204.6298…` km.

### 8.6 The 10× bias collapse

`SwitchbackExperimentTests.swift:44-60`:

```swift
let unpartitioned = meanAbsoluteBias(divisions: 1, design: "switchback-zone-x-timeblock", seeds: 1...12)
let partitioned   = meanAbsoluteBias(divisions: 3, design: "switchback-zone-x-timeblock", seeds: 1...12)
XCTAssertGreaterThan(unpartitioned, 10, …)
XCTAssertLessThan(partitioned, 6, …)
XCTAssertLessThan(partitioned, unpartitioned / 2,
    "zone partitioning should at least halve the bias (\(unpartitioned) → \(partitioned))")
```

`SwitchbackExperimentTests.swift:63-70`:

```swift
XCTAssertGreaterThan(coarse, medium, "1x1 (\(coarse)) should be worse than 2x2 (\(medium))")
XCTAssertGreaterThan(medium, fine, "2x2 (\(medium)) should be worse than 3x3 (\(fine))")
```
(seeds `1...8`, switchback design only.)

`SwitchbackExperimentTests.swift:85-91`:

```swift
XCTAssertLessThan(naive, 6, "naive bias unexpectedly large once zoned: \(naive)")
XCTAssertLessThan(switchback, 6, "switchback bias unexpectedly large once zoned: \(switchback)")
XCTAssertLessThan(max(naive, switchback) / max(min(naive, switchback), 0.01), 3.0, …)
```

**Measured [seeds 1…20, switchback design, 12 couriers]:**

| divisions | truth lift (pts) | zoned-greedy assigned | zoned-optimal assigned | idle couriers | switchback \|bias\| | **relative bias \|bias\|/\|truth\|** |
|---|---|---|---|---|---|---|
| 1 | **+21.06** | 114.7/240 | 165.2/240 | 0.0/12 | 22.25 | **1.06** |
| 2 | **+6.27** | 64.5/240 | 79.5/240 | 2.5/12 | 6.99 | **1.11** |
| 3 | **+1.90** | 8.8/240 | 13.4/240 | 7.1/12 | 3.25 | **1.72** |

Seeds 1…12 agree (`+20.52 / 21.95`, `+4.51 / 8.53`, `+1.98 / 2.34`); seeds 1…8 likewise.

**What the prose claims vs what the test pins vs what is true:**

| | |
|---|---|
| prose (`08:68`) | "Roughly a **10×** reduction in experiment bias" |
| assertion | `unpartitioned > 10` **and** `partitioned < 6` **and** `partitioned < unpartitioned / 2` — i.e. a **2×** floor plus two absolute bands |
| measured absolute | `22.25 → 3.25` ≈ **6.8×** at 20 seeds, `21.95 → 2.34` ≈ **9.4×** at 12 seeds. The "10×" is roughly right on absolute bias at the seed count the tests use. |
| **measured relative** | **`1.06 → 1.72` — it gets 62% WORSE.** In every partition `\|bias\| > \|truth\|`: the estimator's error exceeds the effect it is estimating. Neither design recovers the ground truth at any granularity. |
| mechanism | the absolute bias falls because the **effect** falls 11× (`+21.06 → +1.90` pts), and the effect falls because the 3×3 zoned marketplace assigns 13 of 240 orders with 7 of 12 couriers idle all shift (§5.4). |

`08:87-93` does report the effect falling ("+17.9 → +4.6 points") and frames it as "zones
cost real efficiency". It does **not** connect that to the bias number, and it does not
compute relative bias — so the headline "10× reduction in experiment bias, achieved by
changing the system" reads as an estimator improvement when the measurement shows the
estimator got worse. `08`'s own figures (`+17.9`, `+4.6`, `22.7/24.7`, `7.1/8.7`, `2.4/2.9`,
20 seeds) do not reproduce against current code at any seed count.

`test_biasDecreasesWithFinerPartitioning` is monotone as asserted (`22.25 > 6.99 > 3.25`),
but it is monotone in the effect size, not in estimator quality.

**Nothing reads `groundTruthLiftPoints` in any test.** `Report.groundTruthLiftPoints` and
`groundTruthDeliveryDeltaMinutes` are computed (`:240-243`) and consumed only via
`biasPoints(for:)`, which subtracts them. The two numbers that reveal the mechanism are
unasserted.

### 8.7 What the `+44.6%` is actually attributable to **[measured]**

Added a third dispatcher — courier-centric greedy: for each free courier **in input order**,
take the min-cost eligible order; **no bipartite lookahead whatsoever**.

| dispatcher | pooled assigned, seeds 1…30 | vs FCFS | km / assignment (seeds 1…10) | mean delivery |
|---|---|---|---|---|
| `greedy-fcfs` | 3434 | — | **8.687** | 117.20 min |
| `greedy-nearest-order-per-courier` | **4924** | **+43.4%** | 6.019 | 65.27 min |
| `optimal-batch` | 4957 | **+44.4%** (`+0.7%` over nearest-order) | 5.984 | 64.47 min |

So **97.7% of the throughput win comes from abandoning FCFS order selection**, not from the
Hungarian solver. The mechanism is visible in `km/assignment`: FCFS forces the free courier
onto the *oldest* pending order, which is 44% further away on average, so each courier
completes fewer jobs per shift.

Supporting evidence: inside the optimal-batch run the solver sees **1.69 free couriers on
average** at the tick an order is assigned, and only **30.7%** of assignments are made at
ticks with more than one free courier. With 1.69 rows there is almost nothing for a
bipartite matching to optimise.

This contradicts three source comments, which should be corrected before the port:
- `Dispatcher.swift:176-180` "The win over greedy is lookahead"
- `Dispatcher.swift:6-11` "Greedy nearest-courier … is provably suboptimal"  (true in general, but not the operative effect here)
- `DispatchSimulationTests.swift:16-21` "Optimal matching pays a little more on one assignment to keep the other feasible"

The solver is still worth having — it is the right primitive, it costs nothing (§3.7), and
it is what makes the `+0.7%` and the constraint handling principled. But the *portfolio
claim* "batch matching beats greedy by 44%" is not what the measurement supports.

---

## 9. Port risks and mitigations

### 9.1 **RISK 1 (highest): `libm`, not the RNG**

The world generation is bit-portable (§6.4). The *outcomes* are not, because they are
chaotic in the distance function. Scaling Haversine by `×(1 + 1e-15)` (≈4.5 ulp — smaller
than the documented Darwin-vs-JVM difference for `sin`/`cos`/`atan2`) changes
`ordersAssigned` on **11 of 30 seeds** **[measured;
`…/_scratch/dispatch-spec/perturb/out.txt` vs `…/bench/out.txt`]**:

| seed | baseline optimal | perturbed optimal | Δ |
|---|---|---|---|
| 6 | 165 | 163 | −2 |
| 7 | 171 | 169 | −2 |
| 11 | 167 | 166 | −1 |
| 12 | 165 | 163 | −2 |
| 13 | 165 | 164 | −1 |
| 15 | 166 | 167 | +1 |
| 20 | 168 | 170 | +2 |
| 26 | 161 | 162 | +1 |
| 27 | 159 | 161 | +2 |
| 28 | 160 | 159 | −1 |
| 2, 3 | 165, 165 | 165, 165 | 0, but `meanDelivery` differs at the 4th decimal (64.485 vs 64.904) — different matchings, same count |

`greedy-fcfs` is **unaffected on all 30 seeds** (its argmin gaps are wide); it is the
Hungarian's near-ties that flip, and one flipped assignment re-routes a courier and
cascades through the remaining 4 hours.

**Mitigation (do all four):**
1. **Do not use the 30-seed table as a bit-for-bit oracle.** The comment at the head of
   `…/_scratch/main.swift` ("the port is correct when it reproduces every number here
   bit-for-bit") is **wrong** and will cost a day of chasing a non-bug.
2. **Port in two layers with two different oracles.**
   *Layer A (must be bit-exact):* SplitMix64 + the four range mappings + world generation
   + `ZoneGrid.zone(for:)` + `HungarianSolver.solve` on a *given* matrix. Oracles: the
   golden vectors in §11, the solver fingerprint `0x67C6ECE6FD13637C`, and the P3 order
   stream.
   *Layer B (statistical only):* anything downstream of `distanceKm`. Oracle: the 30-seed
   **distribution** — assert `mean improvement >= 0.35`, `min improvement > 0.25`,
   `strict wins == 30/30`, `|mean delivery Δ| within ±3 pts of −45%`, `per-seed ordersAssigned
   within ±3 of the Swift value`. The ±3 band is ~2× the perturbation sensitivity measured
   above.
3. **If bit-exactness downstream is wanted anyway**, make it achievable: implement
   `distanceKm` over a fixed software `sin`/`cos`/`atan2`/`sqrt` (or `StrictMath` on the JVM,
   *and* switch the Swift side to the same) and re-baseline. That is a deliberate choice with
   a cost; the default should be (2).
4. **Re-measure, don't translate, every number in `05` and `08`.** They are already stale
   against current Swift (§8.1, §8.4, §8.6).

### 9.2 RISK 2: the `Double.random` range-type asymmetry

`ClosedRange` uses Lemire with `ub = 2^53 + 1` and a rejection loop that fires ~1 draw in
2048; `Range` masks the low 53 bits of a single draw and retries only on landing exactly on
the upper bound. Implement both, distinctly, and unit-test each against the golden streams
in §11 for ≥20,000 draws (the rejection path needs volume to be exercised).

### 9.3 RISK 3: `UUID()` in the simulator

Order and courier ids are **not** seeded (`MarketplaceSimulator.swift:279, 303`). Everything
keyed on them is nondeterministic (§7.4). **Mitigation:** generate ids from `SeededRNG` in
the port (fill 16 bytes from two `next()` calls; set the v4 version/variant bits if the
shape matters). This makes the naive design reproducible **and** fixes the flaky test —
but it also changes the naive-design numbers, so re-baseline them, and note that after the
change the 16-LSB parity hash (§7.3) becomes a *deterministic* function of the seed, so the
naive design's balance should be re-checked.

### 9.4 RISK 4: `gaussian` short-circuit and argument evaluation order

`gaussian` consumes **zero** draws when `σ <= 0` (`:246`), and Swift's left-to-right
initialiser argument evaluation pins `location` before `speedFactor` and `truePrep` before
`dropoff`. Both are easy to get wrong and both desynchronise the whole stream. The §6.3
draw-order listing is the contract; the P6 probe is the test.

### 9.5 RISK 5: unstable collection order

`ZonedDispatcher` iterates a `Dictionary` (§5.3) and the emitted `[Assignment]` order
varies. Today this is benign (verified across processes), but a Kotlin `HashMap` iteration
order differs from Swift's, so **any** port test that compares assignment *lists* rather
than *sets* will fail spuriously. Compare sets, or iterate `grid.allZones` in row-major
order.

### 9.6 RISK 6: `Dispatcher` must stay open

`ZonedDispatcher` and `ExperimentDispatcher` are decorators over `any Dispatcher`. A Kotlin
`sealed interface` forecloses the composition the study depends on. Use an open
`interface Dispatcher { val name: String; fun assign(...): List<Assignment> }`.

### 9.7 Unit and sign conventions to carry over verbatim

- cost is in **minutes** and may be **negative**
- `forbidden = 1e9` is a **threshold** (`< forbidden` is dispatchable), and the
  "cardinality first" property depends on real costs being ≪ `1e9 / n` (§3.4)
- lift is in **percentage points**, not ratios (`:168-170`)
- delivery delta is in **minutes**, negative is better (`:171-173`)
- `blockMinutes` is minutes, `dispatchIntervalSeconds` is seconds, `idleSince`/`readyAt`/
  `createdAt` are absolute instants, `OrderRecord` times are **minutes since sim start**
- zone `radiusKm` is a **half-width** of a square box, not a radius (§5.2)

---

## 10. The `Assign` RPC — what must replace the offer feed

### 10.1 What is being replaced (from `app-courier-constraints.md` §1, re-verified)

The production feed is: unfiltered realtime on **all** of `orders`
(`Sources/RavonCore/Services/RealtimeService.swift:381-425`, no `filter:`) → handler
discards the event → `fetchAvailableOrders()`
(`Sources/RavonCore/Services/SupabaseService.swift:773-781`):
`select("*, restaurants(*), order_items(*)").is("courier_id", nil).in("status", ["accepted","preparing","ready"]).order("created_at")`
→ client takes `.first`.

Four defects the RPC must close, all of them structural:
1. **Same offer for everyone.** `.first` of `ORDER BY created_at` is the oldest unassigned
   order **nationwide**, identical for every courier. No proximity, no per-courier state.
2. **Code leak.** `select("*")` returns `verification_code` (pickup) and
   `delivery_verification_code` (hand-off) for every unassigned order to every
   authenticated courier (`Sources/RavonCore/Models/Order.swift:341-342`). A courier can
   read the hand-off code from the feed and complete `courier_deliver_order` in
   `hand_to_me` mode without meeting the customer. `fetch_available_orders`
   (`RETURNS SETOF orders`) does **not** fix this.
3. **Fanout.** `update_courier_heartbeat`
   (`db/migrations/13_courier_status_transition_rpcs_v2.sql:136-139`) ends with an
   `UPDATE orders SET eta_minutes = …` for the courier's active order. Every such write
   fires the unfiltered channel, so every idle courier runs a full-table scan:
   `O(active × idle / 5)` scans per second.
4. **No exclusion state.** Declines have no home; `orders.excluded_courier_ids` is the only
   persisted exclusion and only `fetch_available_orders` reads it.

### 10.2 Request

The engine is pure — no DB reads, no auth decisions — so the request must carry the whole
world slice. Field names in `snake_case` for proto/JSON; types are the Kotlin/proto
equivalents of §4.1.

```
AssignRequest {
  // --- idempotency and provenance ---
  string   request_id                  // caller-generated ULID; the service MUST dedupe on it
  string   zone_id                     // "z1-1" (DispatchZone.description) or "global"
  int64    decision_at_unix_millis     // the `now` fed to the cost model; NEVER server clock —
                                       // the port must be a pure function of the request
  string   algorithm                   // "optimal-batch" | "greedy-fcfs" | "nearest-order"
  string   cost_model_version          // e.g. "v1:18kmh/8km/1.5/0.4/25" — pin the weights in the request
  optional string experiment_arm       // "control"|"treatment", set by the caller; the engine never randomises

  // --- courier positions ---
  repeated CourierCandidate couriers
  // --- order positions ---
  repeated OrderCandidate   orders
}

CourierCandidate {
  string   courier_id                  // uuid
  double   latitude
  double   longitude
  int64    location_fix_at_unix_millis // from courier_locations.last_updated
  optional double accuracy_meters      // heartbeat rejects > 200 m server-side; engine should too
  int64    idle_since_unix_millis      // last delivery completed, or came online
  repeated string excluded_order_ids   // courier -> order exclusions (declines this session)
  optional int32  vehicle_capacity     // reserved; engine ignores it at v1 (no stacking)
}

OrderCandidate {
  string   order_id
  double   pickup_latitude             // restaurant lat/lon — proximity is courier -> RESTAURANT
  double   pickup_longitude
  double   dropoff_latitude            // needed for the delivery-leg cost term
  double   dropoff_longitude
  int64    created_at_unix_millis
  int64    quoted_ready_at_unix_millis // the merchant QUOTE, matching the simulator's readyAt
  repeated string excluded_courier_ids // from orders.excluded_courier_ids
  string   status                       // "accepted"|"preparing"|"ready" — engine asserts the whitelist
  optional string restaurant_id         // for logging / zone attribution only
}
```

Notes that follow directly from the spec above:
- **`decision_at_unix_millis` must be in the request, not read from the clock.** Every cost
  term is relative to `now` (§4.2) and `ExperimentDispatcher`'s arm priority flips on
  `Int(now/60) % 2` (§7.2). A pure function of the request is the only way the simulator can
  remain the test harness, which the architecture docs require
  (`10-POLYGLOT-RESTRUCTURE.md:197`, `11-KOTLIN-DECISION.md:92-95`).
- **Both exclusion directions must be transmitted** — the cost model checks both (§4.1) and
  only one has a database home today.
- `dropoff` is required even though offers are courier→restaurant, because the delivery leg
  is a cost term. It is **not** echoed back (§10.3).
- **Radius must be resolved.** The SQL default is 50 km
  (`mig13:718`), the Swift wrapper overrides to 10 km (`SupabaseService.swift:787`), and the
  cost model forbids beyond 8 km (`Dispatcher.swift:78`). Three values, 6× apart. The
  request should carry the candidate-set radius explicitly (or the caller should pre-filter
  at exactly `maxAssignmentRadiusKm`), and `cost_model_version` should pin the cost-model
  radius. Until someone decides, this is a **spec hole, not an implementation detail**.

### 10.3 Response — the projection that omits codes

```
AssignResponse {
  string   request_id                  // echoed
  string   zone_id
  int64    decided_at_unix_millis
  string   algorithm
  string   cost_model_version
  repeated Offer offers
  repeated Unmatched unmatched_orders
  repeated string idle_courier_ids     // couriers that got nothing this tick (fairness telemetry)
  AssignDiagnostics diagnostics
}

Offer {
  string   courier_id
  string   order_id
  double   cost_minutes                // may be NEGATIVE; the credits can exceed travel
  // ---- the projection: what the courier is allowed to see BEFORE claiming ----
  OfferProjection projection
  int64    offer_expires_at_unix_millis
}

OfferProjection {
  // Pickup side: full detail. The courier must be able to decide.
  string   restaurant_name
  double   pickup_latitude
  double   pickup_longitude
  int64    quoted_ready_at_unix_millis
  double   distance_to_pickup_km
  double   estimated_pickup_eta_minutes

  // Dropoff side: COARSE ONLY until the offer is accepted.
  string   dropoff_area_label          // district/neighbourhood name, NOT a street address
  double   haul_km                     // straight-line pickup -> dropoff
  double   estimated_total_minutes

  // Compensation and size.
  int64    payout_minor_units          // integer dirams; never a float (see the money finding)
  string   currency                    // "TJS"
  int32    item_count

  // ---- FIELDS THAT MUST NOT APPEAR, ENUMERATED SO THE PORT CAN ASSERT IT ----
  // verification_code           — pickup code           (leaks today)
  // delivery_verification_code  — customer hand-off code (leaks today; defeats dual-code design)
  // delivery_address_snapshot   — full street address + entrance/floor/notes
  // customer_name, customer_phone
  // order_items[].* beyond item_count
  // any `orders` column not listed above
}

Unmatched { string order_id; string reason }   // "no_courier_in_radius" | "all_couriers_excluded" |
                                               // "no_free_courier" | "zone_has_no_couriers"

AssignDiagnostics {
  int32  courier_count                 // rows in the matrix
  int32  order_count                   // columns before padding
  int32  padded_columns                // max(rows, cols) — proves which branch ran
  int32  forbidden_pairs
  double total_cost_minutes            // HungarianSolver.totalCost of the emitted matching
  int64  solve_micros
  string solver                         // "hungarian-jv" | "greedy-fcfs" | "nearest-order"
}
```

Why each piece:
- **The response is a projection type, not `SETOF orders`.** This is the load-bearing
  requirement from `app-courier-constraints.md` §1: neither the current SELECT nor
  `fetch_available_orders` can omit columns, because both return whole rows. A hand-built
  response message is the *only* mechanism that structurally cannot leak a code. The
  "must not appear" list belongs in the code as a test, not a comment: enumerate the
  forbidden field names and assert the serialised response contains none of them.
- **Codes are issued on claim, not on offer.** The pickup code goes out when the order
  becomes `assigned` to that courier; the hand-off code goes out no earlier than
  `picked_up`. Both belong on a separate authenticated per-order call keyed to
  `courier_id == caller`, never on the feed.
- **Full address on claim only.** `dropoff_area_label` + `haul_km` is enough to decide; the
  street address is not.
- **Money is integer minor units.** Three apps have three rounding rules today and the
  model uses `Double`; the offer is the wrong place to inherit that.
- **`cost_minutes` can be negative** and the client must not render it as a duration.
- **`unmatched_orders` with reasons** is what replaces "the client re-SELECTs and gets
  nothing" — the caller needs to know whether to widen the radius, wake more couriers, or
  surge.
- **`diagnostics.padded_columns`** exists because the `rows > columns` path is the
  least-tested branch (§8.5); surfacing it makes a port divergence observable in production
  rather than at the next re-baseline.
- **Exactly-once.** `create_order` has no idempotency key today; `Assign` must not repeat
  that. `request_id` + a dedupe window, and a separate `ClaimOffer` call that is the *only*
  thing that writes `orders.courier_id` (compare-and-set on `courier_id IS NULL`).
- **Push, not poll.** The engine returns offers; a per-courier channel delivers them. That
  is what removes the `O(active × idle / 5)` full-table scans — the fanout is a property of
  the *unfiltered subscription*, not of the query, so replacing only the query fixes
  nothing.

### 10.4 Companion calls the engine implies (out of scope here, named so nothing is lost)

`DeclineOffer(courier_id, order_id, reason)` → appends to `orders.excluded_courier_ids`
**and** to a per-courier exclusion set (the courier→order direction has no persistence
today); `ClaimOffer(request_id, courier_id, order_id)` → the CAS that assigns;
`ExpireOffers()` → the offer TTL the simulator does not model at all (§6.5: no declines,
no expiry, no cancellations).

---

## 11. Golden vectors for the port (all **[measured]**)

```
SplitMix64, seed = 42, raw next():
  0xBDD732262FEB6E95  0x28EFE333B266F103  0x47526757130F9F52  0x581CE1FF0E4AE394  0x09BC585A244823F2

Double.random(in: 0...1), seed = 42:
  0x3FE7BAE644C5FD6E = 0.74156487877182342
  0x3FC477F199D93378 = 0.1599103928769201
  0x3FD1D499D5C4C3E8 = 0.27860113025513877
  0x3FD607387FC392B8 = 0.34419071652363753
  0x3FA378B0B4489040 = 0.038030168540246212

Double.random(in: 0..<2π), seed = 42:
  4.5545033701893196   3.1195048189344305   3.6135526258340613

Int.random(in: 0..<6),  seed = 42:  [4, 0, 1, 2, 0, 5, 1, 4, 2, 3]
Int.random(in: 1...5),  seed = 42:  [4, 1, 2, 2, 1, 5, 2, 5, 2, 4]
Lemire threshold for ub = 2^53 + 1:  t = 9007199254738945  (rejection prob 4.883e-4)

Haversine:
  (38.5598, 68.7870) -> (40.2833, 69.6222) = 204.62980642732833 km   (0x406994275FCF05F2)
  (38.5598, 68.7870) -> (38.60,   68.82)   =   5.3112916195781148 km

ZoneGrid(center=(38.5598, 68.7870), radiusKm=6, divisions=3):
  zone(center)      = z1-1
  zone(38.60,68.82) = z2-2
  zone(89, 179)     = z2-2      zone(-89, -179) = z0-0
  allZones          = z0-0, z0-1, z0-2, z1-0, z1-1, z1-2, z2-0, z2-1, z2-2

HungarianSolver fingerprint (2000 random matrices, rows/cols 1...8, costs -10...10,
SplitMix64 state 99, FNV-1a over assignment vector with nil = -1):
  0x67C6ECE6FD13637C

World generation, seed 7, courierCount 12, orderCount 240, durationMinutes 180, latent .none
(first three orders AFTER the createdAt sort):
  [0] restaurant 2  createdAt 0.73149012441932282  quotedPrep 19.271014033099647
      pickup (38.544196451316552, 68.798929610390303)  dropoff (38.587960867620502, 68.746004929540163)
  [1] restaurant 5  createdAt 1.1561798857924011   quotedPrep 12.241413588419491
      pickup (38.551980028651279, 68.791868752432947)  dropoff (38.533055269484947, 68.809580303806271)
  [2] restaurant 0  createdAt 1.4466601948593616   quotedPrep 20.569138790190941
      pickup (38.571162584859948, 68.771045373748137)  dropoff (38.602533705954414, 68.786390567795053)

Full-run fingerprints, seed 7, 12 couriers, 240 orders, 180 min, latent .none:
  greedy-fcfs    assigned 118  meanDelivery 118.08044674322686  travel 1001.2958891357051 km
  optimal-batch  assigned 171  meanDelivery  67.016318358307174 travel 1003.5587579147009 km
  zoned[optimal-batch] 3x3  assigned 3  meanDelivery 38.320569793058361  travel 25.77712310861758 km
  FNV-1a over (createdAt, assignedAt ?? -1, deliveredAt ?? -1) bit patterns:
    greedy 0x49078F7A57DF8236   optimal 0x161E17C2DF9176D1   zoned-optimal 0x73DF8E889838A7CD

switchback cellArm(salt = 7, 3x3, blockMinutes = 30):
  block 0:  z0-0=T z0-1=C z0-2=T  z1-0=T z1-1=C z1-2=T  z2-0=T z2-1=C z2-2=T
  block 1:  exact complement of block 0
  block 2:  == block 0        (strict alternation; see §7.3)
```

The whole 30-seed table (per-seed `ordersAssigned`, `meanWait`, `p95Wait`, `meanDelivery`,
`travelKm`, `gini`, `jobsPerCourier` for both dispatchers) is already captured in
`/Users/mmarufov/conductor/workspaces/ravon-core/bucharest/.context/research/dispatch-baseline-seeds-1-30.json`.
Treat it as a **statistical** baseline (§9.1), not a bit-for-bit one.

---

## 12. Corrections to prior documents (loud)

**To `.context/research/arch-docs-constraints.md`:**

1. **§4d, port property 1 ("Bit-identical determinism from `seed`") is incomplete and, for
   one design, false.** `ArmAssignment.naiveOrderLevel` hashes `UUID()`, which is not
   seeded, so `naiveBias` differs on every run of the *same* binary at the *same* seed:
   `-2.326`, `-0.670`, `+0.792` measured across three processes (§7.4). One shipped test
   (`SwitchbackExperimentTests.swift:81`) consumes that quantity. Everything else *is*
   bit-identical across processes, including the `Dictionary`-ordered `ZonedDispatcher` path
   that §4d flags as a hazard — I verified that one is benign today.
2. **§3a's "`+42.2%` / `−1.4%`" rows are now stale in a second way.** Measured today:
   `+44.59%` mean (min `+29.92%`, max `+53.85%`) and travel `−1.06%` over 30 seeds /
   `−0.78%` over the 10 seeds the test covers, worst `+2.13%`. `05-DISPATCH-ENGINE.md`
   still carries `+42.2%` / `−44.6%` / `−1.4%`; `DispatchSimulationTests.swift` was edited
   at **16:54 during this pass** to `+44.6%` and `mean >= 0.35` (was `0.20`). The
   doc↔repo gap has moved from the test file to `05`.
3. **§3b's note that `GreedyDispatcher` "isolates lookahead as the single independent
   variable" is right about the design and wrong about the result.** Lookahead is worth
   `+0.7%`, not `+44%` (§8.7). The independent variable that moved is order selection.
4. **§4b's verdict on the "10×" claim ("headline overstates the guard by 5×") understates
   the problem.** On absolute bias the 10× is roughly real (`22.25 → 3.25`, 6.8× at 20
   seeds; 9.4× at 12 seeds). The problem is that **relative** bias goes `1.06 → 1.72` —
   worse — and `|bias| > |truth|` in all three partitions (§8.6). The bias collapses
   because the effect collapses, and the effect collapses because the 3×3 zoned market
   assigns 13 of 240 orders with 7 of 12 couriers idle (§5.4). §4b should add that the
   3×3 configuration is degenerate.
5. **§4d's table is accurate on shapes** but omits three things a porter needs:
   `HungarianSolver.solve([[]])` returns length 0 for a 1-row input; a ragged matrix
   **traps**; and `MarketplaceSimulator.SeededRNG` is **internal**, so the harness cannot
   be re-seeded from outside the module without `@testable`.
6. **§4d's dead-code note is right** (`multipliedReportingOverflow(by: 1)`), and there is a
   second, larger one: `DispatchCostModel.distanceOnly` has never been run. I ran it — it
   assigns 5 *fewer* orders and produces a *lower* gini (0.026 vs 0.063), i.e. the opposite
   of the starvation argument the credits were introduced to defend (§4.2).

**To `.context/research/app-courier-constraints.md` §1:** no corrections — the three-link
chain, the nine call sites, the 10 km/50 km split and the code leak all re-verified. §10
above adds the concrete request/response shape §1 asks for, plus one thing §1 does not say:
the offer feed's proximity is courier→**restaurant**, so `dropoff` must be in the *request*
(it is a cost term) while being absent from the *response projection*.

**To `…/_scratch/main.swift` (the baseline generator):** its header comment — "the port is
correct when it reproduces every number here bit-for-bit" — is wrong (§9.1). Eleven of
thirty seeds move under a 4.5-ulp distance perturbation.

**To the source comments (before porting):** `Dispatcher.swift:176-180`,
`Dispatcher.swift:6-11` and `DispatchSimulationTests.swift:16-21` attribute the win to
lookahead; `MarketplaceSimulator.swift:3` calls a fixed-step tick loop a discrete-event
simulation; `SwitchbackExperiment.swift:14-17` describes a randomised switchback that the
code does not implement.

---

## 13. Open questions and UNKNOWNs

1. **Which radius is the product radius — 8, 10 or 50 km?** Three values in three places
   (`Dispatcher.swift:78`, `SupabaseService.swift:787`, `mig13:718`). The repo does not say.
   **UNKNOWN — product decision, not discoverable from the repo.**
2. **Is the 3×3 zone grid meant to be used at all?** At `cityRadiusKm = 6` it partitions
   Dushanbe into 4 km cells and the simulated market collapses (§5.4). Either the grid
   should follow density (the file admits a uniform grid is "deliberately naive",
   `DispatchZone.swift:25-30`), or zones need cross-boundary spillover, or `divisions` should
   be 1–2 at this city size. **Needs a decision before the port, because §7–§8 are measured
   at 3×3.**
3. **Should the switchback be repaired or dropped?** As built it is a deterministic
   alternating crossover with ~1 randomisation unit (§7.3), and the obvious fix (key the
   block on decision time) makes the bias worse (§7.5). A real switchback needs (a) a
   proper hash so `(zone, block)` cells are independent, (b) zone-level courier pools that
   actually function, (c) enough couriers per zone to have a market. All three are missing.
4. **What is the offer TTL, and what happens on decline?** The simulator models neither
   (§6.5), so nothing in the 1208 lines constrains the two decisions that most affect the
   real feed.
5. **Does the port target `StrictMath`-grade reproducibility?** §9.1 makes it a deliberate,
   costed choice. **Needs a decision; either answer is defensible, but "we'll see" costs a
   day of debugging.**
6. **Nothing has ever been measured with `latent: .realistic`** by any test — the
   quote-vs-truth divergence, courier speed spread and traffic cycle are all inert at
   `latent: .none`. Whether the `+44.6%` survives latent noise is **UNKNOWN**; the harness
   can answer it in minutes and no one has run it.
