# DayPage Cloud MCP staging runbook

This runbook promotes the pipeline in [ADR-0008](architecture/decisions/ADR-0008-local-first-sync-and-cloud-mcp.md). Never point the staging hostname at the production Supabase project.

## Preconditions

- A dedicated Supabase staging project and a staging web/MCP hostname exist.
- The web origin is registered in Supabase Auth redirect URLs.
- `DAYPAGE_MCP_RESOURCE` is the canonical external Streamable HTTP URL.
- Only the anon key is available to the MCP container. `DATABASE_URL` and the service-role key are intentionally unsupported.

## Database and Auth

1. Apply the Drizzle journal through `0028_sync_receipt_integrity` to the staging database.
2. Set the environment-owned resource value:

   ```sql
   update public.daypage_runtime_config
   set value = 'https://gcukhewnszjrwfzhxctn.supabase.co/functions/v1/daypage-mcp', updated_at = now()
   where key = 'mcp_resource';
   ```

3. Enable Supabase OAuth Server. For the current staging deployment, use site URL
   `https://getyak.github.io` and authorization path `/daypage/oauth/consent/`.
4. Enable dynamic client registration (DCR).
5. Enable custom access-token hook `pg-functions://postgres/public/daypage_custom_access_token_hook`.
6. Run `web/scripts/verify-local-first-sync.sql` against an isolated database before promotion.

`0027_multi_device_pull` must leave `authenticated` with `USAGE` on
`daypage_memo_change_sequence`; otherwise the revisioned write RPC catches the trigger
failure and returns a rejected operation. The verification script covers this through a
real authenticated-role upsert rather than a privilege-only assertion.

`0028_sync_receipt_integrity` keeps an exact retry idempotent while rejecting reuse of an
existing operation ID with a different memo ID, operation kind, or revision.

Supabase standard scopes (`openid email profile`) identify the user. DayPage read/write authority comes from `mcp_client_grants` and is checked on every MCP request.

For non-interactive agents, a DayPage PAT can be supplied in the same Bearer header.
Generate at least 256 bits of entropy, prefix it with `dpg_stg_` or `dpg_live_`, store
only `sha256(raw_key)` in `api_keys.key_hash`, and display the raw value once. PATs reuse
the existing `read` / `write` scopes and may be revoked or expired independently. Never
use a Supabase anon, publishable, secret, or service-role key as a DayPage PAT.

## Deploy and probe

The portable container deployment remains available: build `deploy/Dockerfile.mcp` and
provide the MCP variables from `.env.example`. The service listens on `43119`; terminate
TLS at the staging reverse proxy. It is deliberately separate from `compose.prod.yml`.

```bash
DAYPAGE_ENV_FILE=../.env.staging \
  docker compose -f deploy/compose.mcp.yml --project-name daypage-mcp-staging up -d --build
```

The accepted staging deployment uses Supabase Edge Functions instead:

```bash
pnpm --filter daypage-mcp-server build:edge
# Deploy packages/mcp-server/dist/edge.js as function `daypage-mcp`.
# Deploy supabase/functions/daypage-oauth/index.ts as function `daypage-oauth`.
```

Both functions have gateway legacy-JWT verification disabled because `daypage-mcp`
performs issuer/audience/client/grant verification itself and `daypage-oauth` exposes
only health, metadata and a redirect to the static consent UI. No service-role key is
used. The staging endpoints are:

- MCP: `https://gcukhewnszjrwfzhxctn.supabase.co/functions/v1/daypage-mcp`
- OAuth docs/redirect: `https://gcukhewnszjrwfzhxctn.supabase.co/functions/v1/daypage-oauth`
- Consent UI: `https://getyak.github.io/daypage/oauth/consent/`

Required probes:

```text
GET /functions/v1/daypage-mcp/healthz                                 -> 200
GET /functions/v1/daypage-mcp/.well-known/oauth-protected-resource    -> 200 metadata
POST /functions/v1/daypage-mcp without bearer token                   -> 401 + WWW-Authenticate
POST with normal DayPage app token                                    -> 401 (wrong audience/client)
POST with OAuth token but revoked grant                               -> 403
POST with invalid, expired, or revoked DayPage PAT                    -> 401
POST with read-only DayPage PAT calls `daypage_search`                -> 200
POST with read-only DayPage PAT cannot advertise `daypage_add_memo`
POST with read/write DayPage PAT advertises and calls `daypage_add_memo` -> 200 + Memo ID
```

Run the deployed read/write contract with the official MCP SDK (credentials stay in
environment variables and must never be committed):

```bash
DAYPAGE_MCP_E2E_URL=https://gcukhewnszjrwfzhxctn.supabase.co/functions/v1/daypage-mcp \
DAYPAGE_MCP_E2E_KEY="$DAYPAGE_MCP_API_KEY" \
DAYPAGE_MCP_E2E_MAC_MARKER=DAYPAGE_MAC_VAULT_SYNC_STAGING_20260824 \
DAYPAGE_MCP_E2E_AGENT_MARKER=DAYPAGE_AGENT_MCP_WRITE_STAGING_20260824 \
pnpm --dir packages/mcp-server test:live
```

## Codex acceptance

