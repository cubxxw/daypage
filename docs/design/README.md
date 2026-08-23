# Historical design explorations

These files preserve product and interaction explorations from July and August 2026.
They are review artifacts, not current requirements, accepted architecture decisions,
or implementation plans. The examples are anonymized and illustrative; they do not
contain or read a user vault.

- `architecture-review.html`: capture/compile separation, skill pipelines, derived
  indexing, and feed hypotheses. SQLite and runtime choices remain proposals.
- `interaction-mockups.html`: mobile interaction sketches for capture, explicit
  commands, compilation, entity views, and conversational entry points.
- `raw-feed-refined.html`: comparison study for transcript density, grouping, and
  inline compiled-day presentation.
- `receipt-artifacts.html`: three proposed presentation levels for outbound-effect
  receipts.

Current documentation is routed from [`docs/README.md`](../README.md). Any proposal
selected for implementation requires a scoped GitHub issue; durable architecture
changes also require an ADR under `docs/architecture/decisions/`.

The interactive decision-memory prototype lives at `web/src/app/memory-demo/` and is
tracked by GitHub issue #871. It uses local component state and sample content only; it
does not implement persistence, retrieval, AI compilation, or analytics.
