import Foundation

/// Deterministic discrete-event simulation of the Ravon marketplace.
///
/// There is no way to A/B a dispatch algorithm against real couriers in a pre-launch
/// city, and "it looks faster" is not a claim worth making. So the marketplace runs in
/// simulation: a seeded clock, synthetic order arrivals, couriers that move at a finite
/// speed, and the real ``Dispatcher`` implementations driving assignment.
///
/// Every run is reproducible from its seed, which means a regression in dispatch quality
/// shows up as a changed number in CI rather than as a vague complaint from a courier.
public struct MarketplaceSimulator: Sendable {

    /// SplitMix64. Chosen over `SystemRandomNumberGenerator` because reproducibility is
    /// the entire point — a result you cannot re-derive is not a measurement.
    struct SeededRNG: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// Hidden state the world runs on but no model is allowed to see.
    ///
    /// Without this, the simulator is a closed formula: delivery time is computed from
    /// distance, speed and prep time, all of which would also be model inputs. Any
    /// "prediction" model would simply re-derive the generating equation and score
    /// R² ≈ 1.0, which measures nothing.
    ///
    /// Latent variability creates **genuine irreducible uncertainty** from the model's
    /// point of view: a per-restaurant kitchen bias, per-order prep noise, per-courier
    /// speed, and a time-varying traffic multiplier. The model can observe *outcomes*
    /// and aggregate features, never these parameters. That makes probabilistic
    /// forecasting, calibration (PIT/CRPS) and drift detection real problems with
    /// checkable answers — and it is what lets the true conditional distribution be
    /// known for validation, which production systems never get.
    public struct LatentVariability: Sendable {
        /// Spread of persistent per-restaurant prep bias. Some kitchens are just slow.
        public var restaurantPrepBiasSigmaMinutes: Double
        /// Per-order prep noise on top of the restaurant's bias.
        public var prepNoiseSigmaMinutes: Double
        /// Fractional spread of per-courier speed, e.g. 0.25 → roughly [0.75, 1.25]×.
        public var courierSpeedSpread: Double
        /// Amplitude of the time-varying city-wide traffic multiplier.
        public var trafficAmplitude: Double
        /// Period of the traffic cycle, in minutes.
        public var trafficPeriodMinutes: Double

        public init(
            restaurantPrepBiasSigmaMinutes: Double,
            prepNoiseSigmaMinutes: Double,
            courierSpeedSpread: Double,
            trafficAmplitude: Double,
            trafficPeriodMinutes: Double = 90
        ) {
            self.restaurantPrepBiasSigmaMinutes = restaurantPrepBiasSigmaMinutes
            self.prepNoiseSigmaMinutes = prepNoiseSigmaMinutes
            self.courierSpeedSpread = courierSpeedSpread
            self.trafficAmplitude = trafficAmplitude
            self.trafficPeriodMinutes = trafficPeriodMinutes
        }

        /// Fully determined world — no hidden state. Correct for dispatch-algorithm
        /// comparisons, where latent noise only adds variance to a paired test, and
        /// **wrong** for any prediction task, where it makes the problem trivial.
        public static let none = LatentVariability(
            restaurantPrepBiasSigmaMinutes: 0, prepNoiseSigmaMinutes: 0,
            courierSpeedSpread: 0, trafficAmplitude: 0
        )

        /// Default for prediction work.
        public static let realistic = LatentVariability(
            restaurantPrepBiasSigmaMinutes: 4,
            prepNoiseSigmaMinutes: 3,
            courierSpeedSpread: 0.30,
            trafficAmplitude: 0.35
        )
    }

    public struct Config: Sendable {
        public var seed: UInt64
        public var courierCount: Int
        public var orderCount: Int
        public var durationMinutes: Double
        /// How often dispatch runs. This is the batching window: longer windows give the
        /// matcher more to work with but make every order wait longer before it is even
        /// considered. The simulator's job is to expose that trade.
        public var dispatchIntervalSeconds: Double
        public var cityCenter: GeoPoint
        public var cityRadiusKm: Double
        public var prepMinutesRange: ClosedRange<Double>
        public var latent: LatentVariability

