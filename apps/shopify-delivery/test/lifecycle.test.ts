import { describe, expect, it } from "vitest";
import {
  ACCEPT,
  CLAIM,
  COURIER_RUN,
  EDGES,
  cancelMove,
  decide,
  isDeclared,
} from "../app/delivery/lifecycle";
import { fromGraphqlNode, fromWebhookPayload, type OrderSnapshot } from "../app/delivery/snapshot";

const snap = (over: Partial<OrderSnapshot> = {}): OrderSnapshot => ({
  orderGid: "gid://shopify/Order/1",
  name: "#1001",
  createdAt: new Date("2026-10-01T12:00:00Z"),
  updatedAt: new Date("2026-10-01T12:00:00Z"),
  cancelledAt: null,
  cancelReason: null,
  ...over,
});

describe("the edge table", () => {
  it("is Ravon's 36 edges", () => {
    expect(EDGES).toHaveLength(36);
  });

  it("declares every move the app makes", () => {
    expect(isDeclared("created", ACCEPT)).toBe(true);
    expect(isDeclared("accepted", CLAIM)).toBe(true);
    let from = "assigned";
    for (const m of COURIER_RUN) {
      expect(isDeclared(from, m), `${from} -> ${m.to}`).toBe(true);
      from = m.to;
    }
    expect(from).toBe("delivered");
  });
});

describe("decide", () => {
  it("creates a new job accepted, and cancelled too when the first snapshot is a cancel", () => {
    expect(decide(null, snap())).toEqual({ kind: "create", moves: [ACCEPT] });
    const d = decide(null, snap({ cancelledAt: new Date("2026-10-01T12:00:05Z"), cancelReason: "customer" }));
    expect(d).toEqual({ kind: "create", moves: [ACCEPT, cancelMove("customer")] });
  });

  it("refuses a snapshot older than the job's", () => {
    const d = decide({ status: "accepted", shopifyUpdatedAt: new Date("2026-10-01T12:00:10Z") }, snap());
    expect(d).toMatchObject({ kind: "reject", reason: "stale" });
  });

  it("does not treat an equal timestamp as stale (Shopify stamps to the second)", () => {
    const at = new Date("2026-10-01T12:00:00Z");
    const d = decide(
      { status: "accepted", shopifyUpdatedAt: at },
      snap({ updatedAt: at, cancelledAt: at, cancelReason: "customer" }),
    );
    expect(d).toEqual({ kind: "apply", moves: [cancelMove("customer")] });
  });

  it("a late orders/create cannot resurrect a cancelled job", () => {
    const d = decide({ status: "cancelled_by_customer", shopifyUpdatedAt: new Date("2026-10-01T12:00:00Z") }, snap());
    expect(d).toEqual({ kind: "noop" });
  });

  it("a buyer may cancel until pickup; after pickup the edge does not exist", () => {
    const c = snap({ updatedAt: new Date("2026-10-01T12:01:00Z"), cancelledAt: new Date("2026-10-01T12:01:00Z"), cancelReason: "customer" });
    const at = new Date("2026-10-01T12:00:00Z");
    expect(decide({ status: "courier_arrived_restaurant", shopifyUpdatedAt: at }, c).kind).toBe("apply");
    expect(decide({ status: "picked_up", shopifyUpdatedAt: at }, c)).toMatchObject({ kind: "reject", reason: "no_edge" });
    expect(decide({ status: "delivered", shopifyUpdatedAt: at }, c)).toMatchObject({ kind: "reject", reason: "no_edge" });
  });

  it("a store cancel is Ravon's merchant cancel, refused once a courier is assigned", () => {
    const c = snap({ updatedAt: new Date("2026-10-01T12:01:00Z"), cancelledAt: new Date("2026-10-01T12:01:00Z"), cancelReason: "staff" });
    const at = new Date("2026-10-01T12:00:00Z");
    expect(decide({ status: "accepted", shopifyUpdatedAt: at }, c)).toEqual({ kind: "apply", moves: [cancelMove("staff")] });
    expect(decide({ status: "assigned", shopifyUpdatedAt: at }, c)).toMatchObject({ kind: "reject", reason: "no_edge" });
  });

  it("a repeated cancel is a no-op, not a rejection", () => {
    const c = snap({ updatedAt: new Date("2026-10-01T12:01:00Z"), cancelledAt: new Date("2026-10-01T12:01:00Z"), cancelReason: "customer" });
    expect(decide({ status: "cancelled_by_customer", shopifyUpdatedAt: new Date("2026-10-01T12:01:00Z") }, c)).toEqual({ kind: "noop" });
  });
});

describe("snapshots", () => {
  it("reads a REST-shaped webhook payload and a GraphQL node to the same thing", () => {
    const a = fromWebhookPayload({
      id: 820982911946154500,
      admin_graphql_api_id: "gid://shopify/Order/820982911946154500",
      name: "#1001",
      created_at: "2026-10-01T08:00:00-04:00",
      updated_at: "2026-10-01T08:00:05-04:00",
      cancelled_at: "2026-10-01T08:00:05-04:00",
      cancel_reason: "customer",
    });
    const b = fromGraphqlNode({
      id: "gid://shopify/Order/820982911946154500",
      name: "#1001",
      createdAt: "2026-10-01T12:00:00Z",
      updatedAt: "2026-10-01T12:00:05Z",
      cancelledAt: "2026-10-01T12:00:05Z",
      cancelReason: "CUSTOMER",
    });
    expect(a).toEqual(b);
  });

  it("uses the GID, never the numeric id, which loses precision as a JS number", () => {
    const s = fromWebhookPayload({
      id: 820982911946154508,
      admin_graphql_api_id: "gid://shopify/Order/820982911946154508",
      created_at: "2026-10-01T12:00:00Z",
      updated_at: "2026-10-01T12:00:00Z",
    });
    expect(s.orderGid).toBe("gid://shopify/Order/820982911946154508");
  });
});