1. Add the staging MCP URL to Codex.
2. Complete DCR, login and the DayPage consent screen using a synthetic staging user.
3. Keep the default grant read-only.
4. Insert a uniquely marked memo through the revisioned sync RPC, not with a service-role bypass.
5. Ask Codex to call `daypage_list_recent`, then `daypage_get_memo` or `daypage_search`.
6. Save the tool result showing the exact marker and memo UUID. Revoke the grant and confirm the same client receives `403`.

Production promotion requires all six checks and must use a different OAuth consent/grant set from staging.

## Native multi-device acceptance

Before distributing a new iOS/macOS test build, run the opt-in test with one normal
staging Supabase Auth session. It creates two independent local Vault directories, then
performs A create -> B pull -> B edit -> A pull -> A delete -> B pull. Credentials are
environment-only and the final cloud row is a tombstone.

```bash
DAYPAGE_SYNC_E2E_URL=https://gcukhewnszjrwfzhxctn.supabase.co \
DAYPAGE_SYNC_E2E_PUBLISHABLE_KEY="$DAYPAGE_STAGING_PUBLISHABLE_KEY" \
DAYPAGE_SYNC_E2E_EMAIL="$DAYPAGE_STAGING_TEST_EMAIL" \
DAYPAGE_SYNC_E2E_PASSWORD="$DAYPAGE_STAGING_TEST_PASSWORD" \
swift test --package-path DayPageKit --filter SupabaseMultiDeviceLiveTests
```

Alternatively set `DAYPAGE_SYNC_E2E_ACCESS_TOKEN`; the test derives the user ID from the
JWT, so `DAYPAGE_SYNC_E2E_USER_ID` is optional. The credential loader refuses the known
production project reference before making any network request.

Release evidence must include the unskipped test result. A skipped test means the
network path is still unverified and is not sufficient for TestFlight or public beta.
Also run the second-account negative transaction in
`web/scripts/verify-local-first-sync.sql`; a local Vault account mismatch must remain a
hard failure rather than an automatic rebind.

## Accepted staging evidence (2026-08-24)

- Supabase project: `daypage-staging` (`gcukhewnszjrwfzhxctn`, Seoul).
- Hosted migration/RLS/OAuth-hook regression printed
  `daypage local-first sync / RLS / OAuth hook verification passed`.
- Hosted migration `0027_multi_device_pull` and its updated transaction verification
  passed on 2026-08-24. The test covered monotonic pull cursors and a user-B zero-result
  negative check, and rolled back its synthetic rows.
- Hosted migration `0028_sync_receipt_integrity` and the expanded transaction
  verification passed on 2026-08-25. The test covered both an exact retry and a rejected
  operation-ID tuple mismatch, and again rolled back all synthetic rows.
- The marker memo was inserted through `daypage_apply_sync_operations` under the
  synthetic user's access token, not through SQL or a service-role bypass.
- Codex CLI 0.147.0 completed DCR + PKCE login and called `daypage_search` on the
  remote MCP. It returned memo `87300000-0000-4000-8000-000000000002` with body
  `DAYPAGE_CODEX_MCP_STAGING_20260824 — local Vault to Supabase to Cloud MCP acceptance memo`.
- A read-only PAT with key ID `30a21a60-604f-4d05-a166-750cccacca67`, display
  prefix `dpg_stg_1_fe0pD1`, and 90-day expiry was issued to the synthetic user.
  The official MCP SDK listed the four read tools, did not advertise
  `daypage_add_memo`, and returned the same marker memo through `daypage_search`.
- A one-character-mutated PAT returned `401`. On 20 warm PAT searches, measured
  latency was 633 ms average, 622 ms p50, 757 ms p95, and 886 ms maximum.
- The native macOS capture path committed marker
  `DAYPAGE_MAC_VAULT_SYNC_STAGING_20260824` to an isolated Vault, persisted its durable
  outbox operation, uploaded through `daypage_apply_sync_operations` with a normal
  synthetic-user session, acknowledged the outbox, and read memo
  `012b7ae9-8b02-467c-a9f8-fc8c7488dba2` back under RLS with source `macos`.
- A second synthetic staging user (`d44e55a5-1a27-43bd-a87b-abcdc585920d`) received a
  90-day read/write PAT. Only its hash was stored; audit-safe metadata is key ID
  `3c3bfcd1-3134-433e-94ac-90e712d71bf4`, prefix `dpg_stg_2_ljYDYp`, scopes
  `read,write`, and expiry `2026-11-22T05:52:04Z`.
- The official MCP SDK listed all five tools, read the macOS marker, called
  `daypage_add_memo`, received memo `f6f308e0-db25-42eb-bd7f-cffec23d66c5`, and found
  its exact marker `DAYPAGE_AGENT_MCP_WRITE_STAGING_20260824` through `daypage_search`.
- Codex CLI 0.147.0 loaded the Streamable HTTP server with
  `bearer_token_env_var = "DAYPAGE_MCP_API_KEY"`, called the deployed
  `daypage_search` tool itself, and returned that same memo ID and marker. The raw PAT
  was not written to Codex configuration or repository files.
- The supplied production project `thnmxpgwzwprixfkqpkw` was not modified.
