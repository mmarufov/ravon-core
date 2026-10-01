// Child processes for the harness: the app's web server and a supervised worker.

import { spawn, type ChildProcess } from "node:child_process";
import { createWriteStream } from "node:fs";

const APP_DIR = new URL("..", import.meta.url).pathname;

export function startWeb(port: number, env: Record<string, string>, logPath: string): ChildProcess {
  const log = createWriteStream(logPath, { flags: "a" });
  const p = spawn(process.execPath, ["node_modules/@react-router/serve/bin.js", "./build/server/index.js"], {
    cwd: APP_DIR,
    env: { ...process.env, ...env, PORT: String(port), NODE_ENV: "production" },
    stdio: ["ignore", "pipe", "pipe"],
  });
  p.stdout!.pipe(log);
  p.stderr!.pipe(log);
  return p;
}

export async function waitHttp(url: string, timeoutMs = 60000): Promise<void> {
  const until = Date.now() + timeoutMs;
  for (;;) {
    try {
      const r = await fetch(url);
      if (r.status < 500) return;
    } catch {
      // not up yet
    }
    if (Date.now() > until) throw new Error(`${url} did not come up in ${timeoutMs} ms`);
    await new Promise((r) => setTimeout(r, 250));
  }
}

// Runs the worker and restarts it whenever it dies of SIGKILL, which is what the crash
// injection does to it. Any other death is a harness failure, not a fault to recover from.
export class Supervisor {
  sigkills = 0;
  otherExits: { code: number | null; signal: string | null }[] = [];
  private child: ChildProcess | null = null;
  private stopping = false;
  private readonly log;

  constructor(
    private readonly env: Record<string, string>,
    logPath: string,
    private readonly restartDelayMs = 200,
  ) {
    this.log = createWriteStream(logPath, { flags: "a" });
  }

  start() {
    // `node --import tsx`, not `npx tsx`: one process, so the SIGKILL the worker sends
    // itself is the exit the supervisor sees, with no wrapper in between.
    const p = spawn(process.execPath, ["--import", "tsx", "app/delivery/worker.ts"], {
      cwd: APP_DIR,
      env: { ...process.env, ...this.env },
      stdio: ["ignore", "pipe", "pipe"],
    });
    p.stdout!.pipe(this.log, { end: false });
    p.stderr!.pipe(this.log, { end: false });
    p.on("exit", (code, signal) => {
      if (this.stopping) return;
      if (signal === "SIGKILL") {
        this.sigkills++;
        setTimeout(() => !this.stopping && this.start(), this.restartDelayMs);
      } else {
        this.otherExits.push({ code, signal });
        this.log.write(`\n[supervisor] worker exited code=${code} signal=${signal}; restarting\n`);
        setTimeout(() => !this.stopping && this.start(), 1000);
      }
    });
    this.child = p;
  }

  async stop() {
    this.stopping = true;
    const p = this.child;
    if (p && p.exitCode === null && p.signalCode === null) {
      await new Promise<void>((r) => {
        p.once("exit", () => r());
        p.kill("SIGTERM");
        setTimeout(() => p.kill("SIGKILL"), 3000);
      });
    }
  }
}

export async function stopProc(p: ChildProcess): Promise<void> {
  if (p.exitCode !== null || p.signalCode !== null) return;
  await new Promise<void>((r) => {
    p.once("exit", () => r());
    p.kill("SIGTERM");
    setTimeout(() => p.kill("SIGKILL"), 3000);
  });
}
