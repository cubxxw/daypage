# ADR-0008: Local-first sync and user-scoped DayPage Cloud MCP

- **Status:** Accepted
- **Date:** 2026-08-23
- **Issue:** [#873](https://github.com/getyak/daypage/issues/873)

## Context

DayPage has working local Vault capture, Supabase authentication, a web database, a
legacy API-key sync uploader, and two partial MCP implementations. They do not yet form
one truthful product path. In particular, an unconfigured `NoopRemoteUploader` can drain
the local queue without writing remotely, edits do not carry a reliable modification
revision, deletes have no sync representation, and the standalone MCP process opens a
broad database connection through a hand-written stdio protocol.

The required path is:

```text
sign in -> commit to local Vault -> durable automatic sync -> Supabase
        -> DayPage Cloud MCP -> explicit OAuth consent -> external agent/app
```

The existing Vault Markdown/YAML representation and separator are compatibility
contracts. This decision must not turn cloud state into the capture source of truth or
rewrite existing Vault files merely to enable sync.

Supabase Auth's OAuth server currently supports OAuth 2.1/OIDC, PKCE, consent and dynamic
client registration. It does not currently support application-defined OAuth scopes, so
DayPage cannot honestly advertise custom `daypage:*` scopes at the authorization server.
OAuth access tokens do include `client_id`, which can be used with RLS and a DayPage grant
record for fine-grained authorization.

## Decision

### 1. Local commit remains the capture boundary

`RawStorage` continues to atomically commit the current `vault/raw/YYYY-MM-DD.md` format
before any network operation. Capture UI success means “saved locally”; it never waits
for Supabase. Network state is shown separately as queued, syncing, synced, or action
required.

Every successful raw mutation also records a compact operation in a versioned local
outbox. The outbox contains identifiers, operation kind, monotonically increasing local
revision, modification time, payload hash, retry metadata and Vault-relative path. It
does not duplicate memo bodies or credentials. Deletes are tombstones and therefore
survive removal of the Markdown record. Startup reconciliation can reconstruct missing
upserts from the Vault after a crash, while tombstones are retained until acknowledged.

The outbox is persisted under `vault/_agent/sync/` as DayPage-owned operational metadata.
It is never treated as user content and never changes the raw memo format. Legacy
UserDefaults queue entries are migrated into the outbox without being acknowledged.

### 2. Sync is revisioned, idempotent and session-backed

The authenticated iOS adapter supplies the current Supabase access token and project URL
at request time. Signing in by email or Apple is therefore sufficient to enable sync;
copying a Personal Access Token is no longer part of the normal product flow.

The remote contract accepts batches of upsert/delete operations with:

- a unique operation ID used as the idempotency key;
- `memo_id`, operation kind and per-memo local revision;
- `source_modified_at` and a stable content hash;
- the memo payload for upserts, or a tombstone for deletes.

Supabase applies an operation only for `auth.uid()` and only when its revision is newer
than the stored device revision. Retrying an acknowledged operation is harmless. The
response acknowledges individual operation IDs and returns the accepted remote revision.
The client removes only exactly acknowledged revisions; a newer local edit remains
queued. Retries use bounded exponential backoff with jitter and no artificial UX delay.

The first delivery is push-oriented and preserves local truth. Pull/merge uses the same
remote revision and tombstone model and is enabled after destructive-conflict fixtures
prove it cannot overwrite newer local content.

### 3. Supabase is the tenant and authorization boundary

Checked-in migrations add sync columns, operation receipts, MCP client grants, indexes,
profile provisioning, and RLS. Policies use `auth.uid() = user_id`; attachment access is
scoped through the owning memo. Negative cross-user tests are release blockers.

Normal app sessions retain Supabase's `authenticated` audience. OAuth-issued tokens also
carry `client_id`. The custom access-token hook adds the canonical MCP resource to the
OAuth token audience while preserving `authenticated`, allowing both resource validation
and RLS/PostgREST access. Cloud MCP rejects tokens without its configured resource
audience, expected issuer, subject, expiry and `client_id`.

Because Supabase custom OAuth scopes are not yet available, tool permissions are stored
in `mcp_client_grants(user_id, client_id, can_read, can_write)`. The DayPage consent UI
shows the OAuth client and requested standard scopes, and separately asks for read-only
or read/write DayPage access. Revoking the Supabase OAuth grant or the DayPage grant
removes access. If Supabase later supports custom scopes, the grant model can map to them
without changing tool contracts.

### 4. Cloud MCP is a standards-based HTTP resource server

`packages/mcp-server` becomes the canonical external MCP implementation and uses the
official TypeScript MCP SDK. Its primary transport is stateless Streamable HTTP. A local
stdio entry point may remain only as a diagnostic adapter and must use the same server,
tool and authorization code.

The service publishes RFC 9728 protected-resource metadata and returns a Bearer
`WWW-Authenticate` challenge for unauthenticated requests. Supabase Auth is advertised as
the authorization server. Dynamic client registration is enabled for compatible agents;
pre-registration remains available for restricted deployments.

The MCP service verifies the caller token, then creates a Supabase client using the anon
key plus that same user token. All data operations consequently execute under RLS. It
does not hold a service-role key or `DATABASE_URL` in the request path and never forwards
the token to any service other than its matching Supabase project.

Cloud agents that cannot complete an interactive OAuth flow may instead use a revocable
DayPage personal access token (PAT). PATs reuse `api_keys`, carry read/write scopes, are
shown only once, and are stored only as SHA-256 hashes. A fixed `SECURITY DEFINER` RPC
revalidates the hash, expiry, revocation and scope on every operation and applies the
resolved `user_id` to every static query. The RPC is executable only by the anonymous
gateway role; the underlying key and content tables remain inaccessible to that role.
This adds non-interactive authentication without introducing a service-role credential
or accepting a caller-supplied user ID. OAuth remains the default for third-party apps.

Initial stable tools are namespaced and bounded:

- `daypage_list_recent`
- `daypage_search`
- `daypage_get_memo`
- `daypage_get_page`
- `daypage_add_memo` when the client grant allows writes

Read-only annotations, pagination/limits, structured results and non-sensitive telemetry
are part of the contract. Memo bodies and tokens are excluded from logs.

### 5. Deployment and rollout

Cloud changes are exercised against an isolated Supabase project and synthetic data
before production. There is no staging environment at the time of this decision, so
production migration/deployment is explicitly held until a staging project is created or
designated.

Rollout order is schema/RLS -> session-backed sync -> read-only MCP -> OAuth/DCR and
consent -> write grant/tool -> measured pull/merge. Legacy API-key endpoints remain only
as a time-limited compatibility and diagnostic path; they never acknowledge the new
outbox unless the server returns the new operation receipt.

Implementation note (2026-08-24): an isolated Seoul staging project
`gcukhewnszjrwfzhxctn` was created after this decision. Migrations, RLS regression,
custom JWT hook, OAuth server, DCR, Cloud MCP and synthetic test data were deployed there;
the supplied production project remained untouched. The accepted MCP resource is
`https://gcukhewnszjrwfzhxctn.supabase.co/functions/v1/daypage-mcp`, with a public static
consent UI on the staging branch's GitHub Pages site. Codex CLI completed DCR/PKCE and
read the uniquely marked memo through `daypage_search`.

The same public endpoint also accepts `Authorization: Bearer dpg_stg_…` PATs for
non-interactive cloud agents. PAT calls are isolated to their owning user and expose
`daypage_add_memo` only when the stored key has the `write` scope.

Implementation evidence (2026-08-24): staging issued a 90-day read-only PAT whose raw
value was displayed once and whose SHA-256 hash was stored. The official MCP SDK used
that PAT to list only the four read tools and retrieve memo
`87300000-0000-4000-8000-000000000002`; a mutated PAT returned `401`. Twenty warm PAT
searches measured 757 ms p95 and 886 ms maximum.

## Performance budgets

- Warm local capture acknowledgement p95: at most 100 ms on the reference Simulator.
- Cached first meaningful content after app shell p95: at most 300 ms.
- Healthy-network incremental sync acknowledgement p95: at most 1.5 s without blocking
  capture.
- Warm Cloud MCP read p95: at most 1.0 s, excluding interactive OAuth authorization.

These are measured budgets, not promises inferred from unit tests. Evidence must include
the environment and sample size.

## Consequences

- Offline capture and existing Vault readability remain intact.
- The false-success path is removed; users may see a persistent actionable backlog when
  signed out or misconfigured, which is more truthful than silently dropping it.
- Tombstones and revisions add operational state and migration code, but avoid relying on
  wall-clock-only last-write-wins behavior.
- Supabase OAuth's current lack of custom scopes requires a DayPage grant table and custom
  consent UI.
- A standalone HTTP service adds one deployable component, but it gives Codex and other
  MCP clients a stable standard endpoint independent of the Next.js request lifecycle.

## Alternatives considered

- **Keep the UserDefaults ID set:** rejected because it cannot represent revisions,
  deletes, per-operation acknowledgement, backoff, or crash-safe recovery.
- **Use `NoopRemoteUploader` while signed out:** rejected because draining the queue is a
  false durability claim.
- **Keep direct Postgres access in MCP:** rejected because compromise exposes a broad
  database credential and bypasses the intended RLS request boundary.
- **Put MCP only in a Next.js route:** rejected as the canonical implementation because
  deployment/runtime coupling and duplicated protocol code already drift from the
  standalone package. The web route may proxy or redirect to the canonical service during
  migration.
- **Implement the legacy proposed CRDT/E2EE design now:** deferred. It is materially larger
  than the reliability and interoperable-MCP problem in #873 and would change the Vault
  protocol. This ADR does not reject a later encrypted CRDT transport.

## Verification and rollback

Completion requires isolated-Vault crash/retry/delete fixtures, positive and negative RLS
tests, MCP SDK client contract tests, OAuth consent/revocation evidence, and an actual
Codex call that reads a uniquely marked synthetic memo from the deployed staging project.

Rollback disables remote sync/MCP feature configuration without deleting the local
outbox. Database changes are additive; a rollback stops writers first and leaves columns,
receipts and tombstones in place until a separately reviewed cleanup.
