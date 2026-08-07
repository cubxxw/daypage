---
name: intake
trigger: Any non-trivial repository request before implementation.
side_effect_level: read_only
requires_issue: false
required_roles: [lead]
completion_gates: [task_brief_complete, ownership_non_overlapping]
---

# Intake

1. Restate the outcome, acceptance criteria, and non-goals.
2. Inspect current instructions, dirty state, relevant code/tests, current docs, and issue context.
3. Classify data, privacy, concurrency, dependency, migration, UI, and remote-side-effect risk.
4. Choose the workflow and decide whether an issue or ADR is required.
5. Build a dependency-aware task graph with explicit owned/forbidden paths and gates.
6. Delegate only independent nodes. Keep integration ownership with the lead.

Output a task contract matching `.agents/schemas/task.schema.json`. Intake grants no
permission to edit, publish, release, deploy, or destructively clean anything.
