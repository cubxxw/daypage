# Current architecture

DayPage is a local-first memory system with Apple, web, integration, and agent-runtime
surfaces in one repository.

```mermaid
flowchart LR
  Apple["iOS / Mac / Watch / Widget"] --> Kit["DayPageKit\nModels · Storage · Services"]
  Kit --> Vault["Local Markdown/YAML vault"]
  Apple --> Remote["Supabase / provider APIs"]
  Web["Next.js web"] --> Remote
  MCP["TypeScript MCP server"] --> Remote
  Agentry["Go agentry runtime"] -. product tools .-> MCP
  Control[".agents development control plane"] -. coordinates repository work .-> Apple
  Control -.-> Web
  Control -.-> MCP
  Control -.-> Agentry
```

## Apple surfaces

`DayPage.xcodeproj` contains iOS, macOS, watchOS, widget, and test targets. The iOS app
uses SwiftUI with sidebar navigation and an implemented Graph surface. App targets own UI,
platform frameworks, secrets adapters, and SDK boundaries.

`DayPageKit` is a Swift package with:

- `DayPageModels`: shared value types and serialization contracts.
- `DayPageStorage`: vault access, mutation, conflict, logging, and storage adapters.
- `DayPageServices`: shared compilation, retrieval, feature, and domain services.

The Kit supports iOS 16, macOS 13, and watchOS 10. App-specific Supabase/Sentry behavior
stays at adapter boundaries instead of forcing those SDKs into the shared package.

## Data and compilation

Raw memos are stored as YAML-front-matter Markdown in
`vault/raw/YYYY-MM-DD.md`, with attachments under `vault/raw/assets/`. Compiled Daily
Pages and knowledge artifacts live under `vault/wiki/`.

The conceptual flow is raw capture -> vault mutation -> AI compilation -> Daily Page ->
entity updates -> graph/retrieval. Storage mutations must serialize concurrent writes;
retryable compilation/entity operations must remain idempotent. Format or migration
changes require compatibility tests, rollback, and an ADR.

Entity persistence treats the raw-input `source_hash` as a compilation operation ID.
Instructions for one resolved entity page are committed atomically with an ignored
Markdown HTML marker, and the entity index is reconciled idempotently on retry. The Daily
Page completion marker is written only after those throwable entity operations succeed.
See [ADR-0007](decisions/ADR-0007-compilation-entity-operation-markers.md).

## Web and integrations

`web/` is a Next.js 16 / React 19 application in the pnpm workspace. It owns web UI,
server routes, auth, connectors, database access, background jobs, and browser tests.

`packages/mcp-server/` is a TypeScript MCP server for DayPage operations. It shares the
workspace but has its own build, type-check, and Node test gates.

## Agent boundaries

`agentry/` is a Go product runtime exposing its own provider/tool/session/transport seams.
It can be integrated into DayPage features, but it does not coordinate repository work.

`.agents/` is the repository development control plane. It defines roles, workflows,
handoffs, and evidence without taking a runtime dependency on `agentry`. Host adapters in
`.codex/` and `.claude/` remain thin.

## Trust boundaries

- User vault content and credentials are private and never development context by default.
- Local verification uses isolated fixtures/containers and must prove restoration.
- Remote services, production databases, releases, and GitHub writes require explicit
  action-specific authorization.
- Historical documents provide evidence but do not override current indexed docs, code,
  tests, or accepted decisions.
