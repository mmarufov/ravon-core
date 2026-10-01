// A fake Shopify for CI and the flash-sale replay: no network, no secrets.
//
// It is NOT a GraphQL server. It answers exactly the named operations this app and its
// harness send (routed on operation name), and models the four behaviours the mechanisms
// depend on:
//   - the cost bucket: requested cost deducted up front, the unused part refunded,
//     THROTTLED when the bucket cannot cover a request, throttleStatus on every reply;
//   - search-index lag: an order becomes visible to orders(query:) some time after it
//     changes, which is what the sweep's overlap window exists for;
//   - fulfillment orders with remaining quantities: a fulfillmentCreate against a closed
//     fulfillment order is refused with a userError, so the fake cannot be more
//     forgiving than the real API about double writes;
//   - webhooks: HMAC-SHA256 over the raw body with the app secret, the X-Shopify-* headers,
//     and retries on any non-2xx.
// Which of these were checked against the development store, and how, is in RESULTS.md.

import { createHash, createHmac } from "node:crypto";
import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import { uniforms, uuidFrom } from "../app/delivery/geo";

export interface FakeOptions {
  shop: string;
  secret: string;
  webhookUrl: string | null;
  apiVersion: string;
  bucket: { maximum: number; restoreRate: number };
  indexLagMs: [number, number];
  // Does creating an order also send orders/updated? Set from what the development
  // store did in R1.
  updatedOnCreate: boolean;
  costs: Record<string, number>;
  seed: string;
  payloadTemplate: Record<string, unknown>;
  // Shopify's text for a fulfillmentCreate on a closed fulfillment order.
  closedFulfillmentOrderMessage: string;
}

interface FakeFulfillmentOrder {
  id: string;
  status: "OPEN" | "IN_PROGRESS" | "CLOSED" | "CANCELLED";
  lineItems: { id: string; remainingQuantity: number }[];
}

interface FakeFulfillment {
  id: string;
  status: "SUCCESS" | "CANCELLED";
  createdAt: string;
  trackingInfo: { number: string; company: string }[];
}

export interface FakeOrder {
  numericId: number;
  gid: string;
  name: string;
  createdAt: Date;
  updatedAt: Date;
  cancelledAt: Date | null;
  cancelReason: string | null;
  indexedUpdatedAt: Date | null;
  fulfillmentOrders: FakeFulfillmentOrder[];
  fulfillments: FakeFulfillment[];
  fulfillmentCreateCalls: number;
}

export interface FakeStats {
  requests: number;
  throttled: number;
  byOperation: Record<string, number>;
  fulfillmentCreateAccepted: number;
  fulfillmentCreateRefused: number;
  webhooksSent: number;
  webhookRetries: number;
}

export class FakeShopify {
  readonly orders = new Map<string, FakeOrder>();
  readonly stats: FakeStats = {
    requests: 0,
    throttled: 0,
    byOperation: {},
    fulfillmentCreateAccepted: 0,
    fulfillmentCreateRefused: 0,
    webhooksSent: 0,
    webhookRetries: 0,
  };
  private server: Server | null = null;
  private nextId = 1000001;
  private nextFulfillment = 5000001;
  private nextWebhook = 1;
  private available: number;
  private bucketAt = Date.now();
  private timers = new Set<NodeJS.Timeout>();
  private inflightWebhooks = new Set<Promise<void>>();

  constructor(readonly opts: FakeOptions) {
    this.available = opts.bucket.maximum;
  }

  async listen(port: number): Promise<string> {
    this.server = createServer((req, res) => void this.handle(req, res));
    await new Promise<void>((r) => this.server!.listen(port, "127.0.0.1", () => r()));
    return `http://127.0.0.1:${port}`;
  }

  async close(): Promise<void> {
    for (const t of this.timers) clearTimeout(t);
    await Promise.allSettled([...this.inflightWebhooks]);
    await new Promise<void>((r) => (this.server ? this.server.close(() => r()) : r()));
  }

  async drainWebhooks(): Promise<void> {
    while (this.inflightWebhooks.size > 0) await Promise.allSettled([...this.inflightWebhooks]);
  }

