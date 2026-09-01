\set ON_ERROR_STOP on

BEGIN;

INSERT INTO public.users (id, email) VALUES
  ('a1000000-0000-4000-8000-000000000001', 'agent-plane-a@example.invalid'),
  ('b1000000-0000-4000-8000-000000000002', 'agent-plane-b@example.invalid');

INSERT INTO public.memos (id, user_id, body, source, origin, sync_revision) VALUES
  ('a2000000-0000-4000-8000-000000000001', 'a1000000-0000-4000-8000-000000000001', 'Owner A source text', 'web', 'web', 1),
  ('b2000000-0000-4000-8000-000000000002', 'b1000000-0000-4000-8000-000000000002', 'Owner B source text', 'web', 'web', 1);

DO $$
BEGIN
  IF (SELECT count(*) FROM gateway_jobs WHERE type = 'memo.synced' AND user_id IN (
    'a1000000-0000-4000-8000-000000000001', 'b1000000-0000-4000-8000-000000000002'
  )) <> 2 THEN
    RAISE EXCEPTION 'memo revision trigger did not enqueue exactly one event per memo';
  END IF;
END;
$$;

UPDATE memos SET compile_status = 'running' WHERE id = 'a2000000-0000-4000-8000-000000000001';
DO $$
BEGIN
  IF (SELECT count(*) FROM gateway_jobs WHERE user_id = 'a1000000-0000-4000-8000-000000000001') <> 1 THEN
    RAISE EXCEPTION 'compiler metadata update re-enqueued a memo revision';
  END IF;
END;
$$;

INSERT INTO skill_versions (
  id, key, version, implementation_ref, checksum, default_risk
) VALUES (
  'a3000000-0000-4000-8000-000000000001', 'verify-skill', '1.0.0',
  'checked-in:verify', 'sha256:verify-agent-plane', 'internal_write'
);

INSERT INTO agent_runs (
  id, user_id, trigger_type, memo_id, memo_revision, skill_version_id,
  skill_checksum, idempotency_key, attempt, is_canonical, status
) VALUES
  (
    'a4000000-0000-4000-8000-000000000001',
    'a1000000-0000-4000-8000-000000000001', 'memo.synced',
    'a2000000-0000-4000-8000-000000000001', 1,
    'a3000000-0000-4000-8000-000000000001', 'sha256:verify-agent-plane',
    'owner-a:memo:1:skill', 1, true, 'completed'
  ),
  (
    'b4000000-0000-4000-8000-000000000002',
    'b1000000-0000-4000-8000-000000000002', 'memo.synced',
    'b2000000-0000-4000-8000-000000000002', 1,
    'a3000000-0000-4000-8000-000000000001', 'sha256:verify-agent-plane',
    'owner-b:memo:1:skill', 1, true, 'completed'
  );

DO $$
BEGIN
  BEGIN
    INSERT INTO agent_runs (
      user_id, trigger_type, memo_id, memo_revision, skill_version_id,
      skill_checksum, idempotency_key, attempt, is_canonical, status
    ) VALUES (
      'a1000000-0000-4000-8000-000000000001', 'memo.synced',
      'a2000000-0000-4000-8000-000000000001', 1,
      'a3000000-0000-4000-8000-000000000001', 'sha256:verify-agent-plane',
      'owner-a:memo:1:skill', 2, true, 'completed'
    );
    RAISE EXCEPTION 'duplicate canonical run was accepted';
  EXCEPTION WHEN unique_violation THEN
    NULL;
  END;
END;
$$;

INSERT INTO agent_artifacts (
  id, user_id, run_id, kind, logical_key, payload, status, revision
) VALUES
  (
    'a5000000-0000-4000-8000-000000000001',
    'a1000000-0000-4000-8000-000000000001',
    'a4000000-0000-4000-8000-000000000001',
    'observation', 'verify:a', '{"subject":"A"}', 'live', 1
  ),
  (
    'b5000000-0000-4000-8000-000000000002',
    'b1000000-0000-4000-8000-000000000002',
    'b4000000-0000-4000-8000-000000000002',
    'observation', 'verify:b', '{"subject":"B"}', 'live', 1
  );

