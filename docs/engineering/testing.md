# Testing and evidence

`make check` aggregates non-Simulator repository gates. Use scoped gates during
implementation and run the full relevant integration gate before handoff.

| Scope | Stable command |
|---|---|
| Agent/docs contracts | `make check-agent` |
| Script fixtures | `make check-scripts` |
| DayPageKit | `make check-kit` |
| Web | `make check-web` |
| MCP server | `make check-mcp` |
| Agentry | `make check-agentry` |
| Localization | `make check-localization` |
| Design tokens | `make check-tokens` |
| iOS build/test | `make check-ios` |
| iOS build only | `make build-ios` |
| Non-Simulator aggregate | `make check` |

Direct focused commands remain useful:

```sh
swift test --package-path DayPageKit
pnpm --filter daypage-web lint
pnpm --filter daypage-web typecheck
pnpm --filter daypage-mcp-server test
(cd agentry && go test ./... && go vet ./... && go build ./...)
```

## Evidence rules

- Capture the exact command, working directory, environment identity, result, and
  non-sensitive artifact paths.
- Do not claim a skipped or blocked command passed.
- iOS UI changes require the app running in Simulator; SwiftUI preview is insufficient.
- Web interaction changes require an affected browser flow at relevant viewport sizes.
- Storage changes require an isolated vault and inspection of actual YAML/Markdown.
- Verification that mutates a fixture, Simulator, or local database must prove restoration.
- Screenshots/logs must not expose vault content, credentials, tokens, or personal paths.

Use `.agents/schemas/evidence.schema.json` for portable evidence records.
