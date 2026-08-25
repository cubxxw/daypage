# DayPage cross-platform contracts

This package is the machine-readable boundary shared by native Apple clients,
the web/Supabase backend, Cloud MCP, and the future Android client.

The current `v1` schemas describe the revisioned local-first sync protocol from
[ADR-0008](../../docs/architecture/decisions/ADR-0008-local-first-sync-and-cloud-mcp.md):

- `sync-push-v1.schema.json` — `daypage_apply_sync_operations` request.
- `sync-push-result-v1.schema.json` — exact per-operation receipts.
- `sync-pull-request-v1.schema.json` — monotonic cursor request.
- `sync-pull-page-v1.schema.json` — ordered remote changes and tombstones.

Fixtures are normative examples, not production data. Swift tests decode the same
fixtures that the JSON Schema tests validate. Android must pass these fixtures before
its Room outbox or WorkManager worker can be connected to a real account.

Run `pnpm --filter @daypage/contracts test` from the repository root.
