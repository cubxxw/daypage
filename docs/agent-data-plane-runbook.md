# Agent Data Plane runbook

This runbook operates the implementation accepted by
[ADR-0018](architecture/decisions/ADR-0018-backend-first-agent-data-plane.md).
It does not authorize a production migration, backfill, connector activation, or mode
change.

Evaluation, feedback, Opik projection, datasets, and promotion gates are operated through
the separate [Agent Evaluation runbook](agent-evaluation-runbook.md).

## Runtime modes

Set `AGENT_DATA_PLANE_MODE` on the Web/Inngest runtime:

| Mode | New worker | Artifact writes | Canonical pages/actions | Legacy compiler default |
| --- | --- | --- | --- | --- |
| `off` | disabled | none | none | enabled |
| `shadow` | enabled | isolated draft artifacts | disabled | enabled |
| `primary` | enabled | canonical | enabled | disabled |

The default is `shadow`. `LEGACY_MEMO_COMPILER_ENABLED` is an emergency override; omit
it during normal rollout. Native convergence is a separate default-off
`backendFirstIntelligence` experiment so server and client promotion can be staged.

## Local setup and verification

Apply the additive migration and run the transactional database gate:

```bash
pnpm db:start
docker exec -i supabase_db_daypage psql -U postgres -d postgres \
  < web/scripts/verify-agent-data-plane.sql
```

The verifier rolls back its synthetic tenants. It checks memo-trigger exactly-once
behavior, no compile-metadata feedback loop, canonical Run uniqueness, provenance span
constraints, cross-tenant RLS, optimistic page locking, and authenticated Daily/Weekly
request RPCs.

Focused code gates:

```bash
pnpm --filter daypage-web typecheck
pnpm --filter daypage-mcp-server typecheck
pnpm --filter daypage-web exec vitest run src/lib/agent-data-plane/__tests__
swift test --package-path DayPageKit
xcodebuild -project DayPage.xcodeproj -scheme DayPage -configuration Debug \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

The repository's broader `pnpm backend:verify:local` remains the release gate because it
also exercises raw Native sync, attachments, two-Vault pull, RLS, OAuth/PAT, and MCP.

## Worker and scheduling

`agent-data-plane-worker` is both a one-minute cron and an event-triggered Inngest
function. Each tick:

1. atomically enqueues due schedule rows and advances their next occurrence;
2. claims at most 20 due Agent jobs with a ten-minute crash-recovery lease;
3. runs memo understanding, delete compensation, Daily, Weekly, or scheduled dispatch;
4. claims at most 10 approved tool executions;
5. marks retryable failures with bounded exponential delay and terminal failures dead.
6. drains bounded, leased Agent trace and feedback-score projections to the configured
   evaluation provider without making provider availability part of Run correctness.

Default Automations are a 180-second living-Daily debounce, Daily finalization at 04:00
local time for the prior date, and a Monday 09:00 local review of the prior ISO week.
They are provisioned on the user's first Agent event or Automation API read, rather than
by scanning every user each minute.
Changing a user's timezone affects subsequent calculated occurrences; it never rewrites
historical Run snapshots.

## Useful diagnostics

Run these with an authorized operations role, always scoped to a tenant when inspecting
user-level data:

```sql
select type, status, count(*)
from gateway_jobs
where created_at > now() - interval '24 hours'
group by type, status
order by type, status;

select status, count(*),
       percentile_cont(0.95) within group (
         order by extract(epoch from (completed_at - started_at)) * 1000
       ) as p95_ms
from agent_runs
where created_at > now() - interval '24 hours'
group by status;

select tool_key, status, count(*), max(attempts) as max_attempts
from tool_execution_outbox
where created_at > now() - interval '24 hours'
group by tool_key, status;
```

Do not include memo bodies, prompts, credentials, or artifact payloads in routine logs.
Run detail APIs are the authorized user-facing audit surface.

## External tool gateway

External writes are unavailable unless both `DAYPAGE_TOOL_EXECUTOR_URL` and
`DAYPAGE_TOOL_EXECUTOR_SECRET` are set. The URL must be HTTPS outside loopback. Approval
fails before changing Work Order state when no executor is configured, no user
connection is bound, the connection is revoked, or required scopes are absent.
Direct authenticated database clients have read-only access to connection, binding,
Automation, and Work Order rows; lifecycle writes must pass through tenant-derived
backend APIs.

The gateway receives the tool key, bounded arguments, user/connection IDs, opaque
`auth_ref`, and an `Idempotency-Key` header. It resolves credentials outside the Agent
data plane and must return a JSON receipt. DayPage rechecks approval and connection
state immediately before execution, scrubs credential-shaped receipt fields, and only
retries tools on the explicit safe-retry allowlist.

## Promotion checklist

Promote `shadow` to `primary` only after:

- shadow/current output parity is reviewed on synthetic and opt-in accounts;
- invalid-output, source-span, latency, token-cost, and dead-job rates meet the design
  acceptance thresholds;
- Daily timezone, DST, finalization, deletion, and late-arrival fixtures pass;
- page conflicts preserve concurrent content and surface `needs_review`;
- Native cache reads are proven on a signed-in TestFlight build;
- every enabled external tool has revoke, scope, provider-idempotency, uncertain-failure,
  and receipt tests;
- rollback has been rehearsed without deleting artifacts or pending raw sync state.

## Rollback

1. Set the server mode back to `shadow` or `off`.
2. Re-enable the legacy compiler override only if the selected mode does not already do
   so.
3. Disable affected Automations or connector definitions; do not delete their history.
4. Turn off Native `backendFirstIntelligence`; the original raw Vault and prior legacy
   wiki files remain present.
5. Leave additive schema, Runs, Artifacts, Work Orders, outbox rows, and receipts intact
   until a separately reviewed retention/cleanup operation.

An external action with a success receipt cannot be undone by rolling back Postgres.
Show the receipt and use a connector-specific compensating action when one exists.
