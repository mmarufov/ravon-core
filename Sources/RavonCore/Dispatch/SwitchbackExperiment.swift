import Foundation

/// Experiment designs for evaluating a dispatch algorithm change.
///
/// ## Why this file exists
///
/// A/B testing a dispatch algorithm by randomising **individual orders** into treatment
/// and control is **invalid**, and the reason is structural rather than statistical:
/// orders in the same place at the same time draw from the *same courier pool*. Serving a
/// treated order well consumes a courier that a control order needed. The two arms
/// interfere, which violates the independence assumption every standard A/B test rests
/// on (SUTVA).
///
/// DoorDash's answer is the **switchback test**: randomise the algorithm over
/// **(geographic zone × time block)** cells, so an entire zone runs one variant for an
/// entire block and the market acts as its own comparison.
///
/// The value of doing this in a simulator is that **ground truth is knowable** — run the
/// world entirely on one algorithm, then entirely on the other, with the same seed, and
/// the difference is the true effect. That makes it possible to *measure the bias* of each
/// experiment design rather than reason about it in the abstract.
public enum ExperimentArm: String, Sendable, CaseIterable {
    case control
    case treatment
}

/// Assigns orders to arms. Deterministic, so an order's arm can be re-derived after the
/// simulation when computing per-arm metrics.
public struct ArmAssignment: Sendable {
    public let name: String
    private let assign: @Sendable (DispatchOrder) -> ExperimentArm
    private let assignRecord: @Sendable (MarketplaceSimulator.OrderRecord) -> ExperimentArm

    public init(
        name: String,
        assign: @escaping @Sendable (DispatchOrder) -> ExperimentArm,
        assignRecord: @escaping @Sendable (MarketplaceSimulator.OrderRecord) -> ExperimentArm
    ) {
        self.name = name
        self.assign = assign
        self.assignRecord = assignRecord
    }

    public func arm(for order: DispatchOrder) -> ExperimentArm { assign(order) }
    public func arm(for record: MarketplaceSimulator.OrderRecord) -> ExperimentArm {
        assignRecord(record)
    }

    /// Hash a UUID to a stable arm. Deterministic and independent of ordering, which is
    /// what makes the assignment re-derivable after the fact.
    private static func hashToArm(_ id: UUID, salt: UInt64) -> ExperimentArm {
        var hash: UInt64 = salt &+ 0x9E37_79B9_7F4A_7C15
        withUnsafeBytes(of: id.uuid) { bytes in
            for byte in bytes {
                hash = (hash ^ UInt64(byte)) &* 0x1000_0000_01B3
            }
        }
        return hash.multipliedReportingOverflow(by: 1).partialValue % 2 == 0 ? .control : .treatment
    }

    /// **The invalid design.** Each order independently coin-flipped into an arm, while
    /// both arms compete for one courier pool.
    public static func naiveOrderLevel(salt: UInt64 = 1) -> ArmAssignment {
        ArmAssignment(
            name: "naive-order-level-ab",
            assign: { hashToArm($0.id, salt: salt) },
            assignRecord: { hashToArm($0.id, salt: salt) }
        )
    }

    /// **The switchback design.** A whole (zone × time block) cell runs one variant, so
    /// orders that compete for the same couriers at the same time are almost always in
    /// the same arm.
    public static func switchback(
        grid: ZoneGrid, blockMinutes: Double, epoch: Date, salt: UInt64 = 1
    ) -> ArmAssignment {
        @Sendable func cellArm(zone: DispatchZone, block: Int) -> ExperimentArm {
            var hash = salt &+ 0x9E37_79B9_7F4A_7C15
            for value in [UInt64(bitPattern: Int64(zone.row)),
                          UInt64(bitPattern: Int64(zone.column)),
                          UInt64(bitPattern: Int64(block))] {
                hash = (hash ^ value) &* 0x1000_0000_01B3
                hash ^= hash >> 29
            }
            return hash % 2 == 0 ? .control : .treatment
        }
        return ArmAssignment(
            name: "switchback-zone-x-timeblock",
            assign: { order in
                let minutes = order.createdAt.timeIntervalSince(epoch) / 60
                let block = Int((minutes / blockMinutes).rounded(.down))
                return cellArm(zone: grid.zone(for: order.pickup), block: block)
            },
            assignRecord: { record in
                let block = Int((record.createdAtMinutes / blockMinutes).rounded(.down))
                return cellArm(zone: grid.zone(for: record.pickup), block: block)
            }
        )
    }
}

/// Runs two dispatchers side by side inside one simulated world, splitting orders by arm
/// while both draw from the **same courier pool** — which is precisely the interference
/// that makes naive A/B testing wrong.
public struct ExperimentDispatcher: Dispatcher {
    public let name: String
    public let control: any Dispatcher
    public let treatment: any Dispatcher
    public let assignment: ArmAssignment

    public init(control: any Dispatcher, treatment: any Dispatcher, assignment: ArmAssignment) {
        self.control = control
        self.treatment = treatment
        self.assignment = assignment
        self.name = "experiment[\(assignment.name)]"
    }

