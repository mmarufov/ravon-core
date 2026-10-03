// What agent/run.ts writes, one JSON object per line, and grade.ts reads.
import type { Answer, Cause } from "./answer.js";
import type { ProposalRecord } from "../agent/tools.js";

export type ViolationKind =
  | "ungrounded_amount"      // amount_minor != signed sum of the cited entries
  | "amount_without_evidence" // an amount with no entry cited
  | "unknown_entry"          // online: not visible to the asker (phantom or another merchant's)
  | "phantom_entry"          // offline: no such entry exists
  | "cross_merchant_entry"   // offline: the entry exists but is not the asker's
  | "money_in_text"          // an amount written into text instead of a checked claim
  | "unknown_proposal";      // a proposal id this conversation did not create

export interface Violation {
  kind: ViolationKind;
  detail: string;
}

export interface Attempt {
  raw: string | null;
  answer: Answer | null;
  parse_error?: string;
  violations: Violation[];
}

export interface Usage {
  input_tokens: number;
  output_tokens: number;
  cache_creation_input_tokens: number;
  cache_read_input_tokens: number;
}

export type Stop = "answered" | "withheld" | "max_turns" | "refusal" | "budget" | "error";

export interface CaseTranscript {
  kind: "case";
  synthetic: true;
  run_id: string;
  case_id: string;
  cause: Cause;            // recorded for grading; never shown to the model
  injected: boolean;
  repeat: number;
  model: string;
  merchant_id: string;
  question: string;
  attempts: Attempt[];
  displayed: boolean;      // true only if the last attempt passed the online check
  final_answer: Answer | null;
  proposals: ProposalRecord[];
  refused_proposals: { input: unknown; error: string }[];
  tool_calls: { name: string; input: unknown; is_error: boolean }[];
  usage: Usage;
  cost_usd: number;
  latency_ms: number;
  api_calls: number;
  stop: Stop;
  error?: string;
  messages: unknown[];     // the full conversation, thinking signatures removed
}

export interface RunHeader {
  kind: "run";
  synthetic: true;
  run_id: string;
  started_at: string;
  git_sha: string;
  machine: string;
  model: string;
  effort: string | null;
  set: string;
  cases_file: string;
  ledger_digest: string;
  repeats: number;
  n_cases: number;
  max_usd: number;
  prices_usd_per_mtok: { input: number; output: number; cache_write: number; cache_read: number };
}

export interface RunSummary {
  kind: "summary";
  run_id: string;
  finished_at: string;
  spent_usd: number;
  aborted: boolean;
  abort_reason?: string;
  unapproved_assist_transactions: number;
}

export type Line = RunHeader | CaseTranscript | RunSummary;
