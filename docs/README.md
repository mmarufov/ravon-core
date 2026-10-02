# Docs

Start with the [repository README](../README.md), then [architecture.md](architecture.md)
for the one diagram worth redrawing from memory.

## Decisions

[`adr/`](adr/README.md) holds the architecture decision records: the problem, the options
weighed, what was chosen and what it cost.

## Studies

| Document | What it covers |
| :--- | :--- |
| [dispatch-engine.md](dispatch-engine.md) | Minimum-cost matching against greedy dispatch, and the conditions under which the advantage disappears |
| [experiment-design-study.md](experiment-design-study.md) | The bias of A/B designs under marketplace interference, and why zone partitioning collapses it |
| [deepred-research.md](deepred-research.md) | What DoorDash's DeepRed dispatch system does, from their published material, and how Ravon compares |

Component write-ups live next to their code: [`db/schema/`](../db/schema/README.md),
[`db/ledger/`](../db/ledger/README.md), [`db/rush/`](../db/rush/README.md),
[`db/temporal_payout/`](../db/temporal_payout/README.md) and [`ml/`](../ml/README.md).

## Results

[`results/`](results/) holds dated run records: the commands, revisions and machines
behind published numbers.

## Plans and research notes

These are point-in-time records. They keep the numbers and file references of the tree
they were written against, including paths on the author's machine and `.context/`
working files that are not in this repository.

- [kotlin-backend-extraction.md](kotlin-backend-extraction.md): the plan for extracting
  the service tier, with progress marked.
- [`research/`](research/): the investigation behind that plan.
  - Specifications: [order lifecycle](research/order-lifecycle-spec.md),
    [dispatch](research/dispatch-spec.md),
    [proto and the iOS client](research/proto-and-ios-client.md),
    [service boundaries](research/service-boundaries.md),
    [security by construction](research/security-by-construction.md) and the
    [SQL function catalogue](research/sql-function-catalogue.md).
  - Schema reconstruction after the Supabase project was deleted:
    [from the migrations](research/schema-from-migrations.md),
    [from the Swift models](research/schema-from-swift-models.md),
    [from the call sites](research/schema-from-callsites.md), and
    [the reconciliation](research/reconstructed-schema.md).
  - Constraints on the extraction from the [consumer](research/app-consumer-constraints.md),
    [merchant](research/app-merchant-constraints.md) and
    [courier](research/app-courier-constraints.md) apps and from the
    [architecture docs](research/arch-docs-constraints.md).
  - The [orchestrator verification log](research/orchestrator-verification-log.md): the
    extraction brief's claims, checked first-hand.
