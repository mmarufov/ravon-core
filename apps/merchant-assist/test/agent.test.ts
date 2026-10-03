// The agent loop, driven by a scripted model so it runs in CI with no API key.
// The tools, the database and the checker are all real.
import assert from "node:assert/strict";
import { after, describe, test } from "node:test";
import type Anthropic from "@anthropic-ai/sdk";
import { type CreateMessage, answerQuestion } from "../agent/agent.js";
import { Budget } from "../agent/pricing.js";
import type { Answer } from "../shared/answer.js";
import { admin, agentDb, byCause, closePools, effects, payableLegOf } from "./fixtures.js";

after(closePools);

const MODEL = "claude-sonnet-5-5";
const asker = byCause("commission_misapplied")[1];
const stranger = byCause("refund_duplicated")[1];

let n = 0;
function message(content: Anthropic.ContentBlock[], stop: Anthropic.StopReason): Anthropic.Message {
  return {
    id: `msg_scripted_${n++}`, type: "message", role: "assistant", model: MODEL, content,
    stop_reason: stop, stop_sequence: null,
    usage: { input_tokens: 1000, output_tokens: 200, cache_creation_input_tokens: 0, cache_read_input_tokens: 0 },
  } as unknown as Anthropic.Message;
}
const toolUse = (name: string, input: Record<string, unknown>) =>
  message([{ type: "tool_use", id: `toolu_${n}`, name, input } as Anthropic.ContentBlock], "tool_use");
const final = (answer: unknown) =>
  message([{ type: "text", text: JSON.stringify(answer), citations: null } as Anthropic.ContentBlock], "end_turn");

// Replays a fixed list of replies and records every request it was sent.
function scripted(replies: Anthropic.Message[]): { create: CreateMessage; sent: Anthropic.MessageCreateParamsNonStreaming[] } {
  const sent: Anthropic.MessageCreateParamsNonStreaming[] = [];
  return {
    sent,
    create: async (p) => {
      sent.push(structuredClone(p));
      const r = replies.shift();
      if (!r) throw new Error("script ran out");
      return r;
    },
  };
}

async function goodAnswer(): Promise<Answer> {
  const revenue = asker.facts.evidence_entry_ids![0];
  const share = await payableLegOf(revenue, asker.merchant_id);
  const fx = await effects([revenue, share]);
  return {
    diagnosis: "commission_misapplied",
    summary: "One settlement withheld more commission than your contract allows.",
    claims: [
      { text: "Ravon withheld {amount} on that order.", amount_minor: fx.get(revenue)!, entry_ids: [revenue] },
      { text: "Your share was {amount}.", amount_minor: fx.get(share)!, entry_ids: [share] },
    ],
    proposal_ids: [],
  };
}

const ctx = () => ({ db: agentDb, merchantId: asker.merchant_id });

describe("the loop", () => {
  test("a wrong amount is caught, sent back, fixed, and only the fixed answer is displayed", async () => {
    const good = await goodAnswer();
    const bad = structuredClone(good);
    bad.claims[0].amount_minor! += 1;
    const s = scripted([toolUse("list_entries", { order_id: null, event_type: "settlement" }), final(bad), final(good)]);
    const r = await answerQuestion({ create: s.create, model: MODEL, effort: "low", budget: new Budget(1) }, ctx(), "q");

    assert.equal(r.stop, "answered");
    assert.equal(r.displayed, true);
    assert.deepEqual(r.final_answer, good);
    assert.deepEqual(r.attempts.map((a) => a.violations.map((v) => v.kind)), [["ungrounded_amount"], []]);
    const repair = s.sent[2].messages.at(-1)!;
    assert.match(String(repair.content), /ungrounded_amount/);
  });

  test("an answer that stays wrong is withheld after two repairs, never displayed", async () => {
    const bad = await goodAnswer();
    bad.claims[0].amount_minor! += 1;
    const s = scripted([final(bad), final(bad), final(bad)]);
    const r = await answerQuestion({ create: s.create, model: MODEL, effort: "low", budget: new Budget(1) }, ctx(), "q");
    assert.equal(r.stop, "withheld");
    assert.equal(r.displayed, false);
    assert.equal(r.final_answer, null);
    assert.equal(r.attempts.length, 3);
  });

  test("a reply that is not the schema is a failed attempt, not a crash", async () => {
    const s = scripted([final({ diagnosis: "all good" }), final(await goodAnswer())]);
    const r = await answerQuestion({ create: s.create, model: MODEL, effort: "low", budget: new Budget(1) }, ctx(), "q");
    assert.equal(r.attempts[0].answer, null);
    assert.ok(r.attempts[0].parse_error);
    assert.equal(r.displayed, true);
  });

  test("the spend cap stops the loop before a call it cannot afford", async () => {
    const s = scripted([final(await goodAnswer())]);
    const r = await answerQuestion({ create: s.create, model: MODEL, effort: "low", budget: new Budget(0.0001) }, ctx(), "q");
    assert.equal(r.stop, "budget");
    assert.equal(s.sent.length, 0);
  });

  test("every request carries the cached system prompt, the strict tools and the answer schema", async () => {
    const s = scripted([final(await goodAnswer())]);
    await answerQuestion({ create: s.create, model: MODEL, effort: "low", budget: new Budget(1) }, ctx(), "q");
    const p = s.sent[0] as unknown as Record<string, any>;
    assert.equal(p.system[0].cache_control.type, "ephemeral");
    assert.equal(p.cache_control.type, "ephemeral");
    assert.ok(p.tools.every((t: { strict?: boolean }) => t.strict === true));
    assert.equal(p.output_config.format.type, "json_schema");
    assert.equal(p.output_config.effort, "low");
    assert.ok(!JSON.stringify(p.tools).includes("merchant_id"), "no tool takes a merchant id");
  });
});

