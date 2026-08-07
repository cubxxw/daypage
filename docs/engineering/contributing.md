# Contributing

1. Read `AGENTS.md`, the closest module instructions, and current indexed docs.
2. Inspect the dirty worktree; preserve all changes outside your owned paths.
3. For feature, design, architecture, or broad refactor work, create/link a GitHub issue.
   Use `gh` for GitHub operations.
4. Define acceptance criteria, non-goals, data risk, rollback, and verification gates.
5. Create a scoped branch and implement only the accepted change.
6. Run focused gates, then independent QA/review appropriate to risk.
7. Update current docs and add/supersede an ADR for durable boundary changes.
8. Prepare a handoff/PR body with issue linkage, evidence, risks, and follow-ups.

Never stage indiscriminately with `git add .` or `git add -A`. Commit, push, PR creation,
merge, deployment, and release each require task authorization; completing code does not
grant it.
