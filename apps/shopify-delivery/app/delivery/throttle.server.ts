import type { AdminGraphql, GraphqlResult } from "./admin.server";

// Pacing by the GraphQL Admin API's cost bucket.
//
// Shopify meters GraphQL by calculated query cost against a leaky bucket per app and
// store, and reports the bucket on every response as extensions.cost.throttleStatus
// (maximumAvailable, currentlyAvailable, restoreRate). The pacer keeps a local model of
// that bucket, refilled at restoreRate since the last observation, and waits before a
// request whose expected cost exceeds what the model says is available, instead of
// sending it and being THROTTLED. Every response, throttled or not, resets the model to
// what Shopify reported, less the cost of requests this process still has in flight
// (Shopify has already deducted those), so the model cannot drift far from the server's.

export interface ThrottleEvent {
  shop: string;
  operation: string;
  kind: "throttled" | "paced";
  requestedCost: number;
  available: number | null;
  maximum: number | null;
  restoreRate: number | null;
  waitMs: number;
  // Whether this process had a reply from Shopify yet when the event happened: a throttle
  // before the first reply is the restarted-worker case.
  seeded?: boolean;
}

export interface Bucket {
  available: number;
  maximum: number;
  restoreRate: number;
  at: number;
}

// Where the model outlives the process. A worker restarted after a crash otherwise starts
// blind and bursts into a bucket its predecessor had just drained.
export interface BucketStore {
  load(shop: string): Promise<{ bucket: Bucket; costs: Record<string, number> } | null>;
  save(shop: string, b: Bucket, costs: Record<string, number>): void;
}

export interface PacerOptions {
  enabled: boolean;
  record?: (e: ThrottleEvent) => void;
  store?: BucketStore;
  now?: () => number;
  sleep?: (ms: number) => Promise<void>;
}

const realSleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));

export class CostPacer {
  private buckets = new Map<string, Bucket>();
  private lastCost = new Map<string, number>();
  private inflight = new Map<string, number>();
  private loaded = new Map<string, Promise<void>>();
  // Shops this process has had a reply for. Until then a loaded model is provisional.
  private seeded = new Set<string>();
  private readonly now: () => number;
  private readonly sleep: (ms: number) => Promise<void>;

  constructor(private readonly opts: PacerOptions) {
    this.now = opts.now ?? Date.now;
    this.sleep = opts.sleep ?? realSleep;
  }

  get enabled() {
    return this.opts.enabled;
  }

  estimate(operation: string, fallback: number): number {
    return this.lastCost.get(operation) ?? fallback;
  }

  projected(shop: string): number | null {
    const b = this.buckets.get(shop);
    if (!b) return null;
    const elapsed = (this.now() - b.at) / 1000;
    return Math.min(b.maximum, b.available + elapsed * b.restoreRate);
  }

  // Reserve `cost` from the modelled bucket, waiting first if it is not there. The
  // reservation is taken before the wait, so concurrent callers queue behind each other
  // rather than all waking at once to the same refill.
  async acquire(shop: string, operation: string, cost: number): Promise<void> {
    if (!this.opts.enabled) return;
    if (this.opts.store && !this.loaded.has(shop)) {
      this.loaded.set(
        shop,
        this.opts.store.load(shop).then((saved) => {
          if (!saved || this.buckets.has(shop)) return;
          // Less a margin: requests the previous process had in flight when it died were
          // charged by Shopify after its last save.
          const b = saved.bucket;
          this.buckets.set(shop, { ...b, available: b.available - 0.2 * b.maximum });
          for (const [op, c] of Object.entries(saved.costs)) if (!this.lastCost.has(op)) this.lastCost.set(op, c);
        }),
      );
    }
    await this.loaded.get(shop);
    // Until this process has a reply, one request goes out alone and its reply seeds the
    // model; everything else waits for that rather than trusting a guess.
    for (let waited = 0; !this.seeded.has(shop) && (this.inflight.get(shop) ?? 0) > 0 && waited < 10000; waited += 50) {
      await this.sleep(50);
    }
    this.inflight.set(shop, (this.inflight.get(shop) ?? 0) + cost);
    const b = this.buckets.get(shop);
    if (!b) return;
    const avail = this.projected(shop)!;
    b.available = avail - cost;
    b.at = this.now();
    if (avail >= cost) return;
    const waitMs = ((cost - avail) / b.restoreRate) * 1000;
    this.opts.record?.({
      shop,
      operation,
      kind: "paced",
      requestedCost: cost,
      available: avail,
      maximum: b.maximum,
      restoreRate: b.restoreRate,
      waitMs,
    });
    await this.sleep(waitMs);
  }

