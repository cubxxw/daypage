# Architecture

- [System overview](overview.md): current components, ownership, data flow, and trust boundaries.
- [Decisions](decisions/): accepted or proposed durable architecture decisions.
- [ADR-0006](decisions/ADR-0006-repository-agent-team-control-plane.md): development Agent Team control plane.
- [ADR-0007](decisions/ADR-0007-compilation-entity-operation-markers.md): retry-safe entity persistence.
- [ADR-0008](decisions/ADR-0008-local-first-sync-and-cloud-mcp.md): local-first multi-device sync and user-scoped Cloud MCP.
- [ADR-0009](decisions/ADR-0009-native-surfaces-shared-contracts.md): proposed cross-platform native surfaces and shared product contracts.
- [ADR-0010](decisions/ADR-0010-vault-derived-read-models.md): asynchronous disposable read models over the Markdown Vault.
- [ADR-0011](decisions/ADR-0011-action-button-voice-capture.md): superseded primary Action Button voice proposal; retained as a possible separate voice shortcut.
- [ADR-0012](decisions/ADR-0012-action-button-screenshot-capture.md): proposed screenshot capture inbox with evidence-first multimodal understanding.

The overview is descriptive and should track executable reality. ADRs explain durable
choices and trade-offs. Product requirements belong in a current PRD or issue, not in an
ADR.
