import Foundation

// Dataset exporter for the Python ML layer.
//
// This is a *one-shot* bridge. `ml/` is required to run with no Swift toolchain at all,
// so the contract is: this executable writes `ml/data/orders.csv.gz` and
// `ml/data/meta.json`, both committed, and nothing downstream ever imports RavonCore.
// The Kotlin extraction happening in parallel can delete or move the simulator without
// breaking the ML layer.
//
// Build + run with `ml/export/export.sh`.

// MARK: - Export configuration

/// One simulator seed == one "service day". The anomaly detector needs
/// 21 (baseline) + 7 (gap) + 1 (test) = 29 days minimum; 200 gives 172 evaluable test
/// days, which is enough to put a usable confidence interval on the false-positive rate.
let dayCount = 200

/// **This is the config that produced the published naive-ETA baseline** — 240 orders
/// over 180 minutes with 24 couriers, dispatched by `OptimalBatchDispatcher`. Measured
/// over seeds 1...30 it gives +36.6 min bias / 50.5 min sd with `latent = .realistic`
/// and +23.4 min bias with `latent = .none`, which is the "+36 / 51, still +24 without
/// latent state" fact on record. Changing any of the three numbers moves the regime:
/// the simulator drains its backlog during the 90-minute post-arrival horizon, so a
/// longer service day accumulates queue and the sd roughly doubles. Keeping the exact
/// config is what makes the model's improvement comparable to the published baseline.
let courierCount = 24
let orderCount = 240
let durationMinutes = 180.0

/// The simulator clock starts at 0. A real service day starts late morning; the offset is
/// applied on the Python side so `hour_of_day` here stays exactly the simulator's own
/// definition.
let serviceDayStartHour = 11.0

let cityCenter = GeoPoint(latitude: 38.5598, longitude: 68.7870)
let cityRadiusKm = 6.0
/// 2, not 3. Restaurants are drawn within `0.5 * cityRadiusKm` of the centre, so a 3x3
/// grid over the full +/-6 km bounding box drops almost every restaurant into the single
/// middle cell. A 2x2 quadrant split spreads the 12 restaurants across all four zones,
/// which is what the anomaly detector needs for `zone` to be a dimension at all.
let zoneDivisions = 2

func makeConfig(seed: UInt64) -> MarketplaceSimulator.Config {
    MarketplaceSimulator.Config(
        seed: seed,
        courierCount: courierCount,
        orderCount: orderCount,
        durationMinutes: durationMinutes,
        cityCenter: cityCenter,
        cityRadiusKm: cityRadiusKm,
        latent: .realistic
    )
}

// MARK: - Paths

let repoRoot: URL = {
    // argv[1] if given, else two levels up from this file's build location.
    if CommandLine.arguments.count > 1 {
        return URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
}()
let dataDir = repoRoot.appendingPathComponent("ml/data", isDirectory: true)
try? FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)

// MARK: - Helpers

func fmt(_ value: Double, _ places: Int = 6) -> String {
    String(format: "%.\(places)f", value)
}

/// Population standard deviation of a sample.
func stdev(_ xs: [Double]) -> Double {
    guard xs.count > 1 else { return 0 }
    let m = xs.reduce(0, +) / Double(xs.count)
    let v = xs.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(xs.count - 1)
    return v.squareRoot()
}

func mean(_ xs: [Double]) -> Double {
    xs.isEmpty ? 0 : xs.reduce(0, +) / Double(xs.count)
}

// MARK: - Naive-ETA reproduction check
//
// The claim on record is that a naive ETA equal to the generating formula
// (quoted prep + nominal travel time) carries roughly +36 min bias / 51 min sd under
// realistic latent settings, and still +24 min bias with latent state switched off —
// because delivery time is dominated by wait-for-assignment, which is emergent
// congestion rather than a term in the formula. Re-measure it here, on the exact
// config that produced it, and ship the numbers alongside the dataset.

struct NaiveCheck: Encodable {
    let label: String
    let seeds: Int
    let delivered: Int
    let biasMinutes: Double
    let sdMinutes: Double
    let maeMinutes: Double
    let meanActualMinutes: Double
    let meanNaiveMinutes: Double
}

func naiveCheck(
    label: String,
    latent: MarketplaceSimulator.LatentVariability,
    seeds: ClosedRange<UInt64>,
    courierCount: Int,
    orderCount: Int,
    durationMinutes: Double
) -> NaiveCheck {
    let costModel = DispatchCostModel()
    var errors: [Double] = []
    var actuals: [Double] = []
    var naives: [Double] = []
    for seed in seeds {
        let cfg = MarketplaceSimulator.Config(
            seed: seed,
            courierCount: courierCount,
            orderCount: orderCount,
            durationMinutes: durationMinutes,
            cityCenter: cityCenter,
            cityRadiusKm: cityRadiusKm,
            latent: latent
        )
        let result = MarketplaceSimulator.run(config: cfg, dispatcher: OptimalBatchDispatcher())
        for record in result.orderRecords {
            guard let actual = record.totalDeliveryMinutes else { continue }
            let naive = record.quotedPrepMinutes + costModel.travelMinutes(km: record.haulKm)
            errors.append(actual - naive)
            actuals.append(actual)
            naives.append(naive)
        }
    }
    return NaiveCheck(
        label: label,
        seeds: seeds.count,
        delivered: errors.count,
        biasMinutes: mean(errors),
        sdMinutes: stdev(errors),
        maeMinutes: mean(errors.map(abs)),
        meanActualMinutes: mean(actuals),
        meanNaiveMinutes: mean(naives)
    )
}

// MARK: - Dataset export

