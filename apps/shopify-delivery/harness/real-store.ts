// The harness against the development store (runs R1 to R4, R6 and the probes in
// PREREGISTRATION.md). Test orders on a development store only; couriers are simulated.
//
//   tsx harness/real-store.ts run    --label r1 --n 200 --cancel 20 --crash-rate 0.15 --out harness/results/r1.json
//   tsx harness/real-store.ts run    --label r3 --n 30 --cancel 0 --disable sweep --out ...
//   tsx harness/real-store.ts burst  --queries 300 --concurrency 10 [--disable pacing] --out ...
//   tsx harness/real-store.ts probes --url https://<tunnel>/webhooks/orders --out ...
//
// Needs the app's env from `shopify app env show` (SHOPIFY_API_KEY, SHOPIFY_API_SECRET,
// SHOPIFY_APP_URL, SCOPES) in the environment, never in a file in the repo; plus
// RAVON_SHOP, RAVON_PG_URL and RAVON_DISPATCH_URL. The web server is `shopify app dev`,
// started separately with the same RAVON_* settings as the run (`run` prints them).

import { readFileSync, rmSync, writeFileSync } from "node:fs";
import { randomUUID } from "node:crypto";
import { execSync } from "node:child_process";
import pg from "pg";
import { migrate, type SchemaControl } from "../db/migrate";
import { templateAdmin, type AdminGraphql } from "../app/delivery/admin.server";
import { uniforms } from "../app/delivery/geo";
import { ORDER_FULFILLMENT_STATE } from "../app/delivery/operations";
import { CostPacer, isThrottled, paced } from "../app/delivery/throttle.server";
import { collect, type OrderTruth } from "./metrics";
import { Supervisor } from "./procs";

const ORDER_CREATE = /* GraphQL */ `
  mutation RavonHarnessOrderCreate($order: OrderCreateOrderInput!, $options: OrderCreateOptionsInput) {
    orderCreate(order: $order, options: $options) {
      order { id name createdAt }
      userErrors { field message }
    }
  }
`;

const ORDER_CANCEL = /* GraphQL */ `
  mutation RavonHarnessOrderCancel($orderId: ID!) {
    orderCancel(orderId: $orderId, reason: CUSTOMER, restock: false, notifyCustomer: false,
                staffNote: "Ravon harness: cancel cohort (test order)") {
      job { id }
      orderCancelUserErrors { field message code }
    }
  }
`;

const ORDER_TRUTH = /* GraphQL */ `
  query RavonHarnessOrderTruth($id: ID!) {
    order(id: $id) {
      id
      createdAt
      cancelledAt
      fulfillments(first: 20) { id status createdAt trackingInfo(first: 5) { number } }
    }
  }
`;

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

function args() {
  const a = process.argv.slice(3);
  const get = (k: string, d?: string) => {
    const i = a.indexOf(k);
    return i >= 0 ? a[i + 1] : d;
  };
  return { get, has: (k: string) => a.includes(k) };
}

function need(name: string): string {
  const v = process.env[name];
  if (!v) throw new Error(`${name} is not set`);
  return v;
}

function provenance() {
  const sha = execSync("git rev-parse HEAD", { encoding: "utf8" }).trim();
  const dirty = execSync("git status --porcelain -- .", { encoding: "utf8" }).trim() !== "";
  return {
    sha,
    dirty,
    at: new Date().toISOString(),
    machine: execSync("sysctl -n machdep.cpu.brand_string 2>/dev/null || uname -m", { encoding: "utf8" }).trim(),
    node: process.version,
    store: "development store (test orders only)",
    couriers: "simulated",
  };
}

async function call(admin: AdminGraphql, query: string, variables: Record<string, unknown>) {
  for (let i = 0; ; i++) {
    const res = await admin.request(query, variables);
    if (!isThrottled(res)) return res;
    if (i > 10) throw new Error("harness call throttled 10 times");
    await sleep(2000);
  }
}

