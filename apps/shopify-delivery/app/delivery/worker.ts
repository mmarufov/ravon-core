// The delivery worker: dispatch, the simulated courier run, fulfillment write-back and
// the reconciliation sweep, as one process separate from the web server. It keeps no
// state of its own (everything is in PostgreSQL), so SIGKILL at any instruction loses
// nothing that a restart cannot recover.
//
//   tsx app/delivery/worker.ts
//
// RAVON_PG_URL, RAVON_DISPATCH_URL (local Kotlin ravon-api), RAVON_ADMIN=template|fake,
// RAVON_FAKE_SHOPIFY_URL when fake, and optional RAVON_DISABLE / RAVON_CRASH.

import { randomUUID } from "node:crypto";
import { assertSchemaMatches } from "../../db/migrate";
import { fetchAdmin, templateAdmin, type AdminGraphql } from "./admin.server";
import { deliveryConfig, env, envNumber } from "./config.server";
import { parseCrash } from "./crash.server";
import { courierTick, dispatchTick, httpAssign, seedCouriers } from "./dispatch.server";
import { fulfillTick } from "./fulfillment.server";
import { pgPool } from "./pg.server";
import { sweepOnce } from "./sweep.server";
import { CostPacer } from "./throttle.server";

const API_VERSION = process.env.RAVON_API_VERSION ?? "2026-07";

async function main() {
  const cfg = deliveryConfig();
  const pool = pgPool();
  await assertSchemaMatches(pool, { jobKey: cfg.on("dedupe"), trigger: cfg.on("lifecycle") });

  const workerId = `${process.env.RAVON_WORKER_NAME ?? "worker"}-${process.pid}-${randomUUID().slice(0, 8)}`;
  const crash = parseCrash();
  const assign = httpAssign(env("RAVON_DISPATCH_URL"));
  const stepMs = envNumber("RAVON_SIM_STEP_MS", 2000);

  const adminMode = env("RAVON_ADMIN", "template");
  const admins = new Map<string, AdminGraphql>();
  const adminFor = async (shop: string) => {
    let a = admins.get(shop);
    if (!a) {
      a =
        adminMode === "fake"
          ? fetchAdmin(env("RAVON_FAKE_SHOPIFY_URL"), shop, "fake-token", API_VERSION)
          : await templateAdmin(shop);
      admins.set(shop, a);
    }
    return a;
  };

  const pacer = new CostPacer({
    enabled: cfg.on("pacing"),
    store: {
      load: async (shop) => {
        const r = await pool.query(
          `SELECT available, maximum, restore_rate, observed_at, costs FROM throttle_state WHERE shop = $1`,
          [shop],
        );
        const row = r.rows[0];
        return row
          ? {
              bucket: { available: row.available, maximum: row.maximum, restoreRate: row.restore_rate, at: row.observed_at.getTime() },
              costs: row.costs,
            }
          : null;
      },
      save: (shop, b, costs) => {
        pool
          .query(
            `INSERT INTO throttle_state (shop, available, maximum, restore_rate, observed_at, costs)
             VALUES ($1, $2, $3, $4, to_timestamp($5 / 1000.0), $6)
             ON CONFLICT (shop) DO UPDATE SET available = EXCLUDED.available, maximum = EXCLUDED.maximum,
               restore_rate = EXCLUDED.restore_rate, observed_at = EXCLUDED.observed_at, costs = EXCLUDED.costs
             WHERE throttle_state.observed_at <= EXCLUDED.observed_at`,
            [shop, b.available, b.maximum, b.restoreRate, b.at, costs],
          )
          .catch((err) => console.error("throttle_state save failed", err));
      },
    },
    record: (e) => {
      pool
        .query(
          `INSERT INTO throttle_events (shop, operation, kind, requested_cost, available, maximum,
                                        restore_rate, wait_ms)
           VALUES ($1, $2, $3, $4, $5, $6, $7, $8)`,
          [e.shop, e.operation, e.kind, e.requestedCost, e.available, e.maximum, e.restoreRate, e.waitMs],
        )
        .catch((err) => console.error("throttle_events insert failed", err));
    },
  });

  await seedCouriers(pool, envNumber("RAVON_SIM_COURIERS", 40), env("RAVON_SIM_SEED", "ravon"));

  const deps = {
    pool,
    adminFor,
    pacer,
    cfg,
    workerId,
    leaseMs: envNumber("RAVON_LEASE_MS", 15000),
    crash,
  };

  let stopping = false;
  const loop = (name: string, everyMs: number, fn: () => Promise<unknown>) => {
    const run = async () => {
      while (!stopping) {
        try {
          await fn();
        } catch (e) {
          console.error(`[${name}]`, e instanceof Error ? e.message : e);
        }
        await new Promise((r) => setTimeout(r, everyMs));
      }
    };
    void run();
  };

  loop("dispatch", envNumber("RAVON_DISPATCH_TICK_MS", 200), () =>
    dispatchTick(pool, assign, { batch: envNumber("RAVON_DISPATCH_BATCH", 50), stepMs }),
  );
  loop("courier", 200, () => courierTick(pool, { stepMs }));
  loop("fulfill", envNumber("RAVON_FULFILL_TICK_MS", 300), () =>
    fulfillTick(deps, envNumber("RAVON_FULFILL_CONCURRENCY", 4)),
  );
  if (cfg.on("sweep")) {
    loop("sweep", envNumber("RAVON_SWEEP_INTERVAL_MS", 60000), async () => {
      const shops = await pool.query<{ shop: string }>(`SELECT shop FROM shops`);
      for (const { shop } of shops.rows) {
        await sweepOnce(pool, await adminFor(shop), pacer, shop, cfg, {
          overlapMs: envNumber("RAVON_SWEEP_OVERLAP_MS", 300000),
          pageSize: envNumber("RAVON_SWEEP_PAGE", 50),
        });
      }
    });
  }

  console.log(
    `worker ${workerId} up: admin=${adminMode} disabled=[${[...cfg.disabled].join(",")}] crash=${crash ? JSON.stringify(crash) : "off"}`,
  );
  const stop = () => {
    stopping = true;
    setTimeout(() => process.exit(0), 500);
  };
  process.on("SIGTERM", stop);
  process.on("SIGINT", stop);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