        public init(
            seed: UInt64 = 42,
            courierCount: Int = 12,
            orderCount: Int = 240,
            durationMinutes: Double = 180,
            dispatchIntervalSeconds: Double = 30,
            cityCenter: GeoPoint = GeoPoint(latitude: 38.5598, longitude: 68.7870),
            cityRadiusKm: Double = 6,
            prepMinutesRange: ClosedRange<Double> = 8...25,
            latent: LatentVariability = .none
        ) {
            self.seed = seed
            self.courierCount = courierCount
            self.orderCount = orderCount
            self.durationMinutes = durationMinutes
            self.dispatchIntervalSeconds = dispatchIntervalSeconds
            self.cityCenter = cityCenter
            self.cityRadiusKm = cityRadiusKm
            self.prepMinutesRange = prepMinutesRange
            self.latent = latent
        }
    }

    /// Per-order outcome, needed by the experiment harness to compute per-arm metrics.
    /// Aggregate numbers cannot answer "what happened to the treated orders specifically."
    public struct OrderRecord: Sendable, Hashable {
        public let id: UUID
        public let pickup: GeoPoint
        public let createdAtMinutes: Double
        public let assignedAtMinutes: Double?
        public let deliveredAtMinutes: Double?

        // MARK: Observable features — legitimate model inputs.
        /// Which restaurant, as an opaque id. A model may learn per-restaurant effects
        /// from history but cannot read the restaurant's hidden prep bias.
        public let restaurantIndex: Int
        /// Straight-line pickup → dropoff distance.
        public let haulKm: Double
        /// The prep time the merchant *quoted*, not the true one.
        public let quotedPrepMinutes: Double
        /// Marketplace load at creation — couriers free, orders waiting.
        public let freeCouriersAtCreation: Int
        public let pendingOrdersAtCreation: Int
        public var hourOfDay: Double { (createdAtMinutes / 60).truncatingRemainder(dividingBy: 24) }

        // MARK: Latent truth — for validating a model, never for training it.
        /// The realised traffic multiplier in force when this order was delivered.
        public let latentTrafficMultiplier: Double
        /// The courier's true speed factor, if assigned.
        public let latentCourierSpeedFactor: Double?

        public var waitToAssignMinutes: Double? {
            assignedAtMinutes.map { $0 - createdAtMinutes }
        }
        public var totalDeliveryMinutes: Double? {
            deliveredAtMinutes.map { $0 - createdAtMinutes }
        }
    }

    public struct Result: Sendable {
        public let dispatcherName: String
        public let ordersOffered: Int
        public let ordersAssigned: Int
        public let ordersNeverAssigned: Int
        public let meanWaitToAssignMinutes: Double
        public let p95WaitToAssignMinutes: Double
        public let meanDeliveryMinutes: Double
        public let totalCourierTravelKm: Double
        public let jobsPerCourier: [Int]
        /// 0 = every courier did identical work, 1 = one courier did everything.
        /// The metric that exposes starvation, which mean delivery time hides completely.
        public let giniCoefficient: Double
        public let couriersWithNoWork: Int
        public let orderRecords: [OrderRecord]

        public var assignmentRate: Double {
            ordersOffered == 0 ? 0 : Double(ordersAssigned) / Double(ordersOffered)
        }

        public var summary: String {
            String(
                format: """
                %@:
                  assigned            %d/%d (%.1f%%)
                  wait to assign      mean %.1f min, p95 %.1f min
                  delivery duration   mean %.1f min
                  courier travel      %.1f km total
                  fairness            gini %.3f, %d courier(s) idle all shift
                """,
                dispatcherName, ordersAssigned, ordersOffered, assignmentRate * 100,
                meanWaitToAssignMinutes, p95WaitToAssignMinutes,
                meanDeliveryMinutes, totalCourierTravelKm,
                giniCoefficient, couriersWithNoWork
            )
        }
    }

