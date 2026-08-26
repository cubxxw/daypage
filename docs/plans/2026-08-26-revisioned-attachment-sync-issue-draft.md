# #884: Revisioned attachment sync and verified cross-device media

## Problem

DayPage's current revisioned Supabase sync proves memo text/metadata durability, tenant
isolation, idempotent receipts, tombstones, monotonic pull, and MCP access. It does not
sync the attachment bytes or a verified attachment manifest. A second empty Vault can
receive a photo/voice memo but not the referenced photo or recording.

The legacy API-key bulk route can store attachment metadata whose `storage_key` is only
an iOS Vault-relative path. The web attachment picker currently adds filenames to memo
text and does not upload bytes. Neither path is evidence of cloud media durability.

## Proposed outcome

Accept and implement ADR-0013. Keep `vault/raw/*.md` and `vault/raw/assets/**` as the
local source of truth while adding:

- versioned attachment descriptors and a canonical manifest hash;
- quota reservations and exact-path private Storage uploads;
- standard upload for small objects and resumable TUS for larger objects;
- one atomic v2 memo/manifest/receipt RPC;
- verified download into a second Vault or a durable pending-download obligation;
- independent text push, pull, and media transfer scheduling;
- deletion grace, restore cancellation, and observable orphan garbage collection;
- explicit media sync state without claiming end-to-end encryption.

## Product decisions to record before implementation

Recommended defaults:

| Decision | Proposed value | Approval |
| --- | --- | --- |
| Cloud deletion grace | 30 days | Accepted |
| Cellular behavior | Wi-Fi default; cellular opt-in | Accepted |
| Object limit | 50 MiB | Accepted |
| Memo limit | 20 objects / 250 MiB | Accepted |
| Account limit | 2 GiB committed + bounded reservations | Accepted |
| Initial MIME set | JPEG, PNG, HEIC/HEIF, M4A/MP4 audio, PDF | Accepted |
| Encryption disclosure | Provider-managed; not E2EE | Accepted |

## Acceptance criteria

### Protocol and persistence

- [ ] Add v2 JSON Schemas and canonical fixtures for push, receipt, pull, upload
      preparation, and manifests; keep all v1 contract tests green.
- [ ] Preserve attachment order and the existing raw YAML fields without putting cloud
      URLs, object keys, accounts, upload IDs, or transfer status into Markdown.
- [ ] Compute lowercase streaming SHA-256 and size from a canonicalized Vault-relative
      path under `raw/assets/**`; reject symlinks, traversal, directories, missing files,
      MIME/extension mismatches, and unsupported content.
- [ ] Bind each v2 receipt to operation ID, user, memo, kind, revision, memo content hash,
      protocol version, and manifest hash. Only an exact retry returns that receipt.
- [ ] Legacy/v1 rows cannot be mistaken for a verified v2 manifest; v1 edits preserve a
      valid v2 manifest during rollout.

### Database, RLS, and Storage

- [ ] Add the manifest columns/constraints, `attachment_manifest_hash`, upload
      reservations, garbage-collection queue, indexes, grants, and owner-scoped RLS in an
      additive migration that applies from an empty database and over the current schema.
- [ ] Revoke authenticated direct mutation of verified manifest rows. The v2 commit RPC
      derives `auth.uid()`, validates every descriptor, replaces the manifest, bumps the
      memo change sequence, and writes the receipt in one database transaction.
- [ ] Replace the broad owner-prefix Storage `INSERT` policy with an exact live-reservation
      policy; keep the bucket private and remove client `UPDATE`/`DELETE` paths.
- [ ] Enforce object, memo, provisional reservation, and committed account quotas under
      concurrency. Reject cross-account, missing, expired, oversized, duplicate, or
      wrong-memo objects.
- [ ] Use the Storage API for object deletion. Never mutate `storage.objects` with SQL.

### Apple upload and recovery

- [ ] Add a versioned transfer sidecar under `vault/_agent/sync/` with atomic writes,
      rebuilding from Vault + remote manifest, and no credentials or media content.
- [ ] Standard upload handles objects at or below the configured threshold without
      unbounded memory use; larger objects use 6 MiB TUS chunks and resume after restart.
- [ ] Authenticated-session expiry and TUS URL expiry renew safely. Immutable keys never
      use overwrite/upsert; a concurrent existing-object response is verified, not trusted.
- [ ] A memo operation is acknowledged only after every referenced object and its exact
      manifest are committed. UI distinguishes memo pending, media pending/transferring,
      fully synced, paused, unsupported, quota failure, and retryable failure.
- [ ] A blocked media operation does not stop unrelated text pushes or incoming pulls;
      ordering is strict per memo revision rather than globally head-of-line blocking.

### Apple pull and convergence

