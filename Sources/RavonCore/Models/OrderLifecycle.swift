import Foundation

// The order lifecycle as declared data.
//
// Before this file, "what can happen next" and "who may see this order" were
// re-derived by hand in every screen of all three apps, and independently again in
// the SQL guards of migration 13. Those copies drifted, which is how the merchant's
// UI ended up hiding an order at `.assigned` — exactly when the courier was standing
// at the counter asking for the pickup code.
//
// The table below is the single source of truth. Visibility and obligations are
// *derived* from it rather than restated, and `OrderLifecycleInvariants` proves the
// properties that the hand-written copies violated.

/// Who is acting on an order. `system` covers pg_cron jobs and triggers.
public enum OrderActor: String, Codable, Sendable, CaseIterable {
    case consumer
    case merchant
    case courier
    case system

    public var displayName: String {
        switch self {
        case .consumer: return "Клиент"
        case .merchant: return "Ресторан"
        case .courier:  return "Курьер"
        case .system:   return "Система"
        }
    }
}

/// A precondition the server enforces before a transition is allowed. These mirror the
/// `RAISE EXCEPTION` guards in the SECURITY DEFINER RPCs — declaring them here lets the
/// client predict a refusal instead of discovering it as an opaque error.
public enum TransitionGuard: String, Codable, Sendable, Hashable, CaseIterable {
    /// Courier must present the restaurant's 4-digit handoff code.
    case pickupCode
    /// Courier must present the consumer's delivery code.
    case deliveryCode
    /// Leave-at-door requires an uploaded proof photo instead of a code.
    case proofImage
    case courierOnline
    case courierNotBusy
    case courierNotSuspended
    case notOnCancelCooldown
    /// Courier cancel reason is one of the reassignable set — the restaurant is at
    /// fault (`COURIER_RESTAURANT_CLOSED`, `COURIER_ITEMS_UNAVAILABLE`,
    /// `RESTAURANT_TOO_LONG_WAIT`), so the order returns to the pool.
    case reassignableReason
    /// Courier cancel reason is not reassignable — the courier is at fault, so the
    /// order terminates rather than being re-offered.
    case nonReassignableReason
}

/// What a party must be *shown* while an order sits in a given state.
///
/// Obligations are the reason visibility exists. Modelling them explicitly is what makes
/// the merchant hand-off blind spot impossible: the code cannot be an obligation at
/// `.assigned` while the order is simultaneously filtered out of every merchant tab.
public enum OrderObligation: String, Codable, Sendable, Hashable, CaseIterable {
    /// Merchant must display the pickup code so the courier can collect.
    case showPickupCode
    /// Consumer must be able to read their delivery code to the courier.
    case showDeliveryCode
    /// Courier must be shown where to go next.
    case showNavigation
    /// Party is waiting on someone else and must see live progress.
    case trackProgress
    /// Merchant must be told the kitchen has to start cooking.
    case startCooking
}

/// One legal edge in the lifecycle graph.
public struct OrderTransition: Sendable, Hashable {
    public let from: OrderStatus
    public let to: OrderStatus
    public let actor: OrderActor
    /// The SECURITY DEFINER function that performs this transition. There is no other
    /// legal way to move an order: `orders` carries no client UPDATE policy.
    public let rpc: String
    public let guards: Set<TransitionGuard>

    public init(
        from: OrderStatus,
        to: OrderStatus,
        actor: OrderActor,
        rpc: String,
        guards: Set<TransitionGuard> = []
    ) {
        self.from = from
        self.to = to
        self.actor = actor
        self.rpc = rpc
        self.guards = guards
    }
}

public enum OrderLifecycle {

