#!/usr/bin/env bash

# Exercise the real local-first backend path against the local Supabase stack:
# Vault/outbox -> revisioned push -> multi-device pull -> PAT-authenticated MCP.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DB_CONTAINER="${DAYPAGE_DB_CONTAINER:-supabase_db_daypage}"
SUPABASE_WORKDIR="${DAYPAGE_SUPABASE_WORKDIR:-${REPO_ROOT}}"
LOCAL_USER_ID=""
LOCAL_ACCESS_TOKEN=""
LOCAL_API_URL=""
LOCAL_SERVICE_ROLE_KEY=""
LOCAL_PROBE_DIR=""

cleanup() {
    if [[ -n "${LOCAL_PROBE_DIR}" && -d "${LOCAL_PROBE_DIR}" ]]; then
        rm -f "${LOCAL_PROBE_DIR}/probe.png" "${LOCAL_PROBE_DIR}/response.json"
        rmdir "${LOCAL_PROBE_DIR}" 2>/dev/null || true
    fi
    if [[ "${LOCAL_USER_ID}" =~ ^[0-9a-f-]{36}$ ]]; then
        if [[ -n "${LOCAL_API_URL}" && -n "${LOCAL_SERVICE_ROLE_KEY}" ]]; then
            LOCAL_OBJECTS="$({
                docker exec "${DB_CONTAINER}" psql -U postgres -d postgres -At \
                    -c "SELECT name FROM storage.objects WHERE bucket_id = 'memo-attachments' AND name LIKE '${LOCAL_USER_ID}/%';"
            } 2>/dev/null || true)"
            while IFS= read -r object_key; do
                [[ -n "${object_key}" ]] || continue
                curl -fsS -X DELETE "${LOCAL_API_URL}/storage/v1/object/memo-attachments" \
                    -H "apikey: ${LOCAL_SERVICE_ROLE_KEY}" \
                    -H "Authorization: Bearer ${LOCAL_SERVICE_ROLE_KEY}" \
                    -H 'content-type: application/json' \
                    --data "$(jq -nc --arg key "${object_key}" '{prefixes: [$key]}')" \
                    >/dev/null 2>&1 || true
            done <<< "${LOCAL_OBJECTS}"
        fi
        docker exec "${DB_CONTAINER}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
            -c "DELETE FROM public.users WHERE id = '${LOCAL_USER_ID}'::uuid; DELETE FROM auth.users WHERE id = '${LOCAL_USER_ID}'::uuid;" \
            >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

for command in curl docker jq openssl pnpm swift; do
    if ! command -v "${command}" >/dev/null 2>&1; then
        echo "Missing required command: ${command}" >&2
        exit 127
    fi
done

cd "${REPO_ROOT}"
LOCAL_STATUS_JSON="$(pnpm exec supabase status --workdir "${SUPABASE_WORKDIR}" -o json 2>/dev/null)"
LOCAL_API_URL="$(printf '%s' "${LOCAL_STATUS_JSON}" | jq -er '.API_URL')"
LOCAL_PUBLISHABLE_KEY="$(printf '%s' "${LOCAL_STATUS_JSON}" | jq -er '.PUBLISHABLE_KEY')"
LOCAL_SERVICE_ROLE_KEY="$(printf '%s' "${LOCAL_STATUS_JSON}" | jq -er '.SERVICE_ROLE_KEY')"
LOCAL_TEST_EMAIL="daypage-e2e-$(date +%s)-${RANDOM}@example.invalid"
LOCAL_TEST_PASSWORD="LocalOnly-$(openssl rand -hex 16)!"
LOCAL_SYNC_MARKER="DAYPAGE_LOCAL_BACKEND_E2E_$(date -u +%Y%m%dT%H%M%SZ)_${RANDOM}"
LOCAL_MCP_URL="${LOCAL_API_URL}/functions/v1/daypage-mcp"

# Transactional database security regression: receipt tuple binding, stale
# revisions, tombstones, monotonic pull, tenant isolation, and token hook.
docker exec -i "${DB_CONTAINER}" psql -U postgres -d postgres \
    < web/scripts/verify-system-actions.sql