- [ ] Pull returns ordered attachment descriptors and manifest hash with every relevant
      memo change, including transcript/status-only changes without byte re-upload.
- [ ] Before advancing the memo cursor, the receiver either installs hash-verified bytes
      atomically or persists an idempotent pending-download obligation with a deterministic
      collision-safe local target.
- [ ] Download never replaces a different valid local file. Hash/size mismatch remains
      actionable and does not advance the transfer state.
- [ ] A second empty Vault converges the same memo, attachment order, metadata, and byte
      hashes and can display/play the JPEG and M4A fixtures.
- [ ] Conflict copies with a new memo UUID preserve local assets and receive new remote
      keys without echoing a pulled local path choice.

### Deletion, operations, and privacy

- [ ] A tombstone hides the manifest, queues objects for the agreed grace period, and can
      be restored before collection. Shared local assets are never silently deleted.
- [ ] The private scheduled worker rechecks active manifests/reservations, deletes only via
      Storage API, retries idempotently, inventories uncommitted orphans, and emits bounded
      metrics without filenames, transcripts, URLs, credentials, or bytes.
- [ ] The product and privacy copy say that cloud memo/media data uses provider-managed
      encryption and is not end-to-end encrypted. MCP does not expose bytes or signed URLs.
- [ ] Release builds reject non-HTTPS media endpoints and contain no secret/service-role
      credential. Server-only worker credentials remain outside source control and logs.

### Cross-surface honesty

- [ ] Android and web decode shared v2 fixtures before cross-platform parity is claimed.
- [ ] The web attachment picker either performs the same verified upload/manifest flow or
      clearly remains local UI scaffolding; filenames in memo text are not presented as
      uploaded files.
- [ ] MCP and legacy bulk behavior remain compatible but cannot report media-complete sync.

## Verification gates

Local gates:

```bash
pnpm backend:check
pnpm backend:verify:local
swift test --package-path DayPageKit
```

The extended local verifier must reset from empty, use real Auth/Storage/RPC endpoints,
exercise two isolated Vaults, run all negative RLS/integrity cases transactionally where
possible, and clean all generated users, Storage objects, reservations, manifests, and
GC rows even after failure.

Staging gates:

- real-device or Simulator JPEG/M4A capture -> upload -> second-Vault download/open;
- interrupted TUS resume with bytes-sent evidence, not just a mocked retry;
- Wi-Fi/cellular policy transition and foreground/restart recovery;
- deletion grace/restore/collection rehearsal and orphan inventory;
- cross-user Storage, reservation, manifest, and expired-session/TUS probes;
- latency, memory, retry, quota, and rollback evidence with synthetic data only.

Production migration, deployment, probes, credentials, and cleanup are explicitly out of
scope until separately authorized.

## Implementation slices and likely owned paths

1. Contracts and schema: `packages/contracts/**`, `web/drizzle/migrations/**`,
   `supabase/migrations/**`, `web/src/lib/db/schema.ts`, SQL verification.
2. Transfer core: new `DayPageKit/Sources/DayPageStorage/*Attachment*` types plus focused
   package tests; no feature-view ownership in this slice.
3. Coordinator integration: `SyncOutboxStore`, `SupabaseSyncUploader`,
   `SupabaseSyncPuller`, `SyncQueueObserver`, `RawStorage`, and multi-device tests.
4. Apple UI state: affected Today/detail/settings views and localization after the core
   protocol is green.
5. Operations and web honesty: GC worker/runbook, privacy copy, web creation/download or
   explicit disabled/scaffold state, shared conformance fixtures.

Each slice requires non-overlapping ownership, a dirty-worktree check, focused gates, and
review evidence. No staging or production side effect is implied by this issue.

## Non-goals

- Replacing the Vault with cloud storage.
- Writing remote URLs or sync metadata into raw Markdown.
- Background execution guarantees that iOS does not provide.
- Attachment bytes or signed URLs through MCP.
- End-to-end encryption in this protocol version.
- Immediate deletion of local asset files.
- Production deployment or migration.

## Primary risks

- A queue-level media failure blocking all text and pull progress.
- A receipt acknowledging a different manifest after operation-ID reuse.
- Storage objects that exist but do not match descriptor bytes.
- Legacy metadata rows being mistaken for verified objects.
- Cursor advancement without a durable transfer obligation.
- Client deletion breaking an active manifest.
- Orphan/reservation accumulation bypassing quota.
- Conflict-copy path changes causing upload echoes or lost references.
- Logs, signed URLs, filenames, or transcripts leaking private information.

## Rollback

Disable v2 upload preparation and writers first, leave v1 text sync/pull available, stop
the GC worker, and preserve all local Vault data, sidecars, receipts, manifests, queued
objects, and tombstones. Do not delete Storage objects as part of rollback. A forward fix
can replay exact operations and transfer obligations.
