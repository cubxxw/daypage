#!/usr/bin/env bash

# Real two-session execution-claim race. All rows use a dedicated synthetic
# tenant and are removed on exit; no migration or existing tenant state changes.

set -euo pipefail

DB_CONTAINER="${DAYPAGE_DB_CONTAINER:-supabase_db_daypage}"
VERIFY_DIR="$(mktemp -d)"
VERIFY_USER="9f000000-0000-4f00-8f00-000000000001"
VERIFY_PROPOSAL="9f000000-0000-4f00-8f00-000000000002"
VERIFY_HASH="a23d62ca3f59c48f8dc75e3eec687990f0fb43623de294bfb6fbe60b7d2f61f0"

cleanup() {
  docker exec "${DB_CONTAINER}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
    -c "DELETE FROM public.users WHERE id = '${VERIFY_USER}'::uuid; DELETE FROM auth.users WHERE id = '${VERIFY_USER}'::uuid;" \
    >/dev/null 2>&1 || true
  rm -f "${VERIFY_DIR}/claim-a" "${VERIFY_DIR}/claim-b"
  rmdir "${VERIFY_DIR}" 2>/dev/null || true
}
trap cleanup EXIT

docker exec -i "${DB_CONTAINER}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 >/dev/null <<SQL
INSERT INTO auth.users (id, email, aud, role, created_at, updated_at, raw_user_meta_data)
VALUES ('${VERIFY_USER}', 'actions-race@daypage.test', 'authenticated', 'authenticated', now(), now(), '{}'::jsonb);
INSERT INTO public.system_action_capability_policies (
  user_id, policy_id, capability, revision, is_offered, sync_enabled,
  disclosure_level, updated_at
) VALUES (
  '${VERIFY_USER}', '9f000000-0000-4f00-8f00-000000000003',
  'calendar', 1, true, true, 'full_proposal', now()
);
INSERT INTO public.system_action_proposals (
  user_id, proposal_id, revision, kind, payload, payload_hash, title,
  rationale, source_refs, creator_source, creator_device_id_hash,
  redaction_level, target_device_preference, target_device_id_hash,
  state, expires_at
) VALUES (
  '${VERIFY_USER}', '${VERIFY_PROPOSAL}', 1, 'calendar_event',
  '{"kind":"calendar_event","title":"Verifier event","start_at":"2026-08-27T01:00:00.000Z","end_at":"2026-08-27T01:30:00.000Z","all_day":false,"time_zone":"Asia/Shanghai","location_label":null,"notes":null}'::jsonb,
  '${VERIFY_HASH}', 'Concurrent verifier event', '', '[]'::jsonb,
  'native', repeat('b', 64), 'private', 'any', NULL, 'approved', now() + interval '1 day'
);
INSERT INTO public.system_action_approvals (
  user_id, approval_id, proposal_id, phase, proposal_revision, payload_hash,
  decision, device_id_hash, decided_at
) VALUES (
  '${VERIFY_USER}', '9f000000-0000-4f00-8f00-000000000004', '${VERIFY_PROPOSAL}',
  'execute', 1, '${VERIFY_HASH}', 'approve', repeat('b', 64), now()
);
SQL

claim() {
  local operation_id="$1"
  local device_character="$2"
  local output_file="$3"
  docker exec -i "${DB_CONTAINER}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -At >"${output_file}" <<SQL
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '${VERIFY_USER}', true);
SELECT set_config('request.jwt.claims', '{"sub":"${VERIFY_USER}","role":"authenticated"}', true);
SELECT public.daypage_claim_system_action_execution_v1(
  '${operation_id}', '${VERIFY_PROPOSAL}', 'execute', 1, '${VERIFY_HASH}',
  repeat('${device_character}', 64), 120
) ->> 'status';
COMMIT;
SQL
}

claim '9f000000-0000-4f00-8f00-000000000005' b "${VERIFY_DIR}/claim-a" &
claim_a_pid=$!
claim '9f000000-0000-4f00-8f00-000000000006' c "${VERIFY_DIR}/claim-b" &
claim_b_pid=$!
wait "${claim_a_pid}"
wait "${claim_b_pid}"

statuses="$(sort "${VERIFY_DIR}/claim-a" "${VERIFY_DIR}/claim-b" | grep -E '^(busy|claimed)$' | tr '\n' ' ')"
if [[ "${statuses}" != "busy claimed " ]]; then
  echo "Concurrent action claims did not produce exactly one winner and one busy result: ${statuses}" >&2
  exit 1
fi

WINNING_CLAIM="$({
  docker exec "${DB_CONTAINER}" psql -U postgres -d postgres -At -v ON_ERROR_STOP=1 \
    -c "SELECT claim_operation_id::text || '|' || lease_id::text || '|' || device_id_hash || '|' || public.daypage_system_action_timestamp_text_v1(created_at) FROM public.system_action_execution_leases WHERE user_id = '${VERIFY_USER}'::uuid AND proposal_id = '${VERIFY_PROPOSAL}'::uuid AND phase = 'execute' AND released_at IS NULL;"
})"
IFS='|' read -r WINNING_OPERATION WINNING_LEASE WINNING_DEVICE_HASH WINNING_ISSUED_AT <<<"${WINNING_CLAIM}"
if [[ -z "${WINNING_OPERATION}" || -z "${WINNING_LEASE}" || -z "${WINNING_DEVICE_HASH}" || -z "${WINNING_ISSUED_AT}" ]]; then
  echo "Concurrent verifier could not identify the winning lease" >&2
  exit 1
