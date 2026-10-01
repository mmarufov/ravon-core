// The fault harness against the fake Shopify: what CI runs on every PR.
//
//   tsx harness/run.ts --scenario full [--out results.json]
//   tsx harness/run.ts --scenario all            # full, then every negative control
//
// Needs RAVON_PG_URL (a database it may wipe), RAVON_DISPATCH_URL (a local Kotlin
// ravon-api), and a built app (`npm run build`, `npx prisma migrate deploy`).
//
// Each scenario starts the real web server (the template's HMAC check and this app's
// route, behind the fault layer), a supervised worker that crash injection SIGKILLs, and
// the fake Shopify, then drives orders through and checks the pre-registered targets.
// A negative control passes only if it shows the failure its mechanism prevents.

import { readFileSync, rmSync, writeFileSync } from "node:fs";
import { randomUUID } from "node:crypto";
import pg from "pg";
import { migrate, type SchemaControl } from "../db/migrate";
import { uniforms } from "../app/delivery/geo";
import { FakeShopify } from "./fake-shopify";
import { collect, type OrderTruth, type RunMetrics } from "./metrics";
import { startWeb, stopProc, Supervisor, waitHttp } from "./procs";

const SHOP = "ravon-ci.myshopify.com";
const SECRET = "ci-dummy-secret-not-a-credential";
const API_VERSION = "2026-07";
const SCOPES =
  "read_orders,write_orders,read_merchant_managed_fulfillment_orders,write_merchant_managed_fulfillment_orders";

interface Scenario {
  name: string;
  disable: string[];
  schema: SchemaControl[];
  n: number;
  cancel: number;
  drop: number;
  dup: number;
  delayMaxMs: number;
  crashRate: number;
  sweepEveryMs: number;
  overlapMs: number;
  lagMs: [number, number];
  createPerSec: number;
  cancelDelayMaxMs: number;
  bucket: { maximum: number; restoreRate: number };
  probes: boolean;
  timeoutMs: number;
  // Returns failures; empty means the scenario showed what it had to.
  check: (m: RunMetrics, k: Kills, probes: ProbeResult | null) => string[];
}

interface Kills {
  logged: number;
  sigkills: number;
  otherExits: number;
}

interface ProbeResult {
  tampered: number[];
  sameId: string[];
  newId: string[];
  jobsBefore: number;
  jobsAfter: number;
  dispatchesBefore: number;
  dispatchesAfter: number;
}

const BASE = {
  disable: [] as string[],
  schema: [] as SchemaControl[],
  n: 200,
  cancel: 20,
  drop: 0.2,
  dup: 0.1,
  delayMaxMs: 3000,
  crashRate: 0.15,
  sweepEveryMs: 2000,
  overlapMs: 10000,
  lagMs: [500, 1500] as [number, number],
  createPerSec: 25,
  cancelDelayMaxMs: 2000,
  bucket: { maximum: 1000, restoreRate: 100 },
  probes: false,
  timeoutMs: 240000,
};

function exactlyOnce(m: RunMetrics): string[] {
  const f: string[] = [];
  const { deliver } = m.orders;
  const o = m.deliverCohortExactlyOnce;
  if (o.jobs !== deliver) f.push(`jobs exactly once for ${o.jobs}/${deliver}`);
  if (o.dispatches !== deliver) f.push(`dispatched exactly once for ${o.dispatches}/${deliver}`);
  if (o.fulfillments !== deliver) f.push(`fulfilled exactly once for ${o.fulfillments}/${deliver}`);
  if (m.cancelCohort.fulfilled > 0) f.push(`${m.cancelCohort.fulfilled} cancelled orders fulfilled`);
  if (m.cancelCohort.resurrected > 0) f.push(`${m.cancelCohort.resurrected} cancelled orders resurrected`);
  return f;
}

