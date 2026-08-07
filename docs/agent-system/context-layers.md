# Context layers

Agent quality degrades when current rules, unrelated history, private data, and raw logs
are loaded together. DayPage routes context in layers:

1. **Constitution:** current user request and root `AGENTS.md`.
2. **Task:** task contract, selected workflow, role, and closest module rules.
3. **Current domain:** owning architecture/engineering docs, target code/tests, direct dependencies.
4. **Decision evidence:** accepted ADRs, current issue/PR, and only the historical material
   needed to explain a trade-off.
5. **Runtime evidence:** concise, redacted results or artifact references, not full noisy logs.

The main/lead thread keeps requirements, decisions, and integration state. Explorers,
testers, and reviewers return distilled evidence from separate contexts.

Never place secrets, auth state, personal vault content, unrelated user files, or
machine-local absolute paths in shared Agent Team context or tracked handoffs.
