# merchant-assist

The agent half of [Ravon Assist](../../db/assist/README.md): TypeScript, `@anthropic-ai/sdk`, `pg`, `zod`.
Evaluated on seeded, synthetic cases only.

| File | What it is |
| :--- | :--- |
| [`shared/answer.ts`](shared/answer.ts) | the one zod schema for an answer, used by the agent, the checker and any UI |
| [`agent/tools.ts`](agent/tools.ts) | six read tools and `propose_action`; each call is one transaction as one role, for the session's merchant |
| [`agent/agent.ts`](agent/agent.ts) | the loop: tools, then an answer that is shown only if `checkAnswer()` passes |
| [`agent/run.ts`](agent/run.ts) | runs the cases with a hard spend cap and writes transcripts to `results/` |
| [`grade.ts`](grade.ts) | the deterministic checker and the run report; no model judges anything |
| [`test/`](test) | mutation controls for the checker, and the loop under a scripted model |

How to run it: [`db/assist/README.md`](../../db/assist/README.md#run-it).
