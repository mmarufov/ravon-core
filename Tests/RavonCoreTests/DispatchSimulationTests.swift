import XCTest
@testable import RavonCore

/// Regression guards on dispatch *quality*.
///
/// These assert properties of the algorithm rather than exact numbers, so they survive
/// reasonable tuning of the cost model but fail loudly if a change makes dispatch worse.
final class DispatchSimulationTests: XCTestCase {

    private func config(seed: UInt64, couriers: Int = 12) -> MarketplaceSimulator.Config {
        MarketplaceSimulator.Config(
            seed: seed, courierCount: couriers, orderCount: 240, durationMinutes: 180
        )
    }

    /// Batch matching must never serve fewer orders than greedy first-come-first-served.
    ///
    /// Greedy hands the nearest courier to the oldest order with no lookahead, which can
    /// consume the only courier within range of a second order. Optimal matching pays a
    /// little more on one assignment to keep the other feasible. Checked over 30 seeds so
    /// this is a property, not a lucky sample.
    func test_optimalDispatchNeverLosesToGreedy() {
        for seed in UInt64(1)...30 {
            let cfg = config(seed: seed)
            let greedy = MarketplaceSimulator.run(config: cfg, dispatcher: GreedyDispatcher())
            let optimal = MarketplaceSimulator.run(config: cfg, dispatcher: OptimalBatchDispatcher())
            XCTAssertGreaterThanOrEqual(
                optimal.ordersAssigned, greedy.ordersAssigned,
                "seed \(seed): batch matching served fewer orders (\(optimal.ordersAssigned)) than greedy (\(greedy.ordersAssigned))"
            )
        }
    }

    /// Under supply constraint the win must be substantial, not noise. Measured at
    /// +44.6% mean across 30 seeds (min +29.9%, optimal wins 30/30); asserted at 0.35 so
    /// cost-model tuning cannot cause spurious failures while still defending the claim.
    func test_optimalDispatchIsSubstantiallyBetterUnderLoad() {
        var improvements: [Double] = []
        for seed in UInt64(1)...30 {
            let cfg = config(seed: seed)
            let greedy = MarketplaceSimulator.run(config: cfg, dispatcher: GreedyDispatcher())
            let optimal = MarketplaceSimulator.run(config: cfg, dispatcher: OptimalBatchDispatcher())
            improvements.append(
                Double(optimal.ordersAssigned - greedy.ordersAssigned) / Double(greedy.ordersAssigned)
            )
        }
        let mean = improvements.reduce(0, +) / Double(improvements.count)
        XCTAssertGreaterThanOrEqual(mean, 0.35, "mean improvement collapsed to \(mean * 100)%")
    }

    /// The throughput win must not be bought with extra driving — otherwise it is just
    /// burning courier fuel for a better-looking latency number.
    func test_throughputGainDoesNotCostExtraTravel() {
        for seed in UInt64(1)...10 {
            let cfg = config(seed: seed)
            let greedy = MarketplaceSimulator.run(config: cfg, dispatcher: GreedyDispatcher())
            let optimal = MarketplaceSimulator.run(config: cfg, dispatcher: OptimalBatchDispatcher())
            // Measured over these 10 seeds: mean -0.78% (slightly less driving), but the
            // worst single seed is +1.87% — optimal does sometimes drive further. Over 30
            // seeds: mean -1.06%, worst +2.13%. So the honest claim is "no measurable travel
            // penalty", not "-1.4% less travel"; the 10% headroom is what accommodates the
            // per-seed spread, and tightening it to the mean would make this test flaky.
            XCTAssertLessThan(
                optimal.totalCourierTravelKm, greedy.totalCourierTravelKm * 1.10,
                "seed \(seed): optimal drove \(optimal.totalCourierTravelKm) km vs greedy \(greedy.totalCourierTravelKm)"
            )
        }
    }

