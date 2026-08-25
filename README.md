# DayPage

DayPage is a local-first personal memory system. It captures text, voice, photos,
location, and daily context as raw signals, then compiles them into Daily Pages,
entity pages, and an explorable knowledge graph.

## Repository map

| Area | Purpose |
|---|---|
| `DayPage/` | SwiftUI iOS app |
| `DayPageMac/`, `DayPageWatch/`, `DayPageWidget/` | Apple companion surfaces |
| `DayPageKit/` | Shared Swift models, storage, and services |
| `DayPageTests/`, `DayPageKit/Tests/` | Xcode and Swift package tests |
| `android/` | Native Jetpack Compose Android client |
| `web/` | Next.js web application |
| `packages/mcp-server/` | TypeScript DayPage MCP server |
| `agentry/` | Go agent runtime product |
| `.agents/` | Development Agent Team control plane |

The core data flow is:

`raw capture -> local vault -> AI compilation -> Daily Page -> entities -> graph`

Raw data remains file-based. Daily memo files live at
`vault/raw/YYYY-MM-DD.md`; compiled content and knowledge artifacts live under
`vault/wiki/`.

## Stack

- Swift 5 / SwiftUI, iOS 16+, macOS 13+, watchOS 10+
- Swift Package Manager through `DayPageKit`
- Kotlin / Jetpack Compose, Room, and WorkManager on Android 8+
- Supabase and Sentry adapters in app-facing layers
- Next.js 16, React 19, TypeScript, pnpm workspace
- TypeScript MCP server
- Go 1.24 `agentry` runtime

## Start here

1. Read [AGENTS.md](AGENTS.md) before changing the repository.
2. Use [docs/README.md](docs/README.md) to find current architecture and engineering docs.
3. Run `make doctor` to check repository contracts and local prerequisites.
4. Choose the scoped commands in [docs/engineering/testing.md](docs/engineering/testing.md).

Secrets are local-only. Generate or configure them through the relevant setup path; never
hardcode or commit credentials, auth state, vault content, or runtime evidence.

## Agent Team

The repository uses a role-based development Agent Team for large, parallel work.
`.agents/` is the canonical registry; Claude and Codex files are thin host adapters.
The product runtime under `agentry/` is intentionally separate.

See [docs/agent-system/README.md](docs/agent-system/README.md) for roles, ownership,
handoffs, evidence, and side-effect gates.

## Status

DayPage is actively evolving across Apple and web surfaces. Historical PRDs and audit
documents remain useful evidence, but only documents linked as current from
`docs/README.md` should drive new implementation.