  private later(ms: number, fn: () => void) {
    const t = setTimeout(() => {
      this.timers.delete(t);
      fn();
    }, ms);
    this.timers.add(t);
  }

  private reindex(o: FakeOrder) {
    const [u] = uniforms(`lag:${this.opts.seed}:${o.gid}:${o.updatedAt.getTime()}`, 1);
    const [lo, hi] = this.opts.indexLagMs;
    const version = o.updatedAt;
    this.later(lo + u * (hi - lo), () => {
      if (!o.indexedUpdatedAt || o.indexedUpdatedAt < version) o.indexedUpdatedAt = version;
    });
  }

  // Shopify stamps orders to the second.
  private stamp(): Date {
    return new Date(Math.floor(Date.now() / 1000) * 1000);
  }

  // ---- harness-side operations (what orderCreate / orderCancel do on the real store)

  createOrder(opts: { emitWebhooks?: boolean } = {}): FakeOrder {
    const numericId = this.nextId++;
    const now = this.stamp();
    const o: FakeOrder = {
      numericId,
      gid: `gid://shopify/Order/${numericId}`,
      name: `#${numericId - 1000000 + 1000}`,
      createdAt: now,
      updatedAt: now,
      cancelledAt: null,
      cancelReason: null,
      indexedUpdatedAt: null,
      fulfillmentOrders: [
        {
          id: `gid://shopify/FulfillmentOrder/${numericId}`,
          status: "OPEN",
          lineItems: [{ id: `gid://shopify/FulfillmentOrderLineItem/${numericId}`, remainingQuantity: 1 }],
        },
      ],
      fulfillments: [],
      fulfillmentCreateCalls: 0,
    };
    this.orders.set(o.gid, o);
    this.reindex(o);
    if (opts.emitWebhooks !== false) {
      this.emit("orders/create", o);
      if (this.opts.updatedOnCreate) this.emit("orders/updated", o);
    }
    return o;
  }

  cancelOrder(gid: string, reason = "customer"): void {
    const o = this.orders.get(gid);
    if (!o || o.cancelledAt) return;
    const now = this.stamp();
    o.cancelledAt = now;
    o.cancelReason = reason;
    o.updatedAt = now;
    for (const fo of o.fulfillmentOrders) if (fo.status === "OPEN") fo.status = "CANCELLED";
    this.reindex(o);
    this.emit("orders/cancelled", o);
    this.emit("orders/updated", o);
  }

  // ---- webhooks

  payloadFor(o: FakeOrder): Record<string, unknown> {
    const iso = (d: Date | null) => (d ? d.toISOString().replace(".000Z", "Z") : null);
    return {
      ...this.opts.payloadTemplate,
      id: o.numericId,
      admin_graphql_api_id: o.gid,
      name: o.name,
      order_number: o.numericId - 1000000 + 1000,
      created_at: iso(o.createdAt),
      updated_at: iso(o.updatedAt),
      cancelled_at: iso(o.cancelledAt),
      cancel_reason: o.cancelReason,
      fulfillment_status: o.fulfillments.some((f) => f.status === "SUCCESS") ? "fulfilled" : null,
    };
  }

  sign(body: string): string {
    return createHmac("sha256", this.opts.secret).update(body, "utf8").digest("base64");
  }

  emit(topic: string, o: FakeOrder): void {
    if (!this.opts.webhookUrl) return;
    const body = JSON.stringify(this.payloadFor(o));
    const headers = {
      "content-type": "application/json",
      "x-shopify-topic": topic,
      "x-shopify-hmac-sha256": this.sign(body),
      "x-shopify-shop-domain": this.opts.shop,
      "x-shopify-api-version": this.opts.apiVersion,
      // Seeded, so the fault layer's per-delivery decisions repeat from run to run.
      "x-shopify-webhook-id": uuidFrom(`${this.opts.seed}:webhook:${this.nextWebhook}`),
      "x-shopify-event-id": uuidFrom(`${this.opts.seed}:event:${this.nextWebhook++}`),
      "x-shopify-triggered-at": new Date().toISOString(),
    };
    const p = this.deliver(headers, body).finally(() => this.inflightWebhooks.delete(p));
    this.inflightWebhooks.add(p);
  }

