// What a run measured, computed the same way for the fake and the development store.
// Shopify's side (fulfillments per order) comes from the caller: the fake's state, or a
// read of each order from the real Admin API at the end of the run.

import type pg from "pg";

export interface OrderTruth {
  gid: string;
  cohort: "deliver" | "cancel";
  shopifyCreatedAt: Date;
  // fulfillments Shopify holds for the order with status SUCCESS
  fulfillments: number;
  // how many fulfillmentCreate calls reached Shopify for it, when known (fake only)
  fulfillmentCreateCalls: number | null;
  // when Shopify recorded the first fulfillment; deliveries after it cannot create a job
  firstFulfilledAt: Date | null;
}

export interface RunMetrics {
  orders: { deliver: number; cancel: number };
  jobsPerOrder: Record<string, number>;
  dispatchesPerOrder: Record<string, number>;
  fulfillmentsPerOrder: Record<string, number>;
  deliverCohortExactlyOnce: { jobs: number; dispatches: number; fulfillments: number };
  violations: { gid: string; cohort: string; jobs: number; dispatches: number; fulfillments: number; statuses: string[] }[];
  cancelCohort: {
    endedCancelled: number;
    fulfilled: number;
    cancelRejectedNoEdge: number;
    resurrected: number;
  };
  deliveries: { total: number; dropped: number; duplicated: number; once: number; ordersReordered: number };
  ordersAllDeliveriesDropped: string[];
  sweep: { jobsCreatedBySweep: number; recoverMs: { p50: number | null; max: number | null }; runs: number };
  ordersNeverDispatched: string[];
  rejected: Record<string, number>;
  intakeOutcomes: Record<string, number>;
  reprocessedDuplicateDeliveries: number;
  throttle: Record<string, number>;
  fulfillment: Record<string, number>;
  jobsFailed: number;
  duplicateCreateCalls: number | null;
}

function hist(values: number[]): Record<string, number> {
  const h: Record<string, number> = {};
  for (const v of values) h[String(v)] = (h[String(v)] ?? 0) + 1;
  return h;
}

function pct(sorted: number[], p: number): number | null {
  if (sorted.length === 0) return null;
  return sorted[Math.min(sorted.length - 1, Math.ceil((p / 100) * sorted.length) - 1)];
}

