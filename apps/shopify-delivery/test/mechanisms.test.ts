import { describe, expect, it } from "vitest";
import { parseDisabled } from "../app/delivery/config.server";
import { parseCrash, selected } from "../app/delivery/crash.server";
import { parseFaults, planFor } from "../app/delivery/faults.server";
import { CostPacer, paced } from "../app/delivery/throttle.server";
import type { AdminGraphql, GraphqlResult } from "../app/delivery/admin.server";

describe("fault plan", () => {
  const cfg = parseFaults("seed=t,drop=0.2,dup=0.1,delayMinMs=0,delayMaxMs=30000")!;

  it("is a function of (seed, webhook id)", () => {
    expect(planFor(cfg, "abc")).toEqual(planFor(cfg, "abc"));
    expect(planFor({ ...cfg, seed: "u" }, "abc")).not.toEqual(planFor(cfg, "abc-other"));
  });

  it("drops about 20% and duplicates about 10% of 20,000 deliveries, delays within bounds", () => {
    const n = 20000;
    let drop = 0;
    let dup = 0;
    for (let i = 0; i < n; i++) {
      const p = planFor(cfg, `w${i}`);
      if (p.action === "drop") drop++;
      if (p.action === "dup") dup++;
      for (const d of p.delays) expect(d >= 0 && d <= 30000).toBe(true);
    }
    expect(Math.abs(drop / n - 0.2)).toBeLessThan(0.01);
    expect(Math.abs(dup / n - 0.1)).toBeLessThan(0.01);
  });

  it("refuses rates that do not add up", () => {
    expect(() => parseFaults("seed=t,drop=0.8,dup=0.3")).toThrow();
  });
});

describe("crash selection", () => {
  it("selects about `rate` of jobs, and only on the first attempt", () => {
    const plan = parseCrash("seed=s,rate=0.15,point=after_fulfillment_reply")!;
    let n = 0;
    for (let i = 0; i < 10000; i++) {
      if (selected(plan, `job-${i}`, 1)) n++;
      expect(selected(plan, `job-${i}`, 2)).toBe(false);
    }
    expect(Math.abs(n / 10000 - 0.15)).toBeLessThan(0.015);
  });
});

describe("mechanism switches", () => {
  it("turning off dedupe also turns off receipts", () => {
    expect([...parseDisabled("dedupe")].sort()).toEqual(["dedupe", "receipts"]);
  });
  it("rejects unknown names", () => {
    expect(() => parseDisabled("sweeep")).toThrow(/unknown mechanism/);
  });
});

// A fake clock and an in-memory bucket with Shopify's semantics, to test the pacer's
// arithmetic without a network.
function bucketApi(max: number, restore: number, clock: { t: number }) {
  let available = max;
  let at = clock.t;
  let throttled = 0;
  const admin: AdminGraphql = {
    async request(): Promise<GraphqlResult> {
      available = Math.min(max, available + ((clock.t - at) / 1000) * restore);
      at = clock.t;
      const cost = 100;
      const status = () => ({ maximumAvailable: max, currentlyAvailable: available, restoreRate: restore });
      if (cost > available) {
        throttled++;
        return { errors: [{ extensions: { code: "THROTTLED" } }], extensions: { cost: { requestedQueryCost: cost, throttleStatus: status() } } };
      }
      available -= cost;
      return { data: {}, extensions: { cost: { requestedQueryCost: cost, actualQueryCost: cost, throttleStatus: status() } } };
    },
  };
  return { admin, throttled: () => throttled };
}

describe("cost pacer", () => {
  for (const enabled of [true, false]) {
    it(`${enabled ? "keeps" : "does not keep"} 50 sequential 100-point calls under a 1000/50 bucket from THROTTLED`, async () => {
      const clock = { t: 0 };
      const sleep = async (ms: number) => {
        clock.t += ms;
      };
      const { admin, throttled } = bucketApi(1000, 50, clock);
      const pacer = new CostPacer({ enabled, now: () => clock.t, sleep });
      for (let i = 0; i < 50; i++) {
        await paced(admin, pacer, "s", "Op", "query Op { x }", {}, 100, 20);
      }
      if (enabled) expect(throttled()).toBe(0);
      else expect(throttled()).toBeGreaterThan(0);
      // Either way the work takes about (50*100 - 1000) / 50 = 80 s of bucket time.
      expect(clock.t).toBeGreaterThan(75000);
    });
  }
});