  // Shopify retries a non-2xx delivery; compressed here from 8 tries over 4 hours.
  private async deliver(headers: Record<string, string>, body: string): Promise<void> {
    for (let attempt = 1; attempt <= 8; attempt++) {
      try {
        const res = await fetch(this.opts.webhookUrl!, { method: "POST", headers, body });
        if (attempt === 1) this.stats.webhooksSent++;
        else this.stats.webhookRetries++;
        if (res.ok) return;
      } catch {
        // connection refused or reset: retried below
      }
      await new Promise((r) => setTimeout(r, 250 * 2 ** (attempt - 1)));
    }
  }

  // ---- Admin GraphQL

  private refill() {
    const now = Date.now();
    this.available = Math.min(
      this.opts.bucket.maximum,
      this.available + ((now - this.bucketAt) / 1000) * this.opts.bucket.restoreRate,
    );
    this.bucketAt = now;
  }

  private throttleStatus() {
    return {
      maximumAvailable: this.opts.bucket.maximum,
      currentlyAvailable: Math.floor(this.available),
      restoreRate: this.opts.bucket.restoreRate,
    };
  }

  private async handle(req: IncomingMessage, res: ServerResponse) {
    const chunks: Buffer[] = [];
    for await (const c of req) chunks.push(c as Buffer);
    const send = (status: number, body: unknown) => {
      res.writeHead(status, { "content-type": "application/json" });
      res.end(JSON.stringify(body));
    };
    if (req.method !== "POST" || !/\/admin\/api\/[^/]+\/graphql\.json$/.test(req.url ?? "")) {
      return send(404, { errors: "Not Found" });
    }
    const { query, variables } = JSON.parse(Buffer.concat(chunks).toString("utf8"));
    const op = /(?:query|mutation)\s+(\w+)/.exec(query)?.[1] ?? "anonymous";
    this.stats.requests++;
    this.stats.byOperation[op] = (this.stats.byOperation[op] ?? 0) + 1;

    const requested = this.opts.costs[op] ?? 10;
    this.refill();
    if (requested > this.available) {
      this.stats.throttled++;
      return send(200, {
        errors: [{ message: "Throttled", extensions: { code: "THROTTLED" } }],
        extensions: { cost: { requestedQueryCost: requested, actualQueryCost: null, throttleStatus: this.throttleStatus() } },
      });
    }
    this.available -= requested;
    let data: unknown;
    let actual = requested;
    try {
      ({ data, actual } = this.execute(op, variables ?? {}, requested));
    } catch (e) {
      this.available += requested;
      return send(200, { errors: [{ message: String(e) }] });
    }
    this.available = Math.min(this.opts.bucket.maximum, this.available + (requested - actual));
    send(200, {
      data,
      extensions: { cost: { requestedQueryCost: requested, actualQueryCost: actual, throttleStatus: this.throttleStatus() } },
    });
  }

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  private execute(op: string, v: any, requested: number): { data: unknown; actual: number } {
    switch (op) {
      case "RavonSweepOrders":
        return this.sweepOrders(v, requested);
      case "RavonOrderFulfillmentState": {
        const o = this.orders.get(v.id);
        return { data: { order: o ? this.orderNode(o) : null }, actual: requested };
      }
      case "RavonFulfillmentCreate":
        return { data: { fulfillmentCreate: this.fulfillmentCreate(v.fulfillment) }, actual: requested };
      default:
        throw new Error(`fake Shopify does not implement operation ${op}`);
    }
  }

  private orderNode(o: FakeOrder) {
    return {
      id: o.gid,
      name: o.name,
      createdAt: o.createdAt.toISOString(),
      updatedAt: o.updatedAt.toISOString(),
      cancelledAt: o.cancelledAt?.toISOString() ?? null,
      cancelReason: o.cancelReason?.toUpperCase() ?? null,
      displayFulfillmentStatus: o.fulfillments.some((f) => f.status === "SUCCESS") ? "FULFILLED" : "UNFULFILLED",
      fulfillments: o.fulfillments,
      fulfillmentOrders: {
        nodes: o.fulfillmentOrders.map((fo) => ({ ...fo, lineItems: { nodes: fo.lineItems } })),
      },
    };
  }

