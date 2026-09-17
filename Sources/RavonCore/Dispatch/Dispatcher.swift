import Foundation

/// A courier available for assignment.
public struct DispatchCourier: Sendable, Identifiable, Hashable {
    public let id: UUID
    public let location: GeoPoint
    /// When this courier last finished a delivery (or came online). Drives the fairness
    /// term: a courier idle for 40 minutes should win ties against one idle for 2.
    public let idleSince: Date
    /// Orders this courier has already declined or been excluded from.
    public let excludedOrderIDs: Set<UUID>

    public init(id: UUID, location: GeoPoint, idleSince: Date, excludedOrderIDs: Set<UUID> = []) {
        self.id = id
        self.location = location
        self.idleSince = idleSince
        self.excludedOrderIDs = excludedOrderIDs
    }
}

/// An order waiting for a courier.
public struct DispatchOrder: Sendable, Identifiable, Hashable {
    public let id: UUID
    public let pickup: GeoPoint
    public let dropoff: GeoPoint
    /// When the kitchen expects the food to be ready. A courier arriving earlier waits.
    public let readyAt: Date
    public let createdAt: Date
    public let excludedCourierIDs: Set<UUID>

    public init(
        id: UUID,
        pickup: GeoPoint,
        dropoff: GeoPoint,
        readyAt: Date,
        createdAt: Date,
        excludedCourierIDs: Set<UUID> = []
    ) {
        self.id = id
        self.pickup = pickup
        self.dropoff = dropoff
        self.readyAt = readyAt
        self.createdAt = createdAt
        self.excludedCourierIDs = excludedCourierIDs
    }
}

public struct Assignment: Sendable, Hashable {
    public let courierID: UUID
    public let orderID: UUID
    public let cost: Double
}

/// How the cost of a (courier, order) pair is scored.
///
/// The design decision worth defending: the objective is **not** "minimise total travel
/// distance." Pure distance minimisation produces two pathologies in a real marketplace —
/// couriers on the edge of town never get work (starvation), and an old order keeps losing
/// to newer ones that happen to have a closer courier (tail latency). So the cost carries
/// explicit fairness and urgency credits that trade a little efficiency for bounded
/// waiting. The simulator exists to measure that trade instead of guessing at it.
public struct DispatchCostModel: Sendable {
    /// Average courier speed. Dushanbe traffic on a scooter, not a highway.
    public var averageSpeedKmh: Double
    /// Beyond this, a pair is forbidden rather than merely expensive.
    public var maxAssignmentRadiusKm: Double
    /// Minutes of cost forgiven per minute an order has been waiting. Higher = orders
    /// are dispatched more strictly in age order.
    public var orderAgeCreditPerMinute: Double
    /// Minutes of cost forgiven per minute a courier has been idle. Higher = work is
    /// spread more evenly and starvation disappears, at some cost in total distance.
    public var courierIdleCreditPerMinute: Double
    /// Cap on each credit so a single stale order or bored courier cannot dominate the
    /// whole matching.
    public var maxCreditMinutes: Double

    public init(
        averageSpeedKmh: Double = 18,
        maxAssignmentRadiusKm: Double = 8,
        orderAgeCreditPerMinute: Double = 1.5,
        courierIdleCreditPerMinute: Double = 0.4,
        maxCreditMinutes: Double = 25
    ) {
        self.averageSpeedKmh = averageSpeedKmh
        self.maxAssignmentRadiusKm = maxAssignmentRadiusKm
        self.orderAgeCreditPerMinute = orderAgeCreditPerMinute
        self.courierIdleCreditPerMinute = courierIdleCreditPerMinute
        self.maxCreditMinutes = maxCreditMinutes
    }

    /// Pure distance only — used as the control in simulator experiments.
    public static let distanceOnly = DispatchCostModel(
        orderAgeCreditPerMinute: 0,
        courierIdleCreditPerMinute: 0
    )

    public func travelMinutes(km: Double) -> Double {
        guard averageSpeedKmh > 0 else { return .infinity }
        return km / averageSpeedKmh * 60
    }

