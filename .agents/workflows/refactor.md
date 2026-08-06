---
name: refactor
trigger: Broad structure, dependency, persistence, concurrency, or engineering-system change.
side_effect_level: workspace_write
requires_issue: true
required_roles: [lead, product_architect, qa_verifier, reviewer, docs_steward]
completion_gates: [issue_linked, behavior_contracts, migration_or_rollback, scoped_gates, review, docs_current]
---

# Refactor

1. Capture existing behavior, seams, risk, and measurable reasons for change.
2. Link the issue; write an ADR when ownership, boundaries, persistence, or public contracts change.
3. Split work by module ownership, with explicit integration order.
4. Add characterization/regression tests before high-risk movement.
5. Refactor incrementally and keep intermediate states buildable.
6. Verify data compatibility, retries/idempotency, concurrency, performance, and rollback.
7. Run independent QA and review, then update the current architecture docs.

Cleanup outside the task's exact owned paths is out of scope.
