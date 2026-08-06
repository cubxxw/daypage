---
name: feature
trigger: New user-visible capability or material behavior change.
side_effect_level: workspace_write
requires_issue: true
required_roles: [lead, product_architect, qa_verifier, reviewer]
completion_gates: [issue_linked, acceptance_tests, independent_qa, review, docs_current]
---

# Feature

1. Run intake and confirm the linked issue contains scope, non-goals, risk, and rollback.
2. Resolve product/design decisions; add an ADR for durable architectural change.
3. Assign non-overlapping implementation and test ownership.
4. Implement the smallest vertical slice and focused tests.
5. Integrate across boundaries only after owner handoffs are complete.
6. Run scoped automated gates and independent runtime verification.
7. Review correctness, privacy, data compatibility, accessibility, and regressions.
8. Update current docs and prepare a PR handoff that links the issue.

Commit, push, PR creation, deploy, and release remain separately authorized actions.
