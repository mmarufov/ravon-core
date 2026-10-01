import type pg from "pg";
import type { AdminGraphql } from "./admin.server";
import type { DeliveryConfig } from "./config.server";
import { ingestSnapshot } from "./intake.server";
import { SWEEP_ORDERS } from "./operations";
import { withTx } from "./pg.server";
import { fromGraphqlNode } from "./snapshot";
import { paced, type CostPacer } from "./throttle.server";

// Reconciliation: page the shop's recently updated orders and feed each one through the
// same ingestSnapshot the webhook uses. A dropped webhook's order is found here and lands
// on the row the webhook would have created; an order the webhook already created is
// found again and changes nothing.
//
// The watermark is the newest updatedAt a completed pass has seen. Each pass queries from
// watermark - overlap, because Shopify's order search is indexed asynchronously: an order
// updated at T can become searchable after a pass has already seen orders newer than T.
// Without the overlap that order would sit behind the watermark forever. The watermark only
// moves after a whole pass, so a pass that dies midway is simply repeated.

export interface SweepOptions {
  overlapMs: number;
  pageSize: number;
}

export interface SweepResult {
  queryFrom: Date;
  pages: number;
  seen: number;
  created: number;
  applied: number;
}

export async function sweepOnce(
  pool: pg.Pool,
  admin: AdminGraphql,
  pacer: CostPacer,
  shop: string,
  cfg: DeliveryConfig,
  opts: SweepOptions,
): Promise<SweepResult> {
  const startedAt = new Date();
  const wm = await pool.query<{ watermark: Date }>(
    `SELECT watermark FROM sweep_state WHERE shop = $1`,
    [shop],
  );
  if (!wm.rows[0]) throw new Error(`no sweep_state for ${shop}`);
  const watermark = wm.rows[0].watermark;
  const queryFrom = new Date(watermark.getTime() - opts.overlapMs);
  const q = `updated_at:>='${queryFrom.toISOString()}'`;

  let after: string | null = null;
  let maxSeen = watermark;
  const out: SweepResult = { queryFrom, pages: 0, seen: 0, created: 0, applied: 0 };
  for (;;) {
    const res = await paced(admin, pacer, shop, "RavonSweepOrders", SWEEP_ORDERS,
      { q, after, first: opts.pageSize }, 2 + opts.pageSize);
    if (res.errors?.length) throw new Error(`sweep: ${JSON.stringify(res.errors)}`);
    const page = res.data.orders;
    out.pages++;
    for (const node of page.nodes) {
      const snap = fromGraphqlNode(node);
      out.seen++;
      if (snap.updatedAt > maxSeen) maxSeen = snap.updatedAt;
      const outcome = await withTx((c) =>
        ingestSnapshot(c, shop, snap, { kind: "sweep", topic: null, webhookId: null, arrivedAt: null }, cfg),
      );
      if (outcome === "created") out.created++;
      if (outcome === "applied") out.applied++;
    }
    if (!page.pageInfo.hasNextPage) break;
    after = page.pageInfo.endCursor;
  }

  await pool.query(
    `UPDATE sweep_state SET watermark = GREATEST(watermark, $2), updated_at = clock_timestamp()
      WHERE shop = $1`,
    [shop, maxSeen],
  );
  await pool.query(
    `INSERT INTO sweep_runs (shop, started_at, finished_at, query_from, pages, orders_seen,
                             jobs_created, applied)
     VALUES ($1, $2, clock_timestamp(), $3, $4, $5, $6, $7)`,
    [shop, startedAt, queryFrom, out.pages, out.seen, out.created, out.applied],
  );
  return out;
}
