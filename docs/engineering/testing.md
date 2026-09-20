# Testing and evidence

`make check` aggregates non-Simulator repository gates. Use scoped gates during
implementation and run the full relevant integration gate before handoff.

| Scope | Stable command |
|---|---|
| Agent/docs contracts | `make check-agent` |
| Script fixtures | `make check-scripts` |
| DayPageKit | `make check-kit` |
| Web | `make check-web` |
| Android | `make check-android` |
| MCP server | `make check-mcp` |
| Cross-platform wire contracts | `make check-contracts` |
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
(cd android && ./gradlew testDebugUnitTest lintDebug assembleDebug)
pnpm --filter daypage-mcp-server test
(cd agentry && go test ./... && go vet ./... && go build ./...)
```

## iOS reliability regressions

Use an isolated temporary Vault for mutation/recovery tests. Today persistence
tests await `waitForMemoPersistence()` and submission completion before removing
the Vault; `observeChanges: false` disables unrelated global notifications in
unit fixtures. Simulator UI verification keeps normal observers enabled.

- `TodayViewModelTests` and `MemoRecordStoreTests` cover ID-based mutation,
  concurrent append preservation, ordered undo, captured Vault roots and failed
  writes. Delete undo restores the record actually removed from disk.
- `InflightDraftStoreTests` cover retained recovery records, occupied composers,
  attachment-only recovery and exact acknowledgement after durable saves.
- `RemoteApplyRecoveryTests` interrupt each durable conflict boundary and replay
  from disk, including moved-day records and startup outbox reconciliation.
- `AccountSyncStatusTests` distinguish an empty upload queue from a verified
  push-and-pull pass, and cover failure, retry and restart.
- `check-localization` checks locale parity, static dotted-key references and
  supported printf placeholders. Dynamic keys and raw display text remain outside
  this static check. Its fixture tests run in `check-scripts`.

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
