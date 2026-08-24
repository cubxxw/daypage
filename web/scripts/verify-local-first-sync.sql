\set ON_ERROR_STOP on

BEGIN;

INSERT INTO auth.users (
  id, email, aud, role, created_at, updated_at, raw_user_meta_data
)
VALUES
  (
    '11111111-1111-4111-8111-111111111111', 'sync-a@daypage.test',
    'authenticated', 'authenticated', now(), now(), '{}'::jsonb
  ),
  (
    '22222222-2222-4222-8222-222222222222', 'sync-b@daypage.test',
    'authenticated', 'authenticated', now(), now(), '{}'::jsonb
  );

DO $$
BEGIN
  IF (SELECT count(*) FROM public.users WHERE id IN (
    '11111111-1111-4111-8111-111111111111',
    '22222222-2222-4222-8222-222222222222'
  )) <> 2 THEN
    RAISE EXCEPTION 'auth profile trigger did not create both users';
  END IF;
  IF has_table_privilege('authenticated', 'public.daypage_runtime_config', 'SELECT') THEN
    RAISE EXCEPTION 'runtime config must not be readable by authenticated';
  END IF;
END
$$;

UPDATE public.daypage_runtime_config
SET value = 'https://mcp.staging.daypage.test/mcp'
WHERE key = 'mcp_resource';

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-111111111111', true);

DO $$
DECLARE
  result jsonb;
BEGIN
  result := public.daypage_apply_sync_operations(jsonb_build_array(jsonb_build_object(
    'operation_id', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1',
    'memo_id', '33333333-3333-4333-8333-333333333333',
    'kind', 'upsert',
    'revision', 1,
    'modified_at', '2026-08-24T00:00:00Z',
    'content_hash', 'hash-v1',
    'device_id', '44444444-4444-4444-8444-444444444444',
    'payload', jsonb_build_object(
      'type', 'text',
      'body', 'DAYPAGE_SYNC_DB_TEST_20260824',
      'created_at', '2026-08-24T00:00:00Z',
      'source', 'ios',
      'vault_path', 'raw/2026-08-24.md'
    )
  )));
  IF result #>> '{accepted,0,status}' <> 'applied' THEN
    RAISE EXCEPTION 'first revision was not applied: %', result;
  END IF;

  result := public.daypage_apply_sync_operations(jsonb_build_array(jsonb_build_object(
    'operation_id', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1',
    'memo_id', '33333333-3333-4333-8333-333333333333',
    'kind', 'upsert',
    'revision', 1,
    'modified_at', '2026-08-24T00:00:00Z'
  )));
  IF result #>> '{accepted,0,status}' <> 'applied' THEN
    RAISE EXCEPTION 'idempotent retry lost its receipt: %', result;
  END IF;

  result := public.daypage_apply_sync_operations(jsonb_build_array(jsonb_build_object(
    'operation_id', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2',
    'memo_id', '33333333-3333-4333-8333-333333333333',
    'kind', 'upsert',
    'revision', 1,
    'modified_at', '2026-08-24T00:00:01Z',
    'payload', jsonb_build_object('body', 'must not overwrite')
  )));
  IF result #>> '{accepted,0,status}' <> 'stale' THEN
    RAISE EXCEPTION 'equal revision was not rejected as stale: %', result;
  END IF;

  INSERT INTO public.mcp_client_grants (user_id, client_id, can_read, can_write)
  VALUES (auth.uid(), 'codex-staging-test', true, false);
END
$$;

RESET ROLE;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '22222222-2222-4222-8222-222222222222', true);

