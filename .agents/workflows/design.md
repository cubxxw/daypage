---
name: design
trigger: Visual, interaction, information-architecture, or design-system change.
side_effect_level: workspace_write
requires_issue: true
required_roles: [lead, product_architect, qa_verifier, reviewer]
completion_gates: [design_agreement, issue_linked, runtime_visual_qa, accessibility_review]
---

# Design

1. Audit the running surface, current code, local evidence, constraints, and target users.
2. Discuss the design direction and trade-offs deeply with the user.
3. After agreement, create/link the design issue and define observable acceptance criteria.
4. Implement on the scoped branch without unrelated restyling.
5. Verify iOS changes in a running Simulator and web changes in a real browser at relevant sizes.
6. Review hierarchy, states, motion, accessibility, localization, performance, and regressions.
7. Update current design/engineering docs and prepare the issue-linked PR handoff.

No deploy, TestFlight, or remote design mutation is implied.
