import XCTest
@testable import RavonCore

/// Property-based invariants over the order lifecycle graph.
///
/// These are not example tests — they quantify over *every* status, actor and
/// randomized path. Each one corresponds to a class of bug found during the
/// 2026-09-15 fleet audit, so a regression fails here rather than in Dushanbe.
final class OrderLifecycleInvariantTests: XCTestCase {

    /// Deterministic RNG (SplitMix64) so a failing random walk is reproducible from
    /// the seed printed in the failure message.
    private struct SeededRNG: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    // MARK: - Graph shape

    /// No dead ends: an order that is not finished must always have somewhere to go.
    ///
    /// The courier "decline" loop was this bug's cousin — a state the user could enter
    /// and never leave. If a future status is added with no outgoing edge, an order can
    /// strand in it forever and no screen will explain why.
    func test_everyNonTerminalStatusHasAnExit() {
        for status in OrderStatus.allCases where !status.isTerminal {
            XCTAssertFalse(
                OrderLifecycle.transitions(from: status).isEmpty,
                "\(status.rawValue) is non-terminal but has no outgoing transition — an order entering it can never leave"
            )
        }
    }

    /// Terminal states are absorbing: nothing leaves a finished order.
    func test_terminalStatusesAreAbsorbing() {
        for status in OrderStatus.allCases where status.isTerminal {
            XCTAssertTrue(
                OrderLifecycle.transitions(from: status).isEmpty,
                "\(status.rawValue) is terminal but has outgoing transitions"
            )
        }
    }

    /// No orphans: every status must be reachable from a genuine entry point.
    /// An unreachable status means dead code in all three apps' switch statements.
    func test_everyStatusIsReachableFromAnEntryPoint() {
        let reachable = OrderLifecycle.reachableStatuses(from: .scheduled)
            .union(OrderLifecycle.reachableStatuses(from: .created))
        for status in OrderStatus.allCases {
            if OrderLifecycle.orphanedLegacyStatuses.contains(status) {
                // Documented dead value — assert it stays dead rather than silently
                // acquiring a producer.
                XCTAssertFalse(
                    reachable.contains(status),
                    "\(status.rawValue) is documented as orphaned legacy but now has a producer — remove it from orphanedLegacyStatuses"
                )
                continue
            }
            XCTAssertTrue(
                reachable.contains(status),
                "\(status.rawValue) is unreachable from .scheduled or .created — nothing can ever produce it"
            )
        }
    }

    /// A courier cancel must resolve to exactly one of two outcomes — back to the pool,
    /// or terminal — and the two must be distinguished by the reason-code guard rather
    /// than left ambiguous.
    func test_courierCancelBranchesOnReasonCode() {
        for status in [OrderStatus.assigned, .courierArrivedRestaurant] {
            let edges = OrderLifecycle.transitions(from: status, by: .courier)
                .filter { $0.rpc == "cancel_order_by_courier" }
            XCTAssertEqual(edges.count, 2, "courier cancel at \(status.rawValue) must have exactly 2 outcomes")
            XCTAssertEqual(
                Set(edges.map(\.to)), [.ready, .cancelledByCourier],
                "courier cancel at \(status.rawValue) must either requeue or terminate"
            )
            for edge in edges {
                let branded = edge.guards.contains(.reassignableReason)
                    || edge.guards.contains(.nonReassignableReason)
                XCTAssertTrue(
                    branded,
                    "courier cancel \(status.rawValue) → \(edge.to.rawValue) does not say which reason codes select it"
                )
            }
        }
    }

    /// Every order terminates. Randomized walks from both entry points must always
    /// reach a terminal state.
    ///
    /// This is the real safety property. The graph deliberately contains a backward
    /// edge (`assigned → ready` when a courier cancels pre-pickup), so "orders only
    /// move forward" is false and a naive cycle check would not do. What must hold is
    /// that no path *livelocks*.
    func test_allRandomWalksTerminate() {
        let maxSteps = 500
        for seed in 0..<5_000 {
            var rng = SeededRNG(state: UInt64(seed) &+ 1)
            var current: OrderStatus = seed.isMultiple(of: 2) ? .created : .scheduled
            var steps = 0
            var path: [String] = [current.rawValue]

            while !current.isTerminal {
                steps += 1
                guard steps <= maxSteps else {
                    XCTFail("Walk did not terminate in \(maxSteps) steps (seed \(seed)): \(path.joined(separator: " → "))")
                    return
                }
                let options = OrderLifecycle.transitions(from: current)
                guard let next = options.randomElement(using: &rng) else {
                    XCTFail("Non-terminal \(current.rawValue) had no exit (seed \(seed))")
                    return
                }
                current = next.to
                path.append(current.rawValue)
            }
        }
    }

    // MARK: - Obligations imply visibility  (the merchant hand-off bug)