    /// Cost in minutes of assigning `courier` to `order` at time `now`.
    ///
    /// Returns ``HungarianSolver/forbidden`` for pairs that must not be matched, so the
    /// solver treats them as unmatchable rather than just unattractive.
    public func cost(courier: DispatchCourier, order: DispatchOrder, now: Date) -> Double {
        if courier.excludedOrderIDs.contains(order.id) { return HungarianSolver.forbidden }
        if order.excludedCourierIDs.contains(courier.id) { return HungarianSolver.forbidden }

        let toPickupKm = courier.location.distanceKm(to: order.pickup)
        if toPickupKm > maxAssignmentRadiusKm { return HungarianSolver.forbidden }

        let toPickup = travelMinutes(km: toPickupKm)
        let deliveryLeg = travelMinutes(km: order.pickup.distanceKm(to: order.dropoff))

        // Courier idles at the counter if they beat the kitchen. That wasted time is a
        // real cost — it is the courier's, and it delays whatever they'd do next.
        let arrival = now.addingTimeInterval(toPickup * 60)
        let waitAtRestaurant = max(0, order.readyAt.timeIntervalSince(arrival) / 60)

        let orderAgeMinutes = max(0, now.timeIntervalSince(order.createdAt) / 60)
        let courierIdleMinutes = max(0, now.timeIntervalSince(courier.idleSince) / 60)

        let urgencyCredit = min(orderAgeMinutes * orderAgeCreditPerMinute, maxCreditMinutes)
        let fairnessCredit = min(courierIdleMinutes * courierIdleCreditPerMinute, maxCreditMinutes)

        // Cost can legitimately go negative once credits apply; the solver handles that
        // fine (potentials are translation-invariant) and it is what lets a stale order
        // outrank a cheap-but-new one.
        return toPickup + waitAtRestaurant + deliveryLeg - urgencyCredit - fairnessCredit
    }
}

public protocol Dispatcher: Sendable {
    var name: String { get }
    func assign(couriers: [DispatchCourier], orders: [DispatchOrder], now: Date) -> [Assignment]
}

/// What Ravon does today, modelled faithfully so it can be measured.
///
/// `fetch_available_orders` sorts by `created_at` and the first courier to tap wins, so
/// in effect the oldest order is taken by whichever courier is nearest to it, one order
/// at a time, with no lookahead. This reproduces that: it is the baseline the optimal
/// dispatcher has to beat.
public struct GreedyDispatcher: Dispatcher {
    public let name = "greedy-fcfs"
    public let costModel: DispatchCostModel

    public init(costModel: DispatchCostModel = DispatchCostModel()) {
        self.costModel = costModel
    }

    public func assign(
        couriers: [DispatchCourier], orders: [DispatchOrder], now: Date
    ) -> [Assignment] {
        var available = couriers
        var result: [Assignment] = []

        for order in orders.sorted(by: { $0.createdAt < $1.createdAt }) {
            var bestIndex: Int?
            var bestCost = Double.infinity
            for (index, courier) in available.enumerated() {
                let cost = costModel.cost(courier: courier, order: order, now: now)
                guard cost < HungarianSolver.forbidden, cost < bestCost else { continue }
                bestCost = cost
                bestIndex = index
            }
            guard let bestIndex else { continue }   // nobody eligible; order waits
            let courier = available.remove(at: bestIndex)
            result.append(Assignment(courierID: courier.id, orderID: order.id, cost: bestCost))
        }
        return result
    }
}

/// Solves the whole batch at once as a minimum-cost bipartite matching.
///
/// The win over greedy is lookahead: greedy hands the nearest courier to the oldest
/// order, which can consume the only courier reachable by a second order and leave it
/// unassigned. Batch matching pays slightly more on one order to keep the other feasible.
public struct OptimalBatchDispatcher: Dispatcher {
    public let name = "optimal-batch"
    public let costModel: DispatchCostModel

    public init(costModel: DispatchCostModel = DispatchCostModel()) {
        self.costModel = costModel
    }

    public func assign(
        couriers: [DispatchCourier], orders: [DispatchOrder], now: Date
    ) -> [Assignment] {
        guard !couriers.isEmpty, !orders.isEmpty else { return [] }

        let matrix = couriers.map { courier in
            orders.map { order in costModel.cost(courier: courier, order: order, now: now) }
        }
        let matching = HungarianSolver.solve(cost: matrix)

        var result: [Assignment] = []
        for (courierIndex, orderIndex) in matching.enumerated() {
            guard let orderIndex else { continue }
            let cost = matrix[courierIndex][orderIndex]
            guard cost < HungarianSolver.forbidden else { continue }
            result.append(
                Assignment(
                    courierID: couriers[courierIndex].id,
                    orderID: orders[orderIndex].id,
                    cost: cost
                )
            )
        }
        return result
    }
}
