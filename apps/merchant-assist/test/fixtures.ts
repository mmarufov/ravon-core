// Shared by the tests. They need the seeded eval database (db/assist/README.md):
//   ASSIST_ADMIN_DSN  table owner, to build expectations and to plant rogue postings
//   ASSIST_AGENT_DSN  assist_agent's login, the same one the agent uses
//   ASSIST_CASES      the cases file seed.py wrote for that database
import { readFileSync } from "node:fs";
import type pg from "pg";
import { pool } from "../db.js";
import type { Cause } from "../shared/answer.js";

export interface SeededCase {
  case_id: string;
  cause: Cause;
  merchant_id: string;
  expected_proposal: { kind: string; amount_minor: number } | null;
  facts: Record<string, unknown> & { evidence_entry_ids?: number[] };
}

export const casesFile = JSON.parse(
  readFileSync(process.env.ASSIST_CASES ?? "../../db/assist/cases.eval.json", "utf8"),
) as { ledger_digest: string; cases: SeededCase[] };

export const byCause = (cause: Cause): SeededCase[] => casesFile.cases.filter((c) => c.cause === cause);

function need(name: string): string {
  const v = process.env[name];
  if (!v) throw new Error(`${name} is not set; see db/assist/README.md`);
  return v;
}

export const admin: pg.Pool = pool(need("ASSIST_ADMIN_DSN"), 3);
export const agentDb: pg.Pool = pool(need("ASSIST_AGENT_DSN"), 3);

export async function effects(ids: number[]): Promise<Map<number, number>> {
  const r = await admin.query(
    `SELECT e.id, (CASE WHEN e.direction = 'debit' THEN e.amount_minor ELSE -e.amount_minor END)
              * public.ledger_normal_sign(a.kind) AS effect
     FROM public.ledger_entries e JOIN public.ledger_accounts a ON a.id = e.account_id
     WHERE e.id = ANY($1::bigint[])`,
    [ids],
  );
  return new Map(r.rows.map((x) => [Number(x.id), Number(x.effect)]));
}

// The merchant_payable leg of the transaction an evidence entry belongs to.
export async function payableLegOf(entryId: number, merchantId: string): Promise<number> {
  const r = await admin.query(
    `SELECT e2.id FROM public.ledger_entries e1
     JOIN public.ledger_entries e2 ON e2.transaction_id = e1.transaction_id
     JOIN public.ledger_accounts a ON a.id = e2.account_id
     WHERE e1.id = $1 AND a.kind = 'merchant_payable' AND a.owner_id = $2`,
    [entryId, merchantId],
  );
  return Number(r.rows[0].id);
}

export async function closePools(): Promise<void> {
  await admin.end();
  await agentDb.end();
}