    /// If a party must be *shown* something at a status, it must be able to see orders
    /// in that status.
    ///
    /// This is the audit's worst UI bug encoded as a law. Merchant's order list filtered
    /// out `.assigned`, while the merchant was simultaneously the only party able to read
    /// out the pickup code — so the order vanished from the tablet exactly when the
    /// courier reached the counter. Deriving visibility from obligations makes that
    /// combination unrepresentable.
    func test_anyObligationImpliesVisibility() {
        for actor in OrderActor.allCases {
            for status in OrderStatus.allCases {
                let obligations = OrderLifecycle.obligations(for: actor, at: status)
                guard !obligations.isEmpty else { continue }
                XCTAssertTrue(
                    OrderLifecycle.isVisible(status, to: actor),
                    "\(actor.rawValue) has obligations \(obligations.map(\.rawValue).sorted()) at \(status.rawValue) but cannot see orders in that status"
                )
            }
        }
    }

    /// If a party can act on a status it must be able to see it.
    func test_anyActionableStatusIsVisible() {
        for actor in OrderActor.allCases {
            for status in OrderLifecycle.actionableStatuses(for: actor) {
                XCTAssertTrue(
                    OrderLifecycle.isVisible(status, to: actor),
                    "\(actor.rawValue) can act on \(status.rawValue) but cannot see it"
                )
            }
        }
    }

    /// Explicit regression test for the reported bug: the merchant must not go blind at
    /// any point between the courier being assigned and the food leaving the counter.
    func test_merchantSeesEntireHandoffWindow() {
        for status in [OrderStatus.assigned, .courierArrivedRestaurant] {
            XCTAssertTrue(
                OrderLifecycle.isVisible(status, to: .merchant),
                "merchant is blind at \(status.rawValue) — the courier is at the counter and the pickup code is on this screen"
            )
            XCTAssertTrue(
                OrderLifecycle.obligations(for: .merchant, at: status).contains(.showPickupCode),
                "merchant must be showing the pickup code at \(status.rawValue)"
            )
        }
    }

    // MARK: - The table agrees with the legacy hand-written predicates

    /// `OrderStatus.consumerCanCancel` was written by hand before the table existed.
    /// Proving the two agree is what makes replacing the predicate safe.
    func test_consumerCancelPredicateMatchesTransitionTable() {
        for status in OrderStatus.allCases {
            let fromTable = OrderLifecycle.canTransition(
                from: status, to: .cancelledByCustomer, by: .consumer
            )
            XCTAssertEqual(
                status.consumerCanCancel, fromTable,
                "consumerCanCancel disagrees with the transition table at \(status.rawValue)"
            )
        }
    }

    /// Same cross-check for the courier's pre-pickup cancel.
    func test_courierCancelPredicateMatchesTransitionTable() {
        for status in OrderStatus.allCases {
            let fromTable = OrderLifecycle
                .transitions(from: status, by: .courier)
                .contains { $0.rpc == "cancel_order_by_courier" }
            XCTAssertEqual(
                status.courierCanCancel, fromTable,
                "courierCanCancel disagrees with the transition table at \(status.rawValue)"
            )
        }
    }

    // MARK: - The graph matches what the server can actually do

    /// Every transition names an RPC, and no transition invents one by typo.
    ///
    /// The audit found the merchant app calling `cancel_order_by_consumer` — the
    /// *consumer's* RPC — which failed silently in production. Pinning each edge to a
    /// named function turns that class of mistake into a test failure.
    func test_transitionRPCsAreNamedAndKnown() {
        // Documented gap: these are required by the lifecycle but not yet in migrations.
        let knownMissing: Set<String> = ["merchant_accept_order", "merchant_start_preparing",
                                         "merchant_reject_order", "merchant_mark_order_ready",
                                         "merchant_cancel_order"]
        for transition in OrderLifecycle.transitions {
            XCTAssertFalse(transition.rpc.isEmpty, "\(transition.from.rawValue) → \(transition.to.rawValue) has no RPC")
            let known = OrderLifecycle.implementedRPCs.contains(transition.rpc)
                || knownMissing.contains(transition.rpc)
            XCTAssertTrue(
                known,
                "\(transition.from.rawValue) → \(transition.to.rawValue) names unknown RPC '\(transition.rpc)'"
            )
        }
        // Keep the documented gap honest — if someone implements these, this fails and
        // the allowlist must shrink.
        XCTAssertEqual(
            OrderLifecycle.unimplementedRPCs, knownMissing,
            "the set of missing server-side RPCs changed; update the allowlist"
        )
    }

