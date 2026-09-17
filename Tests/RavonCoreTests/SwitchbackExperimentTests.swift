import XCTest
@testable import RavonCore

/// Findings from the experiment-design study, pinned so they stay true.
///
/// The headline result is not the one that was expected going in, which is why it is
/// worth having tests for.
final class SwitchbackExperimentTests: XCTestCase {

    private func config(seed: UInt64) -> MarketplaceSimulator.Config {
        MarketplaceSimulator.Config(
            seed: seed, courierCount: 12, orderCount: 240, durationMinutes: 180
        )
    }

    private func meanAbsoluteBias(divisions: Int, design: String, seeds: ClosedRange<UInt64>) -> Double {
        var biases: [Double] = []
        for seed in seeds {
            let cfg = config(seed: seed)
            let grid = ZoneGrid(
                center: cfg.cityCenter, radiusKm: cfg.cityRadiusKm, divisions: divisions
            )
            let report = SwitchbackExperiment.run(
                config: cfg,
                control: ZonedDispatcher(base: GreedyDispatcher(), grid: grid),
                treatment: ZonedDispatcher(base: OptimalBatchDispatcher(), grid: grid),
                zoneDivisions: divisions,
                blockMinutes: 30
            )
            guard let bias = report.biasPoints(for: design) else { continue }
            biases.append(abs(bias))
        }
        return biases.reduce(0, +) / Double(biases.count)
    }

    /// **The main finding.** Experiment bias is dominated by whether the *algorithm*
    /// operates at the same granularity the experiment randomises at — not by
    /// arm-to-arm interference.
    ///
    /// A batch optimiser's effect is a property of the whole dispatch decision, not of an
    /// individual order. Evaluate it on half the orders and it is measurably not the same
    /// algorithm. Partitioning dispatch by zone makes each zone a coherent small market,
    /// and the bias collapses by roughly an order of magnitude.
    func test_zonePartitioningCollapsesExperimentBias() {
        let unpartitioned = meanAbsoluteBias(divisions: 1, design: "switchback-zone-x-timeblock", seeds: 1...12)
        let partitioned = meanAbsoluteBias(divisions: 3, design: "switchback-zone-x-timeblock", seeds: 1...12)

        XCTAssertGreaterThan(
            unpartitioned, 10,
            "expected large bias with one global courier pool, got \(unpartitioned) pts"
        )
        XCTAssertLessThan(
            partitioned, 6,
            "expected small bias once dispatch is zone-partitioned, got \(partitioned) pts"
        )
        XCTAssertLessThan(
            partitioned, unpartitioned / 2,
            "zone partitioning should at least halve the bias (\(unpartitioned) → \(partitioned))"
        )
    }

    /// Bias should fall as the partition gets finer — monotone, not a lucky single point.
    func test_biasDecreasesWithFinerPartitioning() {
        let coarse = meanAbsoluteBias(divisions: 1, design: "switchback-zone-x-timeblock", seeds: 1...8)
        let medium = meanAbsoluteBias(divisions: 2, design: "switchback-zone-x-timeblock", seeds: 1...8)
        let fine = meanAbsoluteBias(divisions: 3, design: "switchback-zone-x-timeblock", seeds: 1...8)

        XCTAssertGreaterThan(coarse, medium, "1x1 (\(coarse)) should be worse than 2x2 (\(medium))")
        XCTAssertGreaterThan(medium, fine, "2x2 (\(medium)) should be worse than 3x3 (\(fine))")
    }

