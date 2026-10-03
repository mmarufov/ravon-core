// The one definition of an Assist answer. The agent asks the model for it
// (structured output), the checker verifies it, and any UI renders it. Change
// it here and all three change together.
import { z } from "zod";

// The eight seeded causes (db/assist/seed.py). nothing_wrong is the control.
export const CAUSES = [
  "commission_misapplied",
  "refund_duplicated",
  "payout_unknown",
  "tip_lowered",
  "chargeback",
  "adjustment_reversed",
  "order_reassigned",
  "nothing_wrong",
] as const;
export type Cause = (typeof CAUSES)[number];

export const PROPOSAL_KINDS = ["commission_correction", "refund_reversal"] as const;

// The placeholder a claim's text uses where its amount goes. The renderer
// fills it from amount_minor, which the checker has re-summed from the cited
// entries; money written anywhere else in the text fails the check.
export const AMOUNT_SLOT = "{amount}";

export const Claim = z.object({
  text: z
    .string()
    .describe(`One sentence to the merchant. Write ${AMOUNT_SLOT} where the amount goes; never write an amount of money yourself.`),
  amount_minor: z
    .number()
    .int()
    .nullable()
    .describe("Exactly the sum of effect_minor over the cited entries, in minor units (100 = 1.00 TJS). null if the claim states no amount."),
  entry_ids: z
    .array(z.number().int())
    .describe("entry_id values from list_entries or get_transaction that this claim rests on."),
});
export type Claim = z.infer<typeof Claim>;

export const Answer = z.object({
  diagnosis: z.enum(CAUSES),
  summary: z.string().describe("Two to four plain sentences to the merchant. No amounts of money."),
  claims: z.array(Claim),
  proposal_ids: z.array(z.string()).describe("Ids returned by propose_action in this conversation, or []."),
});
export type Answer = z.infer<typeof Answer>;

export function formatMinor(minor: number, currency = "TJS"): string {
  const sign = minor < 0 ? "-" : "";
  const abs = Math.abs(minor);
  return `${sign}${Math.floor(abs / 100)}.${String(abs % 100).padStart(2, "0")} ${currency}`;
}

// Only ever called on an answer that passed checkAnswer().
export function renderClaim(claim: Claim): string {
  return claim.amount_minor === null
    ? claim.text
    : claim.text.split(AMOUNT_SLOT).join(formatMinor(claim.amount_minor));
}

// The JSON schema the model is constrained to, derived from Answer. zod's own
// converter keeps the diagnosis enum (the SDK's zod helper turned it into a
// description string when this was written); the integer bounds zod adds are
// dropped because structured outputs does not accept them, and the zod parse
// that follows every reply still enforces everything.
export function answerJsonSchema(): Record<string, unknown> {
  const strip = (node: unknown): unknown => {
    if (Array.isArray(node)) return node.map(strip);
    if (node && typeof node === "object") {
      return Object.fromEntries(
        Object.entries(node)
          .filter(([k]) => !["$schema", "minimum", "maximum"].includes(k))
          .map(([k, v]) => [k, strip(v)]),
      );
    }
    return node;
  };
  return strip(z.toJSONSchema(Answer)) as Record<string, unknown>;
}