    /// Every legal transition in the system. Derived from migration 13's RPC guards, the
    /// four merchant operations, and the pg_cron jobs.
    ///
    /// Two entries are marked `missingServerSide` below — they are obligations the apps
    /// already try to perform but for which no RPC exists yet. They are listed here
    /// deliberately so the gap is visible in one place instead of failing silently at
    /// runtime (merchant currently calls the *consumer's* cancel RPC).
    public static let transitions: [OrderTransition] = [

        // ── system ────────────────────────────────────────────────────────────────
        .init(from: .scheduled, to: .created, actor: .system, rpc: "activate_scheduled_orders"),

        // ── merchant ──────────────────────────────────────────────────────────────
        .init(from: .created,   to: .accepted,  actor: .merchant, rpc: "merchant_accept_order"),
        .init(from: .created,   to: .rejected,  actor: .merchant, rpc: "merchant_reject_order"),
        .init(from: .accepted,  to: .preparing, actor: .merchant, rpc: "merchant_start_preparing"),
        .init(from: .accepted,  to: .ready,     actor: .merchant, rpc: "merchant_mark_order_ready"),
        .init(from: .preparing, to: .ready,     actor: .merchant, rpc: "merchant_mark_order_ready"),

        // ── courier: claim ────────────────────────────────────────────────────────
        // `claim_order` accepts any pickupable status, so the courier can claim before
        // the food is ready. All three edges converge on `.assigned`.
        .init(from: .accepted,  to: .assigned, actor: .courier, rpc: "claim_order",
              guards: [.courierOnline, .courierNotBusy, .courierNotSuspended]),
        .init(from: .preparing, to: .assigned, actor: .courier, rpc: "claim_order",
              guards: [.courierOnline, .courierNotBusy, .courierNotSuspended]),
        .init(from: .ready,     to: .assigned, actor: .courier, rpc: "claim_order",
              guards: [.courierOnline, .courierNotBusy, .courierNotSuspended]),

        // ── courier: the delivery run ─────────────────────────────────────────────
        .init(from: .assigned, to: .courierArrivedRestaurant, actor: .courier,
              rpc: "courier_arrived_restaurant"),
        .init(from: .courierArrivedRestaurant, to: .pickedUp, actor: .courier,
              rpc: "courier_pickup_order", guards: [.pickupCode]),
        .init(from: .pickedUp, to: .delivering, actor: .courier,
              rpc: "courier_start_delivering"),
        .init(from: .delivering, to: .courierArrivedCustomer, actor: .courier,
              rpc: "courier_arrived_at_customer"),
        // Hand-to-customer requires the code; leave-at-door requires a photo instead.
        .init(from: .courierArrivedCustomer, to: .delivered, actor: .courier,
              rpc: "courier_deliver_order", guards: [.deliveryCode]),
        .init(from: .courierArrivedCustomer, to: .delivered, actor: .courier,
              rpc: "courier_deliver_order", guards: [.proofImage]),

        // ── courier: pre-pickup cancel returns the order to the pool ──────────────
        // Note this is a *backward* edge — the order becomes claimable again rather
        // than terminal. Any "orders only move forward" assumption is wrong.
        // `cancel_order_by_courier` *branches on the reason code* — this is not one
        // edge but two. Restaurant-fault reasons return the order to the pool;
        // everything else terminates it. The invariant suite caught the original
        // single-edge model: it left `.cancelledByCourier` unreachable.
        .init(from: .assigned, to: .ready, actor: .courier,
              rpc: "cancel_order_by_courier", guards: [.notOnCancelCooldown, .reassignableReason]),
        .init(from: .courierArrivedRestaurant, to: .ready, actor: .courier,
              rpc: "cancel_order_by_courier", guards: [.notOnCancelCooldown, .reassignableReason]),
        .init(from: .assigned, to: .cancelledByCourier, actor: .courier,
              rpc: "cancel_order_by_courier", guards: [.notOnCancelCooldown, .nonReassignableReason]),
        .init(from: .courierArrivedRestaurant, to: .cancelledByCourier, actor: .courier,
              rpc: "cancel_order_by_courier", guards: [.notOnCancelCooldown, .nonReassignableReason]),

        // ── consumer: cancel before the food is in motion ─────────────────────────
        // Mirrors `OrderStatus.consumerCanCancel`; the invariant suite asserts they agree.
        .init(from: .scheduled,  to: .cancelledByCustomer, actor: .consumer, rpc: "cancel_order_by_consumer"),
        .init(from: .created,    to: .cancelledByCustomer, actor: .consumer, rpc: "cancel_order_by_consumer"),
        .init(from: .accepted,   to: .cancelledByCustomer, actor: .consumer, rpc: "cancel_order_by_consumer"),
        .init(from: .preparing,  to: .cancelledByCustomer, actor: .consumer, rpc: "cancel_order_by_consumer"),
        .init(from: .ready,      to: .cancelledByCustomer, actor: .consumer, rpc: "cancel_order_by_consumer"),
        .init(from: .assigned,   to: .cancelledByCustomer, actor: .consumer, rpc: "cancel_order_by_consumer"),
        .init(from: .courierArrivedRestaurant, to: .cancelledByCustomer, actor: .consumer, rpc: "cancel_order_by_consumer"),

        // ── merchant cancel — RPC does not exist yet ──────────────────────────────
        // Merchant currently calls `cancel_order_by_consumer` and fails silently.
        .init(from: .accepted,  to: .cancelledByRestaurant, actor: .merchant, rpc: "merchant_cancel_order"),
        .init(from: .preparing, to: .cancelledByRestaurant, actor: .merchant, rpc: "merchant_cancel_order"),
        .init(from: .ready,     to: .cancelledByRestaurant, actor: .merchant, rpc: "merchant_cancel_order"),

        // ── system: escalation ladder / no-show auto-cancel ───────────────────────
        .init(from: .created,   to: .cancelledBySystem, actor: .system, rpc: "run_courier_escalation_ladder"),
        .init(from: .accepted,  to: .cancelledBySystem, actor: .system, rpc: "run_courier_escalation_ladder"),
        .init(from: .preparing, to: .cancelledBySystem, actor: .system, rpc: "run_courier_escalation_ladder"),
        .init(from: .ready,     to: .cancelledBySystem, actor: .system, rpc: "run_courier_escalation_ladder"),
        .init(from: .assigned,  to: .cancelledBySystem, actor: .system, rpc: "run_courier_escalation_ladder"),
        .init(from: .courierArrivedRestaurant, to: .cancelledBySystem, actor: .system, rpc: "run_courier_escalation_ladder"),
        .init(from: .courierArrivedCustomer,   to: .cancelledBySystem, actor: .system, rpc: "mark_no_show_deliveries"),
    ]

