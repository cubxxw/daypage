\set ON_ERROR_STOP on

BEGIN;

DO $$
BEGIN
  IF public.daypage_system_action_payload_hash_v1(
    '{"kind":"route","destination_label":"Tiny","destination_latitude":0.000001,"destination_longitude":-0.000001,"transport":"walking"}'::jsonb
  ) IS DISTINCT FROM '0daab34946dd400a4389a48450bc75f500670c92983d722170361bc5119338df' THEN
    RAISE EXCEPTION 'cross-platform fixed-point route hash mismatch';
  END IF;
  BEGIN
    PERFORM public.daypage_system_action_payload_hash_v1('{"n":0.0000001}'::jsonb);
    RAISE EXCEPTION 'sub-microdegree number unexpectedly hashed';
  EXCEPTION WHEN SQLSTATE '22023' THEN
    NULL;
  END;
  IF public.daypage_validate_system_action_payload_v1(
    'calendar_event',
    '{"kind":"calendar_event","title":"   ","start_at":"2026-08-27T01:00:00.000Z","end_at":"2026-08-27T01:30:00.000Z","all_day":false,"time_zone":"UTC","location_label":null,"notes":null}'::jsonb
  ) THEN
    RAISE EXCEPTION 'whitespace-only required payload title was accepted';
  END IF;
  IF public.daypage_validate_system_action_payload_v1(
    'moment',
    '{"kind":"moment","captured_at":"2026-08-27T01:00:00.000Z","title":"Moment","place_label":"   ","people_refs":[],"include_one_shot_location":true}'::jsonb
  ) THEN
    RAISE EXCEPTION 'whitespace-only moment location label was accepted';
  END IF;
  IF public.daypage_validate_system_action_source_refs_v1(
    '[{"kind":"memo","id":"same"},{"kind":"memo","id":"same"}]'::jsonb
  ) THEN
    RAISE EXCEPTION 'duplicate source references were accepted';
  END IF;
END;
$$;

INSERT INTO auth.users (id, email, aud, role, created_at, updated_at, raw_user_meta_data)
VALUES
  ('91000000-0000-4100-8100-000000000001', 'actions-a@daypage.test', 'authenticated', 'authenticated', now(), now(), '{}'::jsonb),
  ('92000000-0000-4200-8200-000000000002', 'actions-b@daypage.test', 'authenticated', 'authenticated', now(), now(), '{}'::jsonb);

INSERT INTO public.system_action_capability_policies (
  user_id, policy_id, capability, revision, is_offered, sync_enabled,
  disclosure_level, updated_at
) VALUES
  ('91000000-0000-4100-8100-000000000001', '9d000000-0000-4d00-8d00-000000000001', 'calendar', 1, true, true, 'full_proposal', now()),
  ('91000000-0000-4100-8100-000000000001', '9d000000-0000-4d00-8d00-000000000002', 'routes', 1, true, true, 'full_proposal', now()),
  ('91000000-0000-4100-8100-000000000001', '9d000000-0000-4d00-8d00-000000000003', 'focus', 1, true, true, 'full_proposal', now());

DO $$
DECLARE
  action_table text;
