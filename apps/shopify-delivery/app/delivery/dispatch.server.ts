import { randomUUID } from "node:crypto";
import type pg from "pg";
import { pointNear, STORE, uuidFrom } from "./geo";
import { CLAIM, COURIER_RUN } from "./lifecycle";
import { move } from "./intake.server";
import { withTx } from "./pg.server";

// Dispatch through Ravon's Assign RPC (services/server, DispatchServiceImpl), a pure
// min-cost matching of (couriers, orders, now). The couriers are simulated: rows in
// sim_couriers placed around the store, with no real person behind any of them.

export interface AssignRequest {
  now: string;
  couriers: { courierId: string; location: { latitude: number; longitude: number }; idleSince: string }[];
  orders: {
    orderId: string;
    pickup: { latitude: number; longitude: number };
    dropoff: { latitude: number; longitude: number };
    readyAt: string;
    createdAt: string;
  }[];
}

export interface AssignResponse {
  assignments?: { courierId: string; orderId: string; costMinutes: number }[];
}

export type AssignFn = (req: AssignRequest) => Promise<AssignResponse>;

// Armeria serves the gRPC service as unframed Protobuf-JSON too, so this is one POST.
export function httpAssign(baseUrl: string, timeoutMs = 5000): AssignFn {
  const url = `${baseUrl.replace(/\/$/, "")}/ravon.dispatch.v1.DispatchService/Assign`;
  return async (req) => {
    const res = await fetch(url, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(req),
      signal: AbortSignal.timeout(timeoutMs),
    });
    const body = await res.json();
    if (!res.ok) throw new Error(`Assign HTTP ${res.status}: ${JSON.stringify(body)}`);
    return body as AssignResponse;
  };
}

export async function seedCouriers(pool: pg.Pool, n: number, seed: string): Promise<void> {
  const have = await pool.query<{ n: string }>(`SELECT count(*) AS n FROM sim_couriers`);
  if (Number(have.rows[0].n) > 0) return;
  for (let i = 0; i < n; i++) {
    const id = uuidFrom(`courier:${seed}:${i}`);
    const p = pointNear(`courier-start:${seed}:${i}`, STORE, 5);
    await pool.query(
      `INSERT INTO sim_couriers (id, lat, lng, idle_since) VALUES ($1, $2, $3, clock_timestamp())
       ON CONFLICT (id) DO NOTHING`,
      [id, p.lat, p.lng],
    );
  }
}

interface PendingJob {
  id: string;
  pickup_lat: number;
  pickup_lng: number;
  dropoff_lat: number;
  dropoff_lng: number;
  created_at: Date;
}

interface IdleCourier {
  id: string;
  lat: number;
  lng: number;
  idle_since: Date;
}

// One batch: every accepted job not locked by another dispatcher, against every idle
// courier, in one Assign call. The job rows stay locked across the call, so a second
// dispatcher skips them instead of matching them again; UNIQUE (job_id) on dispatches
// would refuse a second assignment even if it did not.
export async function dispatchTick(
  pool: pg.Pool,
  assign: AssignFn,
  opts: { batch: number; stepMs: number },
): Promise<number> {
  return withTx(async (c) => {
    const jobs = await c.query<PendingJob>(
      `SELECT id, pickup_lat, pickup_lng, dropoff_lat, dropoff_lng, created_at FROM jobs
        WHERE status = 'accepted' ORDER BY created_at LIMIT $1 FOR UPDATE SKIP LOCKED`,
      [opts.batch],
    );
    if (jobs.rowCount === 0) return 0;
    const couriers = await c.query<IdleCourier>(
      `SELECT id, lat, lng, idle_since FROM sim_couriers WHERE busy_job IS NULL
        ORDER BY idle_since LIMIT $1 FOR UPDATE SKIP LOCKED`,
      [Math.max(opts.batch * 2, 50)],
    );
    if (couriers.rowCount === 0) return 0;

    const now = new Date();
    const res = await assign({
      now: now.toISOString(),
      couriers: couriers.rows.map((k) => ({
        courierId: k.id,
        location: { latitude: k.lat, longitude: k.lng },
        idleSince: k.idle_since.toISOString(),
      })),
      orders: jobs.rows.map((j) => ({
        orderId: j.id,
        pickup: { latitude: j.pickup_lat, longitude: j.pickup_lng },
        dropoff: { latitude: j.dropoff_lat, longitude: j.dropoff_lng },
        readyAt: now.toISOString(),
        createdAt: j.created_at.toISOString(),
      })),
    });
    const batchId = randomUUID();
    const assignments = res.assignments ?? [];
    for (const a of assignments) {
      await c.query(
        `INSERT INTO dispatches (job_id, courier_id, cost_minutes, batch_id, batch_size)
         VALUES ($1, $2, $3, $4, $5)`,
        [a.orderId, a.courierId, a.costMinutes, batchId, jobs.rowCount],
      );
      await move(c, a.orderId, "accepted", CLAIM, "dispatch", null);
      await c.query(
        `UPDATE jobs SET courier_id = $2,
                         sim_next_at = clock_timestamp() + ($3 || ' milliseconds')::interval
          WHERE id = $1`,
        [a.orderId, a.courierId, String(opts.stepMs)],
      );
      await c.query(`UPDATE sim_couriers SET busy_job = $2 WHERE id = $1`, [a.courierId, a.orderId]);
    }
    return assignments.length;
  });
}

const RUN_FROM = ["assigned", ...COURIER_RUN.slice(0, -1).map((m) => m.to)];

// Advance simulated deliveries whose next step is due, one declared edge per step.
export async function courierTick(pool: pg.Pool, opts: { stepMs: number }): Promise<number> {
  return withTx(async (c) => {
    const due = await c.query<{ id: string; status: string; dropoff_lat: number; dropoff_lng: number }>(
      `SELECT id, status, dropoff_lat, dropoff_lng FROM jobs
        WHERE status = ANY($1) AND sim_next_at <= clock_timestamp()
        ORDER BY sim_next_at LIMIT 500 FOR UPDATE SKIP LOCKED`,
      [RUN_FROM],
    );
    for (const j of due.rows) {
      const step = COURIER_RUN[RUN_FROM.indexOf(j.status)];
      await move(c, j.id, j.status, step, "courier_sim", null);
      if (step.to === "delivered") {
        await c.query(`UPDATE jobs SET sim_next_at = NULL WHERE id = $1`, [j.id]);
        await c.query(
          `UPDATE sim_couriers SET busy_job = NULL, idle_since = clock_timestamp(), lat = $2, lng = $3
            WHERE busy_job = $1`,
          [j.id, j.dropoff_lat, j.dropoff_lng],
        );
      } else {
        await c.query(
          `UPDATE jobs SET sim_next_at = clock_timestamp() + ($2 || ' milliseconds')::interval WHERE id = $1`,
          [j.id, String(opts.stepMs)],
        );
      }
    }
    return due.rowCount ?? 0;
  });
}
