// Mechanism switches. Every guarantee this app claims can be turned off one at a time, so
// each claim has a negative control: the same harness, the mechanism off, and a failure
// it must show. Production runs with RAVON_DISABLE unset.
//
//   dedupe        X-Shopify-Webhook-Id receipts AND the (shop, order_gid) job key; intake
//                 becomes "insert a job per orders/create delivery" (needs --control no_job_key)
//   receipts      only the webhook-id receipts; the job key still holds
//   lifecycle     version and edge checks; last writer wins (needs --control no_lifecycle_trigger)
//   sweep         the reconciliation sweep
//   status_check  the read of Shopify's fulfillment state before a retried write
//   pacing        cost-based pacing; requests go out as fast as the worker makes them

export type Mechanism = "dedupe" | "receipts" | "lifecycle" | "sweep" | "status_check" | "pacing";

const ALL: readonly Mechanism[] = ["dedupe", "receipts", "lifecycle", "sweep", "status_check", "pacing"];

export interface DeliveryConfig {
  disabled: ReadonlySet<Mechanism>;
  on(m: Mechanism): boolean;
}

export function parseDisabled(raw: string | undefined): Set<Mechanism> {
  const out = new Set<Mechanism>();
  for (const part of (raw ?? "").split(",").map((s) => s.trim()).filter(Boolean)) {
    if (!(ALL as readonly string[]).includes(part)) {
      throw new Error(`RAVON_DISABLE: unknown mechanism "${part}" (known: ${ALL.join(", ")})`);
    }
    out.add(part as Mechanism);
  }
  // Turning off the job key without the receipts would still dedupe redeliveries, which
  // is not the naive handler the control is meant to stand for.
  if (out.has("dedupe")) out.add("receipts");
  return out;
}

export function deliveryConfig(raw = process.env.RAVON_DISABLE): DeliveryConfig {
  const disabled = parseDisabled(raw);
  return { disabled, on: (m) => !disabled.has(m) };
}

export function env(name: string, fallback?: string): string {
  const v = process.env[name] ?? fallback;
  if (v === undefined || v === "") throw new Error(`${name} is not set`);
  return v;
}

export function envNumber(name: string, fallback: number): number {
  const raw = process.env[name];
  if (raw === undefined || raw === "") return fallback;
  const n = Number(raw);
  if (!Number.isFinite(n)) throw new Error(`${name} is not a number: ${raw}`);
  return n;
}