    /// `OrderStatus.cancelled` (bare) is a **legacy enum value with no producer**.
    /// Across migrations 01–19 it appears only inside `status NOT IN (...)` terminal
    /// lists — nothing ever assigns it. All three apps carry a `case .cancelled:` branch
    /// that cannot execute.
    ///
    /// It is kept in the enum rather than deleted so historical rows and the Postgres
    /// `order_status` enum still decode, but it is excluded from reachability by design.
    /// Use `.cancelledBySystem` for new system cancellations.
    public static let orphanedLegacyStatuses: Set<OrderStatus> = [.cancelled]

    /// RPCs that exist server-side today (migrations 01–19).
    public static let implementedRPCs: Set<String> = [
        "activate_scheduled_orders",
        "claim_order",
        "courier_arrived_restaurant",
        "courier_pickup_order",
        "courier_start_delivering",
        "courier_arrived_at_customer",
        "courier_deliver_order",
        "cancel_order_by_courier",
        "cancel_order_by_consumer",
        "run_courier_escalation_ladder",
        "mark_no_show_deliveries",
    ]

    /// RPCs the lifecycle requires but which no migration provides yet.
    /// Non-empty means the graph describes behaviour the server cannot perform.
    public static var unimplementedRPCs: Set<String> {
        Set(transitions.map(\.rpc)).subtracting(implementedRPCs)
    }

    // MARK: - Derived queries

    public static func transitions(from status: OrderStatus) -> [OrderTransition] {
        transitions.filter { $0.from == status }
    }

