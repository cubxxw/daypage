# Context router

Load only the context required by the task. This file routes to owning documents; it
does not duplicate their facts.

| Need | Read |
|---|---|
| Repository rules and safety | `AGENTS.md` |
| Current system boundaries | `docs/architecture/overview.md` |
| Architecture decisions | `docs/architecture/decisions/` |
| Setup and verification | `docs/engineering/README.md` |
| Agent roles and handoffs | `docs/agent-system/README.md` |
| Product surface specifics | Closest module `AGENTS.md`, code, and tests |
| Historical rationale | Archived PRDs/plans only after current sources |

Context layers should stay small:

1. Constitution and task prompt.
2. Task brief, closest module rules, and current owning docs.
3. Target code/tests and direct dependencies.
4. Historical evidence only when a decision needs it.

Do not load private vault content, secrets, auth state, unrelated build logs, or entire
historical trees into an agent context.
