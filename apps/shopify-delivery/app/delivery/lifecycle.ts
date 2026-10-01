// Shopify order events mapped onto Ravon's order lifecycle.
//
// The edge table is not restated here: lifecycle.edges.json is generated from
// db/schema/03_lifecycle.sql by scripts/lifecycle_parity.py, which CI also runs to prove it
// is the same graph as Sources/RavonCore/Models/OrderLifecycle.swift. The database trigger
// in db/001_delivery.sql enforces the same rows, so this file only decides which edge an
// event asks for; whether it is legal is a lookup, here and again in PostgreSQL.

import edgesJson from "./lifecycle.edges.json";
import type { OrderSnapshot } from "./snapshot";

export type Actor = "consumer" | "merchant" | "courier" | "system";

export interface Edge {
  from: string;
  to: string;
  actor: Actor;
  rpc: string;
  guards: string[];
}

export interface Move {
  to: string;
  actor: Actor;
  rpc: string;
}

export const EDGES: readonly Edge[] = edgesJson as Edge[];

export function isDeclared(from: string, move: Move): boolean {
  return EDGES.some(
    (e) => e.from === from && e.to === move.to && e.actor === move.actor && e.rpc === move.rpc,
  );
}

// A Shopify order has already been accepted by the store when it is placed, so a new job
// takes the merchant's accept edge immediately.
export const ACCEPT: Move = { to: "accepted", actor: "merchant", rpc: "merchant_accept_order" };

// Assign returned a courier for the job.
export const CLAIM: Move = { to: "assigned", actor: "courier", rpc: "claim_order" };

// The simulated courier's delivery run, one declared edge per step.
export const COURIER_RUN: readonly Move[] = [
  { to: "courier_arrived_restaurant", actor: "courier", rpc: "courier_arrived_restaurant" },
  { to: "picked_up", actor: "courier", rpc: "courier_pickup_order" },
  { to: "delivering", actor: "courier", rpc: "courier_start_delivering" },
  { to: "courier_arrived_customer", actor: "courier", rpc: "courier_arrived_at_customer" },
  { to: "delivered", actor: "courier", rpc: "courier_deliver_order" },
];

export const CANCELLED = new Set([
  "cancelled_by_customer",
  "cancelled_by_restaurant",
  "cancelled_by_system",
  "cancelled_by_courier",
  "rejected",
]);

// Shopify's cancel_reason says who cancelled. A buyer's cancellation is Ravon's consumer
// cancel; every other reason (staff, inventory, fraud, declined, other) is the store's,
// which is Ravon's merchant cancel. The two have different legal sources: a consumer may
// cancel until pickup, a merchant only until a courier is assigned.
export function cancelMove(reason: string | null): Move {
  if (reason === "customer") {
    return { to: "cancelled_by_customer", actor: "consumer", rpc: "cancel_order_by_consumer" };
  }
  return { to: "cancelled_by_restaurant", actor: "merchant", rpc: "merchant_cancel_order" };
}

export interface JobView {
  status: string;
  shopifyUpdatedAt: Date;
}

export type Decision =
  | { kind: "create"; moves: Move[] }
  | { kind: "apply"; moves: Move[] }
  | { kind: "noop" }
  | { kind: "reject"; reason: "stale" | "no_edge"; requested: string | null };

// What an order snapshot (from any webhook topic, or from the sweep) does to a job.
//
// Snapshots, not events: every orders/* payload and every sweep row carries the whole
// order, so all four sources go through this one function and converge on the same row.
// An event is refused when it is older than what the job has already seen (Shopify's
// updated_at is the order's version clock), or when the edge it asks for is not declared
// from the job's current status. Equal timestamps are not stale: Shopify stamps to the
// second, and a create and a cancel can share one.
export function decide(job: JobView | null, snap: OrderSnapshot): Decision {
  if (job === null) {
    const moves: Move[] = [ACCEPT];
    if (snap.cancelledAt) moves.push(cancelMove(snap.cancelReason));
    return { kind: "create", moves };
  }
  if (snap.updatedAt.getTime() < job.shopifyUpdatedAt.getTime()) {
    return {
      kind: "reject",
      reason: "stale",
      requested: snap.cancelledAt ? cancelMove(snap.cancelReason).to : null,
    };
  }
  if (!snap.cancelledAt) return { kind: "noop" };
  if (CANCELLED.has(job.status)) return { kind: "noop" };
  const move = cancelMove(snap.cancelReason);
  if (!isDeclared(job.status, move)) {
    return { kind: "reject", reason: "no_edge", requested: move.to };
  }
  return { kind: "apply", moves: [move] };
}

// The negative control's handler: last writer wins, no version check, no edge check. A
// non-cancelled snapshot puts the job back to `accepted`, which is how a late orders/create
// resurrects an order that was already cancelled. Only used with RAVON_DISABLE=lifecycle,
// against a schema migrated without the trigger.
export function naiveStatus(snap: OrderSnapshot): string {
  return snap.cancelledAt ? cancelMove(snap.cancelReason).to : "accepted";
}