    // MARK: - Internal simulation state

    private struct SimCourier {
        let id: UUID
        var location: GeoPoint
        var idleSince: Double        // minutes on the sim clock
        var busyUntil: Double        // minutes; <= now means available
        var excluded: Set<UUID> = []
        var jobsCompleted = 0
        var travelKm = 0.0
        /// Latent. >1 is faster than nominal. Invisible to the dispatcher and to any model.
        let speedFactor: Double
    }

    private struct SimOrder {
        let id: UUID
        let restaurantIndex: Int
        let pickup: GeoPoint
        let dropoff: GeoPoint
        let createdAt: Double        // minutes
        /// What the merchant promised — this is what the dispatcher and any model see.
        let quotedReadyAt: Double
        /// When the food is *actually* ready. Latent.
        let trueReadyAt: Double
        var assignedAt: Double?
        var deliveredAt: Double?
        var freeCouriersAtCreation: Int = 0
        var pendingOrdersAtCreation: Int = 0
        var latentTraffic: Double = 1
        var latentCourierSpeed: Double?
    }

    /// Uniform point within `radiusKm` of `center`. Square-root on the radius keeps the
    /// distribution area-uniform instead of clustering everything at the centre.
    private static func randomPoint(
        near center: GeoPoint, radiusKm: Double, rng: inout SeededRNG
    ) -> GeoPoint {
        let distance = radiusKm * Double.random(in: 0...1, using: &rng).squareRoot()
        let bearing = Double.random(in: 0..<(2 * .pi), using: &rng)
        let deltaLat = distance / 111.0
        let cosLat = cos(center.latitude * .pi / 180)
        let deltaLon = distance / (111.0 * (cosLat == 0 ? 1 : cosLat))
        return GeoPoint(
            latitude: center.latitude + deltaLat * sin(bearing),
            longitude: center.longitude + deltaLon * cos(bearing)
        )
    }