BEGIN
  IF (SELECT count(*) FROM public.users WHERE id IN (
    '91000000-0000-4100-8100-000000000001',
    '92000000-0000-4200-8200-000000000002'
  )) <> 2 THEN
    RAISE EXCEPTION 'auth profile trigger did not create both action verifier users';
  END IF;
  IF public.daypage_system_action_payload_hash_v1(
    '{"kind":"calendar_event","title":"Design review","start_at":"2026-08-27T01:00:00.000Z","end_at":"2026-08-27T01:30:00.000Z","all_day":false,"time_zone":"Asia/Shanghai","location_label":"Studio","notes":null}'::jsonb
  ) IS DISTINCT FROM '025b6f8ab0826324bbcbc4d2d3d7e92a492735931c4543639bb96e043726475c' THEN
    RAISE EXCEPTION 'Postgres action canonical hash drifted from the shared contract';
  END IF;
  PERFORM set_config(
    'daypage.verifier_payload_hash',
    'a23d62ca3f59c48f8dc75e3eec687990f0fb43623de294bfb6fbe60b7d2f61f0',
    true
  );
  PERFORM set_config(
    'daypage.verifier_now',
    to_char(clock_timestamp() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
    true
  );
  PERFORM set_config(
    'daypage.verifier_expires',
    to_char((clock_timestamp() + interval '1 day') AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
    true
  );
  IF has_table_privilege('authenticated', 'public.system_action_proposals', 'INSERT')
    OR has_table_privilege('authenticated', 'public.system_action_proposals', 'UPDATE')
    OR has_table_privilege('authenticated', 'public.system_action_proposals', 'DELETE')
    OR has_table_privilege('authenticated', 'public.system_action_receipts', 'INSERT')
    OR has_table_privilege('authenticated', 'public.system_action_receipts', 'UPDATE')
    OR has_table_privilege('authenticated', 'public.system_action_receipts', 'DELETE')
    OR has_table_privilege('authenticated', 'public.system_action_receipts', 'TRUNCATE')
    OR has_table_privilege('authenticated', 'public.system_action_sync_operations', 'SELECT')
    OR has_table_privilege('authenticated', 'public.system_action_execution_leases', 'SELECT') THEN
    RAISE EXCEPTION 'authenticated has direct system action mutation or private coordination access';
  END IF;
  FOREACH action_table IN ARRAY ARRAY[
    'public.system_action_proposals',
    'public.system_action_approvals',
    'public.system_action_receipts',
    'public.system_action_capability_policies',
    'public.system_action_sync_operations',
    'public.system_action_execution_leases'
  ] LOOP
    IF has_table_privilege('authenticated', action_table, 'INSERT')
      OR has_table_privilege('authenticated', action_table, 'UPDATE')
      OR has_table_privilege('authenticated', action_table, 'DELETE')
      OR has_table_privilege('authenticated', action_table, 'TRUNCATE') THEN
      RAISE EXCEPTION 'authenticated retains direct mutation on %', action_table;
    END IF;
  END LOOP;
  IF has_table_privilege('authenticated', 'public.sync_operations', 'SELECT')
    OR has_table_privilege('authenticated', 'public.sync_operations', 'INSERT')
    OR has_table_privilege('authenticated', 'public.sync_operations', 'UPDATE')
    OR has_table_privilege('authenticated', 'public.sync_operations', 'DELETE')
    OR has_table_privilege('authenticated', 'public.sync_operations', 'TRUNCATE') THEN
    RAISE EXCEPTION 'legacy sync operation receipts remain directly accessible';
  END IF;
  IF has_function_privilege(
    'authenticated',
    'public.daypage_apply_system_action_operations_for_user_v1(uuid,jsonb)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'authenticated can invoke tenant-parameterized action helper';
  END IF;
  IF has_column_privilege('authenticated', 'public.mcp_client_grants', 'can_read_actions', 'INSERT')
    OR has_column_privilege('authenticated', 'public.mcp_client_grants', 'can_read_actions', 'UPDATE')
    OR has_column_privilege('authenticated', 'public.mcp_client_grants', 'can_propose_actions', 'INSERT')
    OR has_column_privilege('authenticated', 'public.mcp_client_grants', 'can_propose_actions', 'UPDATE') THEN
    RAISE EXCEPTION 'OAuth clients can directly escalate independent action grants';
  END IF;
END
$$;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '91000000-0000-4100-8100-000000000001', true);
SELECT set_config('request.jwt.claims', '{"sub":"91000000-0000-4100-8100-000000000001","role":"authenticated"}', true);

DO $$
DECLARE
  proposal jsonb := jsonb_build_object(
    'schema_version', 1,
    'proposal_id', '93000000-0000-4300-8300-000000000003',
    'revision', 1,
    'kind', 'calendar_event',
    'payload', jsonb_build_object(
      'kind', 'calendar_event', 'title', 'Verifier event',
      'start_at', '2026-08-27T01:00:00.000Z',
      'end_at', '2026-08-27T01:30:00.000Z',
      'all_day', false, 'time_zone', 'Asia/Shanghai',
      'location_label', NULL, 'notes', NULL
    ),
    'payload_hash', 'a23d62ca3f59c48f8dc75e3eec687990f0fb43623de294bfb6fbe60b7d2f61f0',
    'title', 'Create verifier event',
    'rationale', 'Synthetic transactional verification',
    'source_refs', jsonb_build_array(jsonb_build_object('kind', 'memo', 'id', 'synthetic-memo')),
    'creator_source', 'native',
    'creator_device_id_hash', repeat('b', 64),
    'redaction_level', 'sensitive',
    'target_device_preference', 'creating_device',
    'target_device_id_hash', NULL,
    'state', 'pending',
    'created_at', current_setting('daypage.verifier_now'),
    'expires_at', current_setting('daypage.verifier_expires'),
    'deleted_at', NULL
  );
  route_proposal jsonb;
  targeted_proposal jsonb;
  result jsonb;
BEGIN
  BEGIN
    INSERT INTO public.system_action_receipts (
      user_id, receipt_id, proposal_id, phase, proposal_revision,
      payload_hash, attempt, outcome, device_id_hash, execution_mode,
      result, reconciliation_state, undo_capability, started_at, completed_at
    ) VALUES (
      auth.uid(), gen_random_uuid(), gen_random_uuid(), 'execute', 1,
      repeat('a', 64), 1, 'succeeded', repeat('b', 64), 'offline_owner',
      '{}'::jsonb, 'confirmed', 'none', now(), now()
    );
    RAISE EXCEPTION 'direct receipt insert unexpectedly succeeded';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;

  result := public.daypage_apply_system_action_operations_v1(jsonb_build_array(jsonb_build_object(
    'protocol_version', 1, 'operation_id', '9e000000-0000-4e00-8e00-000000000001',
    'entity_type', 'proposal', 'entity_id', '9e000000-0000-4e00-8e00-000000000002',
    'operation_kind', 'upsert', 'revision', 1,
    'record', proposal || jsonb_build_object(
      'proposal_id', '9e000000-0000-4e00-8e00-000000000002',
      'kind', 'notification',
      'payload', jsonb_build_object(
        'kind', 'notification', 'title', 'Policy gate', 'body', '',
        'fire_at', '2026-08-27T01:00:00.000Z', 'time_zone', 'UTC',
        'interruption_level', 'active'
      ),
      'payload_hash', '0d2da70e0a5f935b86b48523f3f4ae530a0d66811fca48217d16eef3d5fd324f'
    )
  )));
  IF result #>> '{rejected,0,reason}' IS DISTINCT FROM 'invalid_operation' THEN
    RAISE EXCEPTION 'proposal without an active full-disclosure capability policy reached cloud: %', result;
  END IF;

  result := public.daypage_apply_system_action_operations_v1(jsonb_build_array(jsonb_build_object(
    'protocol_version', 1, 'operation_id', '9e000000-0000-4e00-8e00-000000000003',
    'entity_type', 'proposal', 'entity_id', '9e000000-0000-4e00-8e00-000000000004',
    'operation_kind', 'upsert', 'revision', 1,
    'record', proposal || jsonb_build_object(
      'proposal_id', '9e000000-0000-4e00-8e00-000000000004',
      'kind', 'moment',
      'payload', jsonb_build_object(
        'kind', 'moment', 'captured_at', '2026-08-27T01:00:00.000Z',
        'place_label', NULL, 'people_refs', '[]'::jsonb,
        'include_one_shot_location', false
      ),
      'payload_hash', '933f01ab7d72e52172283bd05b1d84a42313e15409998ca569a1223c363eb19f'
    )
  )));
  IF result #>> '{rejected,0,reason}' IS DISTINCT FROM 'invalid_operation' THEN
    RAISE EXCEPTION 'zero-capability local-only proposal reached cloud: %', result;
  END IF;

  result := public.daypage_apply_system_action_operations_v1(jsonb_build_array(jsonb_build_object(
    'protocol_version', 1,
    'operation_id', '94000000-0000-4400-8400-000000000004',
    'entity_type', 'proposal',
    'entity_id', proposal ->> 'proposal_id',
    'operation_kind', 'upsert',
    'revision', 1,
    'record', proposal
  )));
  IF result #>> '{accepted,0,status}' IS DISTINCT FROM 'applied'
    OR result #>> '{accepted,0,record,state}' IS DISTINCT FROM 'pending' THEN
    RAISE EXCEPTION 'initial proposal was not applied: %', result;
  END IF;

  result := public.daypage_apply_system_action_operations_v1(jsonb_build_array(jsonb_build_object(
    'protocol_version', 1,
    'operation_id', '94000000-0000-4400-8400-000000000004',
    'entity_type', 'proposal',
    'entity_id', proposal ->> 'proposal_id',
    'operation_kind', 'upsert',
    'revision', 1,
    'record', proposal
  )));
  IF result #>> '{accepted,0,status}' IS DISTINCT FROM 'replayed' THEN
    RAISE EXCEPTION 'exact proposal retry did not return historical receipt: %', result;
  END IF;

  result := public.daypage_apply_system_action_operations_v1(jsonb_build_array(jsonb_build_object(
    'protocol_version', 1,
    'operation_id', '94000000-0000-4400-8400-000000000004',
    'entity_type', 'proposal',
    'entity_id', proposal ->> 'proposal_id',
    'operation_kind', 'upsert',
    'revision', 1,
    'record', proposal || jsonb_build_object('title', 'Fingerprint mismatch')
  )));
  IF result #>> '{rejected,0,reason}' IS DISTINCT FROM 'operation_id_reuse_mismatch' THEN
    RAISE EXCEPTION 'operation tuple reuse mismatch was not rejected: %', result;
  END IF;

  result := public.daypage_apply_system_action_operations_v1(jsonb_build_array(jsonb_build_object(
    'protocol_version', 1,
    'operation_id', '94000000-0000-4400-8400-000000000005',
    'entity_type', 'proposal',
    'entity_id', proposal ->> 'proposal_id',
    'operation_kind', 'upsert',
    'revision', 1,
    'record', proposal
  )));
  IF result #>> '{rejected,0,reason}' IS DISTINCT FROM 'stale_revision' THEN
    RAISE EXCEPTION 'stale proposal revision was accepted: %', result;
  END IF;

  result := public.daypage_apply_system_action_operations_v1(jsonb_build_array(jsonb_build_object(
    'protocol_version', 1,
    'operation_id', '94000000-0000-4400-8400-000000000099',
    'entity_type', 'proposal',
    'entity_id', '93000000-0000-4300-8300-000000000099',
    'operation_kind', 'upsert', 'revision', 1,
    'record', proposal
      || jsonb_build_object('proposal_id', '93000000-0000-4300-8300-000000000099')
      || jsonb_build_object('payload', (proposal -> 'payload') || jsonb_build_object(
        'raw_external_identifier', 'must-never-reach-cloud'
      ))
  )));
  IF result #>> '{rejected,0,reason}' IS DISTINCT FROM 'invalid_operation' THEN
    RAISE EXCEPTION 'non-canonical/private proposal payload was accepted: %', result;
  END IF;

  result := public.daypage_apply_system_action_operations_v1(jsonb_build_array(jsonb_build_object(
    'protocol_version', 1,
    'operation_id', '94000000-0000-4400-8400-000000000094',
    'entity_type', 'proposal',
    'entity_id', '93000000-0000-4300-8300-000000000094',
    'operation_kind', 'upsert', 'revision', 1,
    'record', proposal || jsonb_build_object(
      'proposal_id', '93000000-0000-4300-8300-000000000094',
      'creator_device_id_hash', NULL
    )
  )));
  IF result #>> '{rejected,0,reason}' IS DISTINCT FROM 'invalid_operation' THEN
    RAISE EXCEPTION 'creating-device proposal without creator device was accepted: %', result;
  END IF;

  route_proposal := proposal || jsonb_build_object(
    'proposal_id', '93000000-0000-4300-8300-000000000098',
    'kind', 'route',
    'payload', jsonb_build_object(
      'kind', 'route', 'destination_label', 'Verifier studio',
      'destination_address', '100 Design Road, Shanghai', 'transport', 'transit'
    ),
    'payload_hash', '1d113e48b54d2cc2f9fbaa828958261b150f67c26c438134b95a32c36fede996',
    'title', 'Open verifier route'
  );
  result := public.daypage_apply_system_action_operations_v1(jsonb_build_array(jsonb_build_object(
    'protocol_version', 1,
    'operation_id', '94000000-0000-4400-8400-000000000098',
    'entity_type', 'proposal',
    'entity_id', route_proposal ->> 'proposal_id',
    'operation_kind', 'upsert', 'revision', 1, 'record', route_proposal
  )));
  IF result #>> '{accepted,0,status}' IS DISTINCT FROM 'applied' THEN
    RAISE EXCEPTION 'address-only route proposal was rejected: %', result;
  END IF;
  route_proposal := route_proposal
    || jsonb_build_object('proposal_id', '93000000-0000-4300-8300-000000000097')
    || jsonb_build_object('payload', (route_proposal -> 'payload') - 'destination_address'
      || jsonb_build_object('destination_latitude', 31.2304));
  result := public.daypage_apply_system_action_operations_v1(jsonb_build_array(jsonb_build_object(
    'protocol_version', 1,
    'operation_id', '94000000-0000-4400-8400-000000000097',
    'entity_type', 'proposal',
    'entity_id', route_proposal ->> 'proposal_id',
    'operation_kind', 'upsert', 'revision', 1, 'record', route_proposal
  )));
  IF result #>> '{rejected,0,reason}' IS DISTINCT FROM 'invalid_operation' THEN
    RAISE EXCEPTION 'half-coordinate route proposal was accepted: %', result;
  END IF;

  BEGIN
    PERFORM public.daypage_claim_system_action_execution_v1(
      '95000000-0000-4500-8500-000000000005',
      '93000000-0000-4300-8300-000000000003',
      'execute', 1, current_setting('daypage.verifier_payload_hash'), repeat('b', 64), 120
    );
    RAISE EXCEPTION 'execution claim succeeded without exact approval';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;

  result := public.daypage_apply_system_action_operations_v1(jsonb_build_array(jsonb_build_object(
    'protocol_version', 1,
    'operation_id', '94000000-0000-4400-8400-000000000006',
    'entity_type', 'approval',
    'entity_id', '96000000-0000-4600-8600-000000000006',
    'operation_kind', 'append',
    'revision', 1,
    'record', jsonb_build_object(
      'schema_version', 1,
      'approval_id', '96000000-0000-4600-8600-000000000006',
      'proposal_id', '93000000-0000-4300-8300-000000000003',
      'phase', 'execute', 'proposal_revision', 1,
      'payload_hash', repeat('c', 64), 'decision', 'approve',
      'device_id_hash', repeat('b', 64),
      'decided_at', current_setting('daypage.verifier_now'),
      'has_replacement', false
    )
  )));
  IF result #>> '{rejected,0,reason}' IS DISTINCT FROM 'approval_mismatch' THEN
    RAISE EXCEPTION 'stale payload approval was accepted: %', result;
  END IF;

  result := public.daypage_apply_system_action_operations_v1(jsonb_build_array(jsonb_build_object(
    'protocol_version', 1,
    'operation_id', '94000000-0000-4400-8400-000000000106',
    'entity_type', 'approval',
    'entity_id', '96000000-0000-4600-8600-000000000106',
    'operation_kind', 'append', 'revision', 1,
    'record', jsonb_build_object(
      'schema_version', 1,
      'approval_id', '96000000-0000-4600-8600-000000000106',
      'proposal_id', '93000000-0000-4300-8300-000000000003',
      'phase', 'execute', 'proposal_revision', 1,
      'payload_hash', current_setting('daypage.verifier_payload_hash'),
      'decision', 'approve', 'device_id_hash', repeat('b', 64),
      'decided_at', current_setting('daypage.verifier_now'),
      'has_replacement', true
    )
  )));
  IF result #>> '{rejected,0,reason}' IS DISTINCT FROM 'invalid_operation' THEN
    RAISE EXCEPTION 'approve plus replacement was accepted: %', result;
  END IF;

  result := public.daypage_apply_system_action_operations_v1(jsonb_build_array(jsonb_build_object(
    'protocol_version', 1,
    'operation_id', '94000000-0000-4400-8400-000000000107',
    'entity_type', 'approval',
    'entity_id', '96000000-0000-4600-8600-000000000107',
    'operation_kind', 'append', 'revision', 1,
    'record', jsonb_build_object(
      'schema_version', 1,
      'approval_id', '96000000-0000-4600-8600-000000000107',
      'proposal_id', '93000000-0000-4300-8300-000000000003',
      'phase', 'execute', 'proposal_revision', 1,
      'payload_hash', current_setting('daypage.verifier_payload_hash'),
      'decision', 'reject', 'device_id_hash', repeat('b', 64),
      'decided_at', current_setting('daypage.verifier_now'),
      'has_replacement', 'yes'
    )
  )));
  IF result #>> '{rejected,0,reason}' IS DISTINCT FROM 'invalid_operation' THEN
    RAISE EXCEPTION 'non-boolean replacement marker was accepted: %', result;
  END IF;

  result := public.daypage_apply_system_action_operations_v1(jsonb_build_array(jsonb_build_object(
    'protocol_version', 1,
    'operation_id', '94000000-0000-4400-8400-000000000007',
    'entity_type', 'approval',
    'entity_id', '96000000-0000-4600-8600-000000000007',
    'operation_kind', 'append',
    'revision', 1,
    'record', jsonb_build_object(
      'schema_version', 1,
      'approval_id', '96000000-0000-4600-8600-000000000007',
      'proposal_id', '93000000-0000-4300-8300-000000000003',
      'phase', 'execute', 'proposal_revision', 1,
      'payload_hash', current_setting('daypage.verifier_payload_hash'), 'decision', 'approve',
      'device_id_hash', repeat('b', 64),
      'decided_at', '2099-01-01T00:00:00.000Z',
      'has_replacement', false
    )
  )));
  IF result #>> '{accepted,0,status}' IS DISTINCT FROM 'applied' THEN
    RAISE EXCEPTION 'server-valid approval with a fast client clock failed: %', result;
  END IF;

  targeted_proposal := proposal || jsonb_build_object(
    'proposal_id', '93000000-0000-4300-8300-000000000096',
    'title', 'Create verifier event on a specific device',
    'target_device_preference', 'specific_device',
    'target_device_id_hash', repeat('d', 64)
  );
  result := public.daypage_apply_system_action_operations_v1(jsonb_build_array(jsonb_build_object(
    'protocol_version', 1,
    'operation_id', '94000000-0000-4400-8400-000000000096',
    'entity_type', 'proposal',
    'entity_id', targeted_proposal ->> 'proposal_id',
    'operation_kind', 'upsert', 'revision', 1, 'record', targeted_proposal
  )));
  IF result #>> '{accepted,0,status}' IS DISTINCT FROM 'applied' THEN
    RAISE EXCEPTION 'specific-device proposal failed: %', result;
  END IF;
  result := public.daypage_apply_system_action_operations_v1(jsonb_build_array(jsonb_build_object(
    'protocol_version', 1,
    'operation_id', '94100000-0000-4400-8400-000000000096',
    'entity_type', 'approval',
    'entity_id', '96100000-0000-4600-8600-000000000096',
    'operation_kind', 'append', 'revision', 1,
    'record', jsonb_build_object(
      'schema_version', 1,
      'approval_id', '96100000-0000-4600-8600-000000000096',
      'proposal_id', targeted_proposal ->> 'proposal_id',
      'phase', 'execute', 'proposal_revision', 1,
      'payload_hash', current_setting('daypage.verifier_payload_hash'),
      'decision', 'approve', 'device_id_hash', repeat('b', 64),
      'decided_at', current_setting('daypage.verifier_now'), 'has_replacement', false
    )
  )));
  IF result #>> '{accepted,0,status}' IS DISTINCT FROM 'applied' THEN
    RAISE EXCEPTION 'specific-device approval failed: %', result;
  END IF;

  targeted_proposal := proposal || jsonb_build_object(
    'proposal_id', '93000000-0000-4300-8300-000000000095',
    'title', 'Create verifier event on any owned device',
    'target_device_preference', 'any',
    'target_device_id_hash', NULL
  );
  result := public.daypage_apply_system_action_operations_v1(jsonb_build_array(jsonb_build_object(
    'protocol_version', 1,
    'operation_id', '94000000-0000-4400-8400-000000000095',
    'entity_type', 'proposal',
    'entity_id', targeted_proposal ->> 'proposal_id',
    'operation_kind', 'upsert', 'revision', 1, 'record', targeted_proposal
  )));
  IF result #>> '{accepted,0,status}' IS DISTINCT FROM 'applied' THEN
    RAISE EXCEPTION 'any-device proposal failed: %', result;
  END IF;
  result := public.daypage_apply_system_action_operations_v1(jsonb_build_array(jsonb_build_object(
    'protocol_version', 1,
    'operation_id', '94100000-0000-4400-8400-000000000095',
    'entity_type', 'approval',
    'entity_id', '96100000-0000-4600-8600-000000000095',
    'operation_kind', 'append', 'revision', 1,
    'record', jsonb_build_object(
      'schema_version', 1,
      'approval_id', '96100000-0000-4600-8600-000000000095',
      'proposal_id', targeted_proposal ->> 'proposal_id',
      'phase', 'execute', 'proposal_revision', 1,
      'payload_hash', current_setting('daypage.verifier_payload_hash'),
      'decision', 'approve', 'device_id_hash', repeat('b', 64),
      'decided_at', current_setting('daypage.verifier_now'), 'has_replacement', false
    )
  )));
  IF result #>> '{accepted,0,status}' IS DISTINCT FROM 'applied' THEN
    RAISE EXCEPTION 'any-device approval failed: %', result;
  END IF;

  PERFORM public.daypage_upsert_mcp_client_grant_v1('actions-verifier-client', false);
  IF EXISTS (
    SELECT 1 FROM public.mcp_client_grants
    WHERE user_id = auth.uid() AND client_id = 'actions-verifier-client'
      AND (can_read_actions OR can_propose_actions)
  ) THEN
    RAISE EXCEPTION 'new OAuth grant did not default action permissions off';
  END IF;
  BEGIN
    UPDATE public.mcp_client_grants SET can_read_actions = true
    WHERE user_id = auth.uid() AND client_id = 'actions-verifier-client';
    RAISE EXCEPTION 'direct action grant escalation unexpectedly succeeded';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
END
$$;

SELECT set_config(
  'request.jwt.claims',
  '{"sub":"91000000-0000-4100-8100-000000000001","role":"authenticated","client_id":"actions-verifier-client"}',
  true
);
DO $$
BEGIN
  IF (SELECT count(*) FROM public.system_action_proposals) <> 0 THEN
    RAISE EXCEPTION 'default-off OAuth action grant could read proposals';
  END IF;
  BEGIN
    PERFORM public.daypage_mcp_list_system_action_proposals_v1(10, NULL);
    RAISE EXCEPTION 'default-off OAuth action grant invoked proposal list RPC';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
  BEGIN
    PERFORM public.daypage_set_mcp_action_grant_v1('actions-verifier-client', true, true);
    RAISE EXCEPTION 'OAuth resource credential escalated its own action grant';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
  BEGIN
    PERFORM public.daypage_apply_system_action_operations_v1('[]'::jsonb);
    RAISE EXCEPTION 'OAuth resource credential invoked native action apply';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
  BEGIN
    PERFORM public.daypage_pull_system_action_changes_v1(0, 10);
    RAISE EXCEPTION 'OAuth resource credential invoked native action pull';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
  BEGIN
    PERFORM public.daypage_claim_system_action_execution_v1(
      gen_random_uuid(), '93000000-0000-4300-8300-000000000003',
      'execute', 1, current_setting('daypage.verifier_payload_hash'), repeat('b', 64), 120
    );
    RAISE EXCEPTION 'OAuth resource credential claimed native execution';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
END
$$;
SELECT set_config(
  'request.jwt.claims',
  '{"sub":"91000000-0000-4100-8100-000000000001","role":"authenticated"}',
  true
);
SELECT public.daypage_set_mcp_action_grant_v1('actions-verifier-client', true, true);
SELECT public.daypage_upsert_mcp_client_grant_v1('actions-verifier-client', false);
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.mcp_client_grants
    WHERE user_id = auth.uid() AND client_id = 'actions-verifier-client'
      AND (revoked_at IS NOT NULL OR can_read_actions OR can_propose_actions)
  ) THEN
    RAISE EXCEPTION 'OAuth reconnect silently preserved an old action grant';
  END IF;
END
$$;
SELECT public.daypage_set_mcp_action_grant_v1('actions-verifier-client', true, true);

SELECT set_config(
  'request.jwt.claims',
  '{"sub":"91000000-0000-4100-8100-000000000001","role":"authenticated","client_id":"actions-verifier-client"}',
  true
);
DO $$
DECLARE
  proposal jsonb;
  result jsonb;
BEGIN
  IF (SELECT count(*) FROM public.system_action_proposals) <> 0
    OR (SELECT count(*) FROM public.system_action_approvals) <> 0
    OR (SELECT count(*) FROM public.system_action_receipts) <> 0
    OR (SELECT count(*) FROM public.system_action_capability_policies) <> 0 THEN
    RAISE EXCEPTION 'OAuth credential bypassed bounded action read RPCs';
  END IF;
  IF jsonb_array_length(public.daypage_mcp_list_system_action_proposals_v1(10, NULL)) < 1
    OR jsonb_array_length(public.daypage_mcp_list_system_action_receipts_v1(10)) <> 0 THEN
    RAISE EXCEPTION 'enabled OAuth action read RPCs returned unexpected rows';
  END IF;
  proposal := jsonb_build_object(
    'schema_version', 1, 'proposal_id', '9c000000-0000-4c00-8c00-000000000001',
    'revision', 1, 'kind', 'focus_session',
    'payload', jsonb_build_object('kind', 'focus_session', 'title', 'OAuth focus', 'duration_seconds', 900, 'schedule_end_alert', true, 'allow_live_activity', true),
    'payload_hash', '4d5f9b381f33936696f8cf89f97079eeb02b073cda012a60973b73fc2adf7817', 'title', 'Start OAuth focus', 'rationale', '',
    'source_refs', '[]'::jsonb, 'creator_source', 'mcp',
    'creator_device_id_hash', NULL, 'redaction_level', 'private',
    'target_device_preference', 'any', 'target_device_id_hash', NULL,
    'state', 'pending', 'created_at', current_setting('daypage.verifier_now'), 'expires_at', NULL, 'deleted_at', NULL
  );
  result := public.daypage_mcp_propose_system_action_v1(
    '9c000000-0000-4c00-8c00-000000000098',
    proposal || jsonb_build_object(
      'proposal_id', '9c000000-0000-4c00-8c00-000000000098',
      'payload_hash', repeat('0', 64)
    )
  );
  IF result #>> '{rejected,0,reason}' IS DISTINCT FROM 'invalid_operation' THEN
    RAISE EXCEPTION 'OAuth proposal supplied a forged payload hash: %', result;
  END IF;
  BEGIN
    PERFORM public.daypage_mcp_propose_system_action_v1(
      '9c000000-0000-4c00-8c00-000000000099',
      proposal || jsonb_build_object('creator_source', 'native')
    );
    RAISE EXCEPTION 'OAuth proposal spoofed a native creator';
  EXCEPTION WHEN invalid_parameter_value THEN
    NULL;
  END;
  BEGIN
    PERFORM public.daypage_mcp_propose_system_action_v1(
      '9c000000-0000-4c00-8c00-000000000097',
      proposal || jsonb_build_object('redaction_level', 'sensitive')
    );
    RAISE EXCEPTION 'OAuth proposal widened pre-approval disclosure';
  EXCEPTION WHEN invalid_parameter_value THEN
    NULL;
  END;
  result := public.daypage_mcp_propose_system_action_v1(
    '9c000000-0000-4c00-8c00-000000000002', proposal
  );
  IF result #>> '{accepted,0,status}' IS DISTINCT FROM 'applied' THEN
    RAISE EXCEPTION 'enabled OAuth proposal-only RPC failed: %', result;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM jsonb_array_elements(public.daypage_mcp_list_system_action_proposals_v1(10, 'pending')) item(value)
    WHERE item.value ->> 'proposal_id' = '9c000000-0000-4c00-8c00-000000000001'
      AND NOT (item.value ? 'creator_device_id_hash')
      AND NOT (item.value ? 'target_device_id_hash')
  ) THEN
    RAISE EXCEPTION 'bounded OAuth proposal projection missing proposal or leaked device hashes';
  END IF;