bash web/scripts/verify-system-actions-concurrency.sh
docker exec -i "${DB_CONTAINER}" psql -U postgres -d postgres \
    < web/scripts/verify-local-first-sync.sql
docker exec -i "${DB_CONTAINER}" psql -U postgres -d postgres \
    < web/scripts/verify-agent-data-plane.sql
docker exec -i "${DB_CONTAINER}" psql -U postgres -d postgres \
    < web/scripts/verify-agent-evaluation.sql

curl -fsS "${LOCAL_MCP_URL}/healthz" \
    | jq -e '.status == "ok" and .runtime == "supabase-edge"' >/dev/null
curl -fsS "${LOCAL_MCP_URL}/.well-known/oauth-protected-resource" \
    | jq -e --arg resource "${LOCAL_MCP_URL}" \
        '.resource == $resource and .authorization_servers == ["http://127.0.0.1:54321/auth/v1"]' \
        >/dev/null
curl -fsS "${LOCAL_API_URL}/functions/v1/daypage-oauth/docs/mcp" \
    | jq -e --arg resource "${LOCAL_MCP_URL}" \
        '.resource == $resource and .authorization_ui == "http://127.0.0.1:13000/oauth/consent"' \
        >/dev/null
LOCAL_UNAUTH_HEADERS="$(
    curl -sS -o /dev/null -D - -X POST \
        -H 'content-type: application/json' \
        --data '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
        "${LOCAL_MCP_URL}"
)"
printf '%s' "${LOCAL_UNAUTH_HEADERS}" | grep -Eq '^HTTP/[^ ]+ 401 '
printf '%s' "${LOCAL_UNAUTH_HEADERS}" | grep -Eiq '^www-authenticate: Bearer .*resource_metadata='

LOCAL_SIGNUP_BODY="$(
    jq -nc \
        --arg email "${LOCAL_TEST_EMAIL}" \
        --arg password "${LOCAL_TEST_PASSWORD}" \
        '{email: $email, password: $password}'
)"
LOCAL_SIGNUP_RESPONSE="$(
    curl -fsS -X POST "${LOCAL_API_URL}/auth/v1/signup" \
        -H "apikey: ${LOCAL_PUBLISHABLE_KEY}" \
        -H 'content-type: application/json' \
        --data "${LOCAL_SIGNUP_BODY}"
)"
LOCAL_USER_ID="$(printf '%s' "${LOCAL_SIGNUP_RESPONSE}" | jq -er '.user.id')"
LOCAL_ACCESS_TOKEN="$(printf '%s' "${LOCAL_SIGNUP_RESPONSE}" | jq -er '.access_token')"
if [[ ! "${LOCAL_USER_ID}" =~ ^[0-9a-f-]{36}$ ]]; then
    echo "Local Auth returned an invalid user ID" >&2
    exit 1
fi

# Real Storage RLS negatives: an owner prefix alone is insufficient, and a
# reservation cannot be replayed for a different memo or tenant path.
LOCAL_PROBE_DIR="$(mktemp -d)"
printf '\211PNG\r\n\032\n' > "${LOCAL_PROBE_DIR}/probe.png"
LOCAL_PROBE_HASH="$(shasum -a 256 "${LOCAL_PROBE_DIR}/probe.png" | awk '{print $1}')"
LOCAL_PROBE_MEMO="77777777-7777-4777-8777-777777777777"
storage_probe_status() {
    local object_key="$1"
    curl -sS -o "${LOCAL_PROBE_DIR}/response.json" -w '%{http_code}' -X POST \
        "${LOCAL_API_URL}/storage/v1/object/memo-attachments/${object_key}" \
        -H "apikey: ${LOCAL_PUBLISHABLE_KEY}" \
        -H "Authorization: Bearer ${LOCAL_ACCESS_TOKEN}" \
        -H 'content-type: image/png' \
        -H 'x-upsert: false' \
        --data-binary "@${LOCAL_PROBE_DIR}/probe.png"
}
LOCAL_UNRESERVED_STATUS="$(storage_probe_status "${LOCAL_USER_ID}/${LOCAL_PROBE_MEMO}/${LOCAL_PROBE_HASH}.png")"
if [[ "${LOCAL_UNRESERVED_STATUS}" =~ ^2 ]]; then
    echo "Storage accepted an upload without an exact reservation" >&2
    exit 1
