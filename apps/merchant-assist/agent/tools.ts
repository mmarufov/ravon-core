// The agent's tools. Six read, one writes a pending proposal, none takes a
// merchant id: the merchant comes from the session (ToolContext), and each
// call runs as one role inside one transaction (db.ts).
import type Anthropic from "@anthropic-ai/sdk";
import type pg from "pg";
import { asMerchant, reasonOf } from "../db.js";
import { PROPOSAL_KINDS } from "../shared/answer.js";

export interface ToolContext {
  db: pg.Pool;
  merchantId: string;
}

export interface ProposalRecord {
  proposal_id: string;
  kind: string;
  amount_minor: number;
  entry_ids: number[];
  reason: string;
}

export interface ToolOutcome {
  content: string;
  isError: boolean;
  proposal?: ProposalRecord;
}

const UUID = { type: "string", description: "A UUID copied from an earlier tool result." } as const;
const nullable = (t: string, description: string) => ({ type: [t, "null"], description });

export const TOOLS: Anthropic.Tool[] = [
  {
    name: "list_orders",
    description:
      "This merchant's orders: status, subtotal, delivery fee, tip and total in minor units, reassign_count, and customer_note (text written by the customer).",
    input_schema: { type: "object", properties: {}, required: [], additionalProperties: false },
  },
  {
    name: "get_order_history",
    description:
      "The status changes of one order in time order, and any courier cancellation with its reason code.",
    input_schema: {
      type: "object",
      properties: { order_id: UUID },
      required: ["order_id"],
      additionalProperties: false,
    },
  },
  {
    name: "list_entries",
    description:
      "Ledger entries visible to this merchant, oldest first. Each has entry_id, transaction_id, event_type, event_id (the order, payout or adjustment it belongs to), account_kind, order_id (for escrow legs), direction, amount_minor and effect_minor. Filter by order or by event type, or pass null for all.",
    input_schema: {
      type: "object",
      properties: {
        order_id: nullable("string", "Only entries whose event or escrow account is this order, or null."),
        event_type: nullable("string", "Only this event type (e.g. settlement, refund, payout), or null."),
      },
      required: ["order_id", "event_type"],
      additionalProperties: false,
    },
  },
  {
    name: "get_transaction",
    description: "Every visible entry of one ledger transaction.",
    input_schema: {
      type: "object",
      properties: { transaction_id: UUID },
      required: ["transaction_id"],
      additionalProperties: false,
    },
  },
  {
    name: "list_payouts",
    description:
      "This merchant's payouts: payout_id, state (pending, unknown, submitted, posted, failed), amount_minor, provider_ref, failure_verdict, ledger_transaction_id.",
    input_schema: { type: "object", properties: {}, required: [], additionalProperties: false },
  },
  {
    name: "get_contract",
    description: "This merchant's contract: commission_bps (1500 = 15%) and currency.",
    input_schema: { type: "object", properties: {}, required: [], additionalProperties: false },
  },
  {
    name: "propose_action",
    description:
      "Propose a credit to the merchant for a Ravon error. This only creates a pending proposal for a Ravon operator to approve or reject; it moves no money. Cite the ledger entries that justify the amount.",
    input_schema: {
      type: "object",
      properties: {
        kind: { type: "string", enum: [...PROPOSAL_KINDS] },
        amount_minor: { type: "integer", description: "The credit in minor units, greater than 0." },
        entry_ids: { type: "array", items: { type: "integer" }, description: "Evidence entry ids." },
        reason: { type: "string", description: "One sentence for the operator." },
      },
      required: ["kind", "amount_minor", "entry_ids", "reason"],
      additionalProperties: false,
    },
  },
].map((t) => ({ ...t, strict: true }) as Anthropic.Tool);

const ENTRY_COLUMNS = `entry_id, transaction_id, event_type, event_id, account_kind, order_id,
  direction, amount_minor, effect_minor, currency`;

type Input = Record<string, unknown>;

async function read(ctx: ToolContext, sql: string, params: unknown[] = []): Promise<unknown[]> {
  return asMerchant(ctx.db, "assist_reader", ctx.merchantId, async (c) => (await c.query(sql, params)).rows);
}

const handlers: Record<string, (ctx: ToolContext, input: Input) => Promise<ToolOutcome>> = {
  async list_orders(ctx) {
    const rows = await read(ctx, `SELECT order_id, status, subtotal_minor, delivery_fee_minor, tip_minor,
      total_minor, reassign_count, customer_note FROM assist.orders ORDER BY created_at`);
    return ok(rows);
  },
  async get_order_history(ctx, input) {
    const rows = await read(
      ctx,
      `SELECT event, status, detail, created_at FROM assist.order_history
       WHERE order_id = $1::uuid ORDER BY created_at, event`,
      [input.order_id],
    );
    return ok(rows);
  },
  async list_entries(ctx, input) {
    const rows = await read(
      ctx,
      `SELECT ${ENTRY_COLUMNS} FROM assist.entries
       WHERE ($1::uuid IS NULL OR event_id = $1::uuid OR order_id = $1::uuid)
         AND ($2::text IS NULL OR event_type = $2::text)
       ORDER BY entry_id LIMIT 300`,
      [input.order_id ?? null, input.event_type ?? null],
    );
    return ok(rows);
  },
  async get_transaction(ctx, input) {
    const rows = await read(
      ctx,
      `SELECT ${ENTRY_COLUMNS} FROM assist.entries WHERE transaction_id = $1::uuid ORDER BY entry_id`,
      [input.transaction_id],
    );
    return ok(rows);
  },
  async list_payouts(ctx) {
    return ok(await read(ctx, `SELECT payout_id, state, amount_minor, currency, provider_ref, failure_verdict,
      ledger_transaction_id FROM assist.payouts ORDER BY created_at`));
  },
  async get_contract(ctx) {
    return ok(await read(ctx, "SELECT commission_bps, currency FROM assist.contract"));
  },
  async propose_action(ctx, input) {
    const proposal = {
      kind: String(input.kind),
      amount_minor: Number(input.amount_minor),
      entry_ids: (input.entry_ids as number[]).map(Number),
      reason: String(input.reason),
    };
    const id = await asMerchant(ctx.db, "assist_proposer", ctx.merchantId, async (c) => {
      const r = await c.query("SELECT public.assist_propose($1, $2, $3::bigint[], $4) AS id", [
        proposal.kind, proposal.amount_minor, proposal.entry_ids, proposal.reason,
      ]);
      return r.rows[0].id as string;
    });
    return {
      content: JSON.stringify({ proposal_id: id, status: "pending", note: "An operator must approve it. Nothing has been paid." }),
      isError: false,
      proposal: { proposal_id: id, ...proposal },
    };
  },
};

function ok(rows: unknown[]): ToolOutcome {
  return { content: JSON.stringify(rows), isError: false };
}

export async function runTool(name: string, input: Input, ctx: ToolContext): Promise<ToolOutcome> {
  const handler = handlers[name];
  if (!handler) return { content: `unknown tool ${name}`, isError: true };
  try {
    return await handler(ctx, input);
  } catch (err) {
    // Database refusals go back to the model as data, with the reason code.
    const reason = reasonOf(err);
    const message = (err as Error).message;
    return { content: JSON.stringify({ error: reason ?? message }), isError: true };
  }
}