    /// **The honest negative result.** At this scale, once dispatch is zone-partitioned,
    /// order-level randomisation is about as unbiased as a switchback.
    ///
    /// That does not contradict DoorDash — it localises *why* switchbacks matter. With 12
    /// couriers spread over 9 zones there is barely any cross-arm competition left to
    /// contaminate, so the temporal blocking has little left to buy. Their markets are far
    /// more densely coupled, with real carryover between time blocks. The transferable
    /// lesson from this experiment is the granularity one, not a reproduction of their
    /// headline.
    func test_switchbackAndNaiveAreComparableOnceZoned() {
        let naive = meanAbsoluteBias(divisions: 3, design: "naive-order-level-ab", seeds: 1...12)
        let switchback = meanAbsoluteBias(divisions: 3, design: "switchback-zone-x-timeblock", seeds: 1...12)

        XCTAssertLessThan(naive, 6, "naive bias unexpectedly large once zoned: \(naive)")
        XCTAssertLessThan(switchback, 6, "switchback bias unexpectedly large once zoned: \(switchback)")
        // Within 3x of each other — i.e. the same order of magnitude, no dramatic winner.
        XCTAssertLessThan(
            max(naive, switchback) / max(min(naive, switchback), 0.01), 3.0,
            "expected comparable bias at this scale, got naive \(naive) vs switchback \(switchback)"
        )
    }

    /// Arm assignment must be balanced, or the comparison is confounded before it starts.
    func test_armAssignmentIsRoughlyBalanced() {
        let cfg = config(seed: 42)
        let run = MarketplaceSimulator.run(config: cfg, dispatcher: GreedyDispatcher())
        let grid = ZoneGrid(center: cfg.cityCenter, radiusKm: cfg.cityRadiusKm, divisions: 3)

        for assignment in [
            ArmAssignment.naiveOrderLevel(salt: 42),
            ArmAssignment.switchback(
                grid: grid, blockMinutes: 30,
                epoch: Date(timeIntervalSince1970: 1_700_000_000), salt: 42
            ),
        ] {
            let treated = run.orderRecords.filter { assignment.arm(for: $0) == .treatment }.count
            let share = Double(treated) / Double(run.orderRecords.count)
            XCTAssertEqual(
                share, 0.5, accuracy: 0.20,
                "\(assignment.name) put \(share * 100)% in treatment"
            )
        }
    }

    /// Arm assignment must be a pure function of the order, so it can be re-derived after
    /// the simulation when computing per-arm metrics.
    func test_armAssignmentIsDeterministic() {
        let cfg = config(seed: 5)
        let run = MarketplaceSimulator.run(config: cfg, dispatcher: GreedyDispatcher())
        let assignment = ArmAssignment.naiveOrderLevel(salt: 5)
        for record in run.orderRecords.prefix(50) {
            XCTAssertEqual(assignment.arm(for: record), assignment.arm(for: record))
        }
    }

    /// Zoned dispatch must never send a courier to an order outside their own zone.
    func test_zonedDispatcherKeepsAssignmentsWithinZone() {
        let center = GeoPoint(latitude: 38.5598, longitude: 68.7870)
        let grid = ZoneGrid(center: center, radiusKm: 6, divisions: 3)
        let now = Date()

        // One courier in the far north-west, one order in the far south-east.
        let nw = GeoPoint(latitude: center.latitude + 0.04, longitude: center.longitude - 0.05)
        let se = GeoPoint(latitude: center.latitude - 0.04, longitude: center.longitude + 0.05)
        XCTAssertNotEqual(grid.zone(for: nw), grid.zone(for: se), "test setup: points must differ in zone")

        let courier = DispatchCourier(id: UUID(), location: nw, idleSince: now)
        let order = DispatchOrder(id: UUID(), pickup: se, dropoff: se, readyAt: now, createdAt: now)

        let zoned = ZonedDispatcher(base: OptimalBatchDispatcher(), grid: grid)
        XCTAssertTrue(
            zoned.assign(couriers: [courier], orders: [order], now: now).isEmpty,
            "zoned dispatch crossed a zone boundary"
        )
    }

    /// Points outside the grid's bounding box must clamp into edge zones rather than
    /// producing out-of-range indices.
    func test_zoneGridClampsOutOfBoundsPoints() {
        let center = GeoPoint(latitude: 38.5598, longitude: 68.7870)
        let grid = ZoneGrid(center: center, radiusKm: 6, divisions: 3)
        let farAway = GeoPoint(latitude: 89, longitude: 179)
        let zone = grid.zone(for: farAway)
        XCTAssertTrue((0..<3).contains(zone.row))
        XCTAssertTrue((0..<3).contains(zone.column))
    }
}
