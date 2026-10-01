// Turns deliveries captured from the development store (harness.capture, RAVON_CAPTURE=1)
// into what may be committed: one scrubbed orders/create body as the fake's template, and
// a summary of which topics Shopify actually sent per order, which sets the fake's
// `updatedOnCreate`.
//
//   tsx harness/export-capture.ts --label r1 --summary harness/results/r1-topics.json \
//     [--bodies /tmp/ravon-r1-bodies.json]
//
// --bodies writes every captured orders/create body, scrubbed the same way, to a local
// file for the flash-sale replay. It is not committed.
//
// Scrubbed: order, cart and checkout tokens, the order status URL, browser and client
// details, every customer and address field (test data, but nothing is kept that could
// identify a store, buyer or session), and the HMAC header is never exported.

import { writeFileSync } from "node:fs";
import pg from "pg";

const DROP = [
  "token", "cart_token", "checkout_token", "checkout_id", "confirmation_number", "order_status_url",
  "browser_ip", "client_details", "landing_site", "landing_site_ref", "referring_site", "source_identifier",
  "source_url", "device_id", "user_id", "location_id", "customer_locale", "note_attributes", "reference",
];
const PERSON = ["email", "contact_email", "phone"];

// eslint-disable-next-line @typescript-eslint/no-explicit-any
function scrub(o: any): any {
  for (const k of DROP) delete o[k];
  for (const k of PERSON) if (k in o) o[k] = k === "phone" ? null : "test.buyer@example.com";
  const addr = { first_name: "Test", last_name: "Buyer", name: "Test Buyer", address1: "1 Test Street", address2: null,
    city: "Testville", zip: "10001", phone: null, company: null, latitude: null, longitude: null };
  for (const k of ["shipping_address", "billing_address"]) if (o[k]) o[k] = { ...o[k], ...addr };
  if (o.customer) o.customer = { id: 0, admin_graphql_api_id: "gid://shopify/Customer/0", email: "test.buyer@example.com", first_name: "Test", last_name: "Buyer" };
  if (Array.isArray(o.line_items)) {
    for (const li of o.line_items) {
      delete li.origin_location;
      delete li.destination_location;
    }
  }
  return o;
}

async function main() {
  const a = process.argv.slice(2);
  const get = (k: string) => (a.indexOf(k) >= 0 ? a[a.indexOf(k) + 1] : undefined);
  const label = get("--label") ?? "r1";
  const summaryOut = get("--summary");
  const bodiesOut = get("--bodies");
  const pool = new pg.Pool({ connectionString: process.env.RAVON_PG_URL });
  const rows = (await pool.query<{ arrived_at: Date; headers: Record<string, string>; raw_body: string }>(
    `SELECT arrived_at, headers, raw_body FROM harness.capture ORDER BY id`,
  )).rows;
  if (rows.length === 0) throw new Error("harness.capture is empty");

  const create = rows.find((r) => r.headers["x-shopify-topic"] === "orders/create");
  if (!create) throw new Error("no orders/create captured");
  const body = scrub(JSON.parse(create.raw_body));
  const template = {
    _provenance: `Captured from the development store in run ${label} on ${create.arrived_at.toISOString()} (a test order), then scrubbed by harness/export-capture.ts. Ids, timestamps and cancellation fields are overwritten per order by the fake.`,
    ...body,
  };
  writeFileSync(new URL("./recorded/orders-create.template.json", import.meta.url), JSON.stringify(template, null, 2) + "\n");

  // Which topics arrived for each order, in arrival order, and how the first ones line up.
  const byOrder = new Map<string, { topic: string; updatedAt: string; createdAt: string }[]>();
  for (const r of rows) {
    let p;
    try {
      p = JSON.parse(r.raw_body);
    } catch {
      continue;
    }
    const gid = p.admin_graphql_api_id;
    if (!gid) continue;
    byOrder.set(gid, [...(byOrder.get(gid) ?? []), { topic: r.headers["x-shopify-topic"], updatedAt: p.updated_at, createdAt: p.created_at }]);
  }
  const atCreation: Record<string, number> = {};
  for (const evs of byOrder.values()) {
    const first = evs.filter((e) => e.updatedAt === e.createdAt).map((e) => e.topic).sort().join("+");
    atCreation[first] = (atCreation[first] ?? 0) + 1;
  }
  const topics: Record<string, number> = {};
  for (const r of rows) topics[r.headers["x-shopify-topic"]] = (topics[r.headers["x-shopify-topic"]] ?? 0) + 1;
  const summary = {
    label,
    captured: rows.length,
    orders: byOrder.size,
    topics,
    topicsWithUpdatedAtEqualToCreatedAt: atCreation,
    apiVersionHeader: create.headers["x-shopify-api-version"],
    headerNames: Object.keys(create.headers).filter((h) => h.startsWith("x-shopify-")).sort(),
  };
  if (summaryOut) writeFileSync(summaryOut, JSON.stringify(summary, null, 2) + "\n");
  if (bodiesOut) {
    const seen = new Set<string>();
    const bodies = [];
    for (const r of rows.filter((x) => x.headers["x-shopify-topic"] === "orders/create")) {
      const b = scrub(JSON.parse(r.raw_body));
      if (seen.has(b.admin_graphql_api_id)) continue;
      seen.add(b.admin_graphql_api_id);
      bodies.push(b);
    }
    writeFileSync(bodiesOut, JSON.stringify(bodies));
    console.log(`wrote ${bodies.length} scrubbed orders/create bodies to ${bodiesOut}`);
  }
  console.log(JSON.stringify(summary, null, 2));
  await pool.end();
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
