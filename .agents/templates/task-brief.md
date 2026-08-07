# Task brief

Populate every field and validate the equivalent JSON against
`.agents/schemas/task.schema.json`.

```yaml
task_id:
issue_url:
title:
goal:
non_goals: []
acceptance_criteria: []
assumptions: []
dependencies: []
risk_level: medium
owned_paths: []
forbidden_paths: []
required_gates: []
assigned_role:
status: planned
```

Ownership must be non-overlapping across concurrent workers. A broad glob such as the
repository root is not acceptable worker ownership.
