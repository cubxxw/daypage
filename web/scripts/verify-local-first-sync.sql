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
  IF has_table_privilege('authenticated', 'public.memo_attachments', 'INSERT')
    OR has_table_privilege('authenticated', 'public.memo_attachments', 'UPDATE')
    OR has_table_privilege('authenticated', 'public.memo_attachments', 'DELETE') THEN
    RAISE EXCEPTION 'authenticated can mutate verified attachment manifests directly';
  END IF;
  IF has_function_privilege(
    'authenticated', 'public.daypage_claim_attachment_gc(integer)', 'EXECUTE'
  ) OR has_function_privilege(
    'authenticated',
    'public.daypage_finish_attachment_gc(uuid,text,uuid,boolean,text)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'authenticated can invoke the private attachment GC controls';
  END IF;
END
$$;

INSERT INTO public.memos (
  id, user_id, type, body, attachment_manifest_hash, sync_revision
) VALUES (
  '66666666-6666-4666-8666-666666666666',
  '11111111-1111-4111-8111-111111111111',
  'photo', 'v2 media survives a v1 text writer',
  repeat('a', 64), 1
);
INSERT INTO public.memo_attachments (
  memo_id, kind, storage_key, filename, mime_type, size_bytes,
  protocol_version, position, content_sha256, verified_at
) VALUES (
  '66666666-6666-4666-8666-666666666666', 'photo',
  '11111111-1111-4111-8111-111111111111/66666666-6666-4666-8666-666666666666/' || repeat('b', 64) || '.jpg',
  'fixture.jpg', 'image/jpeg', 4, 2, 0, repeat('b', 64), now()
);

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
    'operation_id', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa4',
    'memo_id', '66666666-6666-4666-8666-666666666666',
    'kind', 'upsert',
    'revision', 2,
    'modified_at', '2026-08-24T00:00:00Z',
    'content_hash', 'v1-text-edit',
    'device_id', '44444444-4444-4444-8444-444444444444',
    'payload', jsonb_build_object(
      'type', 'photo',
      'body', 'legacy text edit',
      'created_at', '2026-08-24T00:00:00Z',
      'source', 'ios',
      'vault_path', 'raw/2026-08-24.md'
    )
  )));
  IF result #>> '{accepted,0,status}' <> 'applied'
    OR NOT EXISTS (
      SELECT 1 FROM public.memos memo
      WHERE memo.id = '66666666-6666-4666-8666-666666666666'
        AND memo.attachment_manifest_hash = repeat('a', 64)
    )
    OR NOT EXISTS (
      SELECT 1 FROM public.memo_attachments attachment
      WHERE attachment.memo_id = '66666666-6666-4666-8666-666666666666'
        AND attachment.protocol_version = 2
    ) THEN
    RAISE EXCEPTION 'v1 text edit destroyed a verified v2 manifest';
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
    'operation_id', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1',
    'memo_id', '55555555-5555-4555-8555-555555555555',
    'kind', 'upsert',
    'revision', 1,
    'modified_at', '2026-08-24T00:00:00Z'
  )));
  IF jsonb_array_length(result -> 'accepted') <> 0
    OR result #>> '{rejected,0,reason}' <> 'invalid_or_conflicting_operation' THEN
    RAISE EXCEPTION 'operation id reuse was not rejected: %', result;
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

INSERT INTO public.memos (id, user_id, type, body)
VALUES (
  '77777777-7777-4777-8777-777777777770',
  '11111111-1111-4111-8111-111111111111',
  'file', 'memo byte quota fixture'
);
INSERT INTO public.memo_attachments (
  memo_id, kind, storage_key, filename, mime_type, size_bytes,
  protocol_version, position, content_sha256, verified_at
)
SELECT
  '77777777-7777-4777-8777-777777777770',
  'file',
  '11111111-1111-4111-8111-111111111111/77777777-7777-4777-8777-777777777770/' ||
    lpad(to_hex(sequence), 64, '0') || '.pdf',
  'quota-' || sequence || '.pdf', 'application/pdf', 52428800,
  2, sequence - 1, lpad(to_hex(sequence), 64, '0'), now()
FROM generate_series(1, 5) AS sequence;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-111111111111', true);
DO $$
BEGIN
  BEGIN
    PERFORM public.daypage_prepare_attachment_upload(
      '77777777-7777-4777-8777-777777777770', repeat('e', 64), 1,
      'image/png', 'png'
    );
    RAISE EXCEPTION 'memo attachment byte quota was not enforced before upload';
  EXCEPTION WHEN SQLSTATE '54000' THEN
    IF SQLERRM <> 'memo attachment byte quota exceeded' THEN
      RAISE;
    END IF;
  END;
