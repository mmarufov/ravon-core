// One order shape for both intake paths. Webhook payloads are REST-shaped
// (snake_case, numeric ids, `admin_graphql_api_id`); the sweep reads GraphQL nodes
// (camelCase, GIDs, enum cancel reasons). Everything downstream sees only this.

export interface OrderSnapshot {
  orderGid: string;
  name: string | null;
  createdAt: Date;
  updatedAt: Date;
  cancelledAt: Date | null;
  // Lower-case Shopify cancel reason: customer, staff, inventory, fraud, declined, other.
  cancelReason: string | null;
}

function date(value: unknown, field: string): Date {
  if (typeof value !== "string") throw new Error(`order snapshot: ${field} missing`);
  const d = new Date(value);
  if (Number.isNaN(d.getTime())) throw new Error(`order snapshot: ${field} unparseable: ${value}`);
  return d;
}

function optionalDate(value: unknown, field: string): Date | null {
  return value === null || value === undefined ? null : date(value, field);
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
export function fromWebhookPayload(p: any): OrderSnapshot {
  const gid =
    typeof p?.admin_graphql_api_id === "string"
      ? p.admin_graphql_api_id
      : p?.id !== undefined
        ? `gid://shopify/Order/${p.id}`
        : null;
  if (!gid) throw new Error("order snapshot: no order id in payload");
  return {
    orderGid: gid,
    name: typeof p.name === "string" ? p.name : null,
    createdAt: date(p.created_at, "created_at"),
    updatedAt: date(p.updated_at, "updated_at"),
    cancelledAt: optionalDate(p.cancelled_at, "cancelled_at"),
    cancelReason: typeof p.cancel_reason === "string" ? p.cancel_reason.toLowerCase() : null,
  };
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
export function fromGraphqlNode(n: any): OrderSnapshot {
  if (typeof n?.id !== "string") throw new Error("order snapshot: node has no id");
  return {
    orderGid: n.id,
    name: typeof n.name === "string" ? n.name : null,
    createdAt: date(n.createdAt, "createdAt"),
    updatedAt: date(n.updatedAt, "updatedAt"),
    cancelledAt: optionalDate(n.cancelledAt, "cancelledAt"),
    cancelReason: typeof n.cancelReason === "string" ? n.cancelReason.toLowerCase() : null,
  };
}
