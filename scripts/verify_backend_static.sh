#!/usr/bin/env bash

# Fast, hermetic checks for contracts and request handlers owned by the backend.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

pnpm contracts:test
pnpm --filter daypage-web typecheck
pnpm --filter daypage-mcp-server typecheck
pnpm --filter daypage-mcp-server test
pnpm --filter daypage-mcp-server build:edge
pnpm --filter daypage-web exec vitest run \
    src/lib/auth/__tests__/safe-next.test.ts \
    src/lib/oauth/__tests__/form-origin.test.ts \
    src/lib/oauth/__tests__/consent.test.ts \
    src/lib/__tests__/api-auth.test.ts \
    src/app/api/memos/__tests__/route.test.ts \
    src/app/api/memos/bulk/__tests__/route.test.ts \
    src/app/api/mcp/__tests__/mcp.test.ts

test -f web/drizzle/migrations/0030_system_actions.sql
test -f web/scripts/verify-system-actions.sql
rg -q 'REVOKE ALL ON public\.sync_operations FROM PUBLIC, anon, authenticated' \
    web/drizzle/migrations/0030_system_actions.sql
rg -q 'daypage_apply_system_action_operations_v1' web/drizzle/migrations/0030_system_actions.sql
rg -q 'daypage_pull_system_action_changes_v1' web/drizzle/migrations/0030_system_actions.sql
rg -q 'daypage_claim_system_action_execution_v1' web/drizzle/migrations/0030_system_actions.sql
rg -q "'status', 'attempt_completed'" web/drizzle/migrations/0030_system_actions.sql
rg -q "target device is not eligible for this proposal" web/drizzle/migrations/0030_system_actions.sql
rg -q "target_device_preference' IS DISTINCT FROM 'any'" web/drizzle/migrations/0030_system_actions.sql
rg -q 'daypage_mcp_propose_system_action_v1' web/drizzle/migrations/0030_system_actions.sql
rg -q 'daypage_mcp_list_system_action_proposals_v1' web/drizzle/migrations/0030_system_actions.sql
rg -q 'daypage_mcp_list_system_action_receipts_v1' web/drizzle/migrations/0030_system_actions.sql
rg -q 'daypage_system_action_payload_hash_v1' web/drizzle/migrations/0030_system_actions.sql
rg -q 'daypage_system_action_cloud_policy_allows_v1' web/drizzle/migrations/0030_system_actions.sql
rg -q "redaction_level' IS DISTINCT FROM 'private'" web/drizzle/migrations/0030_system_actions.sql
rg -q 'non-creator device claimed a creating-device proposal' web/scripts/verify-system-actions.sql
rg -q 'non-target device claimed a specific-device proposal' web/scripts/verify-system-actions.sql
rg -q 'any-device proposal denied another owned device' web/scripts/verify-system-actions.sql
rg -q 'zero-capability local-only proposal reached cloud' web/scripts/verify-system-actions.sql
rg -q 'OAuth reconnect silently preserved an old action grant' web/scripts/verify-system-actions.sql
rg -q 'legacy admin PAT silently enabled actions' web/scripts/verify-system-actions.sql
rg -q 'PAT proposal projection emitted noncanonical timestamps' web/scripts/verify-system-actions.sql
rg -q 'PAT receipt projection emitted noncanonical timestamps' web/scripts/verify-system-actions.sql
if rg -q "actions:read' OR v_scopes \? 'admin|actions:propose' OR v_scopes \? 'admin" \
    web/drizzle/migrations/0030_system_actions.sql; then
    echo 'Legacy admin PAT scope must not imply system-action authority' >&2
    exit 1
fi
rg -q 'attempt-2 receipt did not retain proposal revision 1' web/scripts/verify-system-actions.sql
rg -q 'exact ambiguous-attempt retry resurrected its released lease' web/scripts/verify-system-actions.sql
rg -q 'released winning lease became executable on exact retry' web/scripts/verify-system-actions-concurrency.sh
rg -q 'Expired unreceipted lease was reassigned to a competing device' web/scripts/verify-system-actions-concurrency.sh
rg -q 'proposal revision changed after execution evidence existed' web/scripts/verify-system-actions.sql
rg -q 'same-operation expired execution lease became executable' web/scripts/verify-system-actions.sql