INSERT INTO artifact_sources (artifact_id, memo_id, span_start, span_end)
VALUES (
  'a5000000-0000-4000-8000-000000000001',
  'a2000000-0000-4000-8000-000000000001', 0, 5
);

DO $$
BEGIN
  BEGIN
    INSERT INTO artifact_sources (artifact_id, memo_id, span_start, span_end)
    VALUES (
      'a5000000-0000-4000-8000-000000000001',
      'a2000000-0000-4000-8000-000000000001', 5, 5
    );
    RAISE EXCEPTION 'invalid source span was accepted';
  EXCEPTION WHEN check_violation THEN
    NULL;
  END;
END;
$$;

INSERT INTO pages (id, user_id, slug, type, title, body_md, version)
VALUES (
  'a6000000-0000-4000-8000-000000000001',
  'a1000000-0000-4000-8000-000000000001', 'verify/page', 'concept',
  'Verify', 'v0', 0
);

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', 'a1000000-0000-4000-8000-000000000001', true);

DO $$
BEGIN
  IF (SELECT count(*) FROM agent_runs) <> 1 THEN
    RAISE EXCEPTION 'agent_runs RLS leaked another tenant';
  END IF;
  IF (SELECT count(*) FROM agent_artifacts) <> 1 THEN
    RAISE EXCEPTION 'agent_artifacts RLS leaked another tenant';
  END IF;
  BEGIN
    INSERT INTO tool_connections (user_id, provider, auth_ref, scopes)
    VALUES (
      'a1000000-0000-4000-8000-000000000001',
      'forged-client-connection',
      'vault:forged',
      '["calendar.write"]'::jsonb
    );
    RAISE EXCEPTION 'authenticated client directly forged a Tool connection';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
END;
$$;

DO $$
DECLARE
  first_result jsonb;
  stale_result jsonb;
BEGIN
  first_result := daypage_apply_page_patch(
    'a6000000-0000-4000-8000-000000000001', 0, 'Verify', 'v1', '{}'::jsonb
  );
  stale_result := daypage_apply_page_patch(
    'a6000000-0000-4000-8000-000000000001', 0, 'Verify', 'stale overwrite', '{}'::jsonb
  );
  IF first_result ->> 'applied' <> 'true' OR stale_result ->> 'applied' <> 'false' THEN
    RAISE EXCEPTION 'optimistic page patch contract failed';
  END IF;
  IF (SELECT body_md FROM pages WHERE id = 'a6000000-0000-4000-8000-000000000001') <> 'v1' THEN
    RAISE EXCEPTION 'stale page patch overwrote the accepted version';
  END IF;
END;
$$;

DO $$
DECLARE
  daily_first uuid;
  daily_coalesced uuid;
  daily_retry uuid;
  weekly_first uuid;
BEGIN
  daily_first := daypage_request_daily_run('2026-08-27', 'Asia/Shanghai', false, false);
  daily_coalesced := daypage_request_daily_run('2026-08-27', 'Asia/Shanghai', false, false);
  daily_retry := daypage_request_daily_run('2026-08-27', 'Asia/Shanghai', false, true);
  weekly_first := daypage_request_weekly_run('2026-08-24', 'Asia/Shanghai', false);
  IF daily_first <> daily_coalesced THEN
    RAISE EXCEPTION 'ordinary authenticated Daily requests did not coalesce';
  END IF;
  IF daily_retry = daily_first THEN
    RAISE EXCEPTION 'explicit Daily retry reused the canonical queue item';
  END IF;
  IF weekly_first IS NULL THEN
    RAISE EXCEPTION 'authenticated Weekly request did not return a durable job';
  END IF;
  BEGIN
    PERFORM daypage_request_daily_run('2026-08-27', 'Not/A_Real_Zone', false, false);
    RAISE EXCEPTION 'invalid client timezone was accepted';
  EXCEPTION WHEN SQLSTATE '22023' THEN
    NULL;
  END;
END;
$$;

RESET ROLE;
ROLLBACK;

\echo 'Agent Data Plane transactional verification passed.'