    /// **The honest finding.** The advantage of optimal matching is a function of
    /// scarcity: it is large when couriers are the bottleneck and vanishes once supply
    /// exceeds demand. Worth encoding so nobody later "optimises" dispatch for a regime
    /// where it cannot matter.
    func test_advantageVanishesWhenCouriersAreAbundant() {
        let scarce = config(seed: 42, couriers: 6)
        let abundant = config(seed: 42, couriers: 48)

        let scarceGain = Double(
            MarketplaceSimulator.run(config: scarce, dispatcher: OptimalBatchDispatcher()).ordersAssigned
            - MarketplaceSimulator.run(config: scarce, dispatcher: GreedyDispatcher()).ordersAssigned
        )
        let abundantGreedy = MarketplaceSimulator.run(config: abundant, dispatcher: GreedyDispatcher())
        let abundantOptimal = MarketplaceSimulator.run(config: abundant, dispatcher: OptimalBatchDispatcher())

        XCTAssertGreaterThan(scarceGain, 20, "expected a large gain when couriers are scarce")
        XCTAssertEqual(
            abundantOptimal.ordersAssigned, abundantGreedy.ordersAssigned,
            "with surplus couriers both strategies should saturate demand"
        )
    }

    /// Determinism: the same seed must produce the same result, or none of the numbers
    /// above mean anything.
    func test_simulationIsReproducible() {
        let cfg = config(seed: 7)
        let first = MarketplaceSimulator.run(config: cfg, dispatcher: OptimalBatchDispatcher())
        let second = MarketplaceSimulator.run(config: cfg, dispatcher: OptimalBatchDispatcher())
        XCTAssertEqual(first.ordersAssigned, second.ordersAssigned)
        XCTAssertEqual(first.meanDeliveryMinutes, second.meanDeliveryMinutes, accuracy: 1e-12)
        XCTAssertEqual(first.totalCourierTravelKm, second.totalCourierTravelKm, accuracy: 1e-12)
        XCTAssertEqual(first.jobsPerCourier, second.jobsPerCourier)
    }

    /// No courier may be excluded from an order they were banned from — the exclusion
    /// list exists because a courier declined or was reassigned away.
    func test_dispatcherRespectsExclusions() {
        let now = Date()
        let center = GeoPoint(latitude: 38.5598, longitude: 68.7870)
        let orderID = UUID(), courierID = UUID()

        let order = DispatchOrder(
            id: orderID, pickup: center, dropoff: center,
            readyAt: now, createdAt: now, excludedCourierIDs: [courierID]
        )
        let banned = DispatchCourier(id: courierID, location: center, idleSince: now)

        for dispatcher in [AnyDispatcher(GreedyDispatcher()), AnyDispatcher(OptimalBatchDispatcher())] {
            let result = dispatcher.assign(couriers: [banned], orders: [order], now: now)
            XCTAssertTrue(result.isEmpty, "\(dispatcher.name) assigned an excluded courier")
        }
    }

    /// Nobody outside the service radius gets dispatched, however idle they are.
    func test_dispatcherRespectsMaxRadius() {
        let now = Date()
        let dushanbe = GeoPoint(latitude: 38.5598, longitude: 68.7870)
        let khujand = GeoPoint(latitude: 40.2833, longitude: 69.6222) // ~200 km away
        let order = DispatchOrder(id: UUID(), pickup: dushanbe, dropoff: dushanbe, readyAt: now, createdAt: now)
        let farCourier = DispatchCourier(
            id: UUID(), location: khujand, idleSince: now.addingTimeInterval(-86_400)
        )
        XCTAssertTrue(
            OptimalBatchDispatcher().assign(couriers: [farCourier], orders: [order], now: now).isEmpty,
            "a courier 200 km away was dispatched"
        )
    }
}

/// Minimal type eraser so both dispatchers can be exercised by the same loop.
private struct AnyDispatcher: Dispatcher {
    let name: String
    private let _assign: @Sendable ([DispatchCourier], [DispatchOrder], Date) -> [Assignment]

    init(_ base: some Dispatcher) {
        name = base.name
        _assign = { base.assign(couriers: $0, orders: $1, now: $2) }
    }
    func assign(couriers: [DispatchCourier], orders: [DispatchOrder], now: Date) -> [Assignment] {
        _assign(couriers, orders, now)
    }
}
