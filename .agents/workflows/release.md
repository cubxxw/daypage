---
name: release
trigger: Explicit user request to deploy, publish, tag, ship TestFlight, or change production.
side_effect_level: remote_write_high
requires_issue: true
required_roles: [lead, qa_verifier, reviewer]
completion_gates: [explicit_authorization, clean_scope, full_release_gates, rollback_ready, audit_record]
---

# Release

This workflow is opt-in. Selecting it does not grant authorization: the user must name
the release target and action.

1. Resolve the exact commit, artifacts, environment, account, and destination.
2. Confirm authorization, credentials boundary, release notes, migration plan, and rollback.
3. Prove the release gates on the exact candidate; do not reuse ambiguous old evidence.
4. Require independent review of security, privacy, data migration, and configuration.
5. Perform only the authorized remote action.
6. Verify deployed state, capture non-sensitive evidence, and report rollback readiness.

Never silently tag, push, merge, deploy, upload TestFlight, mutate a ruleset/database, or
clean branches/worktrees as part of another workflow.
