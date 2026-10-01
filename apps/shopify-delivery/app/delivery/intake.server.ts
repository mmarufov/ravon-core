import { createHash } from "node:crypto";
import type pg from "pg";
import { deliveryConfig, type DeliveryConfig } from "./config.server";
import { dropoffFor, STORE } from "./geo";
import { CANCELLED, decide, isDeclared, naiveStatus, type Move } from "./lifecycle";
import { asActor, withTx } from "./pg.server";
import { fromWebhookPayload, type OrderSnapshot } from "./snapshot";

export interface Source {
  kind: "webhook" | "sweep";
  topic: string | null;
  webhookId: string | null;
  arrivedAt: Date | null;
}

export type IngestOutcome =
  | "created"
  | "applied"
  | "noop"
  | "stale"
  | "no_edge"
  | "out_of_window"
  | "duplicate"
  | "duplicate_body_mismatch";

interface JobRow {
  id: string;
  status: string;
  shopify_updated_at: Date;
}

async function lockJob(c: pg.PoolClient, shop: string, orderGid: string): Promise<JobRow | null> {
  const r = await c.query<JobRow>(
    `SELECT id, status, shopify_updated_at FROM jobs
      WHERE shop = $1 AND order_gid = $2 FOR UPDATE`,
    [shop, orderGid],
  );
  return r.rows[0] ?? null;
}

async function insertJob(
  c: pg.PoolClient,
  shop: string,
  snap: OrderSnapshot,
  source: Source,
  onConflict: boolean,
): Promise<JobRow | null> {
  const drop = dropoffFor(snap.orderGid);
  const r = await c.query<JobRow>(
    `INSERT INTO jobs (shop, order_gid, order_name, status, shopify_created_at,
                       shopify_updated_at, shopify_cancelled_at, created_via,
                       created_by_topic, first_arrived_at,
                       pickup_lat, pickup_lng, dropoff_lat, dropoff_lng)
     VALUES ($1, $2, $3, 'created', $4, $5, $6, $7, $8, $9, $10, $11, $12, $13)
     ${onConflict ? "ON CONFLICT (shop, order_gid) DO NOTHING" : ""}
     RETURNING id, status, shopify_updated_at`,
    [
      shop,
      snap.orderGid,
      snap.name,
      snap.createdAt,
      snap.updatedAt,
      snap.cancelledAt,
      source.kind,
      source.topic,
      source.arrivedAt,
      STORE.lat,
      STORE.lng,
      drop.lat,
      drop.lng,
    ],
  );
  return r.rows[0] ?? null;
}

export async function move(
  c: pg.PoolClient,
  jobId: string,
  from: string,
  m: Move,
  cause: string,
  webhookId: string | null,
  enforce = true,
): Promise<void> {
  // The trigger enforces this too; checking first turns a refused edge into a typed
  // error at the call site instead of an aborted transaction.
  if (enforce && !isDeclared(from, m)) {
    throw new Error(`undeclared transition ${from} -> ${m.to} by ${m.actor} via ${m.rpc}`);
  }
  await asActor(c, m.actor, m.rpc);
  await c.query(`UPDATE jobs SET status = $2 WHERE id = $1`, [jobId, m.to]);
  await c.query(
    `INSERT INTO job_transitions (job_id, from_status, to_status, actor, rpc, cause, webhook_id)
     VALUES ($1, $2, $3, $4, $5, $6, $7)`,
    [jobId, from, m.to, m.actor, m.rpc, cause, webhookId],
  );
  if (CANCELLED.has(m.to)) {
    // A cancelled job releases its simulated courier.
    await c.query(
      `UPDATE sim_couriers SET busy_job = NULL, idle_since = clock_timestamp() WHERE busy_job = $1`,
      [jobId],
    );
    await c.query(`UPDATE jobs SET sim_next_at = NULL WHERE id = $1`, [jobId]);
  }
}

async function applyMoves(
  c: pg.PoolClient,
  job: JobRow,
  moves: Move[],
  source: Source,
): Promise<void> {
  let from = job.status;
  for (const m of moves) {
    await move(c, job.id, from, m, source.topic ?? source.kind, source.webhookId);
    from = m.to;
  }
}