let grid = ZoneGrid(center: cityCenter, radiusKm: cityRadiusKm, divisions: zoneDivisions)
let dispatcher = OptimalBatchDispatcher()

var csv = ""
csv.reserveCapacity(1 << 24)
csv += [
    "day",
    "seed",
    "order_index",
    "restaurant_index",
    "zone",
    "pickup_lat",
    "pickup_lon",
    "haul_km",
    "quoted_prep_minutes",
    "created_at_minutes",
    "hour_of_day",
    "assigned_at_minutes",
    "delivered_at_minutes",
    "wait_to_assign_minutes",
    "total_delivery_minutes",
    "free_couriers_at_creation",
    "pending_orders_at_creation",
    "latent_traffic_multiplier",
    "latent_courier_speed_factor",
].joined(separator: ",")
csv += "\n"

var totalRows = 0
var deliveredRows = 0

for day in 0..<dayCount {
    let seed = UInt64(day + 1)
    let result = MarketplaceSimulator.run(config: makeConfig(seed: seed), dispatcher: dispatcher)
    for (index, record) in result.orderRecords.enumerated() {
        let zone = grid.zone(for: record.pickup)
        var fields: [String] = [
            String(day),
            String(seed),
            String(index),
            String(record.restaurantIndex),
            zone.description,
            fmt(record.pickup.latitude),
            fmt(record.pickup.longitude),
            fmt(record.haulKm, 5),
            fmt(record.quotedPrepMinutes, 5),
            fmt(record.createdAtMinutes, 5),
            fmt(record.hourOfDay, 5),
        ]
        fields.append(record.assignedAtMinutes.map { fmt($0, 5) } ?? "")
        fields.append(record.deliveredAtMinutes.map { fmt($0, 5) } ?? "")
        fields.append(record.waitToAssignMinutes.map { fmt($0, 5) } ?? "")
        fields.append(record.totalDeliveryMinutes.map { fmt($0, 5) } ?? "")
        fields.append(String(record.freeCouriersAtCreation))
        fields.append(String(record.pendingOrdersAtCreation))
        fields.append(fmt(record.latentTrafficMultiplier, 5))
        fields.append(record.latentCourierSpeedFactor.map { fmt($0, 5) } ?? "")
        csv += fields.joined(separator: ",")
        csv += "\n"
        totalRows += 1
        if record.totalDeliveryMinutes != nil { deliveredRows += 1 }
    }
}

let csvURL = dataDir.appendingPathComponent("orders.csv")
try csv.write(to: csvURL, atomically: true, encoding: .utf8)

// MARK: - Metadata

struct Meta: Encodable {
    let generator: String
    let dayCount: Int
    let courierCount: Int
    let restaurantCount: Int
    let orderCountPerDay: Int
    let durationMinutes: Double
    let serviceDayStartHour: Double
    let dispatchIntervalSeconds: Double
    let dispatcher: String
    let cityCenterLat: Double
    let cityCenterLon: Double
    let cityRadiusKm: Double
    let zoneDivisions: Int
    let nominalSpeedKmh: Double
    let latent: [String: Double]
    let rows: Int
    let deliveredRows: Int
    let naiveEtaChecks: [NaiveCheck]
}

let latent = MarketplaceSimulator.LatentVariability.realistic
let meta = Meta(
    generator: "ml/export/main.swift (RavonCore MarketplaceSimulator)",
    dayCount: dayCount,
    courierCount: courierCount,
    restaurantCount: max(3, courierCount / 2),
    orderCountPerDay: orderCount,
    durationMinutes: durationMinutes,
    serviceDayStartHour: serviceDayStartHour,
    dispatchIntervalSeconds: 30,
    dispatcher: dispatcher.name,
    cityCenterLat: cityCenter.latitude,
    cityCenterLon: cityCenter.longitude,
    cityRadiusKm: cityRadiusKm,
    zoneDivisions: zoneDivisions,
    nominalSpeedKmh: DispatchCostModel().averageSpeedKmh,
    latent: [
        "restaurantPrepBiasSigmaMinutes": latent.restaurantPrepBiasSigmaMinutes,
        "prepNoiseSigmaMinutes": latent.prepNoiseSigmaMinutes,
        "courierSpeedSpread": latent.courierSpeedSpread,
        "trafficAmplitude": latent.trafficAmplitude,
        "trafficPeriodMinutes": latent.trafficPeriodMinutes,
    ],
    rows: totalRows,
    deliveredRows: deliveredRows,
    naiveEtaChecks: [
        naiveCheck(
            label: "reference config (240 orders / 180 min / 24 couriers), seeds 1-30, latent=realistic",
            latent: .realistic, seeds: 1...30,
            courierCount: 24, orderCount: 240, durationMinutes: 180
        ),
        naiveCheck(
            label: "reference config (240 orders / 180 min / 24 couriers), seeds 1-30, latent=none",
            latent: .none, seeds: 1...30,
            courierCount: 24, orderCount: 240, durationMinutes: 180
        ),
        naiveCheck(
            label: "export config == default config, all \(dayCount) exported days, latent=realistic",
            latent: .realistic, seeds: 1...UInt64(dayCount),
            courierCount: courierCount, orderCount: orderCount, durationMinutes: durationMinutes
        ),
    ]
)

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
try encoder.encode(meta).write(to: dataDir.appendingPathComponent("meta.json"))

print("wrote \(csvURL.path): \(totalRows) rows (\(deliveredRows) delivered)")
for check in meta.naiveEtaChecks {
    print(String(
        format: "naive ETA — %@: bias %+.1f min, sd %.1f min, n=%d",
        check.label, check.biasMinutes, check.sdMinutes, check.delivered
    ))
}