const SCENARIOS: Record<string, Scenario> = {
  full: {
    ...BASE,
    name: "full",
    probes: true,
    check: (m, k, p) => {
      const f = exactlyOnce(m);
      if (k.logged < 20) f.push(`only ${k.logged} kills at the kill point (need >= 20)`);
      if (k.logged !== k.sigkills) f.push(`crash log has ${k.logged} kills, supervisor saw ${k.sigkills}`);
      if (k.otherExits > 0) f.push(`worker died ${k.otherExits} times of something other than SIGKILL`);
      if ((m.throttle.throttled ?? 0) > 0) f.push(`${m.throttle.throttled} THROTTLED responses with pacing on`);
      if (m.ordersAllDeliveriesDropped.length === 0) f.push("no order had every delivery dropped; the sweep was not exercised");
      if (m.sweep.jobsCreatedBySweep < m.ordersAllDeliveriesDropped.length) f.push("sweep created fewer jobs than there were all-dropped orders");
      if (m.deliveries.ordersReordered === 0) f.push("no order saw its deliveries reordered");
      if (!p) f.push("probes did not run");
      else {
        if (p.tampered.some((s) => s !== 401)) f.push(`tampered statuses ${p.tampered.join(",")}`);
        if (p.sameId.some((o) => o !== "duplicate")) f.push(`same-id replays: ${p.sameId.join(",")}`);
        if (p.newId.some((o) => o === "created" || o === "applied")) f.push(`new-id replays: ${p.newId.join(",")}`);
        if (p.jobsAfter !== p.jobsBefore || p.dispatchesAfter !== p.dispatchesBefore) f.push("a replay created a job or a dispatch");
      }
      return f;
    },
  },
  dedupe: {
    ...BASE,
    name: "dedupe",
    disable: ["dedupe"],
    schema: ["no_job_key"],
    n: 60,
    cancel: 0,
    crashRate: 0,
    timeoutMs: 120000,
    check: (m) => {
      const dupJobs = Object.entries(m.jobsPerOrder).filter(([k]) => Number(k) >= 2).reduce((a, [, v]) => a + v, 0);
      const dupDispatch = Object.entries(m.dispatchesPerOrder).filter(([k]) => Number(k) >= 2).reduce((a, [, v]) => a + v, 0);
      return dupJobs > 0 && dupDispatch > 0 ? [] : [`expected duplicate jobs and dispatches, got ${dupJobs} and ${dupDispatch}`];
    },
  },
  receipts: {
    ...BASE,
    name: "receipts",
    disable: ["receipts"],
    n: 60,
    cancel: 0,
    crashRate: 0,
    timeoutMs: 120000,
    // Receipts off, job key on: redeliveries are processed again, but the key still
    // holds, so this control shows defense in depth rather than a duplicate.
    check: (m) => {
      const f: string[] = [];
      if (m.reprocessedDuplicateDeliveries === 0) f.push("no duplicate delivery was reprocessed");
      f.push(...exactlyOnce(m));
      return f;
    },
  },
  sweep: {
    ...BASE,
    name: "sweep",
    disable: ["sweep"],
    n: 100,
    cancel: 0,
    crashRate: 0,
    timeoutMs: 120000,
    check: (m) => {
      const want = JSON.stringify(m.ordersAllDeliveriesDropped);
      const got = JSON.stringify(m.ordersNeverDispatched);
      if (m.ordersNeverDispatched.length === 0) return ["every order dispatched with the sweep off"];
      return want === got ? [] : [`never dispatched ${got} != all-dropped ${want}`];
    },
  },
  status_check: {
    ...BASE,
    name: "status_check",
    disable: ["status_check"],
    n: 60,
    cancel: 0,
    crashRate: 0.5,
    timeoutMs: 120000,
    check: (m) => {
      const doubles = Object.entries(m.fulfillmentsPerOrder).filter(([k]) => Number(k) >= 2).reduce((a, [, v]) => a + v, 0);
      const resent = m.duplicateCreateCalls ?? 0;
      if (resent === 0) return ["no retry re-sent fulfillmentCreate"];
      return doubles > 0 || m.jobsFailed > 0 ? [] : ["retries re-sent but nothing went wrong"];
    },
  },
  lifecycle: {
    ...BASE,
    name: "lifecycle",
    disable: ["lifecycle"],
    schema: ["no_lifecycle_trigger"],
    n: 20,
    cancel: 80,
    cancelDelayMaxMs: 300,
    crashRate: 0,
    timeoutMs: 120000,
    check: (m) => (m.cancelCohort.resurrected > 0 ? [] : ["no cancelled order was resurrected"]),
  },
  lifecycle_on: {
    ...BASE,
    name: "lifecycle_on",
    n: 20,
    cancel: 80,
    cancelDelayMaxMs: 300,
    crashRate: 0,
    timeoutMs: 120000,
    check: (m) => {
      const f = exactlyOnce(m);
      if ((m.rejected.stale ?? 0) === 0) f.push("no stale event was refused");
      return f;
    },
  },
  pacing: {
    ...BASE,
    name: "pacing",
    disable: ["pacing"],
    n: 100,
    cancel: 0,
    crashRate: 0,
    bucket: { maximum: 300, restoreRate: 30 },
    timeoutMs: 180000,
    check: (m) => ((m.throttle.throttled ?? 0) > 0 ? [] : ["no THROTTLED response with pacing off"]),
  },
  pacing_on: {
    ...BASE,
    name: "pacing_on",
    n: 100,
    cancel: 0,
    crashRate: 0,
    bucket: { maximum: 300, restoreRate: 30 },
    timeoutMs: 180000,
    check: (m) => {
      const f = exactlyOnce(m);
      if ((m.throttle.throttled ?? 0) > 0) f.push(`${m.throttle.throttled} THROTTLED responses with pacing on`);
      if ((m.throttle.paced ?? 0) === 0) f.push("the pacer never had to wait; the bucket was not exercised");
      return f;
    },
  },
  // The overlap window matters when the search index lags by about a sweep interval.
  // At the full run's 0.5 to 1.5 s lag and 2 s sweeps a miss is rare (about 6% per
  // all-dropped order), so the pair below uses 1 to 5 s lag and 1 s sweeps: the same
  // conditions with and without the overlap.
  overlap0: {
    ...BASE,
    name: "overlap0",
    n: 150,
    cancel: 0,
    crashRate: 0,
    overlapMs: 0,
    lagMs: [1000, 5000],
    sweepEveryMs: 1000,
    timeoutMs: 120000,
    check: (m) =>
      m.ordersNeverDispatched.length > 0
        ? []
        : ["with no overlap window every all-dropped order was still recovered"],
  },
  overlap_on: {
    ...BASE,
    name: "overlap_on",
    n: 150,
    cancel: 0,
    crashRate: 0,
    overlapMs: 10000,
    lagMs: [1000, 5000],
    sweepEveryMs: 1000,
    timeoutMs: 120000,
    check: (m) => {
      const f = exactlyOnce(m);
      if (m.ordersAllDeliveriesDropped.length === 0) f.push("no order had every delivery dropped");
      return f;
    },
  },
};

