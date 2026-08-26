# DayPage cross-platform contracts

This package is the machine-readable boundary shared by native Apple clients,
the web/Supabase backend, Cloud MCP, and the future Android client.

The current `v1` schemas describe the revisioned local-first sync protocol from
[ADR-0008](../../docs/architecture/decisions/ADR-0008-local-first-sync-and-cloud-mcp.md):

- `sync-push-v1.schema.json` — `daypage_apply_sync_operations` request.
- `sync-push-result-v1.schema.json` — exact per-operation receipts.
- `sync-pull-request-v1.schema.json` — monotonic cursor request.
- `sync-pull-page-v1.schema.json` — ordered remote changes and tombstones.
- `sync-push-v2.schema.json` / `sync-push-result-v2.schema.json` — memo plus verified
  attachment-manifest commit and exact receipt.
- `sync-pull-page-v2.schema.json` — ordered memo changes with attachment descriptors.
- `attachment-upload-prepare-v2.schema.json` / `attachment-upload-prepared-v2.schema.json`
  — owner-derived, quota-reserved immutable object preparation.

`manifest-hash.mjs` is the executable reference for the UTF-8 length-prefixed manifest
hash shared by clients and PostgreSQL. Device-local paths never participate.

Fixtures are normative examples, not production data. Swift tests decode the same
fixtures that the JSON Schema tests validate. Android must pass these fixtures before
its Room outbox or WorkManager worker can be connected to a real account.

Run `pnpm --filter @daypage/contracts test` from the repository root.
