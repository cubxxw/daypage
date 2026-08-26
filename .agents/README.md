# DayPage Agent Team

`.agents/` is the canonical development-agent control plane for this repository.
It defines portable roles, workflows, context routing, skills, and machine-checkable
task/handoff/evidence contracts. Host files under `.codex/`, `.claude/`, and `.dsh/`
adapt this system; they must not become competing sources of truth.

This control plane coordinates repository development. The `agentry/` directory is a
DayPage product runtime with its own sessions and tools; it does not own development
tasks or repository policy.

## How to use it

1. Read the root `AGENTS.md`.
2. Pick a workflow from `manifest.yaml`.
3. Create a task brief with explicit owned and forbidden paths.
4. Let the lead delegate only independent, non-overlapping tasks.
5. Capture commands and artifacts as evidence.
6. Hand work back with decisions, tests, conflicts, and residual risks.

Remote writes, releases, deploys, destructive cleanup, and access to private user data
are never default workflow steps. They require explicit, action-specific authorization.

Runtime outputs belong outside version control. Do not store runs, credentials, auth
state, vault content, or personal absolute paths under `.agents/`.