const ORDER = ["full", "dedupe", "receipts", "sweep", "status_check", "lifecycle", "lifecycle_on", "pacing", "pacing_on", "overlap0", "overlap_on"];

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

async function settle(pool: pg.Pool, fake: FakeShopify, s: Scenario, lastEventAt: number): Promise<boolean> {
  const quietAfter = lastEventAt + s.delayMaxMs * 2 + s.lagMs[1] + 3 * s.sweepEveryMs + 2000;
  const deadline = Date.now() + s.timeoutMs;
  let last = "";
  let stableSince = Date.now();
  while (Date.now() < deadline) {
    await sleep(500);
    const r = await pool.query(
      `SELECT
         (SELECT count(*) FROM ravon_delivery.jobs) AS jobs,
         (SELECT count(*) FROM ravon_delivery.dispatches) AS dispatches,
         (SELECT count(*) FROM ravon_delivery.fulfillment_intents) AS intents,
         (SELECT count(*) FROM ravon_delivery.jobs
           WHERE status IN ('accepted','assigned','courier_arrived_restaurant','picked_up','delivering','courier_arrived_customer')
              OR (status = 'delivered' AND fulfillment_state IN ('none','pending'))) AS moving`,
    );
    const row = r.rows[0];
    // Admin API traffic counts as progress (a pacer waiting out the bucket is not stuck),
    // except the sweep's, which never stops.
    const work = fake.stats.requests - (fake.stats.byOperation.RavonSweepOrders ?? 0);
    const sig = `${row.jobs}/${row.dispatches}/${row.intents}/${fake.stats.fulfillmentCreateAccepted}/${work}`;
    if (sig !== last) {
      last = sig;
      stableSince = Date.now();
    }
    const stableMs = Date.now() - stableSince;
    if (Date.now() > quietAfter && Number(row.moving) === 0 && stableMs > 2000) return true;
    // `moving` can stay above zero in a control (an undispatchable job, a stuck lease);
    // there the run ends when nothing at all has changed for 30 s after the quiet point.
    if (Date.now() > quietAfter && stableMs > 30000) return true;
  }
  return false;
}

