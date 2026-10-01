import { uniforms } from "./geo";
import { pgPool } from "./pg.server";

// The seeded fault layer that sits in front of the webhook handler during harness runs.
// Off unless RAVON_FAULTS is set; never set in production.
//
// RAVON_FAULTS="seed=s1,drop=0.2,dup=0.1,delayMinMs=0,delayMaxMs=30000"
//
// It answers Shopify 200 at once, so Shopify considers every delivery done and will not
// retry, and then, per delivery:
//   drop  (probability `drop`): never forwards it. Only the sweep can recover the order.
//   dup   (probability `dup`):  forwards it twice, each after its own random delay.
//   once  (the rest):           forwards it once after a random delay.
// Independent delays in [delayMinMs, delayMaxMs] reorder deliveries for the same order.
// Every decision is a function of (seed, X-Shopify-Webhook-Id), so a run is reproducible
// from its seed and the deliveries Shopify made.
//
// Forwarding goes through the real handler, HMAC check included, with the original
// headers and the original bytes.

export interface FaultConfig {
  seed: string;
  drop: number;
  dup: number;
  delayMinMs: number;
  delayMaxMs: number;
}

export type FaultAction = "drop" | "once" | "dup";

export function parseFaults(raw = process.env.RAVON_FAULTS): FaultConfig | null {
  if (!raw) return null;
  const kv = Object.fromEntries(raw.split(",").map((p) => p.split("=").map((s) => s.trim())));
  const cfg = {
    seed: kv.seed,
    drop: Number(kv.drop ?? 0),
    dup: Number(kv.dup ?? 0),
    delayMinMs: Number(kv.delayMinMs ?? 0),
    delayMaxMs: Number(kv.delayMaxMs ?? 0),
  };
  if (!cfg.seed || [cfg.drop, cfg.dup, cfg.delayMinMs, cfg.delayMaxMs].some((n) => !Number.isFinite(n))) {
    throw new Error(`RAVON_FAULTS unparseable: ${raw}`);
  }
  if (cfg.drop + cfg.dup > 1 || cfg.delayMaxMs < cfg.delayMinMs) {
    throw new Error(`RAVON_FAULTS out of range: ${raw}`);
  }
  return cfg;
}

export function planFor(cfg: FaultConfig, webhookId: string): { action: FaultAction; delays: number[] } {
  const [u, d1, d2] = uniforms(`fault:${cfg.seed}:${webhookId}`, 3);
  const span = cfg.delayMaxMs - cfg.delayMinMs;
  const delay = (x: number) => Math.round(cfg.delayMinMs + x * span);
  if (u < cfg.drop) return { action: "drop", delays: [] };
  if (u < cfg.drop + cfg.dup) return { action: "dup", delays: [delay(d1), delay(d2)] };
  return { action: "once", delays: [delay(d1)] };
}

export type Forward = (request: Request, arrivedAt: Date) => Promise<Response>;

function orderGidOf(raw: string): string | null {
  try {
    const p = JSON.parse(raw);
    return typeof p?.admin_graphql_api_id === "string" ? p.admin_graphql_api_id : null;
  } catch {
    return null;
  }
}

export function faultLayer(cfg: FaultConfig, forward: Forward) {
  const pool = pgPool();
  return async (request: Request, arrivedAt: Date): Promise<Response> => {
    const raw = await request.text();
    const headers = new Headers(request.headers);
    const webhookId = headers.get("x-shopify-webhook-id") ?? `missing-${arrivedAt.getTime()}`;
    const plan = planFor(cfg, webhookId);
    const logged = pool
      .query(
        `INSERT INTO harness.fault_log (webhook_id, topic, order_gid, action, delays_ms, arrived_at)
         VALUES ($1, $2, $3, $4, $5, $6) RETURNING id`,
        [webhookId, headers.get("x-shopify-topic"), orderGidOf(raw), plan.action, plan.delays, arrivedAt],
      )
      .then((r) => r.rows[0].id as number);

    plan.delays.forEach((ms) => {
      setTimeout(async () => {
        let status: number;
        try {
          const res = await forward(new Request(request.url, { method: "POST", headers, body: raw }), arrivedAt);
          status = res.status;
        } catch (e) {
          status = e instanceof Response ? e.status : 599;
        }
        const id = await logged;
        await pool
          .query(
            `UPDATE harness.fault_log SET forward_statuses = array_append(forward_statuses, $2),
                                          forwarded_at = array_append(forwarded_at, clock_timestamp())
              WHERE id = $1`,
            [id, status],
          )
          .catch(() => {});
      }, ms);
    });
    await logged;
    return new Response(null, { status: 200 });
  };
}