async function touchVersion(c: pg.PoolClient, jobId: string, snap: OrderSnapshot, source: Source) {
  await c.query(
    `UPDATE jobs SET shopify_updated_at   = GREATEST(shopify_updated_at, $2),
                     shopify_cancelled_at = COALESCE(shopify_cancelled_at, $3),
                     first_arrived_at     = LEAST(first_arrived_at, $4),
                     updated_at           = clock_timestamp()
      WHERE id = $1`,
    [jobId, snap.updatedAt, snap.cancelledAt, source.arrivedAt],
  );
}

async function reject(
  c: pg.PoolClient,
  shop: string,
  job: JobRow,
  snap: OrderSnapshot,
  source: Source,
  reason: "stale" | "no_edge",
  requested: string | null,
) {
  await c.query(
    `INSERT INTO rejected_events (job_id, shop, order_gid, source, webhook_id, reason,
                                  requested_status, job_status, event_updated_at, job_updated_at)
     VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)`,
    [
      job.id,
      shop,
      snap.orderGid,
      source.topic ?? source.kind,
      source.webhookId,
      reason,
      requested,
      job.status,
      snap.updatedAt,
      job.shopify_updated_at,
    ],
  );
}

// Applies one order snapshot, from any webhook topic or from the sweep, inside the
// caller's transaction. The webhook and the sweep both land here, so whichever sees an
// order first creates the job and the other finds it: they converge on one row because
// (shop, order_gid) is UNIQUE, not because they coordinate.
export async function ingestSnapshot(
  c: pg.PoolClient,
  shop: string,
  snap: OrderSnapshot,
  source: Source,
  cfg: DeliveryConfig = deliveryConfig(),
): Promise<IngestOutcome> {
  const w = await c.query<{ intake_start: Date }>(
    `SELECT intake_start FROM shops WHERE shop = $1`,
    [shop],
  );
  const start = w.rows[0]?.intake_start;
  if (!start || snap.createdAt.getTime() < start.getTime()) return "out_of_window";

  if (!cfg.on("dedupe")) return ingestWithoutJobKey(c, shop, snap, source, cfg);

  let job = await lockJob(c, shop, snap.orderGid);
  if (!job) {
    const created = await insertJob(c, shop, snap, source, true);
    if (created) {
      const d = decide(null, snap);
      if (d.kind !== "create") throw new Error("unreachable");
      await applyMoves(c, created, d.moves, source);
      return "created";
    }
    // Another transaction inserted it between our SELECT and INSERT. It has committed
    // (ON CONFLICT waited for it), so lock the winner's row and treat this as an update.
    job = await lockJob(c, shop, snap.orderGid);
    if (!job) throw new Error(`job for ${snap.orderGid} vanished after a conflict`);
  }
  return applyToExisting(c, shop, job, snap, source, cfg);
}

async function applyToExisting(
  c: pg.PoolClient,
  shop: string,
  job: JobRow,
  snap: OrderSnapshot,
  source: Source,
  cfg: DeliveryConfig,
): Promise<IngestOutcome> {
  if (!cfg.on("lifecycle")) {
    // Negative control: last writer wins.
    const to = naiveStatus(snap);
    await c.query(
      `UPDATE jobs SET status = $2, shopify_updated_at = $3, updated_at = clock_timestamp()
        WHERE id = $1`,
      [job.id, to, snap.updatedAt],
    );
    if (to !== job.status) {
      await c.query(
        `INSERT INTO job_transitions (job_id, from_status, to_status, actor, rpc, cause, webhook_id)
         VALUES ($1, $2, $3, 'system', 'naive_last_writer_wins', $4, $5)`,
        [job.id, job.status, to, source.topic ?? source.kind, source.webhookId],
      );
      if (CANCELLED.has(to)) {
        await c.query(
          `UPDATE sim_couriers SET busy_job = NULL, idle_since = clock_timestamp() WHERE busy_job = $1`,
          [job.id],
        );
      }
      return "applied";
    }
    return "noop";
  }

  const d = decide({ status: job.status, shopifyUpdatedAt: job.shopify_updated_at }, snap);
  switch (d.kind) {
    case "reject":
      await reject(c, shop, job, snap, source, d.reason, d.requested);
      return d.reason;
    case "noop":
      await touchVersion(c, job.id, snap, source);
      return "noop";
    case "apply":
      await applyMoves(c, job, d.moves, source);
      await touchVersion(c, job.id, snap, source);
      return "applied";
    case "create":
      throw new Error("unreachable");
  }
}