END
$$;
SELECT set_config(
  'request.jwt.claims',
  '{"sub":"91000000-0000-4100-8100-000000000001","role":"authenticated"}',
  true
);
SELECT public.daypage_revoke_mcp_client_grant_v1('actions-verifier-client');
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.mcp_client_grants
    WHERE user_id = auth.uid() AND client_id = 'actions-verifier-client'
      AND revoked_at IS NOT NULL
      AND NOT can_read AND NOT can_write
      AND NOT can_read_actions AND NOT can_propose_actions
  ) THEN
    RAISE EXCEPTION 'owner revoke did not clear every MCP permission';
  END IF;
END
$$;

DO $$
DECLARE
  first_claim jsonb;
  busy_claim jsonb;
  targeted_claim jsonb;
  offline_result jsonb;
  lease_mutation jsonb;
  proposal_record jsonb;
BEGIN
  offline_result := public.daypage_apply_system_action_operations_v1(jsonb_build_array(jsonb_build_object(
    'protocol_version', 1, 'operation_id', '95300000-0000-4500-8500-000000000096',
    'entity_type', 'receipt', 'entity_id', '95300000-0000-4500-8500-000000000097',
    'operation_kind', 'append', 'revision', 1,
    'record', jsonb_build_object(
      'schema_version', 1, 'receipt_id', '95300000-0000-4500-8500-000000000097',
      'proposal_id', '93000000-0000-4300-8300-000000000096', 'phase', 'execute',
      'proposal_revision', 1, 'payload_hash', current_setting('daypage.verifier_payload_hash'),
      'attempt', 1, 'outcome', 'failed', 'device_id_hash', repeat('b', 64),
      'execution_mode', 'offline_owner', 'lease_id', NULL, 'result', '{}'::jsonb,
      'error_code', 'offline_test', 'reconciliation_state', 'confirmed',
      'undo_capability', 'none', 'external_id_hash', NULL,
      'started_at', current_setting('daypage.verifier_now'),
      'completed_at', current_setting('daypage.verifier_now')
    )
  )));
  IF offline_result #>> '{rejected,0,reason}' IS DISTINCT FROM 'lease_required' THEN
    RAISE EXCEPTION 'non-target offline receipt bypassed specific-device targeting: %', offline_result;
  END IF;
  offline_result := public.daypage_apply_system_action_operations_v1(jsonb_build_array(jsonb_build_object(
    'protocol_version', 1, 'operation_id', '95300000-0000-4500-8500-000000000095',
    'entity_type', 'receipt', 'entity_id', '95300000-0000-4500-8500-000000000094',
    'operation_kind', 'append', 'revision', 1,
    'record', jsonb_build_object(
      'schema_version', 1, 'receipt_id', '95300000-0000-4500-8500-000000000094',
      'proposal_id', '93000000-0000-4300-8300-000000000095', 'phase', 'execute',
      'proposal_revision', 1, 'payload_hash', current_setting('daypage.verifier_payload_hash'),
      'attempt', 1, 'outcome', 'failed', 'device_id_hash', repeat('d', 64),
      'execution_mode', 'offline_owner', 'lease_id', NULL, 'result', '{}'::jsonb,
      'error_code', 'offline_test', 'reconciliation_state', 'confirmed',
      'undo_capability', 'none', 'external_id_hash', NULL,
      'started_at', current_setting('daypage.verifier_now'),
      'completed_at', current_setting('daypage.verifier_now')
    )
  )));
  IF offline_result #>> '{rejected,0,reason}' IS DISTINCT FROM 'lease_required' THEN
    RAISE EXCEPTION 'any-device offline receipt bypassed creating-device ownership: %', offline_result;
  END IF;
  BEGIN
    PERFORM public.daypage_claim_system_action_execution_v1(
      '95100000-0000-4500-8500-000000000003',
      '93000000-0000-4300-8300-000000000003',
      'execute', 1, current_setting('daypage.verifier_payload_hash'), repeat('d', 64), 120
    );
    RAISE EXCEPTION 'non-creator device claimed a creating-device proposal';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
  BEGIN
    PERFORM public.daypage_claim_system_action_execution_v1(
      '95100000-0000-4500-8500-000000000096',
      '93000000-0000-4300-8300-000000000096',
      'execute', 1, current_setting('daypage.verifier_payload_hash'), repeat('b', 64), 120
    );
    RAISE EXCEPTION 'non-target device claimed a specific-device proposal';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
  targeted_claim := public.daypage_claim_system_action_execution_v1(
    '95200000-0000-4500-8500-000000000096',
    '93000000-0000-4300-8300-000000000096',
    'execute', 1, current_setting('daypage.verifier_payload_hash'), repeat('d', 64), 120
  );
  IF targeted_claim ->> 'status' IS DISTINCT FROM 'claimed' THEN
    RAISE EXCEPTION 'specific target device was denied: %', targeted_claim;
  END IF;
  targeted_claim := public.daypage_claim_system_action_execution_v1(
    '95200000-0000-4500-8500-000000000095',
    '93000000-0000-4300-8300-000000000095',
    'execute', 1, current_setting('daypage.verifier_payload_hash'), repeat('d', 64), 120
  );
  IF targeted_claim ->> 'status' IS DISTINCT FROM 'claimed' THEN
    RAISE EXCEPTION 'any-device proposal denied another owned device: %', targeted_claim;
  END IF;
  first_claim := public.daypage_claim_system_action_execution_v1(
    '95000000-0000-4500-8500-000000000006',
    '93000000-0000-4300-8300-000000000003',
    'execute', 1, current_setting('daypage.verifier_payload_hash'), repeat('b', 64), 120
  );
  IF first_claim ->> 'status' IS DISTINCT FROM 'claimed' OR first_claim ->> 'lease_id' IS NULL THEN
    RAISE EXCEPTION 'first execution lease was not claimed: %', first_claim;
  END IF;
  PERFORM set_config('daypage.verifier_first_lease_id', first_claim ->> 'lease_id', true);
  SELECT (to_jsonb(current_proposal) - ARRAY[
      'user_id','change_sequence','updated_at','created_at','expires_at','deleted_at'
    ]) || jsonb_build_object(
      'created_at', to_char(current_proposal.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
      'expires_at', to_char(current_proposal.expires_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
      'deleted_at', to_char(current_proposal.deleted_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')
    )
  INTO proposal_record
  FROM public.system_action_proposals current_proposal
  WHERE current_proposal.user_id = auth.uid()
    AND current_proposal.proposal_id = '93000000-0000-4300-8300-000000000003';
  lease_mutation := public.daypage_apply_system_action_operations_v1(jsonb_build_array(jsonb_build_object(
    'protocol_version', 1, 'operation_id', '95400000-0000-4500-8500-000000000001',
    'entity_type', 'proposal', 'entity_id', '93000000-0000-4300-8300-000000000003',
    'operation_kind', 'upsert', 'revision', 2,
    'record', proposal_record || jsonb_build_object(
      'revision', 2, 'title', 'Must not mutate under lease', 'state', 'pending'
    )
  )));
  IF lease_mutation #>> '{rejected,0,reason}' IS DISTINCT FROM 'conflict' THEN
    RAISE EXCEPTION 'proposal revision changed while its execution lease was active: %', lease_mutation;
  END IF;
  busy_claim := public.daypage_claim_system_action_execution_v1(
    '95000000-0000-4500-8500-000000000007',
    '93000000-0000-4300-8300-000000000003',
    'execute', 1, current_setting('daypage.verifier_payload_hash'), repeat('b', 64), 120
  );
  IF busy_claim ->> 'status' IS DISTINCT FROM 'busy'
    OR busy_claim ->> 'lease_id' IS DISTINCT FROM first_claim ->> 'lease_id' THEN
    RAISE EXCEPTION 'concurrent execution lease was not excluded: %', busy_claim;
  END IF;
END
$$;

RESET ROLE;
UPDATE public.system_action_execution_leases
SET created_at = date_trunc('milliseconds', now() - interval '2 seconds'),
    expires_at = date_trunc('milliseconds', now() - interval '1 second')
WHERE user_id = '91000000-0000-4100-8100-000000000001'
  AND proposal_id = '93000000-0000-4300-8300-000000000003'
  AND released_at IS NULL;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '91000000-0000-4100-8100-000000000001', true);
SELECT set_config('request.jwt.claims', '{"sub":"91000000-0000-4100-8100-000000000001","role":"authenticated"}', true);

DO $$
DECLARE
  recovered_claim jsonb;
  stale_competing_claim jsonb;
  replayed_claim jsonb;
  receipt_result jsonb;
  duplicate_result jsonb;
  revision_result jsonb;
  proposal_record jsonb;
  original_lease_id uuid;
BEGIN
  original_lease_id := current_setting('daypage.verifier_first_lease_id')::uuid;
  recovered_claim := public.daypage_claim_system_action_execution_v1(
    '95000000-0000-4500-8500-000000000006',
    '93000000-0000-4300-8300-000000000003',
    'execute', 1, current_setting('daypage.verifier_payload_hash'), repeat('b', 64), 120
  );
  IF recovered_claim ->> 'status' IS DISTINCT FROM 'busy'
    OR (recovered_claim ->> 'lease_id')::uuid IS DISTINCT FROM original_lease_id
    OR recovered_claim ->> 'issued_at' IS NULL
    OR (recovered_claim ->> 'expires_at')::timestamptz > now() THEN
    RAISE EXCEPTION 'same-operation expired execution lease became executable: %', recovered_claim;
  END IF;
  stale_competing_claim := public.daypage_claim_system_action_execution_v1(
    '95000000-0000-4500-8500-000000000008',
    '93000000-0000-4300-8300-000000000003',
    'execute', 1, current_setting('daypage.verifier_payload_hash'), repeat('b', 64), 120
  );
  IF stale_competing_claim ->> 'status' IS DISTINCT FROM 'busy'
    OR stale_competing_claim ->> 'lease_id' IS DISTINCT FROM recovered_claim ->> 'lease_id' THEN
    RAISE EXCEPTION 'expired unreceipted lease was reassigned to another operation: %', stale_competing_claim;
  END IF;
  replayed_claim := public.daypage_claim_system_action_execution_v1(
    '95000000-0000-4500-8500-000000000006',
    '93000000-0000-4300-8300-000000000003',
    'execute', 1, current_setting('daypage.verifier_payload_hash'), repeat('b', 64), 120
  );
  IF replayed_claim ->> 'status' IS DISTINCT FROM 'busy'
    OR replayed_claim ->> 'lease_id' IS DISTINCT FROM recovered_claim ->> 'lease_id' THEN
    RAISE EXCEPTION 'exact expired claim retry became executable: %', replayed_claim;
  END IF;
  BEGIN
    PERFORM public.daypage_claim_system_action_execution_v1(
      '95000000-0000-4500-8500-000000000006',
      '93000000-0000-4300-8300-000000000003',
      'execute', 1, current_setting('daypage.verifier_payload_hash'), repeat('d', 64), 120
    );
    RAISE EXCEPTION 'claim operation id accepted a fingerprint mismatch';
  EXCEPTION WHEN invalid_parameter_value THEN
    NULL;
  END;

  revision_result := public.daypage_apply_system_action_operations_v1(jsonb_build_array(jsonb_build_object(
    'protocol_version', 1,
    'operation_id', '97000000-0000-4700-8700-000000000108',
    'entity_type', 'policy',
    'entity_id', '9d000000-0000-4d00-8d00-000000000001',
    'operation_kind', 'upsert', 'revision', 2,
    'record', jsonb_build_object(
      'schema_version', 1, 'policy_id', '9d000000-0000-4d00-8d00-000000000001',
      'capability', 'calendar', 'revision', 2, 'is_offered', true,
      'sync_enabled', false, 'disclosure_level', 'private',
      'updated_at', current_setting('daypage.verifier_now'), 'deleted_at', NULL
    )
  )));
  IF revision_result #>> '{accepted,0,status}' IS DISTINCT FROM 'applied' THEN
    RAISE EXCEPTION 'policy downgrade during lease failed: %', revision_result;
  END IF;

  receipt_result := public.daypage_apply_system_action_operations_v1(jsonb_build_array(jsonb_build_object(
    'protocol_version', 1,
    'operation_id', '97000000-0000-4700-8700-000000000009',
    'entity_type', 'receipt',
    'entity_id', '98000000-0000-4800-8800-000000000009',
    'operation_kind', 'append',
    'revision', 1,
    'record', jsonb_build_object(
      'schema_version', 1,
      'receipt_id', '98000000-0000-4800-8800-000000000009',
      'proposal_id', '93000000-0000-4300-8300-000000000003',
      'phase', 'execute', 'proposal_revision', 1,
      'payload_hash', current_setting('daypage.verifier_payload_hash'), 'attempt', 1,
      'outcome', 'failed', 'device_id_hash', repeat('b', 64),
      'execution_mode', 'online_lease', 'lease_id', recovered_claim ->> 'lease_id',
      'result', jsonb_build_object('summary', 'Calendar adapter failed before commit'),
      'error_code', 'adapter_failed', 'reconciliation_state', 'not_applicable',
      'undo_capability', 'none', 'external_id_hash', NULL,
      'started_at', recovered_claim ->> 'issued_at',
      'completed_at', current_setting('daypage.verifier_now')
    )
  )));
  IF receipt_result #>> '{accepted,0,status}' IS DISTINCT FROM 'applied' THEN
    RAISE EXCEPTION 'failed attempt receipt after policy downgrade was not accepted: %', receipt_result;
  END IF;

  revision_result := public.daypage_apply_system_action_operations_v1(jsonb_build_array(jsonb_build_object(
    'protocol_version', 1,
    'operation_id', '97000000-0000-4700-8700-000000000109',
    'entity_type', 'policy',
    'entity_id', '9d000000-0000-4d00-8d00-000000000001',
    'operation_kind', 'upsert', 'revision', 3,
    'record', jsonb_build_object(
      'schema_version', 1, 'policy_id', '9d000000-0000-4d00-8d00-000000000001',
      'capability', 'calendar', 'revision', 3, 'is_offered', true,
      'sync_enabled', true, 'disclosure_level', 'full_proposal',
      'updated_at', current_setting('daypage.verifier_now'), 'deleted_at', NULL
    )
  )));
  IF revision_result #>> '{accepted,0,status}' IS DISTINCT FROM 'applied' THEN
    RAISE EXCEPTION 'policy restore after lease receipt failed: %', revision_result;
  END IF;

  replayed_claim := public.daypage_claim_system_action_execution_v1(
    '95000000-0000-4500-8500-000000000006',
    '93000000-0000-4300-8300-000000000003',
    'execute', 1, current_setting('daypage.verifier_payload_hash'), repeat('b', 64), 120
  );
  IF replayed_claim ->> 'status' IS DISTINCT FROM 'attempt_completed'
    OR replayed_claim ->> 'lease_id' IS NOT NULL
    OR replayed_claim ->> 'expires_at' IS NOT NULL
    OR replayed_claim ->> 'receipt_id' IS DISTINCT FROM '98000000-0000-4800-8800-000000000009' THEN
    RAISE EXCEPTION 'exact failed-attempt retry resurrected its released lease: %', replayed_claim;
  END IF;

  recovered_claim := public.daypage_claim_system_action_execution_v1(
    '95000000-0000-4500-8500-000000000009',
    '93000000-0000-4300-8300-000000000003',
    'execute', 1, current_setting('daypage.verifier_payload_hash'), repeat('b', 64), 120
  );
  IF recovered_claim ->> 'status' IS DISTINCT FROM 'claimed'
    OR recovered_claim ->> 'lease_id' IS NULL
    OR (recovered_claim ->> 'lease_id')::uuid = original_lease_id THEN
    RAISE EXCEPTION 'fresh attempt did not receive a distinct lease after failure: %', recovered_claim;
  END IF;

  duplicate_result := public.daypage_apply_system_action_operations_v1(jsonb_build_array(jsonb_build_object(
    'protocol_version', 1,
    'operation_id', '97000000-0000-4700-8700-000000000019',
    'entity_type', 'receipt',
    'entity_id', '98000000-0000-4800-8800-000000000019',
    'operation_kind', 'append',
    'revision', 2,
    'record', (receipt_result #> '{accepted,0,record}') || jsonb_build_object(
      'receipt_id', '98000000-0000-4800-8800-000000000019',
      'attempt', 2,
      'lease_id', recovered_claim ->> 'lease_id'
    )
  )));
  IF duplicate_result #>> '{rejected,0,reason}' IS DISTINCT FROM 'invalid_operation' THEN
    RAISE EXCEPTION 'attempt counter was accepted as the receipt operation revision: %', duplicate_result;
  END IF;

  receipt_result := public.daypage_apply_system_action_operations_v1(jsonb_build_array(jsonb_build_object(
    'protocol_version', 1,
    'operation_id', '97000000-0000-4700-8700-000000000010',
    'entity_type', 'receipt',
    'entity_id', '98000000-0000-4800-8800-000000000010',
    'operation_kind', 'append',
    'revision', 1,
    'record', jsonb_build_object(
      'schema_version', 1,
      'receipt_id', '98000000-0000-4800-8800-000000000010',
      'proposal_id', '93000000-0000-4300-8300-000000000003',
      'phase', 'execute', 'proposal_revision', 1,
      'payload_hash', current_setting('daypage.verifier_payload_hash'), 'attempt', 2,
      'outcome', 'ambiguous', 'device_id_hash', repeat('b', 64),
      'execution_mode', 'online_lease', 'lease_id', recovered_claim ->> 'lease_id',
      'result', jsonb_build_object('summary', 'Calendar write outcome requires reconciliation'),
      'error_code', 'write_ambiguous', 'reconciliation_state', 'needs_review',
      'undo_capability', 'manual', 'external_id_hash', NULL,
      'started_at', current_setting('daypage.verifier_now'),
      'completed_at', current_setting('daypage.verifier_now')
    )
  )));
  IF receipt_result #>> '{accepted,0,status}' IS DISTINCT FROM 'applied'
    OR receipt_result #>> '{accepted,0,revision}' IS DISTINCT FROM '1'
    OR receipt_result #>> '{accepted,0,record,attempt}' IS DISTINCT FROM '2' THEN
    RAISE EXCEPTION 'attempt-2 receipt did not retain proposal revision 1: %', receipt_result;
  END IF;

  replayed_claim := public.daypage_claim_system_action_execution_v1(
    '95000000-0000-4500-8500-000000000009',
    '93000000-0000-4300-8300-000000000003',
    'execute', 1, current_setting('daypage.verifier_payload_hash'), repeat('b', 64), 120
  );
  IF replayed_claim ->> 'status' IS DISTINCT FROM 'attempt_completed'
    OR replayed_claim ->> 'lease_id' IS NOT NULL
    OR replayed_claim ->> 'receipt_id' IS DISTINCT FROM '98000000-0000-4800-8800-000000000010' THEN
    RAISE EXCEPTION 'exact ambiguous-attempt retry resurrected its released lease: %', replayed_claim;
  END IF;

  recovered_claim := public.daypage_claim_system_action_execution_v1(
    '95000000-0000-4500-8500-000000000011',
    '93000000-0000-4300-8300-000000000003',
    'execute', 1, current_setting('daypage.verifier_payload_hash'), repeat('b', 64), 120
  );
  IF recovered_claim ->> 'status' IS DISTINCT FROM 'claimed'
    OR recovered_claim ->> 'lease_id' IS NULL THEN
    RAISE EXCEPTION 'reconciled fresh attempt did not receive a lease after ambiguity: %', recovered_claim;
  END IF;

  receipt_result := public.daypage_apply_system_action_operations_v1(jsonb_build_array(jsonb_build_object(
    'protocol_version', 1,
    'operation_id', '97000000-0000-4700-8700-000000000011',
    'entity_type', 'receipt',
    'entity_id', '98000000-0000-4800-8800-000000000011',
    'operation_kind', 'append',
    'revision', 1,
    'record', jsonb_build_object(
      'schema_version', 1,
      'receipt_id', '98000000-0000-4800-8800-000000000011',
      'proposal_id', '93000000-0000-4300-8300-000000000003',
      'phase', 'execute', 'proposal_revision', 1,
      'payload_hash', current_setting('daypage.verifier_payload_hash'), 'attempt', 3,
      'outcome', 'succeeded', 'device_id_hash', repeat('b', 64),
      'execution_mode', 'online_lease', 'lease_id', recovered_claim ->> 'lease_id',
      'result', jsonb_build_object('summary', 'Calendar event reconciled and created', 'resource_kind', 'calendar_event', 'scheduled_at', NULL, 'ended_at', NULL),
      'error_code', NULL, 'reconciliation_state', 'confirmed',
      'undo_capability', 'reversible', 'external_id_hash', repeat('e', 64),
      'started_at', current_setting('daypage.verifier_now'),
      'completed_at', current_setting('daypage.verifier_now')
    )
  )));
  IF receipt_result #>> '{accepted,0,status}' IS DISTINCT FROM 'applied' THEN
    RAISE EXCEPTION 'successful third-attempt receipt failed: %', receipt_result;
  END IF;

  duplicate_result := public.daypage_apply_system_action_operations_v1(jsonb_build_array(jsonb_build_object(
    'protocol_version', 1,
    'operation_id', '97000000-0000-4700-8700-000000000012',
    'entity_type', 'receipt',
    'entity_id', '98000000-0000-4800-8800-000000000012',
    'operation_kind', 'append',
    'revision', 1,
    'record', receipt_result #> '{accepted,0,record}' || jsonb_build_object(
      'receipt_id', '98000000-0000-4800-8800-000000000012'
    )
  )));
  IF duplicate_result #>> '{rejected,0,reason}' IS DISTINCT FROM 'conflict' THEN
    RAISE EXCEPTION 'duplicate execute attempt was not rejected: %', duplicate_result;
  END IF;

  recovered_claim := public.daypage_claim_system_action_execution_v1(
    '95000000-0000-4500-8500-000000000013',
    '93000000-0000-4300-8300-000000000003',
    'execute', 1, current_setting('daypage.verifier_payload_hash'), repeat('b', 64), 120
  );
  IF recovered_claim ->> 'status' IS DISTINCT FROM 'already_completed'
    OR recovered_claim ->> 'receipt_id' IS DISTINCT FROM '98000000-0000-4800-8800-000000000011' THEN
    RAISE EXCEPTION 'historical successful receipt did not stop duplicate execution: %', recovered_claim;
  END IF;

  SELECT (to_jsonb(current_proposal) - ARRAY[
      'user_id','change_sequence','updated_at','created_at','expires_at','deleted_at'
    ]) || jsonb_build_object(
      'created_at', to_char(current_proposal.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
      'expires_at', to_char(current_proposal.expires_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
      'deleted_at', to_char(current_proposal.deleted_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')
    )
  INTO proposal_record
  FROM public.system_action_proposals current_proposal
  WHERE current_proposal.user_id = auth.uid()
    AND current_proposal.proposal_id = '93000000-0000-4300-8300-000000000003';
  revision_result := public.daypage_apply_system_action_operations_v1(jsonb_build_array(jsonb_build_object(
    'protocol_version', 1, 'operation_id', '95400000-0000-4500-8500-000000000002',
    'entity_type', 'proposal', 'entity_id', '93000000-0000-4300-8300-000000000003',
    'operation_kind', 'upsert', 'revision', 2,
    'record', proposal_record || jsonb_build_object(
      'revision', 2, 'title', 'Must not revise after receipt', 'state', 'pending'
    )
  )));
  IF revision_result #>> '{rejected,0,reason}' IS DISTINCT FROM 'conflict' THEN
    RAISE EXCEPTION 'proposal revision changed after execution evidence existed: %', revision_result;
  END IF;
END
$$;

DO $$
DECLARE
  result jsonb;
  undo_claim jsonb;
  pull_page jsonb;
  next_page jsonb;
BEGIN
  result := public.daypage_apply_system_action_operations_v1(jsonb_build_array(jsonb_build_object(
    'protocol_version', 1,
    'operation_id', '99000000-0000-4900-8900-000000000011',
    'entity_type', 'approval',
    'entity_id', '99000000-0000-4900-8900-000000000012',
    'operation_kind', 'append',
    'revision', 1,
    'record', jsonb_build_object(
      'schema_version', 1, 'approval_id', '99000000-0000-4900-8900-000000000012',
      'proposal_id', '93000000-0000-4300-8300-000000000003',
      'phase', 'undo', 'proposal_revision', 1, 'payload_hash', current_setting('daypage.verifier_payload_hash'),
      'decision', 'approve', 'device_id_hash', repeat('b', 64),
      'decided_at', current_setting('daypage.verifier_now'), 'has_replacement', false
    )
  )));
  IF result #>> '{accepted,0,status}' IS DISTINCT FROM 'applied' THEN
    RAISE EXCEPTION 'undo approval failed: %', result;
  END IF;
  undo_claim := public.daypage_claim_system_action_execution_v1(
    '99000000-0000-4900-8900-000000000013',
    '93000000-0000-4300-8300-000000000003',
    'undo', 1, current_setting('daypage.verifier_payload_hash'), repeat('b', 64), 120
  );
  IF undo_claim ->> 'status' IS DISTINCT FROM 'claimed' THEN
    RAISE EXCEPTION 'undo lease was not claimed: %', undo_claim;
  END IF;
  result := public.daypage_apply_system_action_operations_v1(jsonb_build_array(jsonb_build_object(
    'protocol_version', 1,
    'operation_id', '99000000-0000-4900-8900-000000000014',
    'entity_type', 'receipt',
    'entity_id', '99000000-0000-4900-8900-000000000015',
    'operation_kind', 'append',
    'revision', 1,
    'record', jsonb_build_object(
      'schema_version', 1, 'receipt_id', '99000000-0000-4900-8900-000000000015',
      'proposal_id', '93000000-0000-4300-8300-000000000003',
      'phase', 'undo', 'proposal_revision', 1, 'payload_hash', current_setting('daypage.verifier_payload_hash'),
      'attempt', 1, 'outcome', 'succeeded', 'device_id_hash', repeat('b', 64),
      'execution_mode', 'online_lease', 'lease_id', undo_claim ->> 'lease_id',
      'result', jsonb_build_object('summary', 'Calendar event removed', 'resource_kind', 'calendar_event', 'scheduled_at', NULL, 'ended_at', NULL),
      'error_code', NULL, 'reconciliation_state', 'confirmed',
      'undo_capability', 'reversible', 'external_id_hash', repeat('e', 64),
      'started_at', current_setting('daypage.verifier_now'),
      'completed_at', current_setting('daypage.verifier_now')
    )
  )));
  IF result #>> '{accepted,0,status}' IS DISTINCT FROM 'applied' THEN
    RAISE EXCEPTION 'undo receipt failed: %', result;
  END IF;

  result := public.daypage_apply_system_action_operations_v1(jsonb_build_array(
    jsonb_build_object(
      'protocol_version', 1, 'operation_id', '99000000-0000-4900-8900-000000000016',
      'entity_type', 'policy', 'entity_id', '99000000-0000-4900-8900-000000000017',
      'operation_kind', 'upsert', 'revision', 1,
      'record', jsonb_build_object(
        'schema_version', 1, 'policy_id', '99000000-0000-4900-8900-000000000017',
        'capability', 'health_context', 'revision', 1, 'is_offered', true,
        'sync_enabled', true, 'disclosure_level', 'summary',
        'updated_at', current_setting('daypage.verifier_now'), 'deleted_at', NULL
      )
    ),
    jsonb_build_object(
      'protocol_version', 1, 'operation_id', '99000000-0000-4900-8900-000000000018',
      'entity_type', 'policy', 'entity_id', '99000000-0000-4900-8900-000000000017',
      'operation_kind', 'delete', 'revision', 2,
      'record', jsonb_build_object(
        'schema_version', 1, 'policy_id', '99000000-0000-4900-8900-000000000017',
        'capability', 'health_context', 'revision', 2, 'is_offered', false,
        'sync_enabled', false, 'disclosure_level', 'private',
        'updated_at', current_setting('daypage.verifier_now'),
        'deleted_at', current_setting('daypage.verifier_now')
      )
    )
  ));
  IF jsonb_array_length(result -> 'accepted') <> 2 THEN
    RAISE EXCEPTION 'policy upsert/delete did not produce tombstone: %', result;
  END IF;

  pull_page := public.daypage_pull_system_action_changes_v1(0, 1);
  IF jsonb_array_length(pull_page -> 'changes') <> 1
    OR NOT (pull_page ->> 'has_more')::boolean
    OR (pull_page ->> 'next_cursor')::bigint <= 0 THEN
    RAISE EXCEPTION 'first action pull page is not monotonic/paginated: %', pull_page;
  END IF;
  next_page := public.daypage_pull_system_action_changes_v1((pull_page ->> 'next_cursor')::bigint, 200);
  IF NOT EXISTS (
    SELECT 1 FROM jsonb_array_elements(next_page -> 'changes') change(value)
    WHERE change.value ->> 'entity_type' = 'policy'
      AND change.value #>> '{record,policy_id}' = '99000000-0000-4900-8900-000000000017'
      AND change.value #>> '{record,deleted_at}' IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'action pull omitted policy tombstone: %', next_page;
  END IF;
END
$$;

RESET ROLE;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '92000000-0000-4200-8200-000000000002', true);
SELECT set_config('request.jwt.claims', '{"sub":"92000000-0000-4200-8200-000000000002","role":"authenticated"}', true);

DO $$
DECLARE
  result jsonb;
BEGIN
  IF (SELECT count(*) FROM public.system_action_proposals) <> 0
    OR (SELECT count(*) FROM public.system_action_approvals) <> 0
    OR (SELECT count(*) FROM public.system_action_receipts) <> 0
    OR (SELECT count(*) FROM public.system_action_capability_policies) <> 0 THEN
    RAISE EXCEPTION 'tenant B can directly read tenant A system actions';
  END IF;
  IF jsonb_array_length(public.daypage_pull_system_action_changes_v1(0, 200) -> 'changes') <> 0 THEN
    RAISE EXCEPTION 'tenant B pulled tenant A system actions';
  END IF;
  result := public.daypage_apply_system_action_operations_v1(jsonb_build_array(jsonb_build_object(
    'protocol_version', 1,
    'operation_id', '92000000-0000-4200-8200-000000000020',
    'entity_type', 'approval',
    'entity_id', '92000000-0000-4200-8200-000000000021',
    'operation_kind', 'append', 'revision', 1,
    'record', jsonb_build_object(
      'schema_version', 1, 'approval_id', '92000000-0000-4200-8200-000000000021',
      'proposal_id', '93000000-0000-4300-8300-000000000003',
      'phase', 'execute', 'proposal_revision', 1, 'payload_hash', current_setting('daypage.verifier_payload_hash'),
      'decision', 'approve', 'device_id_hash', repeat('b', 64),
      'decided_at', current_setting('daypage.verifier_now'), 'has_replacement', false
    )
  )));
  IF result #>> '{rejected,0,reason}' IS DISTINCT FROM 'approval_mismatch' THEN
    RAISE EXCEPTION 'tenant B affected tenant A proposal: %', result;
  END IF;
END
$$;

RESET ROLE;

INSERT INTO public.api_keys (id, user_id, name, key_hash, key_prefix, scopes)
VALUES
  ('9a000000-0000-4a00-8a00-000000000001', '91000000-0000-4100-8100-000000000001',
    'actions default-off', repeat('1', 64), 'default-off', '["read","write"]'::jsonb),
  ('9a000000-0000-4a00-8a00-000000000002', '91000000-0000-4100-8100-000000000001',
    'actions scoped', repeat('2', 64), 'actions-scoped', '["read","actions:read","actions:propose"]'::jsonb),
  ('9a000000-0000-4a00-8a00-000000000003', '91000000-0000-4100-8100-000000000001',
    'legacy admin default-off', repeat('3', 64), 'legacy-admin', '["admin"]'::jsonb);

SET LOCAL ROLE anon;
DO $$
DECLARE
  grant_result jsonb;
  propose_result jsonb;
  proposal jsonb;
  proposal_list jsonb;
  receipt_list jsonb;
BEGIN
  grant_result := public.daypage_mcp_action_api_key_request_v1(repeat('1', 64), 'resolve_grant', '{}'::jsonb);
  IF (grant_result ->> 'can_read_actions')::boolean
    OR (grant_result ->> 'can_propose_actions')::boolean THEN
    RAISE EXCEPTION 'legacy PAT scopes silently enabled actions: %', grant_result;
  END IF;
  BEGIN
    PERFORM public.daypage_mcp_action_api_key_request_v1(
      repeat('1', 64), 'propose_action',
      jsonb_build_object('operation_id', gen_random_uuid(), 'proposal', '{}'::jsonb)
    );
    RAISE EXCEPTION 'default-off PAT proposed an action';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;

  grant_result := public.daypage_mcp_action_api_key_request_v1(repeat('3', 64), 'resolve_grant', '{}'::jsonb);
  IF (grant_result ->> 'can_read_actions')::boolean
    OR (grant_result ->> 'can_propose_actions')::boolean THEN
    RAISE EXCEPTION 'legacy admin PAT silently enabled actions: %', grant_result;
  END IF;
  BEGIN
    PERFORM public.daypage_mcp_action_api_key_request_v1(
      repeat('3', 64), 'propose_action',
      jsonb_build_object('operation_id', gen_random_uuid(), 'proposal', '{}'::jsonb)
    );
    RAISE EXCEPTION 'legacy admin PAT proposed an action without an explicit action scope';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;

  grant_result := public.daypage_mcp_action_api_key_request_v1(repeat('2', 64), 'resolve_grant', '{}'::jsonb);
  IF NOT (grant_result ->> 'can_read_actions')::boolean
    OR NOT (grant_result ->> 'can_propose_actions')::boolean THEN
    RAISE EXCEPTION 'scoped PAT did not receive independent action grants: %', grant_result;
  END IF;
  proposal := jsonb_build_object(
    'schema_version', 1, 'proposal_id', '9b000000-0000-4b00-8b00-000000000001',
    'revision', 1, 'kind', 'focus_session',
    'payload', jsonb_build_object('kind', 'focus_session', 'title', 'PAT focus', 'duration_seconds', 1200, 'schedule_end_alert', true, 'allow_live_activity', true),
    'payload_hash', '61f9b3d097987b2cd459c863a8d21ff7d20a7c07d3b63e665ef438a41c5661bf', 'title', 'Start PAT focus', 'rationale', '',
    'source_refs', '[]'::jsonb, 'creator_source', 'mcp',
    'creator_device_id_hash', NULL, 'redaction_level', 'private',
    'target_device_preference', 'any', 'target_device_id_hash', NULL,
    'state', 'pending', 'created_at', current_setting('daypage.verifier_now'), 'expires_at', NULL, 'deleted_at', NULL
  );
  propose_result := public.daypage_mcp_action_api_key_request_v1(
    repeat('2', 64), 'propose_action',
    jsonb_build_object('operation_id', '9b000000-0000-4b00-8b00-000000000002', 'proposal', proposal)
  );
  IF propose_result #>> '{accepted,0,status}' IS DISTINCT FROM 'applied' THEN
    RAISE EXCEPTION 'scoped PAT proposal failed: %', propose_result;
  END IF;
  proposal_list := public.daypage_mcp_action_api_key_request_v1(
    repeat('2', 64), 'list_action_proposals', '{"limit":50}'::jsonb
  );
  IF jsonb_array_length(proposal_list) < 1 THEN
    RAISE EXCEPTION 'scoped PAT could not list action proposals';
  END IF;
  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(proposal_list) item(value)
    WHERE item.value ? 'creator_device_id_hash' OR item.value ? 'target_device_id_hash'
  ) THEN
    RAISE EXCEPTION 'PAT proposal projection leaked device hashes';
  END IF;
  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(proposal_list) item(value)
    WHERE jsonb_typeof(item.value -> 'created_at') IS DISTINCT FROM 'string'
      OR item.value ->> 'created_at' !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z$'
      OR (
        jsonb_typeof(item.value -> 'expires_at') IS DISTINCT FROM 'string'
        AND jsonb_typeof(item.value -> 'expires_at') IS DISTINCT FROM 'null'
      )
      OR (
        jsonb_typeof(item.value -> 'expires_at') = 'string'
        AND item.value ->> 'expires_at' !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z$'
      )
      OR (
        jsonb_typeof(item.value -> 'deleted_at') IS DISTINCT FROM 'string'
        AND jsonb_typeof(item.value -> 'deleted_at') IS DISTINCT FROM 'null'
      )
      OR (
        jsonb_typeof(item.value -> 'deleted_at') = 'string'
        AND item.value ->> 'deleted_at' !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z$'
      )
  ) THEN
    RAISE EXCEPTION 'PAT proposal projection emitted noncanonical timestamps: %', proposal_list;
  END IF;

  receipt_list := public.daypage_mcp_action_api_key_request_v1(
    repeat('2', 64), 'list_action_receipts', '{"limit":50}'::jsonb
  );
  IF jsonb_array_length(receipt_list) < 1 THEN
    RAISE EXCEPTION 'scoped PAT could not list action receipts';
  END IF;
  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(receipt_list) item(value)
    WHERE jsonb_typeof(item.value -> 'started_at') IS DISTINCT FROM 'string'
      OR item.value ->> 'started_at' !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z$'
      OR jsonb_typeof(item.value -> 'completed_at') IS DISTINCT FROM 'string'
      OR item.value ->> 'completed_at' !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z$'
  ) THEN
    RAISE EXCEPTION 'PAT receipt projection emitted noncanonical timestamps: %', receipt_list;
  END IF;
END
$$;

RESET ROLE;

-- Attempts are monotonic within one executor identity. Two devices may both
-- report attempt N after a sequential lease handoff (for example when the
-- second device had not pulled the first device's failed receipt yet). The
-- lease is the cross-device exclusion proof, so the database must retain both
-- immutable receipts instead of rejecting the later native side effect.
INSERT INTO public.system_action_receipts (
  user_id, receipt_id, proposal_id, phase, proposal_revision, payload_hash,
  attempt, outcome, device_id_hash, execution_mode, lease_id, result,
  error_code, reconciliation_state, undo_capability, external_id_hash,
  started_at, completed_at
) VALUES
  (
    '91000000-0000-4100-8100-000000000001',
    '9e000000-0000-4e00-8e00-000000000001',
    '93000000-0000-4300-8300-000000000003', 'execute', 1,
    current_setting('daypage.verifier_payload_hash'), 77, 'failed',
    repeat('c', 64), 'offline_owner', NULL, '{}'::jsonb, 'device_c_failure',
    'confirmed', 'none', NULL, now(), now()
  ),
  (
    '91000000-0000-4100-8100-000000000001',
    '9e000000-0000-4e00-8e00-000000000002',
    '93000000-0000-4300-8300-000000000003', 'execute', 1,
    current_setting('daypage.verifier_payload_hash'), 77, 'failed',
    repeat('d', 64), 'offline_owner', NULL, '{}'::jsonb, 'device_d_failure',
    'confirmed', 'none', NULL, now(), now()
  );
DO $$
BEGIN
  IF (
    SELECT count(*) FROM public.system_action_receipts
    WHERE user_id = '91000000-0000-4100-8100-000000000001'
      AND proposal_id = '93000000-0000-4300-8300-000000000003'
      AND phase = 'execute' AND attempt = 77
  ) <> 2 THEN
    RAISE EXCEPTION 'cross-device same-number attempts were not both retained';
  END IF;
END
$$;

ROLLBACK;

SELECT 'daypage system actions / two-tenant RLS / lease / OAuth+PAT verification passed' AS result;
