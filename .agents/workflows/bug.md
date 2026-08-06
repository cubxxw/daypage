---
name: bug
trigger: Incorrect, unsafe, or regressed existing behavior.
side_effect_level: workspace_write
requires_issue: false
required_roles: [lead, qa_verifier, reviewer]
completion_gates: [reproduction_or_proof, regression_test, scoped_gates, review]
---

# Bug fix

1. Reproduce the failure or prove the cause through the actual execution path.
2. Record severity, affected data/users, rollback, and whether an issue/incident is required.
3. Add a failing regression test where practical.
4. Fix the smallest responsible layer; preserve persistence and public contracts.
5. Run the regression, adjacent tests, and relevant runtime verification.
6. Independently review failure paths, concurrency, and recovery.
7. Hand off evidence and residual risk.

Do not publish diagnostics containing secrets, vault data, or personal paths.
