// F1, the flash-sale replay (PREREGISTRATION.md). SYNTHETIC LOAD on one machine.
//
//   tsx harness/flash-sale.ts --orders 1000 --seconds 60 --dups 100 --bodies <file> --out results.json
//
// --bodies is a JSON array of scrubbed captured orders/create bodies (export-capture.ts
// --bodies); order i is a clone of body i mod length. Without it, the recorded template.
//
// Captured orders/create bodies are cloned into `--orders` orders with new ids, re-signed
// with SHOPIFY_API_SECRET (the app secret on a developer's machine; a dummy in CI), and
// posted at a uniform rate to a local build of the app. Dispatch goes through the local
// Kotlin ravon-api; every Admin API call goes to the fake Shopify, because a development
// store accepts 5 orderCreate calls a minute. Nothing here touches a real store.

import { execSync } from "node:child_process";
import { createHmac } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";
import pg from "pg";
import { migrate } from "../db/migrate";
import { uniforms, uuidFrom } from "../app/delivery/geo";
import { FakeShopify } from "./fake-shopify";
import { startWeb, stopProc, Supervisor, waitHttp } from "./procs";

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

function pct(sorted: number[], p: number): number | null {
  if (!sorted.length) return null;
  return sorted[Math.min(sorted.length - 1, Math.ceil((p / 100) * sorted.length) - 1)];
}

