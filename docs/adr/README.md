# Architecture Decision Records

Each record states the problem, the options weighed, what was chosen, and what it cost.
Where a decision was measured, the numbers are in the record and reproducible from the
test suite.

| # | Decision | Status |
|---|---|---|
| [0001](0001-order-lifecycle-as-declared-data.md) | Model the order lifecycle as declared data, not scattered status checks | Accepted |
| [0002](0002-min-cost-matching-over-greedy.md) | Solve dispatch as minimum-cost matching, and do not minimise distance | Accepted |
| [0003](0003-deterministic-simulation-as-evaluation.md) | Evaluate dispatch by deterministic simulation, with latent state | Accepted |
| [0004](0004-zone-partitioning.md) | Partition the market into zones: tractability *and* measurability, at a real cost | Accepted |
| [0005](0005-extract-to-kotlin-not-rewrite.md) | Extract a Kotlin service tier; do not rewrite the backend | **Proposed — not built** |
| [0006](0006-postgres-over-kafka.md) | Implement the event guarantees on Postgres, not on Kafka | Accepted |
| [0007](0007-rejected-technologies.md) | Technologies deliberately not used, and what would change that | Accepted |

## Template

```markdown
# NNNN — Title in the imperative

**Status:** Proposed | Accepted | Superseded by NNNN · date
**Scope:** files or subsystems affected

## Context
What forced a decision. The constraints that were real at the time.

## Decision
What was chosen, stated so someone could implement it from this alone.

## Alternatives considered
Each one taken seriously, with the specific reason it lost.

## Consequences
What got better, what got worse, and what is now harder. Costs stated plainly.

## Verification
How to check the claims in this record.
```

A record is not updated when the decision changes. A new record supersedes it, and the
old one's status changes to point at the replacement — the history of why something was
once right is the part that is expensive to reconstruct.
