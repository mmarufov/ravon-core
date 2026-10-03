// One merchant question, answered. A manual loop rather than the SDK's tool
// runner, because the end of the loop is not "the model stopped": it is "the
// answer passed checkAnswer()". A failing answer goes back to the model with
// the checker's findings, at most MAX_REPAIRS times, and is never displayed.
import type Anthropic from "@anthropic-ai/sdk";
import { checkAnswer, citedEntryIds, onlineLookup } from "../grade.js";
import { Answer, answerJsonSchema } from "../shared/answer.js";
import type { Attempt, Stop, Usage } from "../shared/transcript.js";
import { REPAIR_PROMPT, SYSTEM_PROMPT } from "./prompt.js";
import { Budget, PRICES, costUsd } from "./pricing.js";
import { type ProposalRecord, TOOLS, type ToolContext, runTool } from "./tools.js";

export const MAX_TOKENS = 16_000;
export const MAX_API_CALLS = 16;
export const MAX_REPAIRS = 2;

// The one call the loop makes, injectable so the loop can be tested with a
// scripted model and no API key (test/agent.test.ts).
export type CreateMessage = (params: Anthropic.MessageCreateParamsNonStreaming) => Promise<Anthropic.Message>;

export interface AgentConfig {
  create: CreateMessage;
  model: string;
  effort: "low" | "medium" | "high" | null;   // null for models without effort (Haiku 4.5)
  budget: Budget;
}

export interface AgentResult {
  attempts: Attempt[];
  displayed: boolean;
  final_answer: Answer | null;
  proposals: ProposalRecord[];
  refused_proposals: { input: unknown; error: string }[];
  tool_calls: { name: string; input: unknown; is_error: boolean }[];
  usage: Usage;
  cost_usd: number;
  api_calls: number;
  stop: Stop;
  messages: Anthropic.MessageParam[];
}

const OUTPUT_FORMAT = { type: "json_schema", schema: answerJsonSchema() } as const;

// The system prompt and tools are identical for every case, so they carry an
// explicit breakpoint; automatic caching then follows the growing conversation.
const SYSTEM: Anthropic.TextBlockParam[] = [
  { type: "text", text: SYSTEM_PROMPT, cache_control: { type: "ephemeral" } },
];

function textOf(msg: Anthropic.Message): string {
  return msg.content.filter((b): b is Anthropic.TextBlock => b.type === "text").map((b) => b.text).join("");
}

// Worst case for one call: every input character a token, uncached, plus a
// full max_tokens of output. Deliberately pessimistic; it only gates spend.
function worstCaseUsd(model: string, messages: Anthropic.MessageParam[]): number {
  const p = PRICES[model];
  const inputTokens = (SYSTEM_PROMPT.length + JSON.stringify(TOOLS).length + JSON.stringify(messages).length);
  return (inputTokens * p.cache_write + MAX_TOKENS * p.output) / 1_000_000;
}

export async function answerQuestion(cfg: AgentConfig, ctx: ToolContext, question: string): Promise<AgentResult> {
  const messages: Anthropic.MessageParam[] = [{ role: "user", content: question }];
  const r: AgentResult = {
    attempts: [], displayed: false, final_answer: null, proposals: [], refused_proposals: [], tool_calls: [],
    usage: { input_tokens: 0, output_tokens: 0, cache_creation_input_tokens: 0, cache_read_input_tokens: 0 },
    cost_usd: 0, api_calls: 0, stop: "max_turns", messages,
  };
  let repairs = 0;

  const retry = (problems: string[]): boolean => {
    if (repairs >= MAX_REPAIRS) return false;
    repairs += 1;
    messages.push({ role: "user", content: REPAIR_PROMPT(problems) });
    return true;
  };

  while (r.api_calls < MAX_API_CALLS) {
    const reserve = worstCaseUsd(cfg.model, messages);
    if (!cfg.budget.reserve(reserve)) {
      r.stop = "budget";
      return r;
    }
    let msg: Anthropic.Message;
    try {
      msg = await cfg.create({
        model: cfg.model,
        max_tokens: MAX_TOKENS,
        system: SYSTEM,
        tools: TOOLS,
        messages,
        cache_control: { type: "ephemeral" },
        output_config: { format: OUTPUT_FORMAT, ...(cfg.effort ? { effort: cfg.effort } : {}) },
      } as Anthropic.MessageCreateParamsNonStreaming);
    } catch (err) {
      cfg.budget.settle(reserve, 0);
      throw err;
    }
    const cost = costUsd(cfg.model, msg.usage);
    cfg.budget.settle(reserve, cost);
    r.cost_usd += cost;
    r.api_calls += 1;
    r.usage.input_tokens += msg.usage.input_tokens;
    r.usage.output_tokens += msg.usage.output_tokens;
    r.usage.cache_creation_input_tokens += msg.usage.cache_creation_input_tokens ?? 0;
    r.usage.cache_read_input_tokens += msg.usage.cache_read_input_tokens ?? 0;
    messages.push({ role: "assistant", content: msg.content });

    if (msg.stop_reason === "refusal") {
      r.stop = "refusal";
      return r;
    }

    if (msg.stop_reason === "tool_use") {
      const results: Anthropic.ToolResultBlockParam[] = [];
      for (const block of msg.content) {
        if (block.type !== "tool_use") continue;
        const input = block.input as Record<string, unknown>;
        const out = await runTool(block.name, input, ctx);
        r.tool_calls.push({ name: block.name, input, is_error: out.isError });
        if (out.proposal) r.proposals.push(out.proposal);
        if (block.name === "propose_action" && out.isError) {
          r.refused_proposals.push({ input, error: JSON.parse(out.content).error });
        }
        results.push({ type: "tool_result", tool_use_id: block.id, content: out.content, is_error: out.isError });
      }
      messages.push({ role: "user", content: results });
      continue;
    }

    // A final reply. It is shown only if it parses and passes the checker.
    const raw = textOf(msg);
    let answer: Answer | null = null;
    let parseError: string | undefined;
    try {
      const parsed = Answer.safeParse(JSON.parse(raw));
      if (parsed.success) answer = parsed.data;
      else parseError = parsed.error.message;
    } catch (err) {
      parseError = `not JSON (stop_reason ${msg.stop_reason}): ${(err as Error).message}`;
    }
    if (!answer) {
      r.attempts.push({ raw, answer: null, parse_error: parseError, violations: [] });
      if (retry([`the reply did not match the answer schema: ${parseError}`])) continue;
      r.stop = "withheld";
      return r;
    }

    const evidence = await onlineLookup(ctx.db, ctx.merchantId, citedEntryIds(answer));
    const violations = checkAnswer(answer, evidence, new Set(r.proposals.map((p) => p.proposal_id)));
    r.attempts.push({ raw, answer, violations });
    if (violations.length === 0) {
      r.displayed = true;
      r.final_answer = answer;
      r.stop = "answered";
      return r;
    }
    if (retry(violations.map((v) => `${v.kind}: ${v.detail}`))) continue;
    r.stop = "withheld";
    return r;
  }
  return r;
}

// For the committed transcript: thinking signatures are opaque and large, and
// the conversation is kept for reading, not for replay.
export function forTranscript(messages: Anthropic.MessageParam[]): unknown[] {
  return messages.map((m) =>
    typeof m.content === "string"
      ? m
      : {
          role: m.role,
          content: m.content.map((b) =>
            b.type === "thinking" ? { type: "thinking", thinking: b.thinking }
            : b.type === "redacted_thinking" ? { type: "redacted_thinking" }
            : b),
        },
  );
}