    /// Box-Muller, so latent parameters are Gaussian rather than uniform.
    private static func gaussian(mean: Double, sigma: Double, rng: inout SeededRNG) -> Double {
        guard sigma > 0 else { return mean }
        let u1 = max(Double.random(in: 0...1, using: &rng), 1e-12)
        let u2 = Double.random(in: 0...1, using: &rng)
        return mean + sigma * (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }

    /// City-wide traffic at a given minute. A smooth cycle, so a model *could* in
    /// principle learn it from time-of-day features — which is realistic. What it cannot
    /// see is the per-courier and per-restaurant parameters.
    private static func trafficMultiplier(atMinute minute: Double, latent: LatentVariability) -> Double {
        guard latent.trafficAmplitude > 0 else { return 1 }
        let phase = 2 * .pi * minute / latent.trafficPeriodMinutes
        // >1 means slower than nominal.
        return 1 + latent.trafficAmplitude * (1 - cos(phase)) / 2
    }

    public static func run(config: Config, dispatcher: any Dispatcher) -> Result {
        var rng = SeededRNG(seed: config.seed)
        let epoch = Date(timeIntervalSince1970: 1_700_000_000)

        // Restaurants cluster (a city has commercial districts); dropoffs spread out.
        let restaurantCount = max(3, config.courierCount / 2)
        let restaurants = (0..<restaurantCount).map { _ in
            randomPoint(near: config.cityCenter, radiusKm: config.cityRadiusKm * 0.5, rng: &rng)
        }

        // Latent per-restaurant kitchen bias: some kitchens run persistently slow.
        let restaurantPrepBias = (0..<restaurantCount).map { _ in
            gaussian(mean: 0, sigma: config.latent.restaurantPrepBiasSigmaMinutes, rng: &rng)
        }

        var couriers = (0..<config.courierCount).map { _ in
            SimCourier(
                id: UUID(),
                location: randomPoint(near: config.cityCenter, radiusKm: config.cityRadiusKm, rng: &rng),
                idleSince: 0,
                busyUntil: 0,
                speedFactor: max(
                    0.3,
                    gaussian(mean: 1, sigma: config.latent.courierSpeedSpread, rng: &rng)
                )
            )
        }

        var orders: [SimOrder] = (0..<config.orderCount).map { _ in
            let restaurantIndex = Int.random(in: 0..<restaurantCount, using: &rng)
            let createdAt = Double.random(in: 0...config.durationMinutes, using: &rng)
            // The merchant quotes a prep time; the kitchen's real behaviour is the quote
            // plus a persistent per-restaurant bias plus per-order noise. Only the quote
            // is observable.
            let quotedPrep = Double.random(in: config.prepMinutesRange, using: &rng)
            let truePrep = max(
                1,
                quotedPrep + restaurantPrepBias[restaurantIndex]
                    + gaussian(mean: 0, sigma: config.latent.prepNoiseSigmaMinutes, rng: &rng)
            )
            return SimOrder(
                id: UUID(),
                restaurantIndex: restaurantIndex,
                pickup: restaurants[restaurantIndex],
                dropoff: randomPoint(near: config.cityCenter, radiusKm: config.cityRadiusKm, rng: &rng),
                createdAt: createdAt,
                quotedReadyAt: createdAt + quotedPrep,
                trueReadyAt: createdAt + truePrep
            )
        }
        orders.sort { $0.createdAt < $1.createdAt }

        let costModel = DispatchCostModel()
        let step = config.dispatchIntervalSeconds / 60
        // Run past the arrival window so late orders still get a chance to be served.
        let horizon = config.durationMinutes + 90

        var now = 0.0
        while now <= horizon {
            // Orders that exist, aren't assigned, and whose restaurant has accepted.
            let pendingIndices = orders.indices.filter {
                orders[$0].assignedAt == nil && orders[$0].createdAt <= now
            }
            let freeIndices = couriers.indices.filter { couriers[$0].busyUntil <= now }

            if !pendingIndices.isEmpty && !freeIndices.isEmpty {
                let nowDate = epoch.addingTimeInterval(now * 60)
                let dispatchCouriers = freeIndices.map { index -> DispatchCourier in
                    let c = couriers[index]
                    return DispatchCourier(
                        id: c.id,
                        location: c.location,
                        idleSince: epoch.addingTimeInterval(c.idleSince * 60),
                        excludedOrderIDs: c.excluded
                    )
                }
                let dispatchOrders = pendingIndices.map { index -> DispatchOrder in
                    let o = orders[index]
                    return DispatchOrder(
                        id: o.id,
                        pickup: o.pickup,
                        dropoff: o.dropoff,
                        readyAt: epoch.addingTimeInterval(o.quotedReadyAt * 60),
                        createdAt: epoch.addingTimeInterval(o.createdAt * 60)
                    )
                }

                for assignment in dispatcher.assign(
                    couriers: dispatchCouriers, orders: dispatchOrders, now: nowDate
                ) {
                    guard
                        let ci = couriers.firstIndex(where: { $0.id == assignment.courierID }),
                        let oi = orders.firstIndex(where: { $0.id == assignment.orderID }),
                        orders[oi].assignedAt == nil,
                        couriers[ci].busyUntil <= now
                    else { continue }

                    let order = orders[oi]
                    let toPickupKm = couriers[ci].location.distanceKm(to: order.pickup)
                    let legKm = order.pickup.distanceKm(to: order.dropoff)

                    // Latent: the courier's own speed and the current traffic. The
                    // dispatcher planned with nominal speed and had no access to either.
                    let traffic = trafficMultiplier(atMinute: now, latent: config.latent)
                    let speed = couriers[ci].speedFactor
                    func actualMinutes(_ km: Double) -> Double {
                        costModel.travelMinutes(km: km) * traffic / speed
                    }

                    let arriveAt = now + actualMinutes(toPickupKm)
                    // The courier waits on the kitchen's *true* readiness, not the quote.
                    let departAt = max(arriveAt, order.trueReadyAt)
                    let deliverAt = departAt + actualMinutes(legKm)

                    orders[oi].assignedAt = now
                    orders[oi].deliveredAt = deliverAt
                    orders[oi].latentTraffic = traffic
                    orders[oi].latentCourierSpeed = speed
                    orders[oi].freeCouriersAtCreation = freeIndices.count
                    orders[oi].pendingOrdersAtCreation = pendingIndices.count
                    couriers[ci].location = order.dropoff
                    couriers[ci].busyUntil = deliverAt
                    couriers[ci].idleSince = deliverAt
                    couriers[ci].jobsCompleted += 1
                    couriers[ci].travelKm += toPickupKm + legKm
                }
            }
            now += step
        }

        // MARK: metrics

        let assigned = orders.filter { $0.assignedAt != nil }
        let waits = assigned.map { $0.assignedAt! - $0.createdAt }
        let deliveries = assigned.compactMap { order -> Double? in
            guard let delivered = order.deliveredAt else { return nil }
            return delivered - order.createdAt
        }

        func mean(_ xs: [Double]) -> Double {
            xs.isEmpty ? 0 : xs.reduce(0, +) / Double(xs.count)
        }
        func percentile(_ xs: [Double], _ p: Double) -> Double {
            guard !xs.isEmpty else { return 0 }
            let sorted = xs.sorted()
            let rank = Int((Double(sorted.count - 1) * p).rounded())
            return sorted[min(max(rank, 0), sorted.count - 1)]
        }
        /// Gini over completed jobs. Mean delivery time can look excellent while a third
        /// of the fleet earns nothing, so fairness needs its own number.
        func gini(_ counts: [Int]) -> Double {
            guard counts.count > 1 else { return 0 }
            let values = counts.map(Double.init).sorted()
            let total = values.reduce(0, +)
            guard total > 0 else { return 0 }
            let n = Double(values.count)
            let weighted = values.enumerated().reduce(0.0) { acc, pair in
                acc + (2 * Double(pair.offset + 1) - n - 1) * pair.element
            }
            return weighted / (n * total)
        }

        let jobs = couriers.map(\.jobsCompleted)
        return Result(
            dispatcherName: dispatcher.name,
            ordersOffered: orders.count,
            ordersAssigned: assigned.count,
            ordersNeverAssigned: orders.count - assigned.count,
            meanWaitToAssignMinutes: mean(waits),
            p95WaitToAssignMinutes: percentile(waits, 0.95),
            meanDeliveryMinutes: mean(deliveries),
            totalCourierTravelKm: couriers.reduce(0) { $0 + $1.travelKm },
            jobsPerCourier: jobs,
            giniCoefficient: gini(jobs),
            couriersWithNoWork: jobs.filter { $0 == 0 }.count,
            orderRecords: orders.map { order in
                OrderRecord(
                    id: order.id,
                    pickup: order.pickup,
                    createdAtMinutes: order.createdAt,
                    assignedAtMinutes: order.assignedAt,
                    deliveredAtMinutes: order.deliveredAt,
                    restaurantIndex: order.restaurantIndex,
                    haulKm: order.pickup.distanceKm(to: order.dropoff),
                    quotedPrepMinutes: order.quotedReadyAt - order.createdAt,
                    freeCouriersAtCreation: order.freeCouriersAtCreation,
                    pendingOrdersAtCreation: order.pendingOrdersAtCreation,
                    latentTrafficMultiplier: order.latentTraffic,
                    latentCourierSpeedFactor: order.latentCourierSpeed
                )
            }
        )
    }
}
