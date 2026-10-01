import { appendFileSync } from "node:fs";
import { uniforms } from "./geo";

// Crash injection for the fault harness. Off unless RAVON_CRASH is set.
//
// RAVON_CRASH="seed=s1,rate=0.15,point=after_fulfillment_reply"
//
// At the named point, a job is selected when a uniform draw keyed on (seed, job id) is
// below `rate`, and only on its first attempt, so every selected job dies exactly once and
// its retry has to finish the work. The process SIGKILLs itself: no handler, finally block
// or pending write runs, which is the same as `kill -9` from outside at that instruction.
// A JSON line goes to RAVON_CRASH_LOG first, so the harness can count kills at the point
// independently of counting exits.

export type CrashPoint = "after_fulfillment_reply";

export interface CrashPlan {
  seed: string;
  rate: number;
  point: CrashPoint;
}

export function parseCrash(raw = process.env.RAVON_CRASH): CrashPlan | null {
  if (!raw) return null;
  const kv = Object.fromEntries(raw.split(",").map((p) => p.split("=").map((s) => s.trim())));
  const rate = Number(kv.rate);
  if (!kv.seed || !Number.isFinite(rate) || kv.point !== "after_fulfillment_reply") {
    throw new Error(`RAVON_CRASH unparseable: ${raw}`);
  }
  return { seed: kv.seed, rate, point: kv.point };
}

export function selected(plan: CrashPlan, jobId: string, attempt: number): boolean {
  return attempt === 1 && uniforms(`crash:${plan.seed}:${jobId}`, 1)[0] < plan.rate;
}

export function maybeCrash(
  plan: CrashPlan | null,
  point: CrashPoint,
  jobId: string,
  attempt: number,
  detail: Record<string, unknown> = {},
): void {
  if (!plan || plan.point !== point || !selected(plan, jobId, attempt)) return;
  const log = process.env.RAVON_CRASH_LOG;
  if (log) {
    appendFileSync(
      log,
      JSON.stringify({ point, jobId, attempt, pid: process.pid, at: new Date().toISOString(), ...detail }) +
        "\n",
    );
  }
  process.kill(process.pid, "SIGKILL");
}
