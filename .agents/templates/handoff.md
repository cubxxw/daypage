# Agent handoff

Return this data to the next owner. Validate the equivalent JSON against
`.agents/schemas/handoff.schema.json`.

```yaml
task_id:
role:
status: partial
goal:
assumptions: []
owned_paths: []
touched_files: []
decisions:
  - decision:
    rationale:
    alternatives: []
evidence_refs: []
tests:
  - command:
    result: blocked
    artifact:
residual_risks: []
blockers: []
conflict_notes: []
next_owner:
next_action:
git_sha:
timestamp:
```

Do not replace evidence with “done,” and do not omit concurrent-change conflicts.
