import { appendFileSync, existsSync, readFileSync } from "node:fs";
import { uniforms } from "./geo";

// Crash injection for the fault harness. Off unless RAVON_CRASH is set.
//
// RAVON_CRASH="seed=s1,rate=0.15,point=after_fulfillment_reply"
//
// At the named point, an order is selected when a uniform draw keyed on (seed, order GID)
// is below `rate`, and the process dies the first time a selected order reaches the
// point, so every selected order is killed exactly once and its retry has to finish the
// work. "First time" is read from RAVON_CRASH_LOG, not from the attempt number: when one
// order's kill takes down another selected order's in-flight attempt, that order still
// gets its own kill on the retry. Keyed on the order rather than the job id, so the set of
// selected orders does not depend on random job UUIDs. The process SIGKILLs itself: no
// handler, finally block or pending write runs, which is the same as `kill -9` from
// outside at that instruction. The JSON line is written first, so the harness can count
// kills at the point independently of counting exits.

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

export function selected(plan: CrashPlan, orderGid: string): boolean {
  return uniforms(`crash:${plan.seed}:${orderGid}`, 1)[0] < plan.rate;
}

function alreadyKilled(log: string, orderGid: string): boolean {
  if (!existsSync(log)) return false;
  return readFileSync(log, "utf8")
    .split("\n")
    .some((line) => line.includes(`"orderGid":${JSON.stringify(orderGid)}`));
}

export function maybeCrash(
  plan: CrashPlan | null,
  point: CrashPoint,
  orderGid: string,
  detail: Record<string, unknown> = {},
): void {
  if (!plan || plan.point !== point || !selected(plan, orderGid)) return;
  const log = process.env.RAVON_CRASH_LOG;
  if (!log) throw new Error("RAVON_CRASH needs RAVON_CRASH_LOG");
  if (alreadyKilled(log, orderGid)) return;
  appendFileSync(
    log,
    JSON.stringify({ point, orderGid, pid: process.pid, at: new Date().toISOString(), ...detail }) + "\n",
  );
  process.kill(process.pid, "SIGKILL");
}