async function probe(pool: pg.Pool, port: number): Promise<ProbeResult> {
  const count = async (t: string) => Number((await pool.query(`SELECT count(*) AS n FROM ravon_delivery.${t}`)).rows[0].n);
  const jobsBefore = await count("jobs");
  const dispatchesBefore = await count("dispatches");
  const caps = (
    await pool.query<{ headers: Record<string, string>; raw_body: string }>(
      `SELECT c.headers, c.raw_body FROM harness.capture c
         JOIN ravon_delivery.webhook_receipts r ON r.webhook_id = c.headers->>'x-shopify-webhook-id'
        WHERE c.headers->>'x-shopify-topic' = 'orders/create'
        ORDER BY c.id LIMIT 10`,
    )
  ).rows;
  if (caps.length < 10) throw new Error(`only ${caps.length} captured deliveries to probe with`);
  const url = `http://127.0.0.1:${port}/webhooks/orders`;
  const post = (headers: Record<string, string>, body: string) =>
    fetch(url, { method: "POST", headers: { ...headers, "content-length": String(Buffer.byteLength(body)) }, body });
  const strip = (h: Record<string, string>) => {
    const out: Record<string, string> = {};
    for (const [k, v] of Object.entries(h)) if (k.startsWith("x-shopify-") || k === "content-type") out[k] = v;
    return out;
  };
  const outcomeOf = async (webhookId: string) =>
    (await pool.query(`SELECT outcome FROM ravon_delivery.webhook_log WHERE webhook_id = $1 ORDER BY id DESC LIMIT 1`, [webhookId])).rows[0]?.outcome ?? "none";

  const tampered: number[] = [];
  for (const c of caps) {
    const body = c.raw_body.replace('"test":true', '"test":false').replace(/"name":"#/, '"name":"#9');
    tampered.push((await post(strip(c.headers), body === c.raw_body ? c.raw_body + " " : body)).status);
  }
  const sameId: string[] = [];
  for (const c of caps) {
    const before = (await pool.query(`SELECT count(*) AS n FROM ravon_delivery.webhook_log WHERE webhook_id = $1`, [c.headers["x-shopify-webhook-id"]])).rows[0].n;
    const res = await post(strip(c.headers), c.raw_body);
    const after = (await pool.query(`SELECT count(*) AS n FROM ravon_delivery.webhook_log WHERE webhook_id = $1`, [c.headers["x-shopify-webhook-id"]])).rows[0].n;
    sameId.push(res.status === 200 && Number(after) === Number(before) + 1 ? await outcomeOf(c.headers["x-shopify-webhook-id"]) : `http${res.status}`);
  }
  const newId: string[] = [];
  for (const c of caps) {
    // HMAC covers the body only, so the original signature is still valid under a new id.
    const id = randomUUID();
    const res = await post({ ...strip(c.headers), "x-shopify-webhook-id": id }, c.raw_body);
    newId.push(res.status === 200 ? await outcomeOf(id) : `http${res.status}`);
  }
  return { tampered, sameId, newId, jobsBefore, jobsAfter: await count("jobs"), dispatchesBefore, dispatchesAfter: await count("dispatches") };
}

export async function runScenario(s: Scenario, opts: { seed: string; logDir: string }) {
  const pgUrl = process.env.RAVON_PG_URL!;
  const dispatchUrl = process.env.RAVON_DISPATCH_URL!;
  if (!pgUrl || !dispatchUrl) throw new Error("RAVON_PG_URL and RAVON_DISPATCH_URL are required");
  const base = Number(process.env.RAVON_HARNESS_PORT_BASE ?? 18500);
  const [appPort, probePort, fakePort] = [base, base + 1, base + 2];
  const seed = `${opts.seed}:${s.name}`;
  const crashLog = `${opts.logDir}/crash-${s.name}.jsonl`;
  rmSync(crashLog, { force: true });

  await migrate(pgUrl, { fresh: true, controls: s.schema });
  const pool = new pg.Pool({ connectionString: pgUrl, max: 4 });
  const intakeStart = new Date(Date.now() - 60000);
  await pool.query(`INSERT INTO ravon_delivery.shops (shop, intake_start) VALUES ($1, $2)`, [SHOP, intakeStart]);
  await pool.query(`INSERT INTO ravon_delivery.sweep_state (shop, watermark) VALUES ($1, $2)`, [SHOP, intakeStart]);

  const template = JSON.parse(readFileSync(new URL("./recorded/orders-create.template.json", import.meta.url), "utf8"));
  delete template._provenance;
  const fake = new FakeShopify({
    shop: SHOP,
    secret: SECRET,
    webhookUrl: `http://127.0.0.1:${appPort}/webhooks/orders`,
    apiVersion: API_VERSION,
    bucket: s.bucket,
    indexLagMs: s.lagMs,
    updatedOnCreate: true,
    costs: { RavonSweepOrders: 52, RavonOrderFulfillmentState: 25, RavonFulfillmentCreate: 10 },
    seed,
    payloadTemplate: template,
    closedFulfillmentOrderMessage: "Fulfillment order has an unfulfillable status= closed.",
  });
  const fakeUrl = await fake.listen(fakePort);

  const webEnv = {
    SHOPIFY_API_KEY: "ci-dummy-key",
    SHOPIFY_API_SECRET: SECRET,
    SHOPIFY_APP_URL: `http://127.0.0.1:${appPort}`,
    SCOPES,
    RAVON_PG_URL: pgUrl,
    RAVON_DISABLE: s.disable.join(","),
    RAVON_CAPTURE: s.probes ? "1" : "",
  };
  const web = startWeb(appPort, { ...webEnv, RAVON_FAULTS: `seed=${seed},drop=${s.drop},dup=${s.dup},delayMinMs=0,delayMaxMs=${s.delayMaxMs}` }, `${opts.logDir}/web-${s.name}.log`);
  const sup = new Supervisor(
    {
      RAVON_PG_URL: pgUrl,
      RAVON_DISPATCH_URL: dispatchUrl,
      RAVON_ADMIN: "fake",
      RAVON_FAKE_SHOPIFY_URL: fakeUrl,
      RAVON_API_VERSION: API_VERSION,
      RAVON_DISABLE: s.disable.join(","),
      RAVON_CRASH: s.crashRate > 0 ? `seed=${seed},rate=${s.crashRate},point=after_fulfillment_reply` : "",
      RAVON_CRASH_LOG: crashLog,
      RAVON_SIM_STEP_MS: "100",
      RAVON_SIM_COURIERS: "60",
      RAVON_SIM_SEED: seed,
      RAVON_LEASE_MS: "1500",
      RAVON_SWEEP_INTERVAL_MS: String(s.sweepEveryMs),
      RAVON_SWEEP_OVERLAP_MS: String(s.overlapMs),
      RAVON_DISPATCH_TICK_MS: "100",
      RAVON_FULFILL_TICK_MS: "100",
    },
    `${opts.logDir}/worker-${s.name}.log`,
  );
  let probeWeb: ReturnType<typeof startWeb> | null = null;
  try {
    await waitHttp(`http://127.0.0.1:${appPort}/`);
    sup.start();

    const truthCohort = new Map<string, "deliver" | "cancel">();
    const total = s.n + s.cancel;
    const cancelEvery = s.cancel > 0 ? total / s.cancel : Infinity;
    const started = Date.now();
    let lastEventAt = Date.now();
    const cancels: Promise<void>[] = [];
    for (let i = 0; i < total; i++) {
      const isCancel = s.cancel > 0 && Math.floor((i + 1) / cancelEvery) > Math.floor(i / cancelEvery);
      const o = fake.createOrder();
      truthCohort.set(o.gid, isCancel ? "cancel" : "deliver");
      if (isCancel) {
        const [u] = uniforms(`cancel-delay:${seed}:${o.gid}`, 1);
        cancels.push(
          sleep(u * s.cancelDelayMaxMs).then(() => {
            fake.cancelOrder(o.gid, "customer");
            lastEventAt = Date.now();
          }),
        );
      }
      lastEventAt = Date.now();
      const due = started + ((i + 1) * 1000) / s.createPerSec;
      if (due > Date.now()) await sleep(due - Date.now());
    }
    await Promise.all(cancels);
    const settled = await settle(pool, fake, s, lastEventAt);
    await fake.drainWebhooks();

    let probes: ProbeResult | null = null;
    if (s.probes) {
      probeWeb = startWeb(probePort, webEnv, `${opts.logDir}/web-probe-${s.name}.log`);
      await waitHttp(`http://127.0.0.1:${probePort}/`);
      probes = await probe(pool, probePort);
    }
    await sup.stop();

    const truth: OrderTruth[] = [...fake.orders.values()].map((o) => ({
      gid: o.gid,
      cohort: truthCohort.get(o.gid)!,
      shopifyCreatedAt: o.createdAt,
      fulfillments: o.fulfillments.filter((f) => f.status === "SUCCESS").length,
      fulfillmentCreateCalls: o.fulfillmentCreateCalls,
      firstFulfilledAt: o.fulfillments[0] ? new Date(o.fulfillments[0].createdAt) : null,
    }));
    const metrics = await collect(pool, SHOP, truth);
    let logged = 0;
    try {
      logged = readFileSync(crashLog, "utf8").split("\n").filter(Boolean).length;
    } catch {
      logged = 0;
    }
    const kills = { logged, sigkills: sup.sigkills, otherExits: sup.otherExits.length };
    const failures = s.check(metrics, kills, probes);
    if (!settled) failures.push("did not settle before the timeout");
    return {
      scenario: s.name,
      kind: s.name === "full" || s.name.endsWith("_on") ? "mechanism" : "negative-control",
      disabled: s.disable,
      params: { ...s, check: undefined },
      passed: failures.length === 0,
      failures,
      kills,
      probes,
      fake: fake.stats,
      metrics,
      seconds: Math.round((Date.now() - started) / 1000),
    };
  } finally {
    await sup.stop();
    await stopProc(web);
    if (probeWeb) await stopProc(probeWeb);
    await fake.close();
    await pool.end();
  }
}

async function main() {
  const args = process.argv.slice(2);
  const arg = (k: string, d?: string) => {
    const i = args.indexOf(k);
    return i >= 0 ? args[i + 1] : d;
  };
  const which = arg("--scenario", "full")!;
  const names = which === "all" ? ORDER : which.split(",");
  const logDir = arg("--log-dir", "/tmp")!;
  const seed = arg("--seed", "ci-2026-10")!;
  const out = arg("--out");
  const results = [];
  for (const name of names) {
    const s = SCENARIOS[name];
    if (!s) throw new Error(`unknown scenario ${name}; known: ${ORDER.join(", ")}`);
    console.log(`\n=== ${name} (disabled: ${s.disable.join(",") || "none"})`);
    const r = await runScenario(s, { seed, logDir });
    results.push(r);
    const m = r.metrics;
    console.log(
      `${r.passed ? "PASS" : "FAIL"} ${name} in ${r.seconds}s: orders ${m.orders.deliver}+${m.orders.cancel}, ` +
        `exactly-once jobs/dispatch/fulfil ${m.deliverCohortExactlyOnce.jobs}/${m.deliverCohortExactlyOnce.dispatches}/${m.deliverCohortExactlyOnce.fulfillments}, ` +
        `jobs/order ${JSON.stringify(m.jobsPerOrder)}, dispatches/order ${JSON.stringify(m.dispatchesPerOrder)}, ` +
        `fulfillments/order ${JSON.stringify(m.fulfillmentsPerOrder)}, deliveries ${JSON.stringify(m.deliveries)}, ` +
        `all-dropped ${m.ordersAllDeliveriesDropped.length}, by-sweep ${m.sweep.jobsCreatedBySweep}, never-dispatched ${m.ordersNeverDispatched.length}, ` +
        `kills ${r.kills.logged}/${r.kills.sigkills}, throttle ${JSON.stringify(m.throttle)}, rejected ${JSON.stringify(m.rejected)}, ` +
        `fulfillment ${JSON.stringify(m.fulfillment)}, cancel ${JSON.stringify(m.cancelCohort)}`,
    );
    for (const f of r.failures) console.log(`  - ${f}`);
  }
  if (out) writeFileSync(out, JSON.stringify({ at: new Date().toISOString(), seed, results }, null, 2));
  const failed = results.filter((r) => !r.passed);
  console.log(`\n${results.length - failed.length}/${results.length} scenarios passed`);
  process.exit(failed.length ? 1 : 0);
}

if (process.argv[1] && new URL(import.meta.url).pathname === process.argv[1]) {
  main().catch((e) => {
    console.error(e);
    process.exit(2);
  });
}
