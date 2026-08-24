-- #873: bind idempotent sync receipts to the immutable operation tuple.
--
-- A previously accepted operation_id may be retried, but it must never be
-- reused for a different memo, kind, or revision. Otherwise a damaged client
-- outbox could mistake an unrelated historical receipt for cloud durability.

CREATE OR REPLACE FUNCTION public.daypage_apply_sync_operations(p_operations jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_operation jsonb;
  v_operation_id uuid;
  v_memo_id uuid;
  v_kind text;
  v_revision bigint;
  v_modified_at timestamptz;
  v_payload jsonb;
  v_remote_revision bigint;
  v_status text;
  v_stored_memo_id uuid;
  v_stored_kind text;
  v_stored_revision bigint;
  v_accepted jsonb := '[]'::jsonb;
  v_rejected jsonb := '[]'::jsonb;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'authentication required' USING ERRCODE = '42501';
  END IF;
  IF jsonb_typeof(p_operations) <> 'array' THEN
    RAISE EXCEPTION 'p_operations must be an array' USING ERRCODE = '22023';
  END IF;
  IF jsonb_array_length(p_operations) > 100 THEN
    RAISE EXCEPTION 'at most 100 operations are allowed' USING ERRCODE = '22023';
  END IF;

  FOR v_operation IN SELECT value FROM jsonb_array_elements(p_operations)
  LOOP
    BEGIN
      v_operation_id := (v_operation ->> 'operation_id')::uuid;
      v_memo_id := (v_operation ->> 'memo_id')::uuid;
      v_kind := v_operation ->> 'kind';
      v_revision := (v_operation ->> 'revision')::bigint;
      v_modified_at := (v_operation ->> 'modified_at')::timestamptz;
      v_payload := COALESCE(v_operation -> 'payload', '{}'::jsonb);

      IF v_kind NOT IN ('upsert', 'delete') OR v_revision < 1 THEN
        RAISE EXCEPTION 'invalid operation';
      END IF;

      SELECT memo_id, kind, revision, status
      INTO v_stored_memo_id, v_stored_kind, v_stored_revision, v_status
      FROM public.sync_operations
      WHERE user_id = v_user_id AND operation_id = v_operation_id;

      IF FOUND THEN
        IF v_stored_memo_id <> v_memo_id
          OR v_stored_kind <> v_kind
          OR v_stored_revision <> v_revision THEN
          RAISE EXCEPTION 'operation id reuse mismatch';
        END IF;
        SELECT sync_revision INTO v_remote_revision
        FROM public.memos
        WHERE id = v_stored_memo_id AND user_id = v_user_id;
      ELSE
        v_remote_revision := NULL;
        IF v_kind = 'upsert' THEN
          INSERT INTO public.memos (
            id, user_id, type, body, created_at, pinned_at, location, weather,
            device, origin, source, vault_path, updated_at, source_modified_at,
            content_hash, sync_revision, last_sync_device_id, deleted_at
          ) VALUES (
            v_memo_id,
            v_user_id,
            CASE WHEN v_payload ->> 'type' IN ('text','url','voice','photo','file')
              THEN (v_payload ->> 'type')::public.memo_type ELSE 'text'::public.memo_type END,
            COALESCE(v_payload ->> 'body', ''),
            COALESCE((v_payload ->> 'created_at')::timestamptz, v_modified_at),
            (v_payload ->> 'pinned_at')::timestamptz,
            v_payload -> 'location',
            v_payload -> 'weather',
            NULLIF(v_payload ->> 'device', ''),
            'ios'::public.origin,
            COALESCE(NULLIF(v_payload ->> 'source', ''), 'ios'),
            NULLIF(v_payload ->> 'vault_path', ''),
            v_modified_at,
            v_modified_at,
            NULLIF(v_operation ->> 'content_hash', ''),
            v_revision,
            NULLIF(v_operation ->> 'device_id', ''),
            NULL
          )
          ON CONFLICT (id) DO UPDATE SET
            type = EXCLUDED.type,
            body = EXCLUDED.body,
            pinned_at = EXCLUDED.pinned_at,
            location = EXCLUDED.location,
            weather = EXCLUDED.weather,
            device = EXCLUDED.device,
            origin = EXCLUDED.origin,
            source = EXCLUDED.source,
            vault_path = EXCLUDED.vault_path,
            updated_at = EXCLUDED.updated_at,
            source_modified_at = EXCLUDED.source_modified_at,
            content_hash = EXCLUDED.content_hash,
            sync_revision = EXCLUDED.sync_revision,
            last_sync_device_id = EXCLUDED.last_sync_device_id,
            deleted_at = NULL
          WHERE memos.user_id = v_user_id AND memos.sync_revision < EXCLUDED.sync_revision
          RETURNING sync_revision INTO v_remote_revision;
        ELSE
          INSERT INTO public.memos (
            id, user_id, type, body, created_at, origin, source, updated_at,
            source_modified_at, sync_revision, last_sync_device_id, deleted_at
          ) VALUES (
            v_memo_id, v_user_id, 'text'::public.memo_type, '', v_modified_at,
            'ios'::public.origin, 'ios', v_modified_at, v_modified_at, v_revision,
            NULLIF(v_operation ->> 'device_id', ''), v_modified_at
          )
          ON CONFLICT (id) DO UPDATE SET
            updated_at = EXCLUDED.updated_at,
            source_modified_at = EXCLUDED.source_modified_at,
            sync_revision = EXCLUDED.sync_revision,
            last_sync_device_id = EXCLUDED.last_sync_device_id,
            deleted_at = EXCLUDED.deleted_at
          WHERE memos.user_id = v_user_id AND memos.sync_revision < EXCLUDED.sync_revision
          RETURNING sync_revision INTO v_remote_revision;
        END IF;

        IF v_remote_revision IS NULL THEN
          SELECT sync_revision INTO v_remote_revision
          FROM public.memos WHERE id = v_memo_id AND user_id = v_user_id;
          IF v_remote_revision IS NULL THEN
            RAISE EXCEPTION 'memo id conflicts with another tenant';
          END IF;
          v_status := 'stale';
        ELSE
          v_status := 'applied';
        END IF;

        INSERT INTO public.sync_operations (
          user_id, operation_id, memo_id, kind, revision, status
        ) VALUES (
          v_user_id, v_operation_id, v_memo_id, v_kind, v_revision, v_status
        ) ON CONFLICT (user_id, operation_id) DO NOTHING;
      END IF;

      v_accepted := v_accepted || jsonb_build_array(jsonb_build_object(
        'operation_id', v_operation_id,
        'memo_id', v_memo_id,
        'revision', v_revision,
        'remote_revision', v_remote_revision,
        'status', v_status
      ));
    EXCEPTION WHEN OTHERS THEN
      v_rejected := v_rejected || jsonb_build_array(jsonb_build_object(
        'operation_id', v_operation ->> 'operation_id',
        'memo_id', v_operation ->> 'memo_id',
        'reason', 'invalid_or_conflicting_operation'
      ));
    END;
  END LOOP;

  RETURN jsonb_build_object('accepted', v_accepted, 'rejected', v_rejected);
END;
$$;--> statement-breakpoint

REVOKE ALL ON FUNCTION public.daypage_apply_sync_operations(jsonb) FROM PUBLIC;--> statement-breakpoint
GRANT EXECUTE ON FUNCTION public.daypage_apply_sync_operations(jsonb) TO authenticated;--> statement-breakpoint