async function runCmd() {
  const { get } = args();
  const label = get("--label")!;
  if (!label) throw new Error("--label is required");
  const n = Number(get("--n", "200"));
  const nCancel = Number(get("--cancel", "20"));
  const disable = (get("--disable", "") ?? "").split(",").filter(Boolean);
  const crashRate = Number(get("--crash-rate", "0"));
  const out = get("--out")!;
  const perMinute = Number(get("--per-minute", "5"));
  const shop = need("RAVON_SHOP");
  const pgUrl = need("RAVON_PG_URL");
  const seed = `${label}-2026-10`;
  const schema: SchemaControl[] = [];
  if (disable.includes("dedupe")) schema.push("no_job_key");
  if (disable.includes("lifecycle")) schema.push("no_lifecycle_trigger");

  const faults = process.env.RAVON_FAULTS;
  if (!faults) throw new Error("RAVON_FAULTS must be set, to the same value the web server runs with");
  console.log(`web server must run with: RAVON_FAULTS="${faults}" RAVON_DISABLE="${disable.join(",")}" RAVON_CAPTURE=1`);

  await migrate(pgUrl, { fresh: true, controls: schema });
  const pool = new pg.Pool({ connectionString: pgUrl, max: 4 });
  const intakeStart = new Date(Date.now() - 60000);
  await pool.query(`INSERT INTO ravon_delivery.shops (shop, intake_start) VALUES ($1, $2)`, [shop, intakeStart]);
  await pool.query(`INSERT INTO ravon_delivery.sweep_state (shop, watermark) VALUES ($1, $2)`, [shop, intakeStart]);

  const crashLog = `/tmp/ravon-real-crash-${label}.jsonl`;
  rmSync(crashLog, { force: true });
  const sup = new Supervisor(
    {
      RAVON_ADMIN: "template",
      RAVON_DISABLE: disable.join(","),
      RAVON_CRASH: crashRate > 0 ? `seed=${label}-crash,rate=${crashRate},point=after_fulfillment_reply` : "",
      RAVON_CRASH_LOG: crashLog,
      RAVON_SIM_STEP_MS: "2000",
      RAVON_SIM_COURIERS: "40",
      RAVON_SIM_SEED: seed,
      RAVON_LEASE_MS: "15000",
      RAVON_SWEEP_INTERVAL_MS: "60000",
      RAVON_SWEEP_OVERLAP_MS: "300000",
    },
    `/tmp/ravon-real-worker-${label}.log`,
    1000,
  );
  const admin = await templateAdmin(shop);
  const startedAt = new Date();
  sup.start();

  const orders: { gid: string; cohort: "deliver" | "cancel"; createdAt: Date }[] = [];
  const total = n + nCancel;
  const cancelEvery = nCancel > 0 ? total / nCancel : Infinity;
  const cancels: Promise<void>[] = [];
  const spacing = 60000 / perMinute + 500;
  let lastEventAt = Date.now();
  for (let i = 0; i < total; i++) {
    const t0 = Date.now();
    const isCancel = nCancel > 0 && Math.floor((i + 1) / cancelEvery) > Math.floor(i / cancelEvery);
    const res = await call(admin, ORDER_CREATE, {
      order: {
        test: true,
        currency: "USD",
        financialStatus: "PAID",
        tags: ["ravon-harness", label],
        lineItems: [
          { title: "Plov (test item)", quantity: 1, requiresShipping: true, priceSet: { shopMoney: { amount: "10.00", currencyCode: "USD" } } },
        ],
        shippingLines: [{ title: "Ravon local delivery (simulated)", priceSet: { shopMoney: { amount: "2.00", currencyCode: "USD" } } }],
        shippingAddress: {
          firstName: "Test",
          lastName: `Buyer ${label}-${i}`,
          address1: "1 Test Street",
          city: "New York",
          provinceCode: "NY",
          countryCode: "US",
          zip: "10001",
        },
      },
      options: { sendReceipt: false, sendFulfillmentReceipt: false },
    });
    const payload = res.data?.orderCreate;
    if (res.errors?.length || !payload?.order) {
      console.error(`orderCreate ${i} failed:`, JSON.stringify(res.errors ?? payload?.userErrors));
      // Count it against nothing; wait out a possible rate limit and try the same index again.
      await sleep(61000);
      i--;
      continue;
    }
    const o = payload.order;
    orders.push({ gid: o.id, cohort: isCancel ? "cancel" : "deliver", createdAt: new Date(o.createdAt) });
    console.log(`${new Date().toISOString()} created ${i + 1}/${total} ${o.name} ${o.id}${isCancel ? " (cancel cohort)" : ""}`);
    if (isCancel) {
      const [u] = uniforms(`cancel-delay:${seed}:${o.id}`, 1);
      cancels.push(
        sleep(u * 20000).then(async () => {
          const c = await call(admin, ORDER_CANCEL, { orderId: o.id });
          const errs = c.errors ?? c.data?.orderCancel?.orderCancelUserErrors;
          if (errs?.length) console.error(`orderCancel ${o.id}:`, JSON.stringify(errs));
          lastEventAt = Date.now();
        }),
      );
    }
    lastEventAt = Date.now();
    writeFileSync(`${out}.orders.json`, JSON.stringify(orders, null, 2));
    const wait = spacing - (Date.now() - t0);
    if (wait > 0 && i < total - 1) await sleep(wait);
  }
  await Promise.all(cancels);

  // Settle: every fault delay has elapsed, three sweeps have run since, and nothing has
  // changed for a minute, or 25 minutes have passed.
  const quietAfter = lastEventAt + 2 * 30000 + 3 * 60000;
  const deadline = Date.now() + 25 * 60000;
  let last = "";
  let stableSince = Date.now();
  while (Date.now() < deadline) {
    await sleep(5000);
    const r = await pool.query(
      `SELECT (SELECT count(*) FROM ravon_delivery.jobs) j, (SELECT count(*) FROM ravon_delivery.dispatches) d,
              (SELECT count(*) FROM ravon_delivery.fulfillment_intents) i,
              (SELECT count(*) FROM ravon_delivery.jobs WHERE fulfillment_state = 'done') f`,
    );
    const sig = JSON.stringify(r.rows[0]);
    if (sig !== last) {
      last = sig;
      stableSince = Date.now();
      console.log(`${new Date().toISOString()} ${sig}`);
    }
    if (Date.now() > quietAfter && Date.now() - stableSince > 60000) break;
  }
  await sup.stop();

  const truth: OrderTruth[] = [];
  for (const o of orders) {
    const r = await call(admin, ORDER_TRUTH, { id: o.gid });
    const fs = (r.data?.order?.fulfillments ?? []) as { status: string; createdAt: string }[];
    const ok = fs.filter((f) => f.status === "SUCCESS");
    truth.push({
      gid: o.gid,
      cohort: o.cohort,
      shopifyCreatedAt: new Date(r.data?.order?.createdAt ?? o.createdAt),
      fulfillments: ok.length,
      fulfillmentCreateCalls: null,
      firstFulfilledAt: ok[0] ? new Date(ok[0].createdAt) : null,
    });
    await sleep(100);
  }
  const metrics = await collect(pool, shop, truth);
  const logged = (() => {
    try {
      return readFileSync(crashLog, "utf8").split("\n").filter(Boolean).length;
    } catch {
      return 0;
    }
  })();
  const createdSpanMin = (orders.at(-1)!.createdAt.getTime() - orders[0].createdAt.getTime()) / 60000;
  const result = {
    label,
    provenance: provenance(),
    command: process.argv.join(" "),
    params: { n, nCancel, disable, crashRate, perMinute, faults, schema, seed },
    startedAt,
    finishedAt: new Date(),
    ordersCreatedPerMinute: orders.length / Math.max(createdSpanMin, 1e-9),
    kills: { logged, sigkills: sup.sigkills, otherExits: sup.otherExits },
    metrics,
  };
  writeFileSync(out, JSON.stringify(result, null, 2));
  console.log(JSON.stringify({ ...result, metrics: { ...metrics, violations: metrics.violations.slice(0, 10) } }, null, 2));
  await pool.end();
}