fi
curl -fsS -X POST "${LOCAL_API_URL}/rest/v1/rpc/daypage_prepare_attachment_upload" \
    -H "apikey: ${LOCAL_PUBLISHABLE_KEY}" \
    -H "Authorization: Bearer ${LOCAL_ACCESS_TOKEN}" \
    -H 'content-type: application/json' \
    --data "$(jq -nc \
        --arg memo "${LOCAL_PROBE_MEMO}" \
        --arg hash "${LOCAL_PROBE_HASH}" \
        '{p_memo_id:$memo,p_content_sha256:$hash,p_size_bytes:8,p_mime_type:"image/png",p_extension:"png"}')" \
    >/dev/null
LOCAL_WRONG_MEMO_STATUS="$(storage_probe_status "${LOCAL_USER_ID}/88888888-8888-4888-8888-888888888888/${LOCAL_PROBE_HASH}.png")"
LOCAL_CROSS_TENANT_STATUS="$(storage_probe_status "22222222-2222-4222-8222-222222222222/${LOCAL_PROBE_MEMO}/${LOCAL_PROBE_HASH}.png")"
if [[ "${LOCAL_WRONG_MEMO_STATUS}" =~ ^2 || "${LOCAL_CROSS_TENANT_STATUS}" =~ ^2 ]]; then
    echo "Storage reservation escaped its exact memo or tenant path" >&2
    exit 1
fi

SYNC_ENV=(
    "DAYPAGE_SYNC_E2E_URL=${LOCAL_API_URL}"
    "DAYPAGE_SYNC_E2E_PUBLISHABLE_KEY=${LOCAL_PUBLISHABLE_KEY}"
    "DAYPAGE_SYNC_E2E_EMAIL=${LOCAL_TEST_EMAIL}"
    "DAYPAGE_SYNC_E2E_PASSWORD=${LOCAL_TEST_PASSWORD}"
)

env "${SYNC_ENV[@]}" \
    "DAYPAGE_SYNC_E2E_MARKER=${LOCAL_SYNC_MARKER}" \
    swift test --package-path DayPageKit --filter SupabaseSyncLiveTests

env "${SYNC_ENV[@]}" \
    swift test --package-path DayPageKit --filter SupabaseMultiDeviceLiveTests

LOCAL_GC_SECRET="$(sed -n 's/^DAYPAGE_ATTACHMENT_GC_SECRET=//p' supabase/functions/.env | tail -1)"
if [[ -z "${LOCAL_GC_SECRET}" ]]; then
    echo "Missing local attachment GC secret" >&2
    exit 1
fi
docker exec "${DB_CONTAINER}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
    -c "UPDATE public.attachment_gc_queue SET not_before = now() WHERE user_id = '${LOCAL_USER_ID}'::uuid AND status = 'pending';" \
    >/dev/null
LOCAL_GC_EXPECTED="$(docker exec "${DB_CONTAINER}" psql -U postgres -d postgres -At -c \
    "SELECT count(*) FROM storage.objects WHERE bucket_id = 'memo-attachments' AND name LIKE '${LOCAL_USER_ID}/%';")"
if (( LOCAL_GC_EXPECTED < 3 )); then
    echo "Expected JPEG, M4A, and resumed PDF objects before GC" >&2
    exit 1
fi
LOCAL_GC_RESULT="$({
    curl -fsS -X POST "${LOCAL_API_URL}/functions/v1/daypage-attachment-gc" \
        -H "Authorization: Bearer ${LOCAL_GC_SECRET}" \
        -H 'x-daypage-gc-limit: 10'
})"
printf '%s' "${LOCAL_GC_RESULT}" | jq -e \
    --argjson expected "${LOCAL_GC_EXPECTED}" \
    '.claimed == $expected and .deleted == $expected and .retried == 0' >/dev/null