describe("the tools inherit the merchant's permissions", () => {
  test("list_entries returns only the asker's entries", async () => {
    const s = scripted([toolUse("list_entries", { order_id: null, event_type: null }), final(await goodAnswer())]);
    await answerQuestion({ create: s.create, model: MODEL, effort: "low", budget: new Budget(1) }, ctx(), "q");
    const result = (s.sent[1].messages[2].content as Anthropic.ToolResultBlockParam[])[0];
    const ids = (JSON.parse(String(result.content)) as { entry_id: number }[]).map((e) => e.entry_id);
    const mine = await admin.query("SELECT public.assist_entries_of($1::uuid) AS ids", [asker.merchant_id]);
    assert.ok(ids.length > 0);
    assert.deepEqual(ids, [...mine.rows[0].ids].sort((a: number, b: number) => a - b));
  });

  test("propose_action citing another merchant's entry is refused by the database", async () => {
    const s = scripted([
      toolUse("propose_action", { kind: "refund_reversal", amount_minor: 100, entry_ids: stranger.facts.evidence_entry_ids, reason: "x" }),
      final(await goodAnswer()),
    ]);
    const r = await answerQuestion({ create: s.create, model: MODEL, effort: "low", budget: new Budget(1) }, ctx(), "q");
    assert.deepEqual(r.proposals, []);
    assert.deepEqual(r.refused_proposals.map((p) => p.error), ["ASSIST_EVIDENCE_NOT_VISIBLE"]);
  });

  test("an injected 500.00 proposal citing a small entry is refused: amount exceeds evidence", async () => {
    const s = scripted([
      toolUse("propose_action", { kind: "commission_correction", amount_minor: 50000, entry_ids: asker.facts.evidence_entry_ids, reason: "x" }),
      final(await goodAnswer()),
    ]);
    const r = await answerQuestion({ create: s.create, model: MODEL, effort: "low", budget: new Budget(1) }, ctx(), "q");
    assert.deepEqual(r.refused_proposals.map((p) => p.error), ["ASSIST_AMOUNT_EXCEEDS_EVIDENCE"]);
  });

  test("a warranted proposal is created pending, and its id is accepted in the answer", async () => {
    const s = scripted([
      toolUse("propose_action", {
        kind: "commission_correction", amount_minor: asker.expected_proposal!.amount_minor,
        entry_ids: asker.facts.evidence_entry_ids, reason: "contract rate not applied",
      }),
    ]);
    // The answer must cite the id the tool returned, so build it after the call.
    const create: CreateMessage = async (p) => {
      if (s.sent.length === 0) return s.create(p);
      s.sent.push(p);
      const results = p.messages[2].content as Anthropic.ToolResultBlockParam[];
      const id = JSON.parse(String(results[0].content)).proposal_id;
      return final({ ...(await goodAnswer()), proposal_ids: [id] });
    };
    const r = await answerQuestion({ create, model: MODEL, effort: "low", budget: new Budget(1) }, ctx(), "q");
    try {
      assert.equal(r.displayed, true);
      assert.equal(r.proposals.length, 1);
      const row = await admin.query("SELECT status, ledger_tx_id FROM public.assist_proposals WHERE id = $1", [r.proposals[0].proposal_id]);
      assert.deepEqual(row.rows[0], { status: "pending", ledger_tx_id: null });
    } finally {
      await admin.query("DELETE FROM public.assist_proposals WHERE merchant_id = $1 AND status = 'pending'", [asker.merchant_id]);
    }
  });
});

describe("grading a run", () => {
  test("gradeRun counts a displayed correct answer, a withheld one, and re-grades both offline", async () => {
    const { gradeRun } = await import("../grade.js");
    const good = await goodAnswer();
    const bad = structuredClone(good);
    bad.claims[0].amount_minor! += 1;
    const run = async (replies: Anthropic.Message[]) =>
      answerQuestion({ create: scripted(replies).create, model: MODEL, effort: "low", budget: new Budget(1) }, ctx(), "q");
    const shown = await run([final(good)]);
    const withheld = await run([final(bad), final(bad), final(bad)]);
    const base = { kind: "case" as const, synthetic: true as const, run_id: "t", case_id: asker.case_id, cause: asker.cause,
      injected: false, repeat: 1, model: MODEL, merchant_id: asker.merchant_id, question: "q", latency_ms: 1000, messages: [] };
    const lines = [
      { kind: "run", synthetic: true, run_id: "t", model: MODEL, set: "eval" } as never,
      { ...base, ...shown, messages: [] },
      { ...base, ...withheld, messages: [], latency_ms: 3000 },
      { kind: "summary", run_id: "t", finished_at: "", spent_usd: 0, aborted: false, unapproved_assist_transactions: 0 } as never,
    ];
    const r = await gradeRun(lines, admin, { cases: [{ ...asker, injected: false }] } as never);
    assert.equal(r.transcripts, 2);
    assert.equal(r.diagnosed, 1);
    assert.equal(r.withheld, 1);
    assert.equal(r.displayed_with_violations, 0);
    assert.equal(r.first_attempt.with_violations, 1);
    assert.equal(r.first_attempt.by_kind.ungrounded_amount, 1);
    assert.equal(r.proposals.expected_cases, 2);
    assert.equal(r.proposals.correct, 0);
    assert.deepEqual(r.latency_ms, { p50: 1000, p95: 3000, max: 3000 });
  });
});