  // `reserved` is what acquire() took for this request; it is no longer in flight.
  observe(shop: string, operation: string, res: GraphqlResult, reserved = 0): void {
    if (this.opts.enabled) this.inflight.set(shop, Math.max(0, (this.inflight.get(shop) ?? 0) - reserved));
    const cost = res.extensions?.cost;
    if (cost?.requestedQueryCost !== undefined) {
      this.lastCost.set(operation, cost.requestedQueryCost);
    }
    const t = cost?.throttleStatus;
    if (t) {
      const b = {
        available: t.currentlyAvailable - (this.inflight.get(shop) ?? 0),
        maximum: t.maximumAvailable,
        restoreRate: t.restoreRate,
        at: this.now(),
      };
      this.buckets.set(shop, b);
      this.seeded.add(shop);
      this.opts.store?.save(shop, b, Object.fromEntries(this.lastCost));
    }
  }

  // How long until `cost` is available, from the bucket Shopify just reported.
  waitFor(shop: string, cost: number): number {
    const b = this.buckets.get(shop);
    if (!b) return 1000;
    const avail = this.projected(shop)!;
    return avail >= cost ? 0 : ((cost - avail) / b.restoreRate) * 1000;
  }

  async pause(ms: number) {
    await this.sleep(ms);
  }

  isSeeded(shop: string): boolean {
    return this.seeded.has(shop);
  }

  record(e: ThrottleEvent) {
    this.opts.record?.(e);
  }
}

export function isThrottled(res: GraphqlResult): boolean {
  return !!res.errors?.some((e) => e?.extensions?.code === "THROTTLED");
}

// One Admin API call through the pacer. A THROTTLED reply is recorded and retried after
// the wait the reported bucket implies. With pacing off (the negative control) there is
// no wait before sending, and a throttled request is retried after a flat second, which
// is what a client that ignores throttleStatus does.
export async function paced(
  admin: AdminGraphql,
  pacer: CostPacer,
  shop: string,
  operation: string,
  query: string,
  variables: Record<string, unknown>,
  fallbackCost: number,
  maxAttempts = 8,
): Promise<GraphqlResult> {
  for (let attempt = 1; ; attempt++) {
    const cost = pacer.estimate(operation, fallbackCost);
    await pacer.acquire(shop, operation, cost);
    let res: GraphqlResult;
    try {
      res = await admin.request(query, variables);
    } catch (e) {
      pacer.observe(shop, operation, {}, cost);
      throw e;
    }
    pacer.observe(shop, operation, res, cost);
    if (!isThrottled(res)) return res;
    const t = res.extensions?.cost?.throttleStatus;
    const waitMs = pacer.enabled ? Math.max(pacer.waitFor(shop, cost), 50) : 1000;
    pacer.record({
      shop,
      operation,
      seeded: pacer.isSeeded(shop),
      kind: "throttled",
      requestedCost: cost,
      available: t?.currentlyAvailable ?? null,
      maximum: t?.maximumAvailable ?? null,
      restoreRate: t?.restoreRate ?? null,
      waitMs,
    });
    if (attempt >= maxAttempts) {
      throw new Error(`${operation}: THROTTLED on ${attempt} attempts`);
    }
    await pacer.pause(waitMs);
  }
}