    public static func transitions(from status: OrderStatus, by actor: OrderActor) -> [OrderTransition] {
        transitions.filter { $0.from == status && $0.actor == actor }
    }

    public static func canTransition(from: OrderStatus, to: OrderStatus, by actor: OrderActor) -> Bool {
        transitions.contains { $0.from == from && $0.to == to && $0.actor == actor }
    }

    /// Statuses an actor can move an order out of.
    public static func actionableStatuses(for actor: OrderActor) -> Set<OrderStatus> {
        Set(transitions.filter { $0.actor == actor }.map(\.from))
    }

    // MARK: - Obligations

    /// What `actor` must be shown while an order sits at `status`.
    ///
    /// This is the fix for the hand-off blind spot: the merchant's obligation to show the
    /// pickup code spans `.assigned` and `.courierArrivedRestaurant`, so visibility over
    /// those states is not a UI preference — it is required by the model.
    public static func obligations(for actor: OrderActor, at status: OrderStatus) -> Set<OrderObligation> {
        switch (actor, status) {
        case (.merchant, .created):
            return [.startCooking]
        case (.merchant, .accepted), (.merchant, .preparing):
            return [.startCooking, .trackProgress]
        case (.merchant, .ready):
            return [.trackProgress]
        // The courier is en route or at the counter: the merchant must be able to read
        // out the pickup code for the entire window, not just while cooking.
        case (.merchant, .assigned), (.merchant, .courierArrivedRestaurant):
            return [.showPickupCode, .trackProgress]

        case (.courier, .assigned), (.courier, .pickedUp), (.courier, .delivering):
            return [.showNavigation]
        case (.courier, .courierArrivedRestaurant):
            return [.showNavigation, .trackProgress]

        case (.consumer, .courierArrivedCustomer):
            return [.showDeliveryCode, .trackProgress]
        case (.consumer, _) where status.isActive:
            return [.trackProgress]

        default:
            return []
        }
    }

    /// The statuses an actor must be able to see: anything it can act on, plus anything
    /// it carries an obligation at. Apps should filter their lists with this rather than
    /// hand-rolling a status array per screen.
    public static func visibleStatuses(for actor: OrderActor) -> Set<OrderStatus> {
        var result = actionableStatuses(for: actor)
        for status in OrderStatus.allCases where !obligations(for: actor, at: status).isEmpty {
            result.insert(status)
        }
        return result
    }

    public static func isVisible(_ status: OrderStatus, to actor: OrderActor) -> Bool {
        visibleStatuses(for: actor).contains(status)
    }

    // MARK: - Reachability

    /// Statuses reachable from `start` by any actor. Used to prove no state is orphaned.
    public static func reachableStatuses(from start: OrderStatus) -> Set<OrderStatus> {
        var seen: Set<OrderStatus> = [start]
        var queue: [OrderStatus] = [start]
        while let current = queue.popLast() {
            for edge in transitions(from: current) where !seen.contains(edge.to) {
                seen.insert(edge.to)
                queue.append(edge.to)
            }
        }
        return seen
    }
}

// MARK: - Liveness analysis

extension OrderLifecycle {

