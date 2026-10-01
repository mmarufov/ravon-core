import type pg from "pg";
import type { AdminGraphql } from "./admin.server";
import type { DeliveryConfig } from "./config.server";
import { maybeCrash, type CrashPlan } from "./crash.server";
import { FULFILLMENT_CREATE, ORDER_FULFILLMENT_STATE } from "./operations";
import { paced, type CostPacer } from "./throttle.server";

// Writing a delivered job back to Shopify as a fulfillment, exactly once, across crashes.
//
// fulfillmentCreate takes no idempotency key (checked against the 2026-07 and 2026-10
// docs), so a retry cannot ask Shopify "did you already do this?" through the mutation.
// The protocol instead:
//
//   1. claim the job under a lease and bump its attempt number (the fencing token);
//   2. commit an intent row for (job, attempt) BEFORE calling Shopify;
//   3. read the order's fulfillments from Shopify; if one carries this job's tracking
//      number, Shopify already accepted an earlier attempt, so adopt it and stop;
//   4. otherwise call fulfillmentCreate;
//   5. commit the result, but only if this worker still holds the lease at this attempt.
//
// A process killed between Shopify's reply to (4) and the commit in (5) leaves the job
// `pending` with an expired lease. The next claim is attempt 2, step 3 finds the
// fulfillment by its tracking number, and nothing is written twice.

export interface FulfillDeps {
  pool: pg.Pool;
  adminFor: (shop: string) => Promise<AdminGraphql>;
  pacer: CostPacer;
  cfg: DeliveryConfig;
  workerId: string;
  leaseMs: number;
  crash: CrashPlan | null;
}

interface Claimed {
  id: string;
  shop: string;
  order_gid: string;
  fulfillment_attempts: number;
}

export function trackingNumber(jobId: string): string {
  return `RAVON-${jobId}`;
}

export async function claimFulfillments(deps: FulfillDeps, limit: number): Promise<Claimed[]> {
  const r = await deps.pool.query<Claimed>(
    `UPDATE jobs SET fulfillment_state    = 'pending',
                     fulfillment_attempts = fulfillment_attempts + 1,
                     lease_owner          = $1,
                     lease_until          = clock_timestamp() + ($2 || ' milliseconds')::interval
      WHERE id IN (
        SELECT id FROM jobs
         WHERE status = 'delivered'
           AND (fulfillment_state = 'none'
                OR (fulfillment_state = 'pending' AND lease_until < clock_timestamp()))
         ORDER BY updated_at
         LIMIT $3
         FOR UPDATE SKIP LOCKED)
      RETURNING id, shop, order_gid, fulfillment_attempts`,
    [deps.workerId, String(deps.leaseMs), limit],
  );
  return r.rows;
}

type Finish = {
  outcome: "created" | "adopted" | "rejected" | "skipped_cancelled" | "skipped_fulfilled_elsewhere";
  state: "done" | "failed" | "skipped";
  gid: string | null;
  detail?: string;
};

