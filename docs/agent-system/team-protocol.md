# Team protocol

## Task graph

The lead runs intake, chooses a workflow, and creates tasks matching
`.agents/schemas/task.schema.json`. Each worker receives goal, non-goals, acceptance
criteria, dependencies, owned paths, forbidden paths, gates, and risk.

Parallel nodes must not own the same files. Shared configuration and integration remain
with one named owner. A worker encountering an ownership conflict stops that edit and
reports it; it never reverts another agent.

## Handoff

Non-trivial work returns the fields in `.agents/schemas/handoff.schema.json`:

- assumptions and paths actually touched;
- decisions, rationale, and alternatives;
- evidence references and exact test outcomes;
- conflicts, blockers, and residual risks;
- next owner and action.

QA verifies independently and does not fix implementation unless reassigned. The reviewer
reads the integrated diff and ranks correctness/safety findings. The lead alone reconciles
handoffs and declares task-level completion.

## Side-effect gates

Local reads and scoped workspace edits follow the selected workflow. GitHub writes,
commits/pushes, production services, deploys, releases, TestFlight, and destructive
cleanup require explicit action-specific authorization. No role or workflow title grants
that authority on its own.