    /// Strongly connected components of the lifecycle graph, via Tarjan's algorithm.
    ///
    /// Why this matters: a naive reading says orders only move forward, so termination
    /// is obvious. That is false. `cancel_order_by_courier` with a restaurant-fault
    /// reason sends `.assigned → .ready`, and `.ready` is claimable again — a genuine
    /// cycle. Termination therefore is *not* a structural property of the graph and
    /// cannot be proved by acyclicity.
    ///
    /// What actually bounds it is a rate limit in SQL: `cancel_order_by_courier` refuses
    /// a courier who has cancelled 3 times in 24 hours (`notOnCancelCooldown`), and
    /// `reassign_count` is incremented on every requeue. So every cycle must pass
    /// through a guarded edge, and `test_everyCycleIsBoundedByAGuard` asserts exactly
    /// that. If someone later adds an unguarded backward edge, an order can circulate
    /// forever and that test fails.
    ///
    /// Returns components in reverse topological order; single-status components with
    /// no self-loop are omitted, so a non-empty result means real cycles exist.
    public static func stronglyConnectedComponents() -> [Set<OrderStatus>] {
        var index = 0
        var indices: [OrderStatus: Int] = [:]
        var lowlink: [OrderStatus: Int] = [:]
        var stack: [OrderStatus] = []
        var onStack: Set<OrderStatus> = []
        var components: [Set<OrderStatus>] = []

        // Iterative Tarjan — the recursive form is fine at 17 nodes, but an explicit
        // stack keeps it safe if the status set grows.
        func strongConnect(_ root: OrderStatus) {
            var callStack: [(status: OrderStatus, successors: [OrderStatus], next: Int)] = []

            indices[root] = index
            lowlink[root] = index
            index += 1
            stack.append(root)
            onStack.insert(root)
            callStack.append((root, transitions(from: root).map(\.to), 0))

            while var frame = callStack.popLast() {
                var recursed = false
                while frame.next < frame.successors.count {
                    let successor = frame.successors[frame.next]
                    frame.next += 1
                    if indices[successor] == nil {
                        indices[successor] = index
                        lowlink[successor] = index
                        index += 1
                        stack.append(successor)
                        onStack.insert(successor)
                        callStack.append(frame)
                        callStack.append((successor, transitions(from: successor).map(\.to), 0))
                        recursed = true
                        break
                    } else if onStack.contains(successor) {
                        lowlink[frame.status] = min(lowlink[frame.status]!, indices[successor]!)
                    }
                }
                if recursed { continue }

                // Frame complete: if it is a component root, pop the component.
                if lowlink[frame.status] == indices[frame.status] {
                    var component: Set<OrderStatus> = []
                    while let popped = stack.popLast() {
                        onStack.remove(popped)
                        component.insert(popped)
                        if popped == frame.status { break }
                    }
                    let selfLoop = transitions(from: frame.status).contains { $0.to == frame.status }
                    if component.count > 1 || selfLoop {
                        components.append(component)
                    }
                }
                // Propagate lowlink to the parent frame.
                if var parent = callStack.popLast() {
                    parent.next = parent.next
                    lowlink[parent.status] = min(lowlink[parent.status]!, lowlink[frame.status]!)
                    callStack.append(parent)
                }
            }
        }

        for status in OrderStatus.allCases where indices[status] == nil {
            strongConnect(status)
        }
        return components
    }

    /// Edges whose `from` and `to` both sit inside the same cycle — the edges an order
    /// could traverse repeatedly.
    public static func cyclicTransitions() -> [OrderTransition] {
        let cycles = stronglyConnectedComponents()
        return transitions.filter { edge in
            cycles.contains { $0.contains(edge.from) && $0.contains(edge.to) }
        }
    }

    /// Guards that bound how many times a cycle can be traversed. An edge carrying one
    /// of these cannot be taken indefinitely, because the server rate-limits it.
    public static let boundingGuards: Set<TransitionGuard> = [.notOnCancelCooldown]

    /// Fewest transitions from `start` to `goal`, ignoring guards. Breadth-first, so the
    /// first time `goal` is dequeued the distance is minimal.
    ///
    /// Used to sanity-check the happy path: a scheduled order should be exactly one step
    /// further from delivery than an immediate one.
    public static func minimumSteps(from start: OrderStatus, to goal: OrderStatus) -> Int? {
        if start == goal { return 0 }
        var visited: Set<OrderStatus> = [start]
        var frontier: [OrderStatus] = [start]
        var distance = 0
        while !frontier.isEmpty {
            distance += 1
            var next: [OrderStatus] = []
            for status in frontier {
                for edge in transitions(from: status) where !visited.contains(edge.to) {
                    if edge.to == goal { return distance }
                    visited.insert(edge.to)
                    next.append(edge.to)
                }
            }
            frontier = next
        }
        return nil
    }
}
