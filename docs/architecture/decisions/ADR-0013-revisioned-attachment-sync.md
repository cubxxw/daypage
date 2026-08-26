# ADR-0013: Revisioned local-first attachment synchronization

- **Status:** Accepted
- **Date:** 2026-08-26
- **Extends:** [ADR-0008](ADR-0008-local-first-sync-and-cloud-mcp.md)
- **Implementation issue:** [#884](https://github.com/getyak/daypage/issues/884);
  issue #873 explicitly delivered memo content/metadata while leaving attachment bytes
  local-only.
- **Local issue draft:** [2026-08-26 revisioned attachment sync](../../plans/2026-08-26-revisioned-attachment-sync-issue-draft.md)

## Context

DayPage captures photo and audio attachments under `vault/raw/assets/`, and the
Markdown memo stores their relative paths, duration, transcript, and transcription
state. The cloud schema already has a private `memo-attachments` Storage bucket,
`memo_attachments` rows, and owner-scoped RLS. Those pieces do not currently form a
sync protocol:

- `SyncMemoPayload` omits attachment metadata and bytes;
- `daypage_apply_sync_operations` never writes `memo_attachments`;
- `daypage_pull_sync_changes` never returns attachment descriptors;
- a receiving device preserves only attachments it already has locally;
- acknowledging the memo operation can therefore display “synced” while its photo or
  recording exists on only one device;
- deleting a memo has no defined object-retention or garbage-collection behavior.

This is a data-loss-shaped gap for any promise broader than text memo sync. The solution
must keep the Vault and its asset directory as the capture source of truth, preserve the
existing YAML format, work offline, avoid service-role credentials in clients, and not
turn a large media upload into the local capture success boundary.

## Decision

Adopt a versioned attachment-manifest and transfer protocol layered on the existing memo
outbox. A memo is committed locally first exactly as today. Cloud durability is complete
only when both the memo receipt and every referenced attachment manifest are committed.

```text
RawStorage append/rewrite
        |
        +--> raw/YYYY-MM-DD.md
        +--> raw/assets/<local file>
        +--> memo outbox operation + attachment descriptors
                              |
                              v
                authenticated Storage upload
                  small PUT / resumable TUS
                              |
                              v
             revisioned memo + manifest commit RPC
                              |
                              v
           Postgres/RLS + private Storage objects
                              |
                              v
                 pull memo + asset manifests
                              |
                 durable transfer sidecar
                    /                   \
             verified local file     pending download
                    \                   /
                              v
                   advance durable cursors
```

### 1. Local records remain authoritative

The attachment bytes remain ordinary files under `vault/raw/assets/`; the memo keeps the
current `file`, `kind`, `duration`, `transcript`, and `transcription_status` fields. No
remote URL, signed URL, account identifier, upload session, or cloud object key enters
the raw Markdown/YAML contract.

DayPage adds a replaceable operational sidecar under `vault/_agent/sync/` for transfers.
For each referenced local file it records the owning memo ID, SHA-256, byte length, MIME
type, sanitized original filename, remote object key, direction, retry state, and any
resumable-upload URL/offset. It contains no file bytes or credentials. Losing the sidecar
causes safe reconciliation from the Vault and remote manifest rather than data loss.

Capture success continues to mean “Markdown and asset bytes are durable locally.” UI
sync state distinguishes memo pending, media pending, media transferring, fully synced,
and actionable failure.

### 2. Content-addressed, tenant-scoped cloud objects

The canonical object key is:

```text
{auth.uid()}/{memo_id}/{sha256}.{validated_extension}
```

The client derives it from the authenticated account, memo ID, verified bytes, and an
allow-listed MIME/extension pair. Paths containing traversal, control characters, empty
segments, or unsupported MIME types fail before network work. The existing private
bucket remains non-public and accepts only an authenticated user's first path segment.
Objects are immutable: a different payload never overwrites an existing key.

Each descriptor contains:

```text
position
kind: audio | photo | file
content_sha256
size_bytes
mime_type
original_filename
duration_sec?
transcript?
transcription_status?
```

The local `file` path is deliberately absent. Different devices may select different
collision-safe filenames while preserving identical bytes and metadata.

`position` preserves the YAML attachment order. `content_sha256` is lowercase SHA-256
hex. The manifest hash is SHA-256 over a versioned canonical JSON encoding of the
descriptor array in position order; it deliberately excludes device-local paths and
transfer state. Receipt retries bind to both the memo content hash and this manifest
hash, so reusing an operation ID with different bytes or metadata fails closed even if
the memo ID, kind, and revision are unchanged.

Uploads at or below the measured simple-upload threshold use the ordinary authenticated
Storage endpoint. Larger assets use Supabase's TUS resumable endpoint and persist the
upload URL/offset in the transfer sidecar. Retry never creates a second logical object.
The implementation must measure the threshold and memory use on supported devices; it
must not load a 50 MB object into memory merely to retry it.

The initial implementation uses 6 MiB as the standard/TUS boundary and 6 MiB TUS chunks,
matching the current Supabase guidance, but keeps the boundary server-configurable and
covered by an integration test. The current implementation resolves a fresh authenticated
user session to establish the exact-path TUS upload and persists only its resumable
URL/offset. If `HEAD` shows that a stored TUS session is no longer usable, the client
clears that state and creates a new session for the same immutable key; it never sets the
overwrite/upsert option. A future signed-upload-token optimization must retain these
expiry and retry guarantees.

Before a missing object can be uploaded, an authenticated preparation RPC creates a
short-lived reservation for the exact owner, memo, object key, declared size, and MIME
type. The Storage `INSERT` policy permits only keys with a matching unexpired
reservation; the existing broad owner-prefix insert policy is replaced. Reservations
are serialized per account, rate-limited, and count against provisional quota. The
bucket still enforces the per-object size and MIME allow-list, while manifest commit
rechecks the Storage-recorded size and committed account quota. Supabase creates the
`storage.objects` placeholder before standard/TUS upload bytes are final, so INSERT RLS
cannot compare final size. The orphan inventory expires and queues a reservation whose
actual size/MIME is still mismatched after 10 minutes; matching interrupted uploads keep
the normal 26-hour recovery window. Expired, uncommitted reservations and their objects
are orphan-cleanup candidates.

### 3. Receipt follows object presence and manifest commit

Sync protocol v2 adds `attachments` to an upsert payload. The native uploader performs:

1. validate every Vault-relative path and stream SHA-256/size from the local file;
2. upload every missing immutable object using the user's JWT and bucket RLS;
3. call a v2 sync RPC with the memo operation and exact attachment descriptor set;
4. have the RPC verify that every declared object exists under the caller's prefix and
   matches the declared size before atomically applying the memo, replacing its manifest
   rows, and writing the operation receipt;
5. acknowledge the local memo revision only after that receipt returns.

The RPC never accepts a caller-supplied owner ID. It derives the tenant from `auth.uid()`
and rejects descriptors belonging to another memo, malformed object keys, duplicate
hash/path identities, missing objects, or a manifest that exceeds configured count/byte
limits. A failed manifest transaction leaves the local operation pending. Uploaded but
uncommitted objects are harmless orphans eligible for delayed cleanup.

Authenticated clients receive read-only access to committed manifest rows. Direct
`INSERT`, `UPDATE`, and `DELETE` grants on `memo_attachments` are revoked; the v2 RPC is
the only mutation boundary. It is narrowly `SECURITY DEFINER`, fixes its search path,
fully qualifies cross-schema objects, derives `auth.uid()` internally, and is covered by
cross-tenant and privilege tests. The existing v1 RPC stays available during rollout;
v1 writes preserve a valid v2 manifest and cannot claim media-complete status.

`memos` gains an `attachment_manifest_hash` that participates in its server-owned change
sequence. Changing transcript/status metadata therefore creates a pull-visible revision
without re-uploading unchanged bytes. `memo_attachments` gains the content hash, byte
length, original filename, MIME type, attachment position, transcription status, and a
uniqueness constraint for the memo/object identity. Existing attachment rows created by
the legacy bulk API have no verified content hash and are never presented as a v2 durable
manifest. Protocol v1 remains readable during rollout but cannot claim media-complete
sync.

`sync_operations` also records protocol version, memo content hash, and manifest hash.
An exact v2 retry must match all of them. This closes the current gap where a repeated
operation ID is bound only to memo ID, kind, and revision.

### 4. Push, pull, and media scheduling are independent

The current queue stops at the first failed upload and pulls only after the entire push
snapshot succeeds. That behavior must change before media is enabled: a paused or failed
attachment transfer cannot prevent later text-only operations or incoming remote changes.

The coordinator classifies failures as account/auth fatal, memo conflict, retryable text,
or media deferred/retryable. It may skip a media-blocked operation for the current pass,
continue independent memo operations, and still pull unless account/auth integrity is
unknown. Ordering remains strict per memo ID and revision, not globally across unrelated
memos. Pull and durable transfer reconciliation run on separate bounded schedules with
backoff, reachability, cellular policy, and cancellation.

### 5. Pull is durable even when media is deferred

The pull page returns attachment descriptors with each memo change. Before advancing the
memo cursor, the receiver must durably do one of the following for every descriptor:

- verify matching local bytes already exist; or
- download to a staging file, verify SHA-256 and size, then atomically move it under
  `raw/assets/`; or
- persist a pending-download transfer record with its deterministic target path.

This permits text and metadata to arrive while offline or on a media-restricted network
without losing the obligation to fetch the bytes. The UI renders an explicit download
placeholder from transfer state rather than treating a missing file as an empty image or
recording. A transfer cursor/state is independent from the memo change cursor, so one
large attachment cannot permanently block later text memos.

Downloaded bytes are never trusted solely because their object key contains a hash. A
hash or size mismatch keeps the transfer pending/actionable and never replaces an
existing valid local file. If a target filename already contains different bytes, the
receiver chooses a SHA-prefixed local filename and writes that device-local path into the
incoming memo. Remote application remains excluded from outbound recording, preventing
an echo operation caused only by local path choice.

### 6. Delete, retention, and recovery

A memo tombstone immediately hides the cloud memo and manifest from normal reads but does
not synchronously erase the only remote copy of media. Attachment objects enter a
server-owned garbage-collection queue with a minimum recovery grace period. Cleanup is
idempotent, owner-scoped, observable, and deletes only keys no longer referenced by an
active manifest. Restoring a memo during the grace period cancels cleanup.

Authenticated clients cannot directly delete Storage objects. A scheduled, non-public
garbage-collection worker holds the server-only Storage credential, claims due queue
rows, rechecks that no active manifest or live reservation references the object, calls
the Storage API (never SQL-deletes `storage.objects`), and records the outcome. The same
worker inventories old uploaded objects that never reached manifest commit. It is
idempotent and bounded per run; failures retain the queue row for retry.

Local memo deletion follows the existing Vault behavior and must not silently delete an
asset file that another memo references. A separately reviewed local orphan collector
may offer recoverable cleanup after reference scanning; it is not part of network sync.

Crash recovery cases are explicit:

- asset written, memo append failed: existing capture reconciliation owns it;
- memo committed, upload not started: reconstruct transfers from memo attachments;
- upload interrupted: resume from the durable transfer sidecar;
- object uploaded, RPC not committed: retry exact object key and operation ID;
- RPC committed, receipt lost: exact operation retry returns the same receipt;
- pull manifest persisted, download interrupted: resume without replaying later memos;
- bytes downloaded, Vault write interrupted: verify staging bytes and replay atomically.

### 7. Security, privacy, and limits

- Transport uses TLS outside localhost; Storage and metadata remain private under RLS.
- Native clients hold only the publishable key and the current user session.
- MCP does not expose attachment bytes or signed URLs in this phase.
- Logs and metrics contain object size, kind, duration, latency, retry class, and hashes
  only when truncated; they never contain filenames, transcript, URLs, or media bytes.
- Server-side encryption is provider-managed, consistent with current plaintext memo
  storage. This is not end-to-end encryption and the product must not claim otherwise.
- Per-object, per-memo, and per-account quotas are enforced before upload and again at
  manifest commit. The initial object ceiling remains the bucket's checked-in 50 MB
  limit, subject to measurement before acceptance.
- Cellular upload/download is a user setting. Metadata sync remains available when media
  transfer is paused.

### Accepted launch defaults

The user approved these initial values when authorizing implementation issue #884:

| Policy | Recommended default |
| --- | --- |
| Cloud deletion grace | 30 days |
| Network policy | Wi-Fi by default; cellular is opt-in |
| Per object | 50 MiB |
| Per memo | 20 attachments and 250 MiB total |
| Per account | 2 GiB committed plus bounded live reservations |
| Initial MIME set | JPEG, PNG, HEIC/HEIF, M4A/MP4 audio, and PDF |
| Encryption claim | Provider-managed encryption; explicitly not E2EE |

Unsupported local file types remain durable in the Vault and display an actionable
“media not cloud-synced” state. They must never be silently omitted from a “fully synced”
claim. Expanding the MIME set requires content-sniffing fixtures and a separate review.

## Alternatives considered

### Put base64 bytes inside the memo RPC

Rejected because it multiplies memory use, defeats resumability, bloats operation
receipts/logs, and couples small text sync to large media transfer.

### Acknowledge the memo first and upload files best-effort

Rejected because “synced” could permanently mean “text exists remotely but the only
photo or recording does not.” Separate media state is useful, but the revision receipt
must not claim attachment-manifest durability before the objects and manifest exist.

### Store signed URLs in Markdown

Rejected because URLs expire, leak cloud topology into the Vault format, and make local
files depend on an account/network to remain readable.

### Use local filenames as global attachment identity

Rejected because filenames collide, can contain unsafe paths, change across devices, and
do not prove byte integrity.

### Delete cloud objects immediately with the memo

Rejected because an accidental or conflicting tombstone would destroy the recovery copy
before other offline devices observe it.

## Rollout and verification

Implementation issue #884 records explicit agreement on cloud retention, cellular
defaults, quotas, the initial MIME set, and the non-E2EE disclosure.

1. **Protocol and schema:** versioned JSON schemas/fixtures, additive migration, RLS,
   immutable object policy, v1 compatibility, and rollback flags.
2. **Apple upload:** streaming hash, safe path/MIME validation, simple and resumable
   upload, transfer sidecar, receipt gating, and visible media sync state.
3. **Apple pull:** descriptor decode, verified staging/download, deterministic local
   path, placeholders, retry, and cursor durability.
4. **Other surfaces:** Android conformance, web attachment creation/download, and shared
   fixtures before claiming cross-platform parity.
5. **Operations:** orphan inventory, grace-period cleanup, quota alerts, sampled latency,
   and staging restore rehearsal before production.

Required automated evidence includes:

- raw YAML and attachment bytes survive failed upload, restart, and sidecar rebuild;
- a second empty Vault receives identical bytes and metadata and can open/play them;
- interrupted large uploads resume rather than restart or duplicate;
- hash mismatch, MIME spoof, traversal, oversize, missing object, and cross-user object
  references fail closed;
- exact retry is idempotent while operation-ID tuple/manifest reuse is rejected;
- transcript/status-only edits pull without re-uploading bytes;
- memo deletion becomes a tombstone, remains restorable during grace, and is collected
  only when unreferenced;
- offline metadata-only pull durably queues bytes and later converges;
- no cursor advances past an unpersisted memo or transfer obligation;
- release builds reject non-HTTPS endpoints and never contain privileged credentials.

The local acceptance command must start from an empty backend, upload a JPEG and an M4A
through the real Storage APIs, commit the v2 manifest, pull into a second empty Vault,
verify the exact byte hashes, exercise a deferred-download cursor, and clean up every
synthetic user, object, reservation, manifest, and queue row. Staging promotion adds a
TUS interruption/resume run, deletion-grace rehearsal, cross-user negative probes, and
orphan-worker evidence. Production remains a separately authorized operation.

## Implementation references

- [Supabase Storage access control](https://supabase.com/docs/guides/storage/security/access-control)
- [Supabase resumable uploads](https://supabase.com/docs/guides/storage/uploads/resumable-uploads)
- [Supabase signed upload URLs](https://supabase.com/docs/reference/javascript/file-buckets-createsigneduploadurl)
- [Supabase Storage schema guidance](https://supabase.com/docs/guides/storage/schema/design)

Production promotion additionally requires a real photo, audio, and maximum-supported
file round trip in isolated staging, two-account negative tests, measured transfer
latency/memory, recovery from a killed client, and explicit production authorization.

## Sources

- [Supabase Storage access control](https://supabase.com/docs/guides/storage/security/access-control)
- [Supabase standard uploads](https://supabase.com/docs/guides/storage/uploads/standard-uploads)
- [Supabase resumable uploads](https://supabase.com/docs/guides/storage/uploads/resumable-uploads)
- [tus resumable upload protocol](https://tus.io/protocols/resumable-upload)