DO $$
BEGIN
  IF (SELECT count(*) FROM public.memos) <> 0 THEN
    RAISE EXCEPTION 'tenant B can read tenant A memos';
  END IF;
  IF (SELECT count(*) FROM public.mcp_client_grants) <> 0 THEN
    RAISE EXCEPTION 'tenant B can read tenant A MCP grant';
  END IF;
  IF jsonb_array_length(
    public.daypage_pull_sync_changes(0, 200) -> 'changes'
  ) <> 0 THEN
    RAISE EXCEPTION 'tenant B pulled tenant A sync changes';
  END IF;
  BEGIN
    INSERT INTO public.memos (id, user_id, body)
    VALUES (
      '55555555-5555-4555-8555-555555555555',
      '11111111-1111-4111-8111-111111111111',
      'cross-tenant write must fail'
    );
    RAISE EXCEPTION 'tenant B inserted a tenant A memo';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
END
$$;

RESET ROLE;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-111111111111', true);

DO $$
DECLARE
  result jsonb;
  pulled jsonb;
  cursor_value bigint;
BEGIN
  result := public.daypage_apply_sync_operations(jsonb_build_array(jsonb_build_object(
    'operation_id', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa3',
    'memo_id', '33333333-3333-4333-8333-333333333333',
    'kind', 'delete',
    'revision', 2,
    'modified_at', '2026-08-24T00:00:02Z',
    'device_id', '44444444-4444-4444-8444-444444444444'
  )));
  IF result #>> '{accepted,0,status}' <> 'applied' THEN
    RAISE EXCEPTION 'delete tombstone was not applied: %', result;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.memos
    WHERE id = '33333333-3333-4333-8333-333333333333'
      AND deleted_at IS NOT NULL
      AND sync_revision = 2
  ) THEN
    RAISE EXCEPTION 'delete did not retain a revisioned tombstone';
  END IF;

  pulled := public.daypage_pull_sync_changes(0, 200);
  IF NOT EXISTS (
    SELECT 1
    FROM jsonb_array_elements(pulled -> 'changes') AS pulled_change(value)
    WHERE pulled_change.value ->> 'id' = '33333333-3333-4333-8333-333333333333'
      AND pulled_change.value ->> 'deleted_at' IS NOT NULL
      AND (pulled_change.value ->> 'sync_revision')::bigint = 2
  ) THEN
    RAISE EXCEPTION 'incremental pull omitted the revisioned tombstone: %', pulled;
  END IF;
  cursor_value := (pulled ->> 'next_cursor')::bigint;
  IF cursor_value <= 0 THEN
    RAISE EXCEPTION 'incremental pull did not advance its monotonic cursor: %', pulled;
  END IF;
  IF jsonb_array_length(
    public.daypage_pull_sync_changes(cursor_value, 200) -> 'changes'
  ) <> 0 THEN
    RAISE EXCEPTION 'cursor replayed an already-consumed change';
  END IF;
END
$$;

RESET ROLE;

DO $$
DECLARE
  normal_event jsonb := '{"claims":{"aud":"authenticated","sub":"11111111-1111-4111-8111-111111111111"}}';
  oauth_event jsonb := '{"claims":{"aud":"authenticated","sub":"11111111-1111-4111-8111-111111111111","client_id":"codex-staging-test"}}';
  result jsonb;
BEGIN
  IF NOT has_function_privilege(
    'supabase_auth_admin',
    'public.daypage_custom_access_token_hook(jsonb)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'supabase_auth_admin cannot execute the custom token hook';
  END IF;
  IF has_function_privilege(
    'authenticated',
    'public.daypage_custom_access_token_hook(jsonb)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'authenticated must not execute the custom token hook';
  END IF;

  result := public.daypage_custom_access_token_hook(normal_event);
  IF result <> normal_event THEN
    RAISE EXCEPTION 'normal app token was unexpectedly modified: %', result;
  END IF;

  result := public.daypage_custom_access_token_hook(oauth_event);
  IF NOT (result #> '{claims,aud}') @> '["authenticated","https://mcp.staging.daypage.test/mcp"]'::jsonb THEN
    RAISE EXCEPTION 'OAuth token was not resource-bound: %', result;
  END IF;
END
$$;

ROLLBACK;

SELECT 'daypage local-first sync / RLS / OAuth hook verification passed' AS result;