// R6: the same read the fulfillment writer makes, 300 times, as fast as `concurrency`
// workers can, through the pacer or (with --disable pacing) without it.
async function burstCmd() {
  const { get } = args();
  const shop = need("RAVON_SHOP");
  const queries = Number(get("--queries", "300"));
  const concurrency = Number(get("--concurrency", "10"));
  const pacing = !(get("--disable", "") ?? "").includes("pacing");
  const out = get("--out")!;
  const ordersFile = get("--orders")!;
  const gids = (JSON.parse(readFileSync(ordersFile, "utf8")) as { gid: string }[]).map((o) => o.gid);
  const admin = await templateAdmin(shop);
  const events: { kind: string; at: number; available: number | null; waitMs: number }[] = [];
  const pacer = new CostPacer({ enabled: pacing, record: (e) => events.push({ kind: e.kind, at: Date.now(), available: e.available, waitMs: e.waitMs }) });
  const statuses: { maximumAvailable: number; currentlyAvailable: number; restoreRate: number }[] = [];
  const costs: number[] = [];
  let next = 0;
  const t0 = Date.now();
  await Promise.all(
    Array.from({ length: concurrency }, async () => {
      while (next < queries) {
        const i = next++;
        const res = await paced(admin, pacer, shop, "RavonOrderFulfillmentState", ORDER_FULFILLMENT_STATE, { id: gids[i % gids.length] }, 20, 50);
        const c = res.extensions?.cost;
        if (c?.throttleStatus) statuses.push(c.throttleStatus);
        if (c?.requestedQueryCost !== undefined) costs.push(c.requestedQueryCost);
      }
    }),
  );
  const result = {
    provenance: provenance(),
    command: process.argv.join(" "),
    pacing,
    queries,
    concurrency,
    seconds: (Date.now() - t0) / 1000,
    throttled: events.filter((e) => e.kind === "throttled").length,
    paced: events.filter((e) => e.kind === "paced").length,
    minAvailable: Math.min(...statuses.map((s) => s.currentlyAvailable)),
    bucket: statuses[0] ? { maximumAvailable: statuses[0].maximumAvailable, restoreRate: statuses[0].restoreRate } : null,
    requestedQueryCost: costs[0] ?? null,
  };
  writeFileSync(out, JSON.stringify(result, null, 2));
  console.log(JSON.stringify(result, null, 2));
}

