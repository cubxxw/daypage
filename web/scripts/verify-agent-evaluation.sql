\set ON_ERROR_STOP on

BEGIN;

INSERT INTO public.users (id, email) VALUES
  ('e1000000-0000-4000-8000-000000000001', 'eval-plane-a@example.invalid'),
  ('e1000000-0000-4000-8000-000000000002', 'eval-plane-b@example.invalid');

INSERT INTO public.memos (id, user_id, body, source, origin, sync_revision) VALUES
  ('e2000000-0000-4000-8000-000000000001', 'e1000000-0000-4000-8000-000000000001', 'Owner A evaluation source', 'web', 'web', 1),
  ('e2000000-0000-4000-8000-000000000002', 'e1000000-0000-4000-8000-000000000002', 'Owner B evaluation source', 'web', 'web', 1);

INSERT INTO skill_versions (
  id, key, version, implementation_ref, checksum, default_risk
) VALUES (
  'e3000000-0000-4000-8000-000000000001', 'verify-evaluation', '1.0.0',
  'checked-in:verify-evaluation', 'sha256:verify-evaluation-plane', 'internal_write'
);

INSERT INTO agent_runs (
  id, user_id, trigger_type, memo_id, memo_revision, skill_version_id,
  skill_checksum, idempotency_key, attempt, is_canonical, status
) VALUES
  (
    'e4000000-0000-4000-8000-000000000001',
    'e1000000-0000-4000-8000-000000000001', 'memo.synced',
    'e2000000-0000-4000-8000-000000000001', 1,
    'e3000000-0000-4000-8000-000000000001', 'sha256:verify-evaluation-plane',
    'eval-owner-a:memo:1', 1, true, 'completed'
  ),
  (
    'e4000000-0000-4000-8000-000000000002',
    'e1000000-0000-4000-8000-000000000002', 'memo.synced',
    'e2000000-0000-4000-8000-000000000002', 1,
    'e3000000-0000-4000-8000-000000000001', 'sha256:verify-evaluation-plane',
    'eval-owner-b:memo:1', 1, true, 'completed'
  );

INSERT INTO agent_artifacts (
  id, user_id, run_id, kind, logical_key, payload, status, revision
) VALUES (
  'e5000000-0000-4000-8000-000000000001',
  'e1000000-0000-4000-8000-000000000001',
  'e4000000-0000-4000-8000-000000000001',
  'memory_proposal', 'memory:verify', '{"requires_confirmation":true}', 'draft', 1
);

INSERT INTO agent_feedback_events (
  id, user_id, run_id, artifact_id, event_type, value, idempotency_key
) VALUES (
  'e6000000-0000-4000-8000-000000000001',
  'e1000000-0000-4000-8000-000000000001',
  'e4000000-0000-4000-8000-000000000001',
  'e5000000-0000-4000-8000-000000000001',
  'memory.confirmed', 1, 'eval-feedback-owner-a'
);

INSERT INTO evaluation_results (
  id, user_id, run_id, evaluator_key, evaluator_version, source,
  score, passed, reason, idempotency_key
) VALUES
  (
    'e7000000-0000-4000-8000-000000000001',
    'e1000000-0000-4000-8000-000000000001',
    'e4000000-0000-4000-8000-000000000001',
    'safety.memory_confirmation', '1.0.0', 'deterministic',
    1, true, 'proposal-only', 'eval-result-owner-a'
  ),
  (
    'e7000000-0000-4000-8000-000000000002',
    'e1000000-0000-4000-8000-000000000002',
    'e4000000-0000-4000-8000-000000000002',
    'safety.memory_confirmation', '1.0.0', 'deterministic',
    1, true, 'proposal-only', 'eval-result-owner-b'
  );

INSERT INTO evaluation_case_candidates (
  id, user_id, run_id, feedback_event_id, reason
) VALUES (
  'e8000000-0000-4000-8000-000000000001',
  'e1000000-0000-4000-8000-000000000001',
  'e4000000-0000-4000-8000-000000000001',
  'e6000000-0000-4000-8000-000000000001', 'memory.corrected'
);

INSERT INTO evaluation_export_outbox (
  id, user_id, run_id, entity_type, entity_id, operation,
  privacy_mode, idempotency_key
) VALUES (
  'e9000000-0000-4000-8000-000000000001',
  'e1000000-0000-4000-8000-000000000001',
  'e4000000-0000-4000-8000-000000000001',
  'trace', 'e4000000-0000-4000-8000-000000000001', 'upsert',
  'metadata_only', 'eval-export-owner-a'
);

DO $$
BEGIN
  BEGIN
    INSERT INTO agent_feedback_events (
      user_id, run_id, event_type, value, idempotency_key
    ) VALUES (
      'e1000000-0000-4000-8000-000000000001',
      'e4000000-0000-4000-8000-000000000001',
      'response.saved', 2, 'eval-feedback-invalid-score'
    );
    RAISE EXCEPTION 'out-of-range feedback score was accepted';
  EXCEPTION WHEN check_violation THEN
    NULL;
  END;

  BEGIN
    INSERT INTO evaluation_results (
      user_id, run_id, evaluator_key, evaluator_version, source,
      score, passed, idempotency_key
    ) VALUES (
      'e1000000-0000-4000-8000-000000000001',
      'e4000000-0000-4000-8000-000000000001',
      'invalid', '1.0.0', 'guess', 1, true, 'eval-result-invalid-source'
    );
    RAISE EXCEPTION 'invalid evaluation source was accepted';
  EXCEPTION WHEN check_violation THEN
    NULL;
  END;

  BEGIN
    INSERT INTO evaluation_export_outbox (
      user_id, entity_type, entity_id, operation, privacy_mode, idempotency_key
    ) VALUES (
      'e1000000-0000-4000-8000-000000000001',
      'trace', 'e4000000-0000-4000-8000-000000000001',
      'upsert', 'raw_everything', 'eval-export-invalid-privacy'
    );
    RAISE EXCEPTION 'invalid export privacy mode was accepted';
  EXCEPTION WHEN check_violation THEN
    NULL;
  END;
END;
$$;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', 'e1000000-0000-4000-8000-000000000001', true);

DO $$
BEGIN
  IF (SELECT count(*) FROM agent_feedback_events) <> 1 THEN
    RAISE EXCEPTION 'feedback RLS leaked another tenant or hid owner data';
  END IF;
  IF (SELECT count(*) FROM evaluation_results) <> 1 THEN
    RAISE EXCEPTION 'evaluation result RLS leaked another tenant';
  END IF;
  IF (SELECT count(*) FROM evaluation_case_candidates) <> 1 THEN
    RAISE EXCEPTION 'case candidate RLS failed';
  END IF;
  IF (SELECT count(*) FROM evaluation_export_outbox) <> 1 THEN
    RAISE EXCEPTION 'evaluation export RLS failed';
  END IF;
  BEGIN
    INSERT INTO agent_feedback_events (
      user_id, run_id, event_type, idempotency_key
    ) VALUES (
      'e1000000-0000-4000-8000-000000000001',
      'e4000000-0000-4000-8000-000000000001',
      'response.saved', 'forged-client-feedback'
    );
    RAISE EXCEPTION 'authenticated client directly inserted feedback';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
END;
$$;

RESET ROLE;
ROLLBACK;

\echo 'Agent Evaluation Plane transactional verification passed.'
