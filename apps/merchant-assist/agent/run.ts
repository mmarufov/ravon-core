// Run the seeded cases through the agent and write one transcript per line.
//
//   ASSIST_ADMIN_DSN=postgresql://postgres@host/db ASSIST_AGENT_DSN=postgresql://assist_agent:pw@host/db \
//   npx tsx agent/run.ts --cases-file ../../db/assist/cases.eval.json --cases 40 --repeats 3 \
//     --model claude-sonnet-5-5 --effort low --max-usd 15 --out results/<date>-<model>.jsonl
//
// Spend is capped by --max-usd, which is required: each API call reserves its
// worst case first (agent/pricing.ts) and the run stops scheduling cases once
// the cap would be crossed. The cases are seeded and synthetic.
import { execSync } from "node:child_process";
import { appendFileSync, existsSync, readFileSync, writeFileSync } from "node:fs";
import os from "node:os";
import Anthropic from "@anthropic-ai/sdk";
import { pool } from "../db.js";
import { ledgerDigest, unapprovedAssistTransactions } from "../grade.js";
import type { Cause } from "../shared/answer.js";
import type { CaseTranscript, RunHeader, RunSummary } from "../shared/transcript.js";
import { type AgentConfig, answerQuestion, forTranscript } from "./agent.js";
import { Budget, PRICES } from "./pricing.js";

interface SeededCase {
  case_id: string;
  cause: Cause;
  merchant_id: string;
  question: string;
  injected: boolean;
}

function arg(name: string, fallback?: string): string {
  const i = process.argv.indexOf(`--${name}`);
  const v = i >= 0 ? process.argv[i + 1] : fallback;
  if (v === undefined) throw new Error(`--${name} is required`);
  return v;
}

async function main(): Promise<void> {
  const casesFile = arg("cases-file", "../../db/assist/cases.eval.json");
  const seeded = JSON.parse(readFileSync(casesFile, "utf8")) as { set: string; ledger_digest: string; cases: SeededCase[] };
  const only = process.argv.includes("--only") ? new Set(arg("only").split(",")) : null;
  const cases = seeded.cases.filter((c) => !only || only.has(c.case_id)).slice(0, Number(arg("cases", "1000")));
  const repeats = Number(arg("repeats", "1"));
  const model = arg("model");
  const effortArg = arg("effort", "none");
  const effort = effortArg === "none" ? null : (effortArg as AgentConfig["effort"]);
  const maxUsd = Number(arg("max-usd"));
  const concurrency = Number(arg("concurrency", "4"));
  const out = arg("out");
  if (!PRICES[model]) throw new Error(`unknown model ${model}; add its prices to agent/pricing.ts`);
  if (!(maxUsd > 0)) throw new Error("--max-usd must be a positive number");
  if (existsSync(out)) throw new Error(`${out} exists; transcripts are append-only records, pick a new name`);

  const admin = pool(process.env.ASSIST_ADMIN_DSN ?? arg("admin-dsn"), 2);
  const agentDb = pool(process.env.ASSIST_AGENT_DSN ?? arg("agent-dsn"), concurrency + 1);
  const digest = await ledgerDigest(admin);
  if (digest !== seeded.ledger_digest) {
    throw new Error(`database ledger ${digest} is not the one ${casesFile} was seeded into (${seeded.ledger_digest})`);
  }

  const client = new Anthropic({ maxRetries: 4 });
  const budget = new Budget(maxUsd);
  const cfg: AgentConfig = { create: (p) => client.messages.create(p), model, effort, budget };
  const runId = `${new Date().toISOString().slice(0, 19).replace(/[:T]/g, "")}-${model}-${effortArg}`;

  const header: RunHeader = {
    kind: "run", synthetic: true, run_id: runId, started_at: new Date().toISOString(),
    git_sha: execSync("git rev-parse HEAD").toString().trim(),
    machine: `${os.cpus()[0]?.model ?? "cpu"}, ${os.type()} ${os.release()}, node ${process.version}`,
    model, effort, set: seeded.set, cases_file: casesFile, ledger_digest: digest,
    repeats, n_cases: cases.length, max_usd: maxUsd, prices_usd_per_mtok: PRICES[model],
  };
  writeFileSync(out, JSON.stringify(header) + "\n");

  const jobs = Array.from({ length: repeats }, (_, r) => cases.map((c) => ({ c, repeat: r + 1 }))).flat();
  let next = 0;
  let abortReason: string | undefined;

  async function worker(): Promise<void> {
    while (next < jobs.length && !abortReason) {
      const { c, repeat } = jobs[next++];
      // Each case starts from the seeded state: no proposal left over from an
      // earlier repeat (none is ever approved during a run).
      await admin.query("DELETE FROM public.assist_proposals WHERE merchant_id = $1 AND status = 'pending'", [c.merchant_id]);
      const t0 = performance.now();
      const base = {
        kind: "case" as const, synthetic: true as const, run_id: runId, case_id: c.case_id, cause: c.cause,
        injected: c.injected, repeat, model, merchant_id: c.merchant_id, question: c.question,
      };
      let line: CaseTranscript;
      try {
        const res = await answerQuestion(cfg, { db: agentDb, merchantId: c.merchant_id }, c.question);
        line = { ...base, ...res, messages: forTranscript(res.messages), latency_ms: Math.round(performance.now() - t0) };
        if (res.stop === "budget") abortReason = `budget cap $${maxUsd} reached`;
      } catch (err) {
        line = {
          ...base, attempts: [], displayed: false, final_answer: null, proposals: [], refused_proposals: [],
          tool_calls: [], usage: { input_tokens: 0, output_tokens: 0, cache_creation_input_tokens: 0, cache_read_input_tokens: 0 },
          cost_usd: 0, api_calls: 0, stop: "error", error: String(err), messages: [],
          latency_ms: Math.round(performance.now() - t0),
        };
        if (err instanceof Anthropic.AuthenticationError || err instanceof Anthropic.PermissionDeniedError) {
          abortReason = `API credentials rejected: ${(err as Error).message}`;
        }
      }
      appendFileSync(out, JSON.stringify(line) + "\n");
      const shown = line.displayed ? line.final_answer?.diagnosis : `(${line.stop})`;
      console.log(`${c.case_id} r${repeat}: ${shown} ${line.displayed && line.final_answer?.diagnosis === c.cause ? "ok" : "MISS"} `
        + `$${line.cost_usd.toFixed(4)} ${(line.latency_ms / 1000).toFixed(1)}s  [spent $${budget.spentUsd.toFixed(3)}]`);
    }
  }

  await Promise.all(Array.from({ length: concurrency }, worker));

  const unapproved = await unapprovedAssistTransactions(admin);
  const summary: RunSummary = {
    kind: "summary", run_id: runId, finished_at: new Date().toISOString(),
    spent_usd: Math.round(budget.spentUsd * 1e6) / 1e6, aborted: Boolean(abortReason),
    ...(abortReason ? { abort_reason: abortReason } : {}),
    unapproved_assist_transactions: unapproved.length,
  };
  appendFileSync(out, JSON.stringify(summary) + "\n");
  console.log(`\nspent $${summary.spent_usd.toFixed(4)}; unapproved assist transactions: ${unapproved.length}${abortReason ? `; ABORTED: ${abortReason}` : ""}`);
  await admin.end();
  await agentDb.end();
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