LOCAL_GC_COUNTS="$(docker exec "${DB_CONTAINER}" psql -U postgres -d postgres -At -c \
    "SELECT count(*) FILTER (WHERE status <> 'deleted') || ':' || count(*) FROM public.attachment_gc_queue WHERE user_id = '${LOCAL_USER_ID}'::uuid; SELECT count(*) FROM storage.objects WHERE bucket_id = 'memo-attachments' AND name LIKE '${LOCAL_USER_ID}/%';")"
if [[ "${LOCAL_GC_COUNTS}" != "0:${LOCAL_GC_EXPECTED}"$'\n0' ]]; then
    echo "Attachment GC did not converge synthetic rows and objects" >&2
    exit 1
fi

# The MCP proposal surface is independently default-off at both the credential
# and per-capability policy layers. Enable the synthetic user's Focus policy
# through the same authenticated native RPC used by a device before testing
# that an actions-scoped PAT can propose (but never approve or execute).
LOCAL_POLICY_ID="77777777-7777-4777-8777-777777777779"
LOCAL_POLICY_OPERATION_ID="77777777-7777-4777-8777-777777777780"
LOCAL_POLICY_TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%S).000Z"
LOCAL_POLICY_RESULT="$({
    curl -fsS -X POST "${LOCAL_API_URL}/rest/v1/rpc/daypage_apply_system_action_operations_v1" \
        -H "apikey: ${LOCAL_PUBLISHABLE_KEY}" \
        -H "Authorization: Bearer ${LOCAL_ACCESS_TOKEN}" \
        -H 'content-type: application/json' \
        --data "$(jq -nc \
            --arg operation_id "${LOCAL_POLICY_OPERATION_ID}" \
            --arg policy_id "${LOCAL_POLICY_ID}" \
            --arg updated_at "${LOCAL_POLICY_TIMESTAMP}" \
            '{p_operations:[{protocol_version:1,operation_id:$operation_id,entity_type:"policy",entity_id:$policy_id,operation_kind:"upsert",revision:1,record:{schema_version:1,policy_id:$policy_id,capability:"focus",revision:1,is_offered:true,sync_enabled:true,disclosure_level:"full_proposal",updated_at:$updated_at,deleted_at:null}}]}')"
})"
printf '%s' "${LOCAL_POLICY_RESULT}" | jq -e \
    '.rejected == [] and .accepted[0].status == "applied" and .accepted[0].record.capability == "focus"' \
    >/dev/null

LOCAL_PAT="dpg_dev_$(openssl rand -base64 48 | tr '+/' '_-' | tr -d '=\n')"
LOCAL_PAT_HASH="$(printf '%s' "${LOCAL_PAT}" | shasum -a 256 | awk '{print $1}')"
LOCAL_PAT_PREFIX="$(printf '%s' "${LOCAL_PAT}" | cut -c1-16)"
docker exec "${DB_CONTAINER}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -c \
    "INSERT INTO public.api_keys (user_id, name, key_hash, key_prefix, scopes) VALUES ('${LOCAL_USER_ID}'::uuid, 'local backend e2e', '${LOCAL_PAT_HASH}', '${LOCAL_PAT_PREFIX}', '[\"read\",\"write\",\"actions:read\",\"actions:propose\"]'::jsonb);" \
    >/dev/null

env \
    "DAYPAGE_MCP_E2E_URL=${LOCAL_MCP_URL}" \
    "DAYPAGE_MCP_E2E_KEY=${LOCAL_PAT}" \
    "DAYPAGE_MCP_E2E_MAC_MARKER=${LOCAL_SYNC_MARKER}" \
    "DAYPAGE_MCP_E2E_AGENT_MARKER=DAYPAGE_LOCAL_MCP_WRITE_$(date -u +%Y%m%dT%H%M%SZ)_${RANDOM}" \
    pnpm --filter daypage-mcp-server test:live

echo "Local backend acceptance passed: native text/media sync, two-Vault pull, system actions, and MCP read/write/propose."
