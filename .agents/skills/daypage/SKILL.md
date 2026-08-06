---
name: daypage
description: Repository-specific context and safe development workflow for DayPage changes across Apple apps, DayPageKit, web, MCP server, agentry, documentation, and automation. Use when implementing, reviewing, diagnosing, or planning work in this repository.
---

# DayPage repository workflow

## Trigger

Use for repository work that needs DayPage architecture, ownership, persistence, test,
or delivery conventions. Do not use it as a release command or as permission to write
to GitHub, cloud services, production data, or a user vault.

## Inputs

- The user's goal and authorization.
- The dirty worktree and current branch.
- Root and closest applicable `AGENTS.md`.
- `.agents/manifest.yaml` and the matching workflow.
- Target code, tests, current docs, and accepted ADRs.

## Procedure

1. Classify the touched surface and load only its routed context.
2. State acceptance criteria, non-goals, risks, owned paths, forbidden paths, and gates.
3. Trace current behavior before editing. Treat `DayPageKit` as the shared
   models/storage/services source unless evidence shows a target-specific adapter is needed.
4. For feature, design, architecture, or broad refactor work, confirm the required issue
   and decision record exist.
5. Delegate only independent work with non-overlapping ownership. Preserve all unrelated
   and concurrent changes.
6. Implement the smallest coherent change. Do not change persistence formats, dependencies,
   remote state, or release state implicitly.
7. Run the scoped gates from `docs/engineering/testing.md`; inspect real isolated Markdown
   output for storage changes and a running Simulator/browser for UI changes.
8. Return a structured handoff with touched files, decisions, evidence, conflicts,
   blockers, and residual risks.

## Side effects and recovery

The default mode is local workspace writes only. Commits, pushes, issues, PRs, deploys,
releases, production database changes, and destructive cleanup require explicit
authorization for that action. If verification modifies a fixture vault or Simulator,
use an isolated target and prove restoration before reporting success.

On failure, stop unsafe follow-on steps, preserve diagnostics without secrets or private
content, restore any isolated fixture state, and report the exact failed gate.

## Output

Use `.agents/templates/handoff.md` for non-trivial work. A completion claim must cite
commands and results; “done” without evidence is invalid.