  // Only the query shape the sweep sends: updated_at:>='ISO', sorted by UPDATED_AT.
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  private sweepOrders(v: any, requested: number) {
    const m = /updated_at:>='([^']+)'/.exec(v.q ?? "");
    if (!m) throw new Error(`fake Shopify cannot parse sweep query ${v.q}`);
    const from = new Date(m[1]);
    const matching = [...this.orders.values()]
      .filter((o) => o.indexedUpdatedAt && o.indexedUpdatedAt >= from)
      .sort((a, b) => a.indexedUpdatedAt!.getTime() - b.indexedUpdatedAt!.getTime() || a.numericId - b.numericId);
    // Keyset cursor (sort key, id), like Shopify's opaque cursors: rows that change between
    // pages move rather than shifting every later page by one.
    const key = (o: FakeOrder): [number, number] => [o.indexedUpdatedAt!.getTime(), o.numericId];
    const after: [number, number] | null = v.after ? JSON.parse(Buffer.from(v.after, "base64").toString()) : null;
    const rest = after
      ? matching.filter((o) => {
          const [t, id] = key(o);
          return t > after[0] || (t === after[0] && id > after[1]);
        })
      : matching;
    const page = rest.slice(0, v.first);
    return {
      data: {
        orders: {
          pageInfo: {
            hasNextPage: rest.length > page.length,
            endCursor: page.length
              ? Buffer.from(JSON.stringify(key(page[page.length - 1]))).toString("base64")
              : null,
          },
          nodes: page.map((o) => {
            const n = this.orderNode(o);
            return {
              id: n.id,
              name: n.name,
              createdAt: n.createdAt,
              updatedAt: n.updatedAt,
              cancelledAt: n.cancelledAt,
              cancelReason: n.cancelReason,
            };
          }),
        },
      },
      actual: Math.min(requested, 2 + page.length),
    };
  }

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  private fulfillmentCreate(input: any) {
    const items: { fulfillmentOrderId: string }[] = input?.lineItemsByFulfillmentOrder ?? [];
    const fos = items.map((i) => {
      for (const o of this.orders.values()) {
        const fo = o.fulfillmentOrders.find((f) => f.id === i.fulfillmentOrderId);
        if (fo) return { o, fo };
      }
      return null;
    });
    const owner = fos.find(Boolean)?.o;
    if (owner) owner.fulfillmentCreateCalls++;
    const bad = fos.find(
      (x) => !x || x.fo.status === "CLOSED" || x.fo.status === "CANCELLED" || x.fo.lineItems.every((l) => l.remainingQuantity === 0),
    );
    if (!owner || bad !== undefined) {
      this.stats.fulfillmentCreateRefused++;
      return {
        fulfillment: null,
        userErrors: [{ field: ["fulfillment"], message: this.opts.closedFulfillmentOrderMessage }],
      };
    }
    for (const x of fos) {
      x!.fo.status = "CLOSED";
      for (const l of x!.fo.lineItems) l.remainingQuantity = 0;
    }
    const f: FakeFulfillment = {
      id: `gid://shopify/Fulfillment/${this.nextFulfillment++}`,
      status: "SUCCESS",
      createdAt: new Date().toISOString(),
      trackingInfo: input.trackingInfo ? [{ number: input.trackingInfo.number, company: input.trackingInfo.company }] : [],
    };
    owner.fulfillments.push(f);
    owner.updatedAt = this.stamp();
    this.reindex(owner);
    this.stats.fulfillmentCreateAccepted++;
    this.emit("orders/updated", owner);
    return { fulfillment: { id: f.id, status: f.status, trackingInfo: f.trackingInfo }, userErrors: [] };
  }
}

export function sha256(s: string): string {
  return createHash("sha256").update(s).digest("hex");
}