// Negative control for `dedupe`: what a handler without an idempotency key does. Every
// orders/create delivery inserts a job; the sweep and the other topics insert one when a
// read finds none. Needs a schema migrated with --control no_job_key.
async function ingestWithoutJobKey(
  c: pg.PoolClient,
  shop: string,
  snap: OrderSnapshot,
  source: Source,
  cfg: DeliveryConfig,
): Promise<IngestOutcome> {
  const existing = await c.query<JobRow>(
    `SELECT id, status, shopify_updated_at FROM jobs WHERE shop = $1 AND order_gid = $2`,
    [shop, snap.orderGid],
  );
  if (source.topic === "orders/create" || existing.rowCount === 0) {
    const created = await insertJob(c, shop, snap, source, false);
    if (!created) throw new Error("insert without a job key returned no row");
    const d = decide(null, snap);
    if (d.kind !== "create") throw new Error("unreachable");
    await applyMoves(c, created, d.moves, source);
    return "created";
  }
  let outcome: IngestOutcome = "noop";
  for (const row of existing.rows) {
    const locked = await c.query<JobRow>(
      `SELECT id, status, shopify_updated_at FROM jobs WHERE id = $1 FOR UPDATE`,
      [row.id],
    );
    outcome = await applyToExisting(c, shop, locked.rows[0], snap, source, cfg);
  }
  return outcome;
}

export interface WebhookDelivery {
  shop: string;
  topic: string;
  webhookId: string;
  eventId: string | null;
  triggeredAt: string | null;
  payload: unknown;
  rawBody: string;
  arrivedAt: Date;
}

// One delivery, after the template's authenticate.webhook has verified its HMAC.
//
// The receipt and the effect commit together. Acknowledge only after that commit: if this
// throws, the route returns 500 and Shopify retries, and the retry is not mistaken for a
// duplicate because the receipt rolled back with everything else.
export async function handleOrderDelivery(
  d: WebhookDelivery,
  cfg: DeliveryConfig = deliveryConfig(),
): Promise<IngestOutcome> {
  const snap = fromWebhookPayload(d.payload);
  const bodySha = createHash("sha256").update(d.rawBody).digest("hex");
  return withTx(async (c) => {
    let outcome: IngestOutcome | null = null;
    if (cfg.on("receipts")) {
      const r = await c.query(
        `INSERT INTO webhook_receipts (shop, webhook_id, topic, order_gid, body_sha256)
         VALUES ($1, $2, $3, $4, $5) ON CONFLICT (shop, webhook_id) DO NOTHING`,
        [d.shop, d.webhookId, d.topic, snap.orderGid, bodySha],
      );
      if (r.rowCount === 0) {
        const prior = await c.query<{ body_sha256: string }>(
          `SELECT body_sha256 FROM webhook_receipts WHERE shop = $1 AND webhook_id = $2`,
          [d.shop, d.webhookId],
        );
        outcome =
          prior.rows[0]?.body_sha256 === bodySha ? "duplicate" : "duplicate_body_mismatch";
      }
    }
    if (outcome === null) {
      outcome = await ingestSnapshot(
        c,
        d.shop,
        snap,
        { kind: "webhook", topic: d.topic, webhookId: d.webhookId, arrivedAt: d.arrivedAt },
        cfg,
      );
    }
    await c.query(
      `INSERT INTO webhook_log (shop, webhook_id, event_id, topic, order_gid, triggered_at,
                                arrived_at, outcome)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8)`,
      [
        d.shop,
        d.webhookId,
        d.eventId,
        d.topic,
        snap.orderGid,
        d.triggeredAt ? new Date(d.triggeredAt) : null,
        d.arrivedAt,
        outcome,
      ],
    );
    return outcome;
  });
}

export async function ensureShop(shop: string, intakeStart = new Date()): Promise<void> {
  await withTx(async (c) => {
    await c.query(
      `INSERT INTO shops (shop, intake_start) VALUES ($1, $2) ON CONFLICT (shop) DO NOTHING`,
      [shop, intakeStart],
    );
    await c.query(
      `INSERT INTO sweep_state (shop, watermark) VALUES ($1, $2) ON CONFLICT (shop) DO NOTHING`,
      [shop, intakeStart],
    );
  });
}