async function finish(deps: FulfillDeps, job: Claimed, f: Finish): Promise<boolean> {
  const c = await deps.pool.connect();
  try {
    await c.query("BEGIN");
    // Fenced: a worker whose lease expired and was re-claimed holds a stale attempt
    // number and changes nothing.
    const r = await c.query(
      `UPDATE jobs SET fulfillment_state = $4, fulfillment_gid = $5,
                       lease_owner = NULL, lease_until = NULL, updated_at = clock_timestamp()
        WHERE id = $1 AND lease_owner = $2 AND fulfillment_attempts = $3`,
      [job.id, deps.workerId, job.fulfillment_attempts, f.state, f.gid],
    );
    const fenced = r.rowCount === 0;
    await c.query(
      `UPDATE fulfillment_intents SET outcome = $3, fulfillment_gid = $4, detail = $5,
                                      finished_at = clock_timestamp()
        WHERE job_id = $1 AND attempt = $2`,
      [job.id, job.fulfillment_attempts, fenced ? "fenced" : f.outcome, f.gid, f.detail ?? null],
    );
    await c.query("COMMIT");
    return !fenced;
  } catch (e) {
    await c.query("ROLLBACK").catch(() => {});
    throw e;
  } finally {
    c.release();
  }
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
type Json = any;

export async function fulfillOne(deps: FulfillDeps, job: Claimed): Promise<Finish["outcome"] | "error"> {
  const attempt = job.fulfillment_attempts;
  const tracking = trackingNumber(job.id);
  const admin = await deps.adminFor(job.shop);

  await deps.pool.query(
    `INSERT INTO fulfillment_intents (job_id, attempt, worker, tracking_number)
     VALUES ($1, $2, $3, $4)`,
    [job.id, attempt, deps.workerId, tracking],
  );

  let request: Json = null;
  if (attempt > 1 && !deps.cfg.on("status_check")) {
    // Negative control: a retry that replays its previous request without asking
    // Shopify what happened to it.
    const prev = await deps.pool.query<{ request: Json }>(
      `SELECT request FROM fulfillment_intents
        WHERE job_id = $1 AND attempt < $2 AND request IS NOT NULL
        ORDER BY attempt DESC LIMIT 1`,
      [job.id, attempt],
    );
    request = prev.rows[0]?.request ?? null;
  }

  if (request === null) {
    const state = await paced(admin, deps.pacer, job.shop, "RavonOrderFulfillmentState",
      ORDER_FULFILLMENT_STATE, { id: job.order_gid }, 20);
    if (state.errors?.length) throw new Error(`order state: ${JSON.stringify(state.errors)}`);
    const order = state.data?.order;
    if (!order) throw new Error(`order ${job.order_gid} not found`);

    if (deps.cfg.on("status_check")) {
      const mine = (order.fulfillments as Json[]).find(
        (f) => f.status !== "CANCELLED" && (f.trackingInfo as Json[]).some((t) => t.number === tracking),
      );
      if (mine) {
        await finish(deps, job, { outcome: "adopted", state: "done", gid: mine.id });
        return "adopted";
      }
    }
    if (order.cancelledAt) {
      await finish(deps, job, { outcome: "skipped_cancelled", state: "skipped", gid: null });
      return "skipped_cancelled";
    }
    const open = (order.fulfillmentOrders.nodes as Json[]).filter(
      (fo) =>
        (fo.status === "OPEN" || fo.status === "IN_PROGRESS") &&
        (fo.lineItems.nodes as Json[]).some((li) => li.remainingQuantity > 0),
    );
    if (open.length === 0) {
      await finish(deps, job, {
        outcome: "skipped_fulfilled_elsewhere",
        state: "skipped",
        gid: null,
        detail: `displayFulfillmentStatus=${order.displayFulfillmentStatus}`,
      });
      return "skipped_fulfilled_elsewhere";
    }
    request = {
      lineItemsByFulfillmentOrder: open.map((fo) => ({ fulfillmentOrderId: fo.id })),
      notifyCustomer: false,
      trackingInfo: { company: "Ravon (simulated courier)", number: tracking },
    };
    await deps.pool.query(
      `UPDATE fulfillment_intents SET request = $3 WHERE job_id = $1 AND attempt = $2`,
      [job.id, attempt, request],
    );
  }

  const res = await paced(admin, deps.pacer, job.shop, "RavonFulfillmentCreate",
    FULFILLMENT_CREATE, { fulfillment: request }, 10);
  if (res.errors?.length) throw new Error(`fulfillmentCreate: ${JSON.stringify(res.errors)}`);

  // The kill point: Shopify has replied, nothing local has been committed.
  maybeCrash(deps.crash, "after_fulfillment_reply", job.id, attempt, {
    shopifyFulfillment: res.data?.fulfillmentCreate?.fulfillment?.id ?? null,
  });

  const payload = res.data?.fulfillmentCreate;
  if (payload?.userErrors?.length) {
    await finish(deps, job, {
      outcome: "rejected",
      state: "failed",
      gid: null,
      detail: JSON.stringify(payload.userErrors),
    });
    return "rejected";
  }
  await finish(deps, job, { outcome: "created", state: "done", gid: payload.fulfillment.id });
  return "created";
}

export async function fulfillTick(deps: FulfillDeps, limit = 10): Promise<number> {
  const jobs = await claimFulfillments(deps, limit);
  await Promise.all(
    jobs.map(async (job) => {
      try {
        await fulfillOne(deps, job);
      } catch (e) {
        // Left `pending`; the lease expires and a later attempt reads Shopify first.
        await deps.pool
          .query(
            `UPDATE fulfillment_intents SET outcome = 'error', detail = $3, finished_at = clock_timestamp()
              WHERE job_id = $1 AND attempt = $2`,
            [job.id, job.fulfillment_attempts, String(e).slice(0, 2000)],
          )
          .catch(() => {});
      }
    }),
  );
  return jobs.length;
}
