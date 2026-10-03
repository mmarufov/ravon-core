// USD per million tokens, from https://platform.claude.com/docs/en/about-claude/pricing
// (read 2026-10-02). Cache writes are the 5-minute rate, the only TTL used here.
export interface Prices {
  input: number;
  output: number;
  cache_write: number;
  cache_read: number;
}

export const PRICES: Record<string, Prices> = {
  "claude-sonnet-5-5": { input: 2, output: 10, cache_write: 2.5, cache_read: 0.2 },
  "claude-haiku-4-5-20251001": { input: 1, output: 5, cache_write: 1.25, cache_read: 0.1 },
  "claude-opus-5-5": { input: 4, output: 20, cache_write: 5, cache_read: 0.2 },
};

export interface UsageLike {
  input_tokens: number;
  output_tokens: number;
  cache_creation_input_tokens?: number | null;
  cache_read_input_tokens?: number | null;
}

export function costUsd(model: string, u: UsageLike): number {
  const p = PRICES[model];
  if (!p) throw new Error(`no price for ${model}; add it to agent/pricing.ts from the pricing page`);
  return (
    (u.input_tokens * p.input +
      u.output_tokens * p.output +
      (u.cache_creation_input_tokens ?? 0) * p.cache_write +
      (u.cache_read_input_tokens ?? 0) * p.cache_read) /
    1_000_000
  );
}

// A hard cap shared by every case in a run. Each API call reserves its
// worst case before it is sent (all input uncached plus max_tokens of output)
// and settles to the real cost after, so concurrent cases cannot together
// overshoot the cap.
export class Budget {
  private spent = 0;
  private reserved = 0;
  constructor(readonly capUsd: number) {}

  reserve(usd: number): boolean {
    if (this.spent + this.reserved + usd > this.capUsd) return false;
    this.reserved += usd;
    return true;
  }

  settle(reservedUsd: number, actualUsd: number): void {
    this.reserved -= reservedUsd;
    this.spent += actualUsd;
  }

  get spentUsd(): number {
    return this.spent;
  }
}

export class BudgetExceeded extends Error {}
