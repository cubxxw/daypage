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

ADR-0017 system actions use a separate v1 contract family. It keeps proposals,
exact native decisions, immutable receipts, synchronized product policy, pull pages,
push receipts, and execution claims distinct:

- `system-action-proposal-v1.schema.json` — one bounded, versioned proposal whose
  typed payload kind must match the proposal kind and whose executable bytes are
  bound by `payload_hash`; route destinations contain exactly one of a complete
  latitude/longitude pair or a non-whitespace `destination_address`. A
  `creating_device` target requires `creator_device_id_hash`, a `specific_device`
  target requires `target_device_id_hash`, and `any` carries no target hash.
  MCP-created proposals are fixed to `private` redaction until native approval.
  Focus payloads include both `schedule_end_alert` and `allow_live_activity`;
  local-context payloads include `observed_at` and fixed `summary_only`
  disclosure. Route v1 always opens immediately and carries no variable launch flag.
- `system-action-approval-v1.schema.json` — an execute/undo decision bound to the
  exact proposal revision and payload hash. The standard JSON Schema field
  `has_replacement` must be false for `approve`; when true for `reject`, both clients
  derive the replacement as the next revision of this same `proposal_id` rather than
  accepting another UUID.
- `system-action-receipt-v1.schema.json` — a privacy-bounded per-attempt result;
  raw Apple identifiers and undo snapshots are intentionally not representable. A
  receipt sync operation's envelope `revision` is the receipt's `proposal_revision`;
  `attempt` is an independent execution-attempt counter and never substitutes for the
  proposal revision. It is monotonic within one executor identity; receipts from two
  lease-serialized devices may retain the same ordinal and are distinct by device hash.
  A native client associates pulled evidence with an interrupted local execution only
  when the normalized executor device matches and, once stored locally, the lease matches;
  another device's same ordinal never advances or resolves the local execution.
- `system-action-capability-policy-v1.schema.json` — synchronized DayPage product
  policy only, never a device OS authorization status.
- `system-action-push-result-v1.schema.json`, `system-action-pull-page-v1.schema.json`,
  and `system-action-execution-claim-v1.schema.json` — exact RPC boundary results.

An execution claim operation ID identifies exactly one durable attempt. Its exact retry
replays the same lease only while the server still considers that lease active. An expired
but unreceipted lease returns `busy`, even to the original operation, instead of becoming
executable again or moving to another device; its original operation can only reconcile
and publish terminal evidence against that original lease. It must not claim a replacement
lease merely to report reconciliation. Claim responses include the server-issued timestamp used as the
receipt start, so device clock skew cannot invalidate a completed native write. Once any
receipt releases that lease, the same operation ID
returns `attempt_completed` with the immutable receipt and no executable lease. A
genuinely new, reconciled non-success attempt uses a new operation ID and a new lease.
A tuple or fingerprint change remains a hard rejection, and any historical success for
the proposal phase returns `already_completed` instead of another execution lease.
Claims also enforce the proposal target: the creating device must match its creator
hash, a specific device must match its target hash, and `any` accepts any device in
the authenticated owner's tenant. Offline receipts are narrower: they must match the
creating device, or the explicit target for `specific_device`; an MCP-created `any`
proposal has no native creator and therefore cannot execute offline. Undo claims and
receipts must use the device that produced the successful execute receipt.
An exact online receipt for a lease issued under an eligible capability policy remains
valid if that policy is revoked before publication; this closes only the existing lease
and does not permit another claim or tuple.
Approval expiry is evaluated against database time, not the client-supplied
`decided_at`; offline clients still reject an expired proposal before persisting a claim.

Every normative fixture has a paired `.invalid.json` fixture proving a material
privacy, state-machine, or tuple-binding rejection.

`payload_hash` is lowercase SHA-256 over UTF-8 canonical JSON: object keys are
sorted lexicographically at every depth, arrays preserve order, and strings,
numbers, booleans, and null use their JSON representation with no insignificant
whitespace. Device-local paths, Apple identifiers, and display-only rendering do
not participate. `system-action-hash.mjs` is the executable reference and the
proposal/approval/receipt fixtures must all carry its exact result.
All wire timestamps use exactly `YYYY-MM-DDTHH:mm:ss.SSSZ`, and normative text
limits count UTF-8 bytes. The schemas expose semantic byte, timestamp, and interval
keywords exercised by the executable contract tests.
Migration 0030 implements the same canonicalizer and rejects any proposal whose
declared hash does not match its typed payload.

`manifest-hash.mjs` is the executable reference for the UTF-8 length-prefixed manifest
hash shared by clients and PostgreSQL. Device-local paths never participate.

Fixtures are normative examples, not production data. Swift tests decode the same
fixtures that the JSON Schema tests validate. Android must pass these fixtures before
its Room outbox or WorkManager worker can be connected to a real account.

Run `pnpm --filter @daypage/contracts test` from the repository root.