// Security probes against the running app (faults off): tampered bodies, byte-for-byte
// replays, and captured bodies under a fresh webhook id.
async function probesCmd() {
  const { get } = args();
  const url = get("--url")!;
  const out = get("--out")!;
  const pool = new pg.Pool({ connectionString: need("RAVON_PG_URL"), max: 2 });
  const count = async (t: string) => Number((await pool.query(`SELECT count(*) AS n FROM ravon_delivery.${t}`)).rows[0].n);
  const caps = (
    await pool.query<{ headers: Record<string, string>; raw_body: string }>(
      `SELECT c.headers, c.raw_body FROM harness.capture c
         JOIN ravon_delivery.webhook_receipts r ON r.webhook_id = c.headers->>'x-shopify-webhook-id'
        WHERE c.headers->>'x-shopify-topic' = 'orders/create' ORDER BY c.id LIMIT 10`,
    )
  ).rows;
  if (caps.length < 10) throw new Error(`only ${caps.length} captured deliveries`);
  const strip = (h: Record<string, string>) =>
    Object.fromEntries(Object.entries(h).filter(([k]) => k.startsWith("x-shopify-") || k === "content-type"));
  const post = (headers: Record<string, string>, body: string) => fetch(url, { method: "POST", headers, body });
  const outcomeOf = async (id: string) =>
    (await pool.query(`SELECT outcome FROM ravon_delivery.webhook_log WHERE webhook_id = $1 ORDER BY id DESC LIMIT 1`, [id])).rows[0]?.outcome ?? "none";
  const before = { jobs: await count("jobs"), dispatches: await count("dispatches") };
  const tampered = [];
  for (const c of caps) {
    const body = c.raw_body.replace('"test":true', '"test":false');
    tampered.push((await post(strip(c.headers), body === c.raw_body ? c.raw_body + " " : body)).status);
  }
  const sameId = [];
  for (const c of caps) {
    const res = await post(strip(c.headers), c.raw_body);
    await sleep(300);
    sameId.push({ status: res.status, outcome: await outcomeOf(c.headers["x-shopify-webhook-id"]) });
  }
  const newId = [];
  for (const c of caps) {
    const id = randomUUID();
    const res = await post({ ...strip(c.headers), "x-shopify-webhook-id": id }, c.raw_body);
    await sleep(300);
    newId.push({ status: res.status, outcome: await outcomeOf(id) });
  }
  const after = { jobs: await count("jobs"), dispatches: await count("dispatches") };
  const result = { provenance: provenance(), command: process.argv.join(" "), url, tampered, sameId, newId, before, after };
  writeFileSync(out, JSON.stringify(result, null, 2));
  console.log(JSON.stringify(result, null, 2));
  await pool.end();
}

const cmd = process.argv[2];
const run = cmd === "run" ? runCmd : cmd === "burst" ? burstCmd : cmd === "probes" ? probesCmd : null;
if (!run) {
  console.error("usage: real-store.ts run|burst|probes ...");
  process.exit(2);
}
run().then(
  () => process.exit(0),
  (e) => {
    console.error(e);
    process.exit(1);
  },
);
