import type { ActionFunctionArgs } from "react-router";
import { faultLayer, parseFaults } from "../delivery/faults.server";
import { handleOrderDelivery } from "../delivery/intake.server";
import { pgPool } from "../delivery/pg.server";
import { authenticate } from "../shopify.server";

// orders/create, orders/updated and orders/cancelled, all on one URI (shopify.app.toml).
//
// HMAC verification is the template's authenticate.webhook: it answers 401 for a bad
// signature and 400 for missing headers before any of this project's code runs. The
// handler then records the delivery and applies it in one transaction, and answers 200
// only after that commits; an error answers 500, so Shopify retries.

async function handle(request: Request, arrivedAt: Date): Promise<Response> {
  const raw = await request.clone().text();
  const { shop, topic, webhookId, eventId, triggeredAt, payload } = await authenticate.webhook(request);
  try {
    await handleOrderDelivery({
      shop,
      topic: String(topic).toLowerCase().replace("_", "/"),
      webhookId,
      eventId: eventId ?? null,
      triggeredAt: triggeredAt ?? null,
      payload,
      rawBody: raw,
      arrivedAt,
    });
  } catch (e) {
    console.error(`webhook ${webhookId} (${topic}) failed:`, e);
    return new Response(null, { status: 500 });
  }
  return new Response(null, { status: 200 });
}

const faults = parseFaults();
const front = faults ? faultLayer(faults, handle) : handle;

export const action = async ({ request }: ActionFunctionArgs) => {
  const arrivedAt = new Date();
  if (process.env.RAVON_CAPTURE === "1") {
    const body = await request.clone().text();
    await pgPool().query(
      `INSERT INTO harness.capture (arrived_at, headers, raw_body) VALUES ($1, $2, $3)`,
      [arrivedAt, Object.fromEntries(request.headers.entries()), body],
    );
  }
  return front(request, arrivedAt);
};