    public func assign(
        couriers: [DispatchCourier], orders: [DispatchOrder], now: Date
    ) -> [Assignment] {
        let treated = orders.filter { assignment.arm(for: $0) == .treatment }
        let controlled = orders.filter { assignment.arm(for: $0) == .control }

        // Whichever arm runs first gets first refusal on the courier pool. Alternating by
        // tick prevents that ordering from becoming a systematic advantage that would
        // masquerade as a treatment effect.
        let treatmentFirst = Int(now.timeIntervalSince1970 / 60) % 2 == 0

        var remaining = couriers
        var result: [Assignment] = []

        func runArm(_ dispatcher: any Dispatcher, _ subset: [DispatchOrder]) {
            guard !subset.isEmpty, !remaining.isEmpty else { return }
            let assignments = dispatcher.assign(couriers: remaining, orders: subset, now: now)
            let consumed = Set(assignments.map(\.courierID))
            remaining.removeAll { consumed.contains($0.id) }
            result.append(contentsOf: assignments)
        }

        if treatmentFirst {
            runArm(treatment, treated)
            runArm(control, controlled)
        } else {
            runArm(control, controlled)
            runArm(treatment, treated)
        }
        return result
    }
}

/// Measures a dispatch change under three designs and reports how badly each one lies.
public struct SwitchbackExperiment: Sendable {

    public struct ArmMetrics: Sendable {
        public let orders: Int
        public let assigned: Int
        public let meanDeliveryMinutes: Double
        public var assignmentRate: Double {
            orders == 0 ? 0 : Double(assigned) / Double(orders)
        }
    }

    public struct DesignResult: Sendable {
        public let designName: String
        public let control: ArmMetrics
        public let treatment: ArmMetrics
        /// Estimated effect on assignment rate, in percentage points.
        public var estimatedLiftPoints: Double {
            (treatment.assignmentRate - control.assignmentRate) * 100
        }
        /// Estimated effect on mean delivery time, in minutes (negative is better).
        public var estimatedDeliveryDeltaMinutes: Double {
            treatment.meanDeliveryMinutes - control.meanDeliveryMinutes
        }
    }

    public struct Report: Sendable {
        /// The true effect, from running the world entirely on each algorithm.
        public let groundTruthLiftPoints: Double
        public let groundTruthDeliveryDeltaMinutes: Double
        public let designs: [DesignResult]

        public func biasPoints(for designName: String) -> Double? {
            designs.first { $0.designName == designName }
                .map { $0.estimatedLiftPoints - groundTruthLiftPoints }
        }

        public var summary: String {
            var lines: [String] = []
            lines.append(String(
                format: "ground truth (full-world A vs full-world B):  lift %+.1f pts, delivery %+.1f min",
                groundTruthLiftPoints, groundTruthDeliveryDeltaMinutes
            ))
            for design in designs {
                let bias = design.estimatedLiftPoints - groundTruthLiftPoints
                // Pad in Swift: `%s` in String(format:) takes a C string, and handing it
                // a Swift String segfaults. `%@` is the correct specifier but does not
                // honour width flags.
                let label = design.designName.padding(
                    toLength: 30, withPad: " ", startingAt: 0
                )
                lines.append(
                    label + String(
                        format: "lift %+6.1f pts  (bias %+6.1f pts)  delivery %+6.1f min",
                        design.estimatedLiftPoints, bias, design.estimatedDeliveryDeltaMinutes
                    )
                )
            }
            return lines.joined(separator: "\n")
        }
    }

    private static func metrics(
        records: [MarketplaceSimulator.OrderRecord], arm: ExperimentArm, assignment: ArmAssignment
    ) -> ArmMetrics {
        let subset = records.filter { assignment.arm(for: $0) == arm }
        let delivered = subset.compactMap(\.totalDeliveryMinutes)
        return ArmMetrics(
            orders: subset.count,
            assigned: subset.filter { $0.assignedAtMinutes != nil }.count,
            meanDeliveryMinutes: delivered.isEmpty
                ? 0 : delivered.reduce(0, +) / Double(delivered.count)
        )
    }

    /// - Parameters:
    ///   - blockMinutes: switchback block length. Short blocks give more randomisation
    ///     units and more statistical power; long blocks reduce carryover between arms.
    ///     The trade DoorDash calls out explicitly.
    public static func run(
        config: MarketplaceSimulator.Config,
        control: any Dispatcher,
        treatment: any Dispatcher,
        zoneDivisions: Int = 3,
        blockMinutes: Double = 30
    ) -> Report {
        // Ground truth: two separate worlds, same seed, one algorithm each.
        let fullControl = MarketplaceSimulator.run(config: config, dispatcher: control)
        let fullTreatment = MarketplaceSimulator.run(config: config, dispatcher: treatment)
        let truthLift =
            (Double(fullTreatment.ordersAssigned) / Double(fullTreatment.ordersOffered)
             - Double(fullControl.ordersAssigned) / Double(fullControl.ordersOffered)) * 100
        let truthDelivery = fullTreatment.meanDeliveryMinutes - fullControl.meanDeliveryMinutes

        let epoch = Date(timeIntervalSince1970: 1_700_000_000)
        let grid = ZoneGrid(
            center: config.cityCenter, radiusKm: config.cityRadiusKm, divisions: zoneDivisions
        )

        let designs: [ArmAssignment] = [
            .naiveOrderLevel(salt: config.seed),
            .switchback(grid: grid, blockMinutes: blockMinutes, epoch: epoch, salt: config.seed),
        ]

        let results = designs.map { assignment -> DesignResult in
            let mixed = MarketplaceSimulator.run(
                config: config,
                dispatcher: ExperimentDispatcher(
                    control: control, treatment: treatment, assignment: assignment
                )
            )
            return DesignResult(
                designName: assignment.name,
                control: metrics(records: mixed.orderRecords, arm: .control, assignment: assignment),
                treatment: metrics(records: mixed.orderRecords, arm: .treatment, assignment: assignment)
            )
        }

        return Report(
            groundTruthLiftPoints: truthLift,
            groundTruthDeliveryDeltaMinutes: truthDelivery,
            designs: results
        )
    }
}
