# DayPage Cloud MCP staging runbook

This runbook promotes the pipeline in [ADR-0008](architecture/decisions/ADR-0008-local-first-sync-and-cloud-mcp.md). Never point the staging hostname at the production Supabase project.

## Preconditions

- A dedicated Supabase staging project and a staging web/MCP hostname exist.
- The web origin is registered in Supabase Auth redirect URLs.
- `DAYPAGE_MCP_RESOURCE` is the canonical external Streamable HTTP URL.
- Only the anon key is available to the MCP container. `DATABASE_URL` and the service-role key are intentionally unsupported.

## Database and Auth

1. Apply the Drizzle journal through `0025_local_first_sync_and_mcp` to the staging database.
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

Supabase standard scopes (`openid email profile`) identify the user. DayPage read/write authority comes from `mcp_client_grants` and is checked on every MCP request.

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
```

## Codex acceptance

1. Add the staging MCP URL to Codex.
2. Complete DCR, login and the DayPage consent screen using a synthetic staging user.
3. Keep the default grant read-only.
4. Insert a uniquely marked memo through the revisioned sync RPC, not with a service-role bypass.
5. Ask Codex to call `daypage_list_recent`, then `daypage_get_memo` or `daypage_search`.
6. Save the tool result showing the exact marker and memo UUID. Revoke the grant and confirm the same client receives `403`.

Production promotion requires all six checks and must use a different OAuth consent/grant set from staging.

## Accepted staging evidence (2026-08-24)

- Supabase project: `daypage-staging` (`gcukhewnszjrwfzhxctn`, Seoul).
- Hosted migration/RLS/OAuth-hook regression printed
  `daypage local-first sync / RLS / OAuth hook verification passed`.
- The marker memo was inserted through `daypage_apply_sync_operations` under the
  synthetic user's access token, not through SQL or a service-role bypass.
- Codex CLI 0.147.0 completed DCR + PKCE login and called `daypage_search` on the
  remote MCP. It returned memo `87300000-0000-4000-8000-000000000002` with body
  `DAYPAGE_CODEX_MCP_STAGING_20260824 — local Vault to Supabase to Cloud MCP acceptance memo`.
- The supplied production project `thnmxpgwzwprixfkqpkw` was not modified.