    /// A courier cancelling pre-pickup must return the order to the claimable pool,
    /// not strand or terminate it.
    func test_courierCancelReturnsOrderToPool() {
        for status in [OrderStatus.assigned, .courierArrivedRestaurant] {
            XCTAssertTrue(
                OrderLifecycle.canTransition(from: status, to: .ready, by: .courier),
                "courier cancel at \(status.rawValue) must return the order to .ready"
            )
        }
        // And `.ready` must be claimable again, or the order is stranded.
        XCTAssertTrue(
            OrderLifecycle.canTransition(from: .ready, to: .assigned, by: .courier),
            ".ready must be re-claimable or a courier cancel strands the order"
        )
    }

    /// Delivery must be provable: completing an order always requires either the
    /// consumer's code or a proof photo. Never neither.
    func test_deliveryAlwaysRequiresProof() {
        let deliveryEdges = OrderLifecycle.transitions.filter { $0.to == .delivered }
        XCTAssertFalse(deliveryEdges.isEmpty, "no transition reaches .delivered")
        for edge in deliveryEdges {
            let hasProof = edge.guards.contains(.deliveryCode) || edge.guards.contains(.proofImage)
            XCTAssertTrue(
                hasProof,
                "\(edge.from.rawValue) → delivered via \(edge.rpc) requires no proof — a courier could mark it delivered from the road"
            )
        }
    }
}

// MARK: - Liveness (graph analysis)

extension OrderLifecycleInvariantTests {

    /// The lifecycle graph is *not* acyclic, and that is a real property of the domain —
    /// a courier cancelling for a restaurant-fault reason returns the order to the pool.
    /// This test pins the cycle so it stays understood rather than discovered.
    func test_theOnlyCycleIsTheCourierRequeueLoop() {
        let components = OrderLifecycle.stronglyConnectedComponents()
        XCTAssertEqual(components.count, 1, "expected exactly one cycle in the lifecycle, found \(components.map { $0.map(\.rawValue).sorted() })")
        guard let cycle = components.first else { return }
        XCTAssertEqual(
            cycle, [.ready, .assigned, .courierArrivedRestaurant],
            "the requeue cycle changed shape: \(cycle.map(\.rawValue).sorted())"
        )
    }

    /// **The liveness proof.**
    ///
    /// Because a cycle exists, termination cannot be established by acyclicity. It holds
    /// only because every edge inside the cycle that makes progress *backwards* is rate
    /// limited server-side — `cancel_order_by_courier` refuses a courier who has already
    /// cancelled three times in 24 hours.
    ///
    /// So the law is: no order may circulate forever. Every backward edge within a cycle
    /// must carry a bounding guard. Add an unguarded one and this fails.
    func test_everyCycleIsBoundedByAGuard() {
        let cycles = OrderLifecycle.stronglyConnectedComponents()
        guard !cycles.isEmpty else { return } // acyclic graph terminates trivially

        for edge in OrderLifecycle.cyclicTransitions() {
            // Forward progress within the cycle is fine; it is the edges that move an
            // order *back* toward an earlier state that must be bounded.
            let goesBackwards = edge.to.stepIndex < edge.from.stepIndex
            guard goesBackwards else { continue }

            let bounded = !edge.guards.isDisjoint(with: OrderLifecycle.boundingGuards)
            XCTAssertTrue(
                bounded,
                "\(edge.from.rawValue) → \(edge.to.rawValue) via \(edge.rpc) moves the order backwards inside a cycle with no bounding guard — an order can circulate forever"
            )
        }
    }

    /// Every non-terminal status must have a path to a terminal one. Stronger than
    /// "has an exit": an exit into a closed cycle would still strand the order.
    func test_everyStatusCanReachATerminalState() {
        let terminals = OrderStatus.allCases.filter(\.isTerminal)
        for status in OrderStatus.allCases where !status.isTerminal {
            let canFinish = terminals.contains { OrderLifecycle.minimumSteps(from: status, to: $0) != nil }
            XCTAssertTrue(
                canFinish,
                "\(status.rawValue) cannot reach any terminal state — an order entering it never completes"
            )
        }
    }

    /// Happy-path sanity: a scheduled order is exactly one transition further from
    /// delivery than an immediate one, and the immediate path is the length the
    /// lifecycle documentation claims.
    func test_happyPathLengthIsStable() {
        let fromCreated = OrderLifecycle.minimumSteps(from: .created, to: .delivered)
        let fromScheduled = OrderLifecycle.minimumSteps(from: .scheduled, to: .delivered)
        XCTAssertNotNil(fromCreated)
        XCTAssertNotNil(fromScheduled)
        guard let created = fromCreated, let scheduled = fromScheduled else { return }
        XCTAssertEqual(
            scheduled, created + 1,
            "a scheduled order should be exactly one activation step further from delivery"
        )
        // created → accepted → assigned → arrived_restaurant → picked_up → delivering
        //   → arrived_customer → delivered
        XCTAssertEqual(created, 7, "shortest path to delivery changed; confirm this is intended")
    }
}
