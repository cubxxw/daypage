# DayPage documentation

This index distinguishes current operating documents from historical evidence. If a
document is not linked as current here, verify it against code and tests before using it
to drive a change.

## Current

- [Repository constitution](../AGENTS.md)
- [Architecture index](architecture/README.md)
- [System overview](architecture/overview.md)
- [Engineering index](engineering/README.md)
- [Setup](engineering/setup.md)
- [Testing and evidence](engineering/testing.md)
- [DayPage Cloud MCP staging runbook](mcp-cloud-runbook.md)
- [Contributing workflow](engineering/contributing.md)
- [Agent Team system](agent-system/README.md)

There is currently no single repository-wide PRD designated as current. For scoped work,
the active GitHub issue, accepted ADRs, code, and tests define the contract until a
current PRD is adopted and linked here.

## Architecture decisions

- [ADR-0008: Local-first sync and OAuth-protected DayPage Cloud MCP](architecture/decisions/ADR-0008-local-first-sync-and-cloud-mcp.md) — Accepted
- [ADR-0006: Repository Agent Team control plane](architecture/decisions/ADR-0006-repository-agent-team-control-plane.md) — Accepted
- [ADR-0013: Privacy-safe operational diagnostics](architecture/decisions/ADR-0013-privacy-safe-operational-diagnostics.md) — Accepted
- `docs/ADR-0001-*.md` through `docs/ADR-0005-*.md` are legacy-location decisions.
  Read their status fields and verify implementation before relying on them.

## Historical material

Top-level `docs/PRD-vNext.md`, dated research/audits, `docs/plans/`, `tasks/`, `archive/`,
screenshots, and [design explorations](design/README.md) preserve rationale and evidence.
They are not automatically current requirements.

When implementation changes a documented boundary, update the owning current document
and add or supersede an ADR; do not silently rewrite historical documents.