export async function collect(pool: pg.Pool, shop: string, truth: OrderTruth[]): Promise<RunMetrics> {
  const q = async <T extends pg.QueryResultRow>(sql: string, params: unknown[] = []) =>
    (await pool.query<T>(sql, params)).rows;

  const jobs = await q<{ order_gid: string; id: string; status: string; created_via: string; created_at: Date; shopify_created_at: Date; fulfillment_state: string }>(
    `SELECT order_gid, id, status, created_via, created_at, shopify_created_at, fulfillment_state
       FROM ravon_delivery.jobs WHERE shop = $1`,
    [shop],
  );
  const dispatches = await q<{ order_gid: string; n: string }>(
    `SELECT j.order_gid, count(d.id) AS n FROM ravon_delivery.jobs j
       JOIN ravon_delivery.dispatches d ON d.job_id = j.id WHERE j.shop = $1 GROUP BY j.order_gid`,
    [shop],
  );
  const dmap = new Map(dispatches.map((r) => [r.order_gid, Number(r.n)]));
  const jobsBy = new Map<string, typeof jobs>();
  for (const j of jobs) jobsBy.set(j.order_gid, [...(jobsBy.get(j.order_gid) ?? []), j]);

  const violations: RunMetrics["violations"] = [];
  const once = { jobs: 0, dispatches: 0, fulfillments: 0 };
  let endedCancelled = 0;
  let cancelFulfilled = 0;
  for (const t of truth) {
    const js = jobsBy.get(t.gid) ?? [];
    const nd = dmap.get(t.gid) ?? 0;
    if (t.cohort === "deliver") {
      if (js.length === 1) once.jobs++;
      if (nd === 1) once.dispatches++;
      if (t.fulfillments === 1) once.fulfillments++;
      if (js.length !== 1 || nd !== 1 || t.fulfillments !== 1) {
        violations.push({ gid: t.gid, cohort: t.cohort, jobs: js.length, dispatches: nd, fulfillments: t.fulfillments, statuses: js.map((j) => `${j.status}/${j.fulfillment_state}`) });
      }
    } else {
      if (js.length === 1 && js[0].status.startsWith("cancelled")) endedCancelled++;
      if (t.fulfillments > 0) cancelFulfilled++;
      if (js.length !== 1 || t.fulfillments !== 0) {
        violations.push({ gid: t.gid, cohort: t.cohort, jobs: js.length, dispatches: nd, fulfillments: t.fulfillments, statuses: js.map((j) => `${j.status}/${j.fulfillment_state}`) });
      }
    }
  }

  const cancelGids = truth.filter((t) => t.cohort === "cancel").map((t) => t.gid);
  const resurrected = await q<{ n: string }>(
    `SELECT count(DISTINCT j.order_gid) AS n FROM ravon_delivery.job_transitions t
       JOIN ravon_delivery.jobs j ON j.id = t.job_id
      WHERE j.shop = $1 AND j.order_gid = ANY($2)
        AND t.from_status LIKE 'cancelled%' AND t.to_status NOT LIKE 'cancelled%'`,
    [shop, cancelGids],
  );
  const noEdge = await q<{ n: string }>(
    `SELECT count(DISTINCT order_gid) AS n FROM ravon_delivery.rejected_events
      WHERE shop = $1 AND reason = 'no_edge' AND order_gid = ANY($2)`,
    [shop, cancelGids],
  );

  const gids = truth.map((t) => t.gid);
  const faults = await q<{ order_gid: string; action: string; arrived_at: Date; forwarded_at: Date[] }>(
    `SELECT order_gid, action, arrived_at, forwarded_at FROM harness.fault_log WHERE order_gid = ANY($1)`,
    [gids],
  );
  const byOrder = new Map<string, typeof faults>();
  for (const f of faults) byOrder.set(f.order_gid, [...(byOrder.get(f.order_gid) ?? []), f]);
  const allDropped: string[] = [];
  let reordered = 0;
  const fulfilledAt = new Map(truth.map((t) => [t.gid, t.firstFulfilledAt]));
  for (const [gid, fs] of byOrder) {
    // Only the sweep could create this order's job: every delivery Shopify sent before
    // the order was fulfilled was dropped. (After a fulfillment, orders/updated fires
    // again, but by then the job already exists.)
    const cutoff = fulfilledAt.get(gid);
    const before = fs.filter((f) => !cutoff || f.arrived_at < cutoff);
    if (before.every((f) => f.action === "drop")) allDropped.push(gid);
    // Reordered: the app saw this order's deliveries in a different order than Shopify sent them.
    const sent = [...fs].sort((a, b) => a.arrived_at.getTime() - b.arrived_at.getTime());
    const seen = fs
      .flatMap((f) => f.forwarded_at.map((at) => ({ f, at })))
      .sort((a, b) => a.at.getTime() - b.at.getTime())
      .map((x) => x.f);
    const firstSeen = [...new Set(seen)];
    const sentForwarded = sent.filter((f) => firstSeen.includes(f));
    if (firstSeen.some((f, i) => f !== sentForwarded[i])) reordered++;
  }

  const sweepJobs = jobs.filter((j) => j.created_via === "sweep" && gids.includes(j.order_gid));
  const recover = sweepJobs.map((j) => j.created_at.getTime() - j.shopify_created_at.getTime()).sort((a, b) => a - b);
  const sweepRuns = await q<{ n: string }>(`SELECT count(*) AS n FROM ravon_delivery.sweep_runs WHERE shop = $1`, [shop]);

  const neverDispatched = truth.filter((t) => t.cohort === "deliver" && !dmap.get(t.gid)).map((t) => t.gid);

  const rejected = await q<{ reason: string; n: string }>(
    `SELECT reason, count(*) AS n FROM ravon_delivery.rejected_events WHERE shop = $1 GROUP BY reason`,
    [shop],
  );
  const outcomes = await q<{ outcome: string; n: string }>(
    `SELECT outcome, count(*) AS n FROM ravon_delivery.webhook_log WHERE shop = $1 GROUP BY outcome`,
    [shop],
  );
  const reprocessed = await q<{ n: string }>(
    `SELECT count(*) AS n FROM (
       SELECT webhook_id FROM ravon_delivery.webhook_log WHERE shop = $1 AND outcome <> 'duplicate'
        GROUP BY webhook_id HAVING count(*) > 1) x`,
    [shop],
  );
  const throttle = await q<{ kind: string; n: string }>(
    `SELECT kind, count(*) AS n FROM ravon_delivery.throttle_events WHERE shop = $1 GROUP BY kind`,
    [shop],
  );
  const intents = await q<{ outcome: string; n: string }>(
    `SELECT coalesce(i.outcome, 'unfinished') AS outcome, count(*) AS n
       FROM ravon_delivery.fulfillment_intents i JOIN ravon_delivery.jobs j ON j.id = i.job_id
      WHERE j.shop = $1 GROUP BY 1`,
    [shop],
  );
  const failed = jobs.filter((j) => j.fulfillment_state === "failed").length;
  const calls = truth.map((t) => t.fulfillmentCreateCalls);

  const rec = (rows: { n: string }[], key: (r: never) => string) =>
    Object.fromEntries(rows.map((r) => [key(r as never), Number(r.n)]));

  return {
    orders: { deliver: truth.filter((t) => t.cohort === "deliver").length, cancel: cancelGids.length },
    jobsPerOrder: hist(truth.map((t) => (jobsBy.get(t.gid) ?? []).length)),
    dispatchesPerOrder: hist(truth.map((t) => dmap.get(t.gid) ?? 0)),
    fulfillmentsPerOrder: hist(truth.map((t) => t.fulfillments)),
    deliverCohortExactlyOnce: once,
    violations,
    cancelCohort: {
      endedCancelled,
      fulfilled: cancelFulfilled,
      cancelRejectedNoEdge: Number(noEdge[0].n),
      resurrected: Number(resurrected[0].n),
    },
    deliveries: {
      total: faults.length,
      dropped: faults.filter((f) => f.action === "drop").length,
      duplicated: faults.filter((f) => f.action === "dup").length,
      once: faults.filter((f) => f.action === "once").length,
      ordersReordered: reordered,
    },
    ordersAllDeliveriesDropped: allDropped.sort(),
    sweep: { jobsCreatedBySweep: sweepJobs.length, recoverMs: { p50: pct(recover, 50), max: recover.at(-1) ?? null }, runs: Number(sweepRuns[0].n) },
    ordersNeverDispatched: neverDispatched.sort(),
    rejected: rec(rejected, (r: { reason: string }) => r.reason),
    intakeOutcomes: rec(outcomes, (r: { outcome: string }) => r.outcome),
    reprocessedDuplicateDeliveries: Number(reprocessed[0].n),
    throttle: rec(throttle, (r: { kind: string }) => r.kind),
    fulfillment: rec(intents, (r: { outcome: string }) => r.outcome),
    jobsFailed: failed,
    duplicateCreateCalls: calls.every((c) => c !== null) ? calls.filter((c) => (c ?? 0) > 1).length : null,
  };
}