async function main() {
  const a = process.argv.slice(2);
  const get = (k: string, d?: string) => (a.indexOf(k) >= 0 ? a[a.indexOf(k) + 1] : d);
  const n = Number(get("--orders", "1000"));
  const seconds = Number(get("--seconds", "60"));
  const dups = Number(get("--dups", "100"));
  const payloadFile = get("--payload", new URL("./recorded/orders-create.template.json", import.meta.url).pathname)!;
  const out = get("--out")!;
  const bucket = { maximum: Number(get("--bucket-max", "2000")), restoreRate: Number(get("--bucket-restore", "100")) };
  const seed = get("--seed", "f1-2026-10")!;
  const pgUrl = process.env.RAVON_PG_URL!;
  const dispatchUrl = process.env.RAVON_DISPATCH_URL!;
  const secret = process.env.SHOPIFY_API_SECRET ?? "ci-dummy-secret-not-a-credential";
  const shop = process.env.RAVON_SHOP ?? "ravon-flash.myshopify.com";
  const base = Number(process.env.RAVON_HARNESS_PORT_BASE ?? 18600);
  const [appPort, fakePort] = [base, base + 2];

  const template = JSON.parse(readFileSync(payloadFile, "utf8"));
  delete template._provenance;
  const bodiesFile = get("--bodies");
  const captured: Record<string, unknown>[] = bodiesFile ? JSON.parse(readFileSync(bodiesFile, "utf8")) : [template];

  await migrate(pgUrl, { fresh: true });
  const pool = new pg.Pool({ connectionString: pgUrl, max: 4 });
  const intakeStart = new Date(Date.now() - 60000);
  await pool.query(`INSERT INTO ravon_delivery.shops (shop, intake_start) VALUES ($1, $2)`, [shop, intakeStart]);
  await pool.query(`INSERT INTO ravon_delivery.sweep_state (shop, watermark) VALUES ($1, $2)`, [shop, intakeStart]);

  const fake = new FakeShopify({
    shop,
    secret,
    webhookUrl: null,
    apiVersion: "2026-07",
    bucket,
    indexLagMs: [500, 1500],
    updatedOnCreate: false,
    costs: { RavonSweepOrders: Number(get("--cost-sweep", "52")), RavonOrderFulfillmentState: Number(get("--cost-state", "25")), RavonFulfillmentCreate: Number(get("--cost-create", "10")) },
    seed,
    payloadTemplate: template,
    closedFulfillmentOrderMessage: "Fulfillment order has an unfulfillable status= closed.",
  });
  const fakeUrl = await fake.listen(fakePort);
  const web = startWeb(
    appPort,
    {
      SHOPIFY_API_KEY: process.env.SHOPIFY_API_KEY ?? "flash-dummy-key",
      SHOPIFY_API_SECRET: secret,
      SHOPIFY_APP_URL: `http://127.0.0.1:${appPort}`,
      SCOPES: "read_orders",
      RAVON_PG_URL: pgUrl,
      RAVON_FAULTS: "",
      RAVON_CAPTURE: "",
      RAVON_DISABLE: "",
      RAVON_PG_POOL: "20",
    },
    "/tmp/ravon-flash-web.log",
  );
  const sup = new Supervisor(
    {
      RAVON_PG_URL: pgUrl,
      RAVON_DISPATCH_URL: dispatchUrl,
      RAVON_ADMIN: "fake",
      RAVON_FAKE_SHOPIFY_URL: fakeUrl,
      RAVON_DISABLE: "",
      RAVON_CRASH: "",
      RAVON_SIM_STEP_MS: "500",
      RAVON_SIM_COURIERS: "300",
      RAVON_SIM_SEED: seed,
      RAVON_LEASE_MS: "15000",
      RAVON_SWEEP_INTERVAL_MS: "60000",
      RAVON_SWEEP_OVERLAP_MS: "300000",
      RAVON_DISPATCH_TICK_MS: "50",
      RAVON_FULFILL_TICK_MS: "100",
    },
    "/tmp/ravon-flash-worker.log",
  );

  try {
    await waitHttp(`http://127.0.0.1:${appPort}/`);
    sup.start();
    await sleep(3000);

    // Build every delivery up front so the send loop only sends.
    const sends: { at: number; headers: Record<string, string>; body: string; gid: string; dup: boolean }[] = [];
    const stamp = () => new Date(Math.floor(Date.now() / 1000) * 1000).toISOString().replace(".000Z", "Z");
    const orders = Array.from({ length: n }, (_, i) => {
      const o = fake.createOrder({ emitWebhooks: false });
      const webhookId = uuidFrom(`${seed}:wh:${i}`);
      return { o, i, webhookId };
    });
    const indexOf = new Map(orders.map(({ o, i }) => [o.gid, i]));
    const dupIdx = new Set<number>();
    for (let k = 0; dupIdx.size < Math.min(dups, n); k++) {
      dupIdx.add(Math.floor(uniforms(`${seed}:dup:${k}`, 1)[0] * n));
    }
    const intervalMs = (seconds * 1000) / n;
    for (const { o, i, webhookId } of orders) {
      sends.push({ at: i * intervalMs, headers: { "x-shopify-webhook-id": webhookId }, body: "", gid: o.gid, dup: false });
      if (dupIdx.has(i)) {
        const later = i * intervalMs + uniforms(`${seed}:dupat:${i}`, 1)[0] * (seconds * 1000 - i * intervalMs);
        sends.push({ at: later, headers: { "x-shopify-webhook-id": webhookId }, body: "", gid: o.gid, dup: true });
      }
    }
    sends.sort((x, y) => x.at - y.at);

    const bodies = new Map<string, string>();
    const sign = (body: string) => createHmac("sha256", secret).update(body, "utf8").digest("base64");
    const ack: number[] = [];
    const statuses: Record<string, number> = {};
    const t0 = Date.now();
    const inflight: Promise<void>[] = [];
    for (const s of sends) {
      const wait = t0 + s.at - Date.now();
      if (wait > 0) await sleep(wait);
      let body = bodies.get(s.gid);
      if (!body) {
        // Stamped when first sent, as Shopify stamps an order when it is created.
        const now = stamp();
        const o = fake.orders.get(s.gid)!;
        o.createdAt = new Date(now);
        o.updatedAt = new Date(now);
        // A captured body with only its identity and timestamps replaced.
        const k = indexOf.get(s.gid)!;
        const ids = fake.payloadFor(o);
        body = JSON.stringify({
          ...captured[k % captured.length],
          id: ids.id,
          admin_graphql_api_id: ids.admin_graphql_api_id,
          name: ids.name,
          order_number: ids.order_number,
          cancelled_at: null,
          cancel_reason: null,
          created_at: now,
          updated_at: now,
          processed_at: now,
        });
        bodies.set(s.gid, body);
      }
      const headers = {
        "content-type": "application/json",
        "x-shopify-topic": "orders/create",
        "x-shopify-hmac-sha256": sign(body),
        "x-shopify-shop-domain": shop,
        "x-shopify-api-version": "2026-07",
        "x-shopify-webhook-id": s.headers["x-shopify-webhook-id"],
        "x-shopify-event-id": s.headers["x-shopify-webhook-id"],
        "x-shopify-triggered-at": new Date().toISOString(),
      };
      const sentAt = performance.now();
      inflight.push(
        fetch(`http://127.0.0.1:${appPort}/webhooks/orders`, { method: "POST", headers, body }).then(async (r) => {
          await r.arrayBuffer();
          ack.push(performance.now() - sentAt);
          statuses[r.status] = (statuses[r.status] ?? 0) + 1;
        }),
      );
    }
    await Promise.all(inflight);
    const sendSeconds = (Date.now() - t0) / 1000;

    // Wait for every order to be dispatched, then for fulfillment to drain.
    const deadline = Date.now() + 10 * 60000;
    let dispatchedAllAt: number | null = null;
    while (Date.now() < deadline) {
      await sleep(1000);
      const r = await pool.query(
        `SELECT (SELECT count(*) FROM ravon_delivery.dispatches) d,
                (SELECT count(*) FROM ravon_delivery.jobs WHERE fulfillment_state = 'done') f`,
      );
      if (dispatchedAllAt === null && Number(r.rows[0].d) >= n) dispatchedAllAt = Date.now();
      if (Number(r.rows[0].f) >= n) break;
    }
    await sup.stop();

    const lat = (
      await pool.query<{ ms: number }>(
        `SELECT extract(epoch FROM d.assigned_at - j.first_arrived_at) * 1000 AS ms
           FROM ravon_delivery.dispatches d JOIN ravon_delivery.jobs j ON j.id = d.job_id`,
      )
    ).rows
      .map((r) => Number(r.ms))
      .sort((x, y) => x - y);
    const perOrder = (
      await pool.query<{ jobs: string; dispatches: string; n: string }>(
        `SELECT jobs, dispatches, count(*) AS n FROM (
           SELECT j.order_gid, count(DISTINCT j.id) jobs, count(d.id) dispatches
             FROM ravon_delivery.jobs j LEFT JOIN ravon_delivery.dispatches d ON d.job_id = j.id
            GROUP BY j.order_gid) x GROUP BY jobs, dispatches`,
      )
    ).rows;
    const outcomes = (await pool.query(`SELECT outcome, count(*) n FROM ravon_delivery.webhook_log GROUP BY outcome`)).rows;
    const throttle = (await pool.query(`SELECT kind, count(*) n FROM ravon_delivery.throttle_events GROUP BY kind`)).rows;
    const fulfilled = [...fake.orders.values()].map((o) => o.fulfillments.length);
    const ackSorted = ack.sort((x, y) => x - y);
    const result = {
      label: "F1 flash-sale replay (SYNTHETIC LOAD, local, fake Shopify for Admin API calls)",
      provenance: {
        sha: execSync("git rev-parse HEAD", { encoding: "utf8" }).trim(),
        dirty: execSync("git status --porcelain -- .", { encoding: "utf8" }).trim() !== "",
        at: new Date().toISOString(),
        machine: execSync("sysctl -n machdep.cpu.brand_string 2>/dev/null || uname -m", { encoding: "utf8" }).trim(),
        node: process.version,
        payload: bodiesFile ?? payloadFile,
        payloadProvenance: bodiesFile
          ? `${captured.length} scrubbed orders/create bodies captured from the development store`
          : JSON.parse(readFileSync(payloadFile, "utf8"))._provenance ?? null,
        secret: process.env.SHOPIFY_API_SECRET ? "app secret from env" : "dummy",
      },
      command: process.argv.join(" "),
      params: { n, seconds, dups, bucket, couriers: 300, stepMs: 500 },
      sendSeconds,
      deliveriesSent: sends.length,
      httpStatuses: statuses,
      ackMs: { p50: pct(ackSorted, 50), p99: pct(ackSorted, 99), max: ackSorted.at(-1) },
      webhookToDispatchMs: { n: lat.length, p50: pct(lat, 50), p99: pct(lat, 99), max: lat.at(-1) ?? null },
      allDispatchedSecondsAfterFirstSend: dispatchedAllAt ? (dispatchedAllAt - t0) / 1000 : null,
      jobsAndDispatchesPerOrder: perOrder,
      intakeOutcomes: outcomes,
      throttleEvents: throttle,
      fakeShopify: fake.stats,
      fulfillmentsPerOrder: fulfilled.reduce((h: Record<string, number>, v) => ((h[v] = (h[v] ?? 0) + 1), h), {}),
    };
    writeFileSync(out, JSON.stringify(result, null, 2));
    console.log(JSON.stringify(result, null, 2));
  } finally {
    await sup.stop();
    await stopProc(web);
    await fake.close();
    await pool.end();
  }
}

main().then(
  () => process.exit(0),
  (e) => {
    console.error(e);
    process.exit(1);
  },
);