END
$$;

RESET ROLE;

-- A byte quota does not bound abusive one-byte reservation cardinality. Seed
-- rows through the privileged verification connection, then prove the public
-- RPC rejects both a short burst and too many simultaneously live slots.
INSERT INTO public.attachment_upload_reservations (
  user_id, memo_id, object_key, content_sha256, size_bytes, mime_type,
  status, expires_at, created_at
)
SELECT
  '11111111-1111-4111-8111-111111111111',
  '77777777-7777-4777-8777-777777777777',
  'rate-limit-fixture/' || sequence,
  repeat('c', 64), 1, 'image/png', 'expired', now() - interval '1 second', now()
FROM generate_series(1, 60) AS sequence;

INSERT INTO public.attachment_upload_reservations (
  user_id, memo_id, object_key, content_sha256, size_bytes, mime_type,
  status, expires_at, created_at
)
SELECT
  '22222222-2222-4222-8222-222222222222',
  '88888888-8888-4888-8888-888888888888',
  'live-limit-fixture/' || sequence,
  repeat('d', 64), 1, 'image/png', 'prepared', now() + interval '1 hour',
  now() - interval '1 day'
FROM generate_series(1, 100) AS sequence;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-111111111111', true);
DO $$
BEGIN
  BEGIN
    PERFORM public.daypage_prepare_attachment_upload(
      '99999999-9999-4999-8999-999999999991', repeat('e', 64), 1,
      'image/png', 'png'
    );
    RAISE EXCEPTION 'reservation rate limit was not enforced';
  EXCEPTION WHEN SQLSTATE '54000' THEN
    IF SQLERRM <> 'attachment reservation rate limit exceeded' THEN
      RAISE;
    END IF;
  END;
END
$$;

RESET ROLE;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '22222222-2222-4222-8222-222222222222', true);
DO $$
BEGIN
  BEGIN
    PERFORM public.daypage_prepare_attachment_upload(
      '99999999-9999-4999-8999-999999999992', repeat('f', 64), 1,
      'image/png', 'png'
    );
    RAISE EXCEPTION 'live reservation limit was not enforced';
  EXCEPTION WHEN SQLSTATE '54000' THEN
    IF SQLERRM <> 'live attachment reservation limit exceeded' THEN
      RAISE;
    END IF;
  END;
END
$$;

RESET ROLE;

INSERT INTO storage.objects (
  bucket_id, name, owner, owner_id, created_at, metadata, version
) VALUES (
  'memo-attachments',
  '11111111-1111-4111-8111-111111111111/99999999-9999-4999-8999-999999999993/' ||
    repeat('a', 63) || '1.png',
  '11111111-1111-4111-8111-111111111111',
  '11111111-1111-4111-8111-111111111111',
  now() - interval '11 minutes',
  '{"size":9,"mimetype":"image/png"}'::jsonb,
  'mismatch-fixture'
);
INSERT INTO public.attachment_upload_reservations (
  user_id, memo_id, object_key, content_sha256, size_bytes, mime_type,
  status, expires_at
) VALUES (
  '11111111-1111-4111-8111-111111111111',
  '99999999-9999-4999-8999-999999999993',
  '11111111-1111-4111-8111-111111111111/99999999-9999-4999-8999-999999999993/' ||
    repeat('a', 63) || '1.png',
  repeat('a', 63) || '1', 8, 'image/png', 'prepared', now() + interval '1 hour'
);
SELECT set_config('request.jwt.claim.role', 'service_role', true);
DO $$
DECLARE
  result jsonb;
BEGIN
  result := public.daypage_inventory_attachment_orphans();
  IF (result ->> 'queued')::integer < 1
    OR NOT EXISTS (
      SELECT 1 FROM public.attachment_upload_reservations reservation
      WHERE reservation.object_key LIKE '%99999999-9999-4999-8999-999999999993%'
        AND reservation.status = 'expired'
    )
    OR NOT EXISTS (
      SELECT 1 FROM public.attachment_gc_queue queue
      WHERE queue.object_key LIKE '%99999999-9999-4999-8999-999999999993%'
        AND queue.status = 'pending'
        AND queue.reason = 'uncommitted_orphan'
    ) THEN
    RAISE EXCEPTION 'mismatched uploaded bytes were not expired and queued: %', result;
  END IF;
END
$$;

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