fi

docker exec "${DB_CONTAINER}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
  -c "UPDATE public.system_action_execution_leases SET created_at = date_trunc('milliseconds', now() - interval '2 seconds'), expires_at = date_trunc('milliseconds', now() - interval '1 second') WHERE user_id = '${VERIFY_USER}'::uuid AND lease_id = '${WINNING_LEASE}'::uuid;" \
  >/dev/null
WINNING_ISSUED_AT="$({
  docker exec "${DB_CONTAINER}" psql -U postgres -d postgres -At -v ON_ERROR_STOP=1 \
    -c "SELECT public.daypage_system_action_timestamp_text_v1(created_at) FROM public.system_action_execution_leases WHERE user_id = '${VERIFY_USER}'::uuid AND lease_id = '${WINNING_LEASE}'::uuid;"
})"
claim '9f000000-0000-4f00-8f00-00000000000b' d "${VERIFY_DIR}/claim-a"
if [[ "$(grep -E '^(busy|claimed)$' "${VERIFY_DIR}/claim-a")" != "busy" ]]; then
  echo "Expired unreceipted lease was reassigned to a competing device" >&2
  exit 1
fi

docker exec -i "${DB_CONTAINER}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 >/dev/null <<SQL
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '${VERIFY_USER}', true);
SELECT set_config('request.jwt.claims', '{"sub":"${VERIFY_USER}","role":"authenticated"}', true);
DO \$\$
DECLARE
  receipt_result jsonb;
  terminal_retry jsonb;
  receipt_time text;
BEGIN
  receipt_time := '${WINNING_ISSUED_AT}';
  receipt_result := public.daypage_apply_system_action_operations_v1(jsonb_build_array(jsonb_build_object(
    'protocol_version', 1,
    'operation_id', '9f000000-0000-4f00-8f00-000000000009',
    'entity_type', 'receipt',
    'entity_id', '9f000000-0000-4f00-8f00-00000000000a',
    'operation_kind', 'append', 'revision', 1,
    'record', jsonb_build_object(
      'schema_version', 1,
      'receipt_id', '9f000000-0000-4f00-8f00-00000000000a',
      'proposal_id', '${VERIFY_PROPOSAL}', 'phase', 'execute',
      'proposal_revision', 1, 'payload_hash', '${VERIFY_HASH}', 'attempt', 1,
      'outcome', 'failed', 'device_id_hash', '${WINNING_DEVICE_HASH}',
      'execution_mode', 'online_lease', 'lease_id', '${WINNING_LEASE}',
      'result', jsonb_build_object('summary', 'Synthetic pre-effect failure'),
      'error_code', 'synthetic_failure', 'reconciliation_state', 'not_applicable',
      'undo_capability', 'none', 'external_id_hash', NULL,
      'started_at', receipt_time, 'completed_at', receipt_time
    )
  )));
  IF receipt_result #>> '{accepted,0,status}' IS DISTINCT FROM 'applied' THEN
    RAISE EXCEPTION 'concurrency verifier failed receipt apply: %', receipt_result;
  END IF;
  terminal_retry := public.daypage_claim_system_action_execution_v1(
    '${WINNING_OPERATION}', '${VERIFY_PROPOSAL}', 'execute', 1, '${VERIFY_HASH}',
    '${WINNING_DEVICE_HASH}', 120
  );
  IF terminal_retry ->> 'status' IS DISTINCT FROM 'attempt_completed'
    OR terminal_retry ->> 'lease_id' IS NOT NULL
    OR terminal_retry ->> 'receipt_id' IS DISTINCT FROM '9f000000-0000-4f00-8f00-00000000000a' THEN
    RAISE EXCEPTION 'released winning lease became executable on exact retry: %', terminal_retry;
  END IF;
END
\$\$;
COMMIT;
SQL

claim '9f000000-0000-4f00-8f00-000000000007' b "${VERIFY_DIR}/claim-a" &
retry_a_pid=$!
claim '9f000000-0000-4f00-8f00-000000000008' b "${VERIFY_DIR}/claim-b" &
retry_b_pid=$!
wait "${retry_a_pid}"
wait "${retry_b_pid}"

retry_statuses="$(sort "${VERIFY_DIR}/claim-a" "${VERIFY_DIR}/claim-b" | grep -E '^(busy|claimed)$' | tr '\n' ' ')"
if [[ "${retry_statuses}" != "busy claimed " ]]; then
  echo "Fresh retry claims after a failed release did not produce one winner: ${retry_statuses}" >&2
  exit 1
fi

echo "Concurrent system action claim and terminal-retry verification passed"
