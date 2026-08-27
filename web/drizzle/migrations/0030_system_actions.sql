-- #887 / ADR-0017: local-first Apple system action cloud replica.
--
-- Apple Frameworks execute only on a user-confirmed native device. Postgres is
-- an authenticated replica, MCP proposal boundary, monotonic pull log, and
-- short execution-lease coordinator. Direct durable mutation is intentionally
-- unavailable to clients; all writes flow through the versioned RPCs below.

CREATE SEQUENCE IF NOT EXISTS public.daypage_system_action_change_sequence AS bigint;--> statement-breakpoint
REVOKE ALL ON SEQUENCE public.daypage_system_action_change_sequence FROM PUBLIC, anon, authenticated;--> statement-breakpoint

ALTER TABLE public.mcp_client_grants
  ADD COLUMN IF NOT EXISTS can_read_actions boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS can_propose_actions boolean NOT NULL DEFAULT false;--> statement-breakpoint

CREATE TABLE IF NOT EXISTS public.system_action_proposals (
  user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  proposal_id uuid NOT NULL,
  schema_version integer NOT NULL DEFAULT 1 CHECK (schema_version = 1),
  revision bigint NOT NULL CHECK (revision >= 1),
  kind text NOT NULL CHECK (kind IN (
    'calendar_event', 'reminder', 'contact_draft', 'notification', 'route',
    'capture', 'focus_session', 'moment', 'local_context_attachment'
  )),
  payload jsonb NOT NULL CHECK (
    jsonb_typeof(payload) = 'object'
    AND payload ->> 'kind' = kind
    AND octet_length(payload::text) <= 32768
  ),
  payload_hash text NOT NULL CHECK (payload_hash ~ '^[0-9a-f]{64}$'),
  title text NOT NULL CHECK (octet_length(title) BETWEEN 1 AND 160),
  rationale text NOT NULL DEFAULT '' CHECK (octet_length(rationale) <= 500),
  source_refs jsonb NOT NULL DEFAULT '[]'::jsonb CHECK (
    jsonb_typeof(source_refs) = 'array'
    AND jsonb_array_length(source_refs) <= 20
    AND octet_length(source_refs::text) <= 8192
  ),
  creator_source text NOT NULL CHECK (creator_source IN (
    'native', 'mcp', 'local_inference', 'shortcut', 'widget', 'share'
  )),
  creator_device_id_hash text CHECK (creator_device_id_hash IS NULL OR creator_device_id_hash ~ '^[0-9a-f]{64}$'),
  redaction_level text NOT NULL CHECK (redaction_level IN ('private', 'sensitive', 'summary')),
  target_device_preference text NOT NULL CHECK (target_device_preference IN ('any', 'creating_device', 'specific_device')),
  target_device_id_hash text CHECK (target_device_id_hash IS NULL OR target_device_id_hash ~ '^[0-9a-f]{64}$'),
  state text NOT NULL DEFAULT 'pending' CHECK (state IN (
    'pending', 'approved', 'rejected', 'executing', 'completed', 'failed',
    'cancelled', 'needs_review'
  )),
  expires_at timestamptz,
  deleted_at timestamptz,
  change_sequence bigint NOT NULL DEFAULT nextval('public.daypage_system_action_change_sequence'),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, proposal_id),
  CHECK (
    (target_device_preference = 'specific_device' AND target_device_id_hash IS NOT NULL)
    OR (
      target_device_preference = 'creating_device'
      AND creator_device_id_hash IS NOT NULL
      AND target_device_id_hash IS NULL
    )
    OR (target_device_preference = 'any' AND target_device_id_hash IS NULL)
  )
);--> statement-breakpoint
CREATE INDEX IF NOT EXISTS system_action_proposals_user_change
  ON public.system_action_proposals(user_id, change_sequence);--> statement-breakpoint
CREATE INDEX IF NOT EXISTS system_action_proposals_user_state_updated
  ON public.system_action_proposals(user_id, state, updated_at DESC);--> statement-breakpoint

CREATE TABLE IF NOT EXISTS public.system_action_approvals (
  user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  approval_id uuid NOT NULL,
  proposal_id uuid NOT NULL,
  schema_version integer NOT NULL DEFAULT 1 CHECK (schema_version = 1),
  phase text NOT NULL CHECK (phase IN ('execute', 'undo')),
  proposal_revision bigint NOT NULL CHECK (proposal_revision >= 1),
  payload_hash text NOT NULL CHECK (payload_hash ~ '^[0-9a-f]{64}$'),
  decision text NOT NULL CHECK (decision IN ('approve', 'reject')),
  device_id_hash text NOT NULL CHECK (device_id_hash ~ '^[0-9a-f]{64}$'),
  replacement_proposal_id uuid,
  change_sequence bigint NOT NULL DEFAULT nextval('public.daypage_system_action_change_sequence'),
  decided_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, approval_id),
  UNIQUE (user_id, proposal_id, phase, proposal_revision),
  FOREIGN KEY (user_id, proposal_id)
    REFERENCES public.system_action_proposals(user_id, proposal_id) ON DELETE RESTRICT
);--> statement-breakpoint
CREATE INDEX IF NOT EXISTS system_action_approvals_user_change
  ON public.system_action_approvals(user_id, change_sequence);--> statement-breakpoint

CREATE TABLE IF NOT EXISTS public.system_action_receipts (
  user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  receipt_id uuid NOT NULL,
  proposal_id uuid NOT NULL,
  schema_version integer NOT NULL DEFAULT 1 CHECK (schema_version = 1),
  phase text NOT NULL CHECK (phase IN ('execute', 'undo')),
  proposal_revision bigint NOT NULL CHECK (proposal_revision >= 1),
  payload_hash text NOT NULL CHECK (payload_hash ~ '^[0-9a-f]{64}$'),
  attempt integer NOT NULL CHECK (attempt BETWEEN 1 AND 1000),
  outcome text NOT NULL CHECK (outcome IN ('succeeded', 'failed', 'cancelled', 'ambiguous')),
  device_id_hash text NOT NULL CHECK (device_id_hash ~ '^[0-9a-f]{64}$'),
  execution_mode text NOT NULL CHECK (execution_mode IN ('online_lease', 'offline_owner')),
  lease_id uuid,
  result jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (
    jsonb_typeof(result) = 'object'
    AND result - ARRAY['summary', 'resource_kind', 'scheduled_at', 'ended_at'] = '{}'::jsonb
    AND octet_length(result::text) <= 2048
  ),
  error_code text CHECK (error_code IS NULL OR error_code ~ '^[a-z0-9_.-]{1,80}$'),
  reconciliation_state text NOT NULL CHECK (reconciliation_state IN ('confirmed', 'pending', 'needs_review', 'not_applicable')),
  undo_capability text NOT NULL CHECK (undo_capability IN ('reversible', 'compensating', 'manual', 'none')),
  external_id_hash text CHECK (external_id_hash IS NULL OR external_id_hash ~ '^[0-9a-f]{64}$'),
  change_sequence bigint NOT NULL DEFAULT nextval('public.daypage_system_action_change_sequence'),
  started_at timestamptz NOT NULL,
  completed_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, receipt_id),
  UNIQUE (user_id, proposal_id, phase, device_id_hash, attempt),
  FOREIGN KEY (user_id, proposal_id)
    REFERENCES public.system_action_proposals(user_id, proposal_id) ON DELETE RESTRICT,
  CHECK (completed_at >= started_at),
  CHECK ((outcome = 'succeeded' AND error_code IS NULL) OR outcome <> 'succeeded'),
  CHECK ((execution_mode = 'online_lease' AND lease_id IS NOT NULL) OR (execution_mode = 'offline_owner' AND lease_id IS NULL))
);--> statement-breakpoint
CREATE INDEX IF NOT EXISTS system_action_receipts_user_change
  ON public.system_action_receipts(user_id, change_sequence);--> statement-breakpoint

CREATE TABLE IF NOT EXISTS public.system_action_capability_policies (
  user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  policy_id uuid NOT NULL,
  schema_version integer NOT NULL DEFAULT 1 CHECK (schema_version = 1),
  capability text NOT NULL CHECK (capability IN (
    'calendar', 'reminders', 'contacts', 'notifications', 'location', 'routes',
    'photos', 'capture', 'focus', 'spotlight', 'health_context', 'weather_context'
  )),
  revision bigint NOT NULL CHECK (revision >= 1),
  is_offered boolean NOT NULL,
  sync_enabled boolean NOT NULL,
  disclosure_level text NOT NULL CHECK (disclosure_level IN ('private', 'summary', 'full_proposal')),
  CHECK (
    (NOT is_offered AND NOT sync_enabled AND disclosure_level = 'private')
    OR (
      is_offered
      AND (
        (NOT sync_enabled AND disclosure_level = 'private')
        OR (sync_enabled AND disclosure_level IN ('summary', 'full_proposal'))
      )
    )
  ),
  deleted_at timestamptz,
  change_sequence bigint NOT NULL DEFAULT nextval('public.daypage_system_action_change_sequence'),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, policy_id),
  UNIQUE (user_id, capability)
);--> statement-breakpoint
CREATE INDEX IF NOT EXISTS system_action_capability_policies_user_change
  ON public.system_action_capability_policies(user_id, change_sequence);--> statement-breakpoint

CREATE TABLE IF NOT EXISTS public.system_action_sync_operations (
  user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  operation_id uuid NOT NULL,
  entity_type text NOT NULL CHECK (entity_type IN ('proposal', 'approval', 'receipt', 'policy', 'lease')),
  entity_id uuid NOT NULL,
  operation_kind text NOT NULL CHECK (operation_kind IN ('upsert', 'delete', 'append', 'claim')),
  revision bigint NOT NULL CHECK (revision >= 1),
  request_fingerprint text NOT NULL CHECK (request_fingerprint ~ '^[0-9a-f]{64}$'),
  result jsonb NOT NULL CHECK (jsonb_typeof(result) = 'object' AND octet_length(result::text) <= 65536),
  applied_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, operation_id)
);--> statement-breakpoint
CREATE INDEX IF NOT EXISTS system_action_sync_operations_entity
  ON public.system_action_sync_operations(user_id, entity_type, entity_id);--> statement-breakpoint

CREATE TABLE IF NOT EXISTS public.system_action_execution_leases (
  user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  lease_id uuid NOT NULL,
  claim_operation_id uuid NOT NULL,
  proposal_id uuid NOT NULL,
  phase text NOT NULL CHECK (phase IN ('execute', 'undo')),
  proposal_revision bigint NOT NULL CHECK (proposal_revision >= 1),
  payload_hash text NOT NULL CHECK (payload_hash ~ '^[0-9a-f]{64}$'),
  device_id_hash text NOT NULL CHECK (device_id_hash ~ '^[0-9a-f]{64}$'),
  expires_at timestamptz NOT NULL,
  released_at timestamptz,
  release_reason text CHECK (release_reason IS NULL OR release_reason IN ('completed', 'expired', 'cancelled')),
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, lease_id),
  UNIQUE (user_id, claim_operation_id),
  FOREIGN KEY (user_id, proposal_id)
    REFERENCES public.system_action_proposals(user_id, proposal_id) ON DELETE RESTRICT
);--> statement-breakpoint
CREATE INDEX IF NOT EXISTS system_action_execution_leases_lookup
  ON public.system_action_execution_leases(user_id, proposal_id, phase, expires_at);--> statement-breakpoint
CREATE UNIQUE INDEX IF NOT EXISTS system_action_execution_leases_one_active
  ON public.system_action_execution_leases(user_id, proposal_id, phase)
  WHERE released_at IS NULL;--> statement-breakpoint

ALTER TABLE public.system_action_receipts
  ADD CONSTRAINT system_action_receipts_lease_fk
  FOREIGN KEY (user_id, lease_id)
  REFERENCES public.system_action_execution_leases(user_id, lease_id) ON DELETE RESTRICT;--> statement-breakpoint

ALTER TABLE public.system_action_proposals ENABLE ROW LEVEL SECURITY;--> statement-breakpoint
ALTER TABLE public.system_action_approvals ENABLE ROW LEVEL SECURITY;--> statement-breakpoint
ALTER TABLE public.system_action_receipts ENABLE ROW LEVEL SECURITY;--> statement-breakpoint
ALTER TABLE public.system_action_capability_policies ENABLE ROW LEVEL SECURITY;--> statement-breakpoint
ALTER TABLE public.system_action_sync_operations ENABLE ROW LEVEL SECURITY;--> statement-breakpoint
ALTER TABLE public.system_action_execution_leases ENABLE ROW LEVEL SECURITY;--> statement-breakpoint

CREATE POLICY system_action_proposals_select_own ON public.system_action_proposals
  FOR SELECT TO authenticated USING (
    user_id = auth.uid()
    AND COALESCE(auth.jwt() ->> 'client_id', '') = ''
  );--> statement-breakpoint
CREATE POLICY system_action_approvals_select_own ON public.system_action_approvals
  FOR SELECT TO authenticated USING (
    user_id = auth.uid()
    AND COALESCE(auth.jwt() ->> 'client_id', '') = ''
  );--> statement-breakpoint
CREATE POLICY system_action_receipts_select_own ON public.system_action_receipts
  FOR SELECT TO authenticated USING (
    user_id = auth.uid()
    AND COALESCE(auth.jwt() ->> 'client_id', '') = ''
  );--> statement-breakpoint
CREATE POLICY system_action_capability_policies_select_own ON public.system_action_capability_policies
  FOR SELECT TO authenticated USING (
    user_id = auth.uid()
    AND COALESCE(auth.jwt() ->> 'client_id', '') = ''
  );--> statement-breakpoint

REVOKE ALL ON public.system_action_proposals FROM PUBLIC, anon, authenticated;--> statement-breakpoint
REVOKE ALL ON public.system_action_approvals FROM PUBLIC, anon, authenticated;--> statement-breakpoint
REVOKE ALL ON public.system_action_receipts FROM PUBLIC, anon, authenticated;--> statement-breakpoint
REVOKE ALL ON public.system_action_capability_policies FROM PUBLIC, anon, authenticated;--> statement-breakpoint
REVOKE ALL ON public.system_action_sync_operations FROM PUBLIC, anon, authenticated;--> statement-breakpoint
REVOKE ALL ON public.system_action_execution_leases FROM PUBLIC, anon, authenticated;--> statement-breakpoint
GRANT SELECT ON public.system_action_proposals, public.system_action_approvals,
  public.system_action_receipts, public.system_action_capability_policies TO authenticated;--> statement-breakpoint

-- Preserve the existing v1/v2 sync RPCs while removing direct access to their
-- idempotency receipts. auth.uid() continues to bind the caller tenant.
REVOKE ALL ON public.sync_operations FROM PUBLIC, anon, authenticated;--> statement-breakpoint
ALTER FUNCTION public.daypage_apply_sync_operations(jsonb) SECURITY DEFINER;--> statement-breakpoint
ALTER FUNCTION public.daypage_apply_sync_operations(jsonb) SET search_path = public, pg_temp;--> statement-breakpoint
ALTER FUNCTION public.daypage_apply_sync_operations_v2(jsonb) SECURITY DEFINER;--> statement-breakpoint
ALTER FUNCTION public.daypage_apply_sync_operations_v2(jsonb) SET search_path = public, pg_temp;--> statement-breakpoint

-- Existing consent/session code may maintain memo read/write grants but cannot
-- silently set the independent action grants through PostgREST.
REVOKE INSERT, UPDATE ON public.mcp_client_grants FROM authenticated;--> statement-breakpoint
GRANT INSERT (user_id, client_id, can_read, can_write, created_at, updated_at, revoked_at)
  ON public.mcp_client_grants TO authenticated;--> statement-breakpoint
GRANT UPDATE (can_read, can_write, updated_at, revoked_at)
  ON public.mcp_client_grants TO authenticated;--> statement-breakpoint

CREATE OR REPLACE FUNCTION public.daypage_canonical_system_action_json_v1(p_value jsonb)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
STRICT
PARALLEL SAFE
SET search_path = pg_catalog
AS $$
DECLARE
  v_type text := jsonb_typeof(p_value);
  v_result text;
  v_number numeric;
BEGIN
  IF v_type = 'object' THEN
    SELECT '{' || COALESCE(string_agg(
      to_jsonb(item.key)::text || ':' || public.daypage_canonical_system_action_json_v1(item.value),
      ',' ORDER BY item.key COLLATE "C"
    ), '') || '}'
    INTO v_result
    FROM jsonb_each(p_value) item(key, value);
    RETURN v_result;
  ELSIF v_type = 'array' THEN
    SELECT '[' || COALESCE(string_agg(
      public.daypage_canonical_system_action_json_v1(item.value),
      ',' ORDER BY item.ordinal
    ), '') || ']'
    INTO v_result
    FROM jsonb_array_elements(p_value) WITH ORDINALITY item(value, ordinal);
    RETURN v_result;
  ELSIF v_type = 'string' THEN
    RETURN to_jsonb(p_value #>> '{}')::text;
  ELSIF v_type = 'number' THEN
    v_number := (p_value #>> '{}')::numeric;
    IF v_number * 1000000 <> trunc(v_number * 1000000) THEN
      RAISE EXCEPTION 'system action numbers require at most six decimal places'
        USING ERRCODE = '22023';
    END IF;
    RETURN trim_scale(v_number)::text;
  ELSIF v_type IN ('boolean', 'null') THEN
    RETURN p_value::text;
  END IF;
  RAISE EXCEPTION 'unsupported JSON value' USING ERRCODE = '22023';
END;
$$;--> statement-breakpoint
REVOKE ALL ON FUNCTION public.daypage_canonical_system_action_json_v1(jsonb)
  FROM PUBLIC, anon, authenticated, service_role;--> statement-breakpoint

CREATE OR REPLACE FUNCTION public.daypage_system_action_payload_hash_v1(p_payload jsonb)
RETURNS text
LANGUAGE sql
IMMUTABLE
STRICT
PARALLEL SAFE
SET search_path = pg_catalog
AS $$
  SELECT encode(
    extensions.digest(
      convert_to(public.daypage_canonical_system_action_json_v1(p_payload), 'UTF8'),
      'sha256'
    ),
    'hex'
  )
$$;--> statement-breakpoint
REVOKE ALL ON FUNCTION public.daypage_system_action_payload_hash_v1(jsonb)
  FROM PUBLIC, anon, authenticated, service_role;--> statement-breakpoint

CREATE OR REPLACE FUNCTION public.daypage_is_canonical_system_action_timestamp_v1(p_value text)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
STRICT
PARALLEL SAFE
SET search_path = pg_catalog
AS $$
BEGIN
  IF p_value !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[.][0-9]{3}Z$' THEN
    RETURN false;
  END IF;
  RETURN to_char(
    p_value::timestamptz AT TIME ZONE 'UTC',
    'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'
  ) = p_value;
EXCEPTION WHEN OTHERS THEN
  RETURN false;
END;
$$;--> statement-breakpoint
REVOKE ALL ON FUNCTION public.daypage_is_canonical_system_action_timestamp_v1(text)
  FROM PUBLIC, anon, authenticated, service_role;--> statement-breakpoint

CREATE OR REPLACE FUNCTION public.daypage_system_action_timestamp_text_v1(p_value timestamptz)
RETURNS text
LANGUAGE sql
IMMUTABLE
STRICT
PARALLEL SAFE
SET search_path = pg_catalog
AS $$
  SELECT to_char(p_value AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')
$$;--> statement-breakpoint
REVOKE ALL ON FUNCTION public.daypage_system_action_timestamp_text_v1(timestamptz)
  FROM PUBLIC, anon, authenticated, service_role;--> statement-breakpoint

CREATE OR REPLACE FUNCTION public.daypage_validate_system_action_payload_v1(
  p_kind text,
  p_payload jsonb
)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
SET search_path = public, pg_temp
AS $$
  SELECT CASE
    WHEN jsonb_typeof(p_payload) <> 'object'
      OR p_payload ->> 'kind' IS DISTINCT FROM p_kind
      OR octet_length(p_payload::text) > 32768 THEN false
    WHEN p_kind = 'calendar_event' THEN
      p_payload ?& ARRAY['kind','title','start_at','end_at','all_day','time_zone','location_label','notes']
      AND p_payload - ARRAY['kind','title','start_at','end_at','all_day','time_zone','location_label','notes'] = '{}'::jsonb
      AND jsonb_typeof(p_payload -> 'title') = 'string'
      AND octet_length(COALESCE(p_payload ->> 'title', '')) BETWEEN 1 AND 160
      AND length(btrim(COALESCE(p_payload ->> 'title', ''))) > 0
      AND jsonb_typeof(p_payload -> 'start_at') = 'string'
      AND public.daypage_is_canonical_system_action_timestamp_v1(p_payload ->> 'start_at')
      AND jsonb_typeof(p_payload -> 'end_at') = 'string'
      AND public.daypage_is_canonical_system_action_timestamp_v1(p_payload ->> 'end_at')
      AND (p_payload ->> 'end_at')::timestamptz > (p_payload ->> 'start_at')::timestamptz
      AND jsonb_typeof(p_payload -> 'all_day') = 'boolean'
      AND jsonb_typeof(p_payload -> 'time_zone') = 'string'
      AND octet_length(COALESCE(p_payload ->> 'time_zone', '')) BETWEEN 1 AND 64
      AND length(btrim(COALESCE(p_payload ->> 'time_zone', ''))) > 0
      AND jsonb_typeof(p_payload -> 'location_label') IN ('string','null')
      AND octet_length(COALESCE(p_payload ->> 'location_label', '')) <= 240
      AND jsonb_typeof(p_payload -> 'notes') IN ('string','null')
      AND octet_length(COALESCE(p_payload ->> 'notes', '')) <= 2000
    WHEN p_kind = 'reminder' THEN
      p_payload ?& ARRAY['kind','title','due_at','time_zone','priority','notes']
      AND p_payload - ARRAY['kind','title','due_at','time_zone','priority','notes'] = '{}'::jsonb
      AND jsonb_typeof(p_payload -> 'title') = 'string'
      AND octet_length(COALESCE(p_payload ->> 'title', '')) BETWEEN 1 AND 160
      AND length(btrim(COALESCE(p_payload ->> 'title', ''))) > 0
      AND (
        jsonb_typeof(p_payload -> 'due_at') = 'null'
        OR (
          jsonb_typeof(p_payload -> 'due_at') = 'string'
          AND public.daypage_is_canonical_system_action_timestamp_v1(p_payload ->> 'due_at')
        )
      )
      AND jsonb_typeof(p_payload -> 'time_zone') IN ('string','null')
      AND octet_length(COALESCE(p_payload ->> 'time_zone', '')) <= 64
      AND jsonb_typeof(p_payload -> 'priority') = 'number'
      AND (p_payload ->> 'priority') ~ '^[0-9]$'
      AND jsonb_typeof(p_payload -> 'notes') IN ('string','null')
      AND octet_length(COALESCE(p_payload ->> 'notes', '')) <= 2000
    WHEN p_kind = 'contact_draft' THEN
      p_payload ?& ARRAY['kind','given_name','family_name','organization','phones','emails']
      AND p_payload - ARRAY['kind','given_name','family_name','organization','phones','emails'] = '{}'::jsonb
      AND jsonb_typeof(p_payload -> 'given_name') = 'string'
      AND octet_length(p_payload ->> 'given_name') <= 100
      AND jsonb_typeof(p_payload -> 'family_name') = 'string'
      AND octet_length(p_payload ->> 'family_name') <= 100
      AND jsonb_typeof(p_payload -> 'organization') IN ('string','null')
      AND octet_length(COALESCE(p_payload ->> 'organization', '')) <= 160
      AND (
        length(btrim(COALESCE(p_payload ->> 'given_name', ''))) > 0
        OR length(btrim(COALESCE(p_payload ->> 'family_name', ''))) > 0
        OR length(btrim(COALESCE(p_payload ->> 'organization', ''))) > 0
      )
      AND jsonb_typeof(p_payload -> 'phones') = 'array'
      AND jsonb_array_length(p_payload -> 'phones') <= 5
      AND NOT EXISTS (
        SELECT 1 FROM jsonb_array_elements(p_payload -> 'phones') phone(value)
        WHERE jsonb_typeof(phone.value) <> 'string'
          OR octet_length(phone.value #>> '{}') NOT BETWEEN 1 AND 40
          OR length(btrim(phone.value #>> '{}')) = 0
      )
      AND jsonb_typeof(p_payload -> 'emails') = 'array'
      AND jsonb_array_length(p_payload -> 'emails') <= 5
      AND NOT EXISTS (
        SELECT 1 FROM jsonb_array_elements(p_payload -> 'emails') email(value)
        WHERE jsonb_typeof(email.value) <> 'string'
          OR octet_length(email.value #>> '{}') NOT BETWEEN 3 AND 254
          OR length(btrim(email.value #>> '{}')) = 0
      )
    WHEN p_kind = 'notification' THEN
      p_payload ?& ARRAY['kind','title','body','fire_at','time_zone','interruption_level']
      AND p_payload - ARRAY['kind','title','body','fire_at','time_zone','interruption_level'] = '{}'::jsonb
      AND jsonb_typeof(p_payload -> 'title') = 'string'
      AND octet_length(COALESCE(p_payload ->> 'title', '')) BETWEEN 1 AND 160
      AND length(btrim(COALESCE(p_payload ->> 'title', ''))) > 0
      AND jsonb_typeof(p_payload -> 'body') = 'string'
      AND octet_length(COALESCE(p_payload ->> 'body', '')) <= 500
      AND jsonb_typeof(p_payload -> 'fire_at') = 'string'
      AND public.daypage_is_canonical_system_action_timestamp_v1(p_payload ->> 'fire_at')
      AND jsonb_typeof(p_payload -> 'time_zone') = 'string'
      AND octet_length(p_payload ->> 'time_zone') BETWEEN 1 AND 64
      AND length(btrim(COALESCE(p_payload ->> 'time_zone', ''))) > 0
      AND p_payload ->> 'interruption_level' IN ('passive','active','time_sensitive')
    WHEN p_kind = 'route' THEN
      p_payload ?& ARRAY['kind','destination_label','transport']
      AND p_payload - ARRAY['kind','destination_label','destination_address','destination_latitude','destination_longitude','transport'] = '{}'::jsonb
      AND jsonb_typeof(p_payload -> 'destination_label') = 'string'
      AND octet_length(COALESCE(p_payload ->> 'destination_label', '')) <= 240
      AND length(btrim(COALESCE(p_payload ->> 'destination_label', ''))) > 0
      AND p_payload ->> 'transport' IN ('any','walking','driving','transit','cycling')
      AND CASE
        WHEN p_payload ? 'destination_address' THEN
          jsonb_typeof(p_payload -> 'destination_address') = 'string'
          AND octet_length(COALESCE(p_payload ->> 'destination_address', '')) <= 500
          AND length(btrim(COALESCE(p_payload ->> 'destination_address', ''))) > 0
          AND NOT (p_payload ? 'destination_latitude')
          AND NOT (p_payload ? 'destination_longitude')
        ELSE
          p_payload ?& ARRAY['destination_latitude','destination_longitude']
          AND jsonb_typeof(p_payload -> 'destination_latitude') = 'number'
          AND (p_payload ->> 'destination_latitude')::numeric BETWEEN -90 AND 90
          AND (p_payload ->> 'destination_latitude')::numeric * 1000000
            = trunc((p_payload ->> 'destination_latitude')::numeric * 1000000)
          AND jsonb_typeof(p_payload -> 'destination_longitude') = 'number'
          AND (p_payload ->> 'destination_longitude')::numeric BETWEEN -180 AND 180
          AND (p_payload ->> 'destination_longitude')::numeric * 1000000
            = trunc((p_payload ->> 'destination_longitude')::numeric * 1000000)
      END
    WHEN p_kind = 'capture' THEN
      p_payload ?& ARRAY['kind','mode','destination','suggested_title']
      AND p_payload - ARRAY['kind','mode','destination','suggested_title'] = '{}'::jsonb
      AND p_payload ->> 'mode' IN ('text','photo','camera','file','scan','ocr','ink','voice')
      AND p_payload ->> 'destination' IN ('new_memo','current_draft')
      AND jsonb_typeof(p_payload -> 'suggested_title') IN ('string','null')
      AND octet_length(COALESCE(p_payload ->> 'suggested_title', '')) <= 200
    WHEN p_kind = 'focus_session' THEN
      p_payload ?& ARRAY['kind','title','duration_seconds','schedule_end_alert','allow_live_activity']
      AND p_payload - ARRAY['kind','title','duration_seconds','schedule_end_alert','allow_live_activity'] = '{}'::jsonb
      AND jsonb_typeof(p_payload -> 'title') = 'string'
      AND octet_length(COALESCE(p_payload ->> 'title', '')) BETWEEN 1 AND 160
      AND length(btrim(COALESCE(p_payload ->> 'title', ''))) > 0
      AND jsonb_typeof(p_payload -> 'duration_seconds') = 'number'
      AND (p_payload ->> 'duration_seconds') ~ '^[0-9]+$'
      AND (p_payload ->> 'duration_seconds')::integer BETWEEN 60 AND 86400
      AND jsonb_typeof(p_payload -> 'schedule_end_alert') = 'boolean'
      AND jsonb_typeof(p_payload -> 'allow_live_activity') = 'boolean'
    WHEN p_kind = 'moment' THEN
      p_payload ?& ARRAY['kind','captured_at','title','place_label','people_refs','include_one_shot_location']
      AND p_payload - ARRAY['kind','captured_at','title','place_label','people_refs','include_one_shot_location'] = '{}'::jsonb
      AND jsonb_typeof(p_payload -> 'captured_at') = 'string'
      AND public.daypage_is_canonical_system_action_timestamp_v1(p_payload ->> 'captured_at')
      AND jsonb_typeof(p_payload -> 'title') IN ('string','null')
      AND octet_length(COALESCE(p_payload ->> 'title', '')) <= 160
      AND jsonb_typeof(p_payload -> 'place_label') IN ('string','null')
      AND octet_length(COALESCE(p_payload ->> 'place_label', '')) <= 240
      AND jsonb_typeof(p_payload -> 'people_refs') = 'array'
      AND jsonb_array_length(p_payload -> 'people_refs') <= 20
      AND NOT EXISTS (
        SELECT 1 FROM jsonb_array_elements(p_payload -> 'people_refs') person(value)
        WHERE jsonb_typeof(person.value) <> 'string'
          OR octet_length(person.value #>> '{}') NOT BETWEEN 1 AND 160
      )
      AND jsonb_typeof(p_payload -> 'include_one_shot_location') = 'boolean'
      AND ((p_payload ->> 'place_label') IS NOT NULL) = ((p_payload ->> 'include_one_shot_location')::boolean)
      AND (p_payload ->> 'place_label' IS NULL OR length(btrim(p_payload ->> 'place_label')) > 0)
    WHEN p_kind = 'local_context_attachment' THEN
      p_payload ?& ARRAY['kind','context_kind','local_reference','observed_at','disclosure']
      AND p_payload - ARRAY['kind','context_kind','local_reference','observed_at','disclosure'] = '{}'::jsonb
      AND p_payload ->> 'context_kind' IN ('photo','health_summary','weather_summary','location_summary','contact_selection')
      AND jsonb_typeof(p_payload -> 'local_reference') = 'string'
      AND COALESCE(p_payload ->> 'local_reference', '') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
      AND jsonb_typeof(p_payload -> 'observed_at') = 'string'
      AND public.daypage_is_canonical_system_action_timestamp_v1(p_payload ->> 'observed_at')
      AND p_payload ->> 'disclosure' = 'summary_only'
    ELSE false
  END;
$$;--> statement-breakpoint
REVOKE ALL ON FUNCTION public.daypage_validate_system_action_payload_v1(text, jsonb)
  FROM PUBLIC, anon, authenticated, service_role;--> statement-breakpoint

CREATE OR REPLACE FUNCTION public.daypage_validate_system_action_source_refs_v1(p_refs jsonb)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
SET search_path = public, pg_temp
AS $$
  SELECT CASE WHEN jsonb_typeof(p_refs) <> 'array' THEN false ELSE
    jsonb_array_length(p_refs) <= 20
      AND octet_length(p_refs::text) <= 8192
      AND jsonb_array_length(p_refs) = (
        SELECT count(DISTINCT reference.value)
        FROM jsonb_array_elements(p_refs) reference(value)
      )
      AND NOT EXISTS (
        SELECT 1 FROM jsonb_array_elements(p_refs) reference(value)
        WHERE jsonb_typeof(reference.value) <> 'object'
          OR NOT (reference.value ?& ARRAY['kind','id'])
          OR reference.value - ARRAY['kind','id'] <> '{}'::jsonb
          OR reference.value ->> 'kind' NOT IN ('memo','daily_page','entity','place','system_entry')
          OR octet_length(COALESCE(reference.value ->> 'id', '')) NOT BETWEEN 1 AND 160
      )
  END;
$$;--> statement-breakpoint
REVOKE ALL ON FUNCTION public.daypage_validate_system_action_source_refs_v1(jsonb)
  FROM PUBLIC, anon, authenticated, service_role;--> statement-breakpoint

CREATE OR REPLACE FUNCTION public.daypage_system_action_required_capabilities_v1(
  p_kind text,
  p_payload jsonb
)
RETURNS text[]
LANGUAGE sql
IMMUTABLE
STRICT
PARALLEL SAFE
SET search_path = pg_catalog
AS $$
  SELECT CASE p_kind
    WHEN 'calendar_event' THEN ARRAY['calendar']::text[]
    WHEN 'reminder' THEN ARRAY['reminders']::text[]
    WHEN 'contact_draft' THEN ARRAY['contacts']::text[]
    WHEN 'notification' THEN ARRAY['notifications']::text[]
    WHEN 'route' THEN ARRAY['routes']::text[]
    WHEN 'capture' THEN ARRAY['capture']::text[]
    WHEN 'focus_session' THEN ARRAY['focus']::text[]
    WHEN 'moment' THEN CASE
      WHEN COALESCE((p_payload ->> 'include_one_shot_location')::boolean, false)
        THEN ARRAY['location']::text[]
      ELSE ARRAY[]::text[]
    END
    WHEN 'local_context_attachment' THEN ARRAY[CASE p_payload ->> 'context_kind'
      WHEN 'weather_summary' THEN 'weather_context'
      WHEN 'health_summary' THEN 'health_context'
      WHEN 'location_summary' THEN 'location'
      WHEN 'photo' THEN 'photos'
      WHEN 'contact_selection' THEN 'contacts'
      ELSE NULL
    END]::text[]
    ELSE ARRAY[]::text[]
  END
$$;--> statement-breakpoint
REVOKE ALL ON FUNCTION public.daypage_system_action_required_capabilities_v1(text, jsonb)
  FROM PUBLIC, anon, authenticated, service_role;--> statement-breakpoint

CREATE OR REPLACE FUNCTION public.daypage_system_action_cloud_policy_allows_v1(
  p_user_id uuid,
  p_kind text,
  p_payload jsonb
)
RETURNS boolean
LANGUAGE plpgsql
VOLATILE
STRICT
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_capabilities text[] := public.daypage_system_action_required_capabilities_v1(p_kind, p_payload);
  v_capability text;
BEGIN
  -- Payloads with no external/cloud-disclosable capability are intentionally
  -- local-only and must never acquire a cloud proposal/decision/receipt.
  IF cardinality(v_capabilities) = 0 OR array_position(v_capabilities, NULL) IS NOT NULL THEN
    RETURN false;
  END IF;
  FOREACH v_capability IN ARRAY v_capabilities LOOP
    PERFORM 1
    FROM public.system_action_capability_policies policy
    WHERE policy.user_id = p_user_id
      AND policy.capability = v_capability
      AND policy.is_offered
      AND policy.sync_enabled
      AND policy.disclosure_level = 'full_proposal'
      AND policy.deleted_at IS NULL
    FOR KEY SHARE;
    IF NOT FOUND THEN
      RETURN false;
    END IF;
  END LOOP;
  RETURN true;
END;
$$;--> statement-breakpoint
REVOKE ALL ON FUNCTION public.daypage_system_action_cloud_policy_allows_v1(uuid, text, jsonb)
  FROM PUBLIC, anon, authenticated, service_role;--> statement-breakpoint

CREATE OR REPLACE FUNCTION public.daypage_validate_system_action_receipt_result_v1(p_result jsonb)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
SET search_path = public, pg_temp
AS $$
  SELECT CASE WHEN jsonb_typeof(p_result) <> 'object' THEN false ELSE
    p_result - ARRAY['summary','resource_kind','scheduled_at','ended_at'] = '{}'::jsonb
      AND octet_length(p_result::text) <= 2048
      AND (
        NOT (p_result ? 'summary')
        OR (jsonb_typeof(p_result -> 'summary') = 'string' AND octet_length(p_result ->> 'summary') <= 240)
      )
      AND (
        NOT (p_result ? 'resource_kind')
        OR (jsonb_typeof(p_result -> 'resource_kind') = 'string' AND octet_length(p_result ->> 'resource_kind') <= 64)
      )
      AND (
        NOT (p_result ? 'scheduled_at')
        OR jsonb_typeof(p_result -> 'scheduled_at') = 'null'
        OR (
          jsonb_typeof(p_result -> 'scheduled_at') = 'string'
          AND public.daypage_is_canonical_system_action_timestamp_v1(p_result ->> 'scheduled_at')
        )
      )
      AND (
        NOT (p_result ? 'ended_at')
        OR jsonb_typeof(p_result -> 'ended_at') = 'null'
        OR (
          jsonb_typeof(p_result -> 'ended_at') = 'string'
          AND public.daypage_is_canonical_system_action_timestamp_v1(p_result ->> 'ended_at')
        )
      )
  END;
$$;--> statement-breakpoint
REVOKE ALL ON FUNCTION public.daypage_validate_system_action_receipt_result_v1(jsonb)
  FROM PUBLIC, anon, authenticated, service_role;--> statement-breakpoint

ALTER TABLE public.system_action_proposals
  ADD CONSTRAINT system_action_proposals_payload_v1_check
    CHECK (public.daypage_validate_system_action_payload_v1(kind, payload)),
  ADD CONSTRAINT system_action_proposals_payload_hash_v1_check
    CHECK (payload_hash = public.daypage_system_action_payload_hash_v1(payload)),
  ADD CONSTRAINT system_action_proposals_source_refs_v1_check
    CHECK (public.daypage_validate_system_action_source_refs_v1(source_refs));--> statement-breakpoint
ALTER TABLE public.system_action_receipts
  ADD CONSTRAINT system_action_receipts_result_v1_check
    CHECK (public.daypage_validate_system_action_receipt_result_v1(result));--> statement-breakpoint

CREATE OR REPLACE FUNCTION public.daypage_apply_system_action_operations_for_user_v1(
  p_user_id uuid,
  p_operations jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_operation jsonb;
  v_operation_id uuid;
  v_entity_type text;
  v_entity_id uuid;
  v_operation_kind text;
  v_revision bigint;
  v_record jsonb;
  v_fingerprint text;
  v_stored public.system_action_sync_operations%ROWTYPE;
  v_result jsonb;
  v_accepted jsonb := '[]'::jsonb;
  v_rejected jsonb := '[]'::jsonb;
  v_reason text;
  v_change_sequence bigint;
  v_current_revision bigint;
  v_proposal public.system_action_proposals%ROWTYPE;
  v_lease public.system_action_execution_leases%ROWTYPE;
  v_deleted_at timestamptz;
BEGIN
  IF p_user_id IS NULL THEN
    RAISE EXCEPTION 'authentication required' USING ERRCODE = '42501';
  END IF;
  IF jsonb_typeof(p_operations) <> 'array' THEN
    RAISE EXCEPTION 'p_operations must be an array' USING ERRCODE = '22023';
  END IF;
  IF jsonb_array_length(p_operations) < 1 OR jsonb_array_length(p_operations) > 100 THEN
    RAISE EXCEPTION 'p_operations must contain 1 to 100 operations' USING ERRCODE = '22023';
  END IF;
  IF octet_length(p_operations::text) > 1048576 THEN
    RAISE EXCEPTION 'p_operations is too large' USING ERRCODE = '22023';
  END IF;

  FOR v_operation IN SELECT value FROM jsonb_array_elements(p_operations)
  LOOP
    v_reason := 'invalid_operation';
    BEGIN
      IF jsonb_typeof(v_operation) <> 'object'
        OR v_operation - ARRAY['protocol_version','operation_id','entity_type','entity_id','operation_kind','revision','record'] <> '{}'::jsonb
        OR NOT (v_operation ?& ARRAY['protocol_version','operation_id','entity_type','entity_id','operation_kind','revision','record'])
        OR COALESCE((v_operation ->> 'protocol_version')::integer, 0) <> 1 THEN
        RAISE EXCEPTION 'invalid protocol version';
      END IF;
      v_operation_id := (v_operation ->> 'operation_id')::uuid;
      v_entity_type := v_operation ->> 'entity_type';
      v_entity_id := (v_operation ->> 'entity_id')::uuid;
      v_operation_kind := v_operation ->> 'operation_kind';
      v_revision := (v_operation ->> 'revision')::bigint;
      v_record := v_operation -> 'record';
      IF v_entity_type NOT IN ('proposal', 'approval', 'receipt', 'policy')
        OR v_operation_kind NOT IN ('upsert', 'delete', 'append')
        OR v_revision < 1
        OR jsonb_typeof(v_record) <> 'object' THEN
        RAISE EXCEPTION 'invalid operation tuple';
      END IF;

      v_fingerprint := encode(extensions.digest(
        concat_ws(E'\x1f', '1', v_entity_type, v_entity_id::text,
          v_operation_kind, v_revision::text, v_record::text),
        'sha256'
      ), 'hex');

      SELECT * INTO v_stored
      FROM public.system_action_sync_operations
      WHERE user_id = p_user_id AND operation_id = v_operation_id;
      IF FOUND THEN
        IF v_stored.entity_type <> v_entity_type
          OR v_stored.entity_id <> v_entity_id
          OR v_stored.operation_kind <> v_operation_kind
          OR v_stored.revision <> v_revision
          OR v_stored.request_fingerprint <> v_fingerprint THEN
          v_rejected := v_rejected || jsonb_build_array(jsonb_build_object(
            'operation_id', v_operation_id, 'entity_type', v_entity_type,
            'entity_id', v_entity_id, 'reason', 'operation_id_reuse_mismatch'
          ));
          CONTINUE;
        END IF;
        v_result := v_stored.result || jsonb_build_object('status', 'replayed');
        v_accepted := v_accepted || jsonb_build_array(v_result);
        CONTINUE;
      END IF;

      IF v_entity_type = 'proposal' THEN
        IF v_operation_kind NOT IN ('upsert', 'delete')
          OR v_record - ARRAY[
            'schema_version','proposal_id','revision','kind','payload','payload_hash',
            'title','rationale','source_refs','creator_source','creator_device_id_hash',
            'redaction_level','target_device_preference','target_device_id_hash',
            'state','created_at','expires_at','deleted_at'
          ] <> '{}'::jsonb
          OR NOT (v_record ?& ARRAY[
            'schema_version','proposal_id','revision','kind','payload','payload_hash',
            'title','rationale','source_refs','creator_source','creator_device_id_hash',
            'redaction_level','target_device_preference','state','created_at','expires_at','deleted_at'
          ])
          OR COALESCE((v_record ->> 'schema_version')::integer, 0) <> 1
          OR (v_record ->> 'proposal_id')::uuid <> v_entity_id
          OR (v_record ->> 'revision')::bigint <> v_revision
          OR COALESCE(v_record ->> 'kind', '') NOT IN (
            'calendar_event', 'reminder', 'contact_draft', 'notification', 'route',
            'capture', 'focus_session', 'moment', 'local_context_attachment'
          )
          OR jsonb_typeof(v_record -> 'payload') <> 'object'
          OR v_record #>> '{payload,kind}' IS DISTINCT FROM v_record ->> 'kind'
          OR COALESCE(v_record ->> 'payload_hash', '') !~ '^[0-9a-f]{64}$'
          OR jsonb_typeof(v_record -> 'title') <> 'string'
          OR octet_length(COALESCE(v_record ->> 'title', '')) NOT BETWEEN 1 AND 160
          OR length(btrim(COALESCE(v_record ->> 'title', ''))) = 0
          OR jsonb_typeof(v_record -> 'rationale') <> 'string'
          OR octet_length(COALESCE(v_record ->> 'rationale', '')) > 500
          OR jsonb_typeof(v_record -> 'source_refs') <> 'array'
          OR jsonb_array_length(v_record -> 'source_refs') > 20
          OR COALESCE(v_record ->> 'creator_source', '') NOT IN ('native', 'mcp', 'local_inference', 'shortcut', 'widget', 'share')
          OR COALESCE(v_record ->> 'redaction_level', '') NOT IN ('private', 'sensitive', 'summary')
          OR COALESCE(v_record ->> 'target_device_preference', '') NOT IN ('any', 'creating_device', 'specific_device')
          OR COALESCE(v_record ->> 'state', '') NOT IN ('pending', 'cancelled')
          OR jsonb_typeof(v_record -> 'created_at') <> 'string'
          OR NOT public.daypage_is_canonical_system_action_timestamp_v1(v_record ->> 'created_at')
          OR (
            v_record ->> 'expires_at' IS NOT NULL
            AND (
              jsonb_typeof(v_record -> 'expires_at') <> 'string'
              OR NOT public.daypage_is_canonical_system_action_timestamp_v1(v_record ->> 'expires_at')
            )
          )
          OR (
            v_record ->> 'deleted_at' IS NOT NULL
            AND (
              jsonb_typeof(v_record -> 'deleted_at') <> 'string'
              OR NOT public.daypage_is_canonical_system_action_timestamp_v1(v_record ->> 'deleted_at')
            )
          ) THEN
          RAISE EXCEPTION 'invalid proposal';
        END IF;
        IF v_record ->> 'target_device_preference' = 'specific_device' THEN
          IF COALESCE(v_record ->> 'target_device_id_hash', '') !~ '^[0-9a-f]{64}$' THEN
            RAISE EXCEPTION 'specific device hash required';
          END IF;
        ELSIF v_record ->> 'target_device_preference' = 'creating_device' THEN
          IF COALESCE(v_record ->> 'creator_device_id_hash', '') !~ '^[0-9a-f]{64}$' THEN
            RAISE EXCEPTION 'creating device hash required';
          END IF;
          IF v_record ->> 'target_device_id_hash' IS NOT NULL THEN
            RAISE EXCEPTION 'unexpected target device hash';
          END IF;
        ELSIF v_record ->> 'target_device_id_hash' IS NOT NULL THEN
          RAISE EXCEPTION 'unexpected target device hash';
        END IF;
        IF NOT public.daypage_system_action_cloud_policy_allows_v1(
          p_user_id, v_record ->> 'kind', v_record -> 'payload'
        ) THEN
          RAISE EXCEPTION 'active full-proposal capability policy required';
        END IF;

        SELECT * INTO v_proposal
        FROM public.system_action_proposals
        WHERE user_id = p_user_id AND proposal_id = v_entity_id
        FOR UPDATE;
        v_current_revision := CASE WHEN FOUND THEN v_proposal.revision ELSE NULL END;
        IF (v_current_revision IS NOT NULL AND v_revision <> v_current_revision + 1)
          OR (v_current_revision IS NULL AND v_revision <> 1) THEN
          v_rejected := v_rejected || jsonb_build_array(jsonb_build_object(
            'operation_id', v_operation_id, 'entity_type', v_entity_type,
            'entity_id', v_entity_id, 'reason', 'stale_revision'
          ));
          CONTINUE;
        END IF;
        IF v_current_revision IS NOT NULL AND (
          v_proposal.creator_source <> v_record ->> 'creator_source'
          OR v_proposal.creator_device_id_hash IS DISTINCT FROM NULLIF(v_record ->> 'creator_device_id_hash', '')
          OR v_proposal.created_at <> (v_record ->> 'created_at')::timestamptz
        ) THEN
          v_rejected := v_rejected || jsonb_build_array(jsonb_build_object(
            'operation_id', v_operation_id, 'entity_type', v_entity_type,
            'entity_id', v_entity_id, 'reason', 'conflict'
          ));
          CONTINUE;
        END IF;
        IF v_current_revision IS NOT NULL AND (
          EXISTS (
            SELECT 1 FROM public.system_action_execution_leases lease
            WHERE lease.user_id = p_user_id
              AND lease.proposal_id = v_entity_id
          )
          OR EXISTS (
            SELECT 1 FROM public.system_action_receipts receipt
            WHERE receipt.user_id = p_user_id
              AND receipt.proposal_id = v_entity_id
          )
        ) THEN
          v_rejected := v_rejected || jsonb_build_array(jsonb_build_object(
            'operation_id', v_operation_id, 'entity_type', v_entity_type,
            'entity_id', v_entity_id, 'reason', 'conflict'
          ));
          CONTINUE;
        END IF;
        IF v_operation_kind = 'delete' THEN
          IF v_current_revision IS NULL THEN
            v_rejected := v_rejected || jsonb_build_array(jsonb_build_object(
              'operation_id', v_operation_id, 'entity_type', v_entity_type,
              'entity_id', v_entity_id, 'reason', 'stale_revision'
            ));
            CONTINUE;
          END IF;
          v_deleted_at := COALESCE(NULLIF(v_record ->> 'deleted_at', '')::timestamptz, now());
        ELSE
          v_deleted_at := NULL;
        END IF;

        INSERT INTO public.system_action_proposals (
          user_id, proposal_id, schema_version, revision, kind, payload,
          payload_hash, title, rationale, source_refs, creator_source,
          creator_device_id_hash, redaction_level, target_device_preference,
          target_device_id_hash, state, expires_at, deleted_at, created_at,
          updated_at, change_sequence
        ) VALUES (
          p_user_id, v_entity_id, 1, v_revision, v_record ->> 'kind',
          v_record -> 'payload', v_record ->> 'payload_hash', v_record ->> 'title',
          COALESCE(v_record ->> 'rationale', ''), v_record -> 'source_refs',
          v_record ->> 'creator_source', NULLIF(v_record ->> 'creator_device_id_hash', ''),
          v_record ->> 'redaction_level', v_record ->> 'target_device_preference',
          NULLIF(v_record ->> 'target_device_id_hash', ''),
          CASE WHEN v_operation_kind = 'delete' THEN 'cancelled' ELSE 'pending' END,
          NULLIF(v_record ->> 'expires_at', '')::timestamptz, v_deleted_at,
          COALESCE(NULLIF(v_record ->> 'created_at', '')::timestamptz, now()),
          now(), nextval('public.daypage_system_action_change_sequence')
        )
        ON CONFLICT (user_id, proposal_id) DO UPDATE SET
          schema_version = EXCLUDED.schema_version,
          revision = EXCLUDED.revision,
          kind = EXCLUDED.kind,
          payload = EXCLUDED.payload,
          payload_hash = EXCLUDED.payload_hash,
          title = EXCLUDED.title,
          rationale = EXCLUDED.rationale,
          source_refs = EXCLUDED.source_refs,
          redaction_level = EXCLUDED.redaction_level,
          target_device_preference = EXCLUDED.target_device_preference,
          target_device_id_hash = EXCLUDED.target_device_id_hash,
          state = EXCLUDED.state,
          expires_at = EXCLUDED.expires_at,
          deleted_at = EXCLUDED.deleted_at,
          updated_at = EXCLUDED.updated_at,
          change_sequence = EXCLUDED.change_sequence
        RETURNING change_sequence INTO v_change_sequence;

        v_record := v_record || jsonb_build_object(
          'state', CASE WHEN v_operation_kind = 'delete' THEN 'cancelled' ELSE 'pending' END,
          'deleted_at', public.daypage_system_action_timestamp_text_v1(v_deleted_at)
        );

      ELSIF v_entity_type = 'approval' THEN
        IF v_operation_kind <> 'append'
          OR v_record - ARRAY[
            'schema_version','approval_id','proposal_id','phase','proposal_revision',
            'payload_hash','decision','device_id_hash','decided_at','has_replacement'
          ] <> '{}'::jsonb
          OR NOT (v_record ?& ARRAY[
            'schema_version','approval_id','proposal_id','phase','proposal_revision',
            'payload_hash','decision','device_id_hash','decided_at','has_replacement'
          ])
          OR COALESCE((v_record ->> 'schema_version')::integer, 0) <> 1
          OR (v_record ->> 'approval_id')::uuid <> v_entity_id
          OR (v_record ->> 'proposal_revision')::bigint <> v_revision
          OR COALESCE(v_record ->> 'phase', '') NOT IN ('execute', 'undo')
          OR COALESCE(v_record ->> 'decision', '') NOT IN ('approve', 'reject')
          OR jsonb_typeof(v_record -> 'has_replacement') <> 'boolean'
          OR (
            v_record ->> 'decision' = 'approve'
            AND (v_record ->> 'has_replacement')::boolean
          )
          OR COALESCE(v_record ->> 'payload_hash', '') !~ '^[0-9a-f]{64}$'
          OR COALESCE(v_record ->> 'device_id_hash', '') !~ '^[0-9a-f]{64}$'
          OR jsonb_typeof(v_record -> 'decided_at') <> 'string'
          OR NOT public.daypage_is_canonical_system_action_timestamp_v1(v_record ->> 'decided_at') THEN
          RAISE EXCEPTION 'invalid approval';
        END IF;
        SELECT * INTO v_proposal
        FROM public.system_action_proposals
        WHERE user_id = p_user_id
          AND proposal_id = (v_record ->> 'proposal_id')::uuid
          AND deleted_at IS NULL
        FOR UPDATE;
        IF NOT FOUND
          OR v_proposal.revision <> v_revision
          OR v_proposal.payload_hash <> v_record ->> 'payload_hash'
          OR NOT public.daypage_system_action_cloud_policy_allows_v1(
            p_user_id, v_proposal.kind, v_proposal.payload
          )
          OR (v_proposal.expires_at IS NOT NULL AND v_proposal.expires_at <= now()) THEN
          v_rejected := v_rejected || jsonb_build_array(jsonb_build_object(
            'operation_id', v_operation_id, 'entity_type', v_entity_type,
            'entity_id', v_entity_id, 'reason', 'approval_mismatch'
          ));
          CONTINUE;
        END IF;
        IF v_record ->> 'phase' = 'undo'
          AND NOT EXISTS (
            SELECT 1 FROM public.system_action_receipts
            WHERE user_id = p_user_id AND proposal_id = v_proposal.proposal_id
              AND phase = 'execute' AND outcome = 'succeeded'
          ) THEN
          v_rejected := v_rejected || jsonb_build_array(jsonb_build_object(
            'operation_id', v_operation_id, 'entity_type', v_entity_type,
            'entity_id', v_entity_id, 'reason', 'approval_mismatch'
          ));
          CONTINUE;
        END IF;

        INSERT INTO public.system_action_approvals (
          user_id, approval_id, proposal_id, schema_version, phase,
          proposal_revision, payload_hash, decision, device_id_hash,
          replacement_proposal_id, decided_at
        ) VALUES (
          p_user_id, v_entity_id, v_proposal.proposal_id, 1,
          v_record ->> 'phase', v_revision, v_record ->> 'payload_hash',
          v_record ->> 'decision', v_record ->> 'device_id_hash',
          CASE WHEN (v_record ->> 'has_replacement')::boolean
            THEN v_proposal.proposal_id ELSE NULL END,
          (v_record ->> 'decided_at')::timestamptz
        ) RETURNING change_sequence INTO v_change_sequence;

        IF v_record ->> 'phase' = 'execute' THEN
          UPDATE public.system_action_proposals SET
            state = CASE WHEN v_record ->> 'decision' = 'approve' THEN 'approved' ELSE 'rejected' END,
            updated_at = now(),
            change_sequence = nextval('public.daypage_system_action_change_sequence')
          WHERE user_id = p_user_id AND proposal_id = v_proposal.proposal_id;
        END IF;

      ELSIF v_entity_type = 'receipt' THEN
        IF v_operation_kind <> 'append'
          OR v_record - ARRAY[
            'schema_version','receipt_id','proposal_id','phase','proposal_revision',
            'payload_hash','attempt','outcome','device_id_hash','execution_mode',
            'lease_id','result','error_code','reconciliation_state','undo_capability',
            'external_id_hash','started_at','completed_at'
          ] <> '{}'::jsonb
          OR NOT (v_record ?& ARRAY[
            'schema_version','receipt_id','proposal_id','phase','proposal_revision',
            'payload_hash','attempt','outcome','device_id_hash','execution_mode',
            'lease_id','result','error_code','reconciliation_state','undo_capability',
            'external_id_hash','started_at','completed_at'
          ])
          OR COALESCE((v_record ->> 'schema_version')::integer, 0) <> 1
          OR (v_record ->> 'receipt_id')::uuid <> v_entity_id
          OR (v_record ->> 'proposal_revision')::bigint <> v_revision
          OR COALESCE(v_record ->> 'phase', '') NOT IN ('execute', 'undo')
          OR COALESCE(v_record ->> 'outcome', '') NOT IN ('succeeded', 'failed', 'cancelled', 'ambiguous')
          OR COALESCE(v_record ->> 'execution_mode', '') NOT IN ('online_lease', 'offline_owner')
          OR COALESCE(v_record ->> 'payload_hash', '') !~ '^[0-9a-f]{64}$'
          OR COALESCE(v_record ->> 'device_id_hash', '') !~ '^[0-9a-f]{64}$'
          OR jsonb_typeof(v_record -> 'result') <> 'object'
          OR NOT public.daypage_validate_system_action_receipt_result_v1(v_record -> 'result')
          OR COALESCE((v_record ->> 'attempt')::integer, 0) NOT BETWEEN 1 AND 1000
          OR COALESCE(v_record ->> 'reconciliation_state', '') NOT IN ('confirmed','pending','needs_review','not_applicable')
          OR COALESCE(v_record ->> 'undo_capability', '') NOT IN ('reversible','compensating','manual','none')
          OR (v_record ->> 'error_code' IS NOT NULL AND v_record ->> 'error_code' !~ '^[a-z0-9_.-]{1,80}$')
          OR (v_record ->> 'external_id_hash' IS NOT NULL AND v_record ->> 'external_id_hash' !~ '^[0-9a-f]{64}$')
          OR jsonb_typeof(v_record -> 'started_at') <> 'string'
          OR NOT public.daypage_is_canonical_system_action_timestamp_v1(v_record ->> 'started_at')
          OR jsonb_typeof(v_record -> 'completed_at') <> 'string'
          OR NOT public.daypage_is_canonical_system_action_timestamp_v1(v_record ->> 'completed_at')
          OR (v_record ->> 'completed_at')::timestamptz < (v_record ->> 'started_at')::timestamptz
          OR (v_record ->> 'outcome' = 'succeeded' AND v_record ->> 'error_code' IS NOT NULL)
          OR (v_record ->> 'execution_mode' = 'online_lease' AND v_record ->> 'lease_id' IS NULL)
          OR (v_record ->> 'execution_mode' = 'offline_owner' AND v_record ->> 'lease_id' IS NOT NULL) THEN
          RAISE EXCEPTION 'invalid receipt';
        END IF;
        IF EXISTS (
          SELECT 1 FROM public.system_action_receipts
          WHERE user_id = p_user_id
            AND proposal_id = (v_record ->> 'proposal_id')::uuid
            AND phase = v_record ->> 'phase'
            AND device_id_hash = v_record ->> 'device_id_hash'
            AND attempt = (v_record ->> 'attempt')::integer
        ) THEN
          v_rejected := v_rejected || jsonb_build_array(jsonb_build_object(
            'operation_id', v_operation_id, 'entity_type', v_entity_type,
            'entity_id', v_entity_id, 'reason', 'conflict'
          ));
          CONTINUE;
        END IF;
        SELECT * INTO v_proposal
        FROM public.system_action_proposals
        WHERE user_id = p_user_id
          AND proposal_id = (v_record ->> 'proposal_id')::uuid
          AND deleted_at IS NULL
        FOR UPDATE;
        IF NOT FOUND OR v_proposal.revision <> v_revision
          OR v_proposal.payload_hash <> v_record ->> 'payload_hash'
          OR NOT EXISTS (
            SELECT 1 FROM public.system_action_approvals
            WHERE user_id = p_user_id AND proposal_id = v_proposal.proposal_id
              AND phase = v_record ->> 'phase'
              AND proposal_revision = v_revision
              AND payload_hash = v_proposal.payload_hash
              AND decision = 'approve'
          ) THEN
          v_rejected := v_rejected || jsonb_build_array(jsonb_build_object(
            'operation_id', v_operation_id, 'entity_type', v_entity_type,
            'entity_id', v_entity_id, 'reason', 'approval_mismatch'
          ));
          CONTINUE;
        END IF;
        IF v_record ->> 'phase' = 'undo'
          AND NOT EXISTS (
            SELECT 1 FROM public.system_action_receipts
            WHERE user_id = p_user_id AND proposal_id = v_proposal.proposal_id
              AND phase = 'execute' AND outcome = 'succeeded'
              AND proposal_revision = v_revision
              AND payload_hash = v_proposal.payload_hash
              AND device_id_hash = v_record ->> 'device_id_hash'
          ) THEN
          v_rejected := v_rejected || jsonb_build_array(jsonb_build_object(
            'operation_id', v_operation_id, 'entity_type', v_entity_type,
            'entity_id', v_entity_id, 'reason', 'approval_mismatch'
          ));
          CONTINUE;
        END IF;
        IF EXISTS (
          SELECT 1 FROM public.system_action_receipts
          WHERE user_id = p_user_id
            AND proposal_id = v_proposal.proposal_id
            AND phase = v_record ->> 'phase'
            AND proposal_revision = v_revision
            AND payload_hash = v_proposal.payload_hash
            AND outcome = 'succeeded'
        ) THEN
          v_rejected := v_rejected || jsonb_build_array(jsonb_build_object(
            'operation_id', v_operation_id, 'entity_type', v_entity_type,
            'entity_id', v_entity_id, 'reason', 'conflict'
          ));
          CONTINUE;
        END IF;

        IF v_record ->> 'execution_mode' = 'online_lease' THEN
          SELECT * INTO v_lease
          FROM public.system_action_execution_leases
          WHERE user_id = p_user_id
            AND lease_id = (v_record ->> 'lease_id')::uuid
            AND proposal_id = v_proposal.proposal_id
            AND phase = v_record ->> 'phase'
            AND proposal_revision = v_revision
            AND payload_hash = v_proposal.payload_hash
            AND device_id_hash = v_record ->> 'device_id_hash'
            AND released_at IS NULL
            AND date_trunc('milliseconds', created_at) <= (v_record ->> 'started_at')::timestamptz
            AND date_trunc('milliseconds', expires_at) >= (v_record ->> 'started_at')::timestamptz
          FOR UPDATE;
          IF NOT FOUND THEN
            v_rejected := v_rejected || jsonb_build_array(jsonb_build_object(
              'operation_id', v_operation_id, 'entity_type', v_entity_type,
              'entity_id', v_entity_id, 'reason', 'lease_required'
            ));
            CONTINUE;
          END IF;
        ELSE
          IF NOT (
            (v_proposal.target_device_preference = 'creating_device'
              AND v_proposal.creator_device_id_hash = v_record ->> 'device_id_hash')
            OR (v_proposal.target_device_preference = 'specific_device'
              AND v_proposal.target_device_id_hash = v_record ->> 'device_id_hash')
            OR (v_proposal.target_device_preference = 'any'
              AND v_proposal.creator_device_id_hash = v_record ->> 'device_id_hash')
          ) THEN
            v_rejected := v_rejected || jsonb_build_array(jsonb_build_object(
              'operation_id', v_operation_id, 'entity_type', v_entity_type,
              'entity_id', v_entity_id, 'reason', 'lease_required'
            ));
            CONTINUE;
          END IF;
        END IF;

        INSERT INTO public.system_action_receipts (
          user_id, receipt_id, proposal_id, schema_version, phase,
          proposal_revision, payload_hash, attempt, outcome, device_id_hash,
          execution_mode, lease_id, result, error_code, reconciliation_state,
          undo_capability, external_id_hash, started_at, completed_at
        ) VALUES (
          p_user_id, v_entity_id, v_proposal.proposal_id, 1, v_record ->> 'phase',
          v_revision, v_record ->> 'payload_hash', (v_record ->> 'attempt')::integer,
          v_record ->> 'outcome', v_record ->> 'device_id_hash',
          v_record ->> 'execution_mode', NULLIF(v_record ->> 'lease_id', '')::uuid,
          v_record -> 'result', NULLIF(v_record ->> 'error_code', ''),
          v_record ->> 'reconciliation_state', v_record ->> 'undo_capability',
          NULLIF(v_record ->> 'external_id_hash', ''),
          (v_record ->> 'started_at')::timestamptz,
          (v_record ->> 'completed_at')::timestamptz
        ) RETURNING change_sequence INTO v_change_sequence;

        IF v_record ->> 'execution_mode' = 'online_lease' THEN
          UPDATE public.system_action_execution_leases SET
            released_at = now(), release_reason = 'completed'
          WHERE user_id = p_user_id AND lease_id = v_lease.lease_id;
        END IF;
        UPDATE public.system_action_proposals SET
          state = CASE
            WHEN v_record ->> 'outcome' = 'ambiguous' THEN 'needs_review'
            WHEN v_record ->> 'outcome' = 'failed' THEN 'failed'
            WHEN v_record ->> 'outcome' = 'cancelled' THEN 'cancelled'
            WHEN v_record ->> 'phase' = 'undo' THEN 'cancelled'
            ELSE 'completed'
          END,
          updated_at = now(),
          change_sequence = nextval('public.daypage_system_action_change_sequence')
        WHERE user_id = p_user_id AND proposal_id = v_proposal.proposal_id;

      ELSIF v_entity_type = 'policy' THEN
        IF v_operation_kind NOT IN ('upsert', 'delete')
          OR v_record - ARRAY[
            'schema_version','policy_id','capability','revision','is_offered',
            'sync_enabled','disclosure_level','updated_at','deleted_at'
          ] <> '{}'::jsonb
          OR NOT (v_record ?& ARRAY[
            'schema_version','policy_id','capability','revision','is_offered',
            'sync_enabled','disclosure_level','updated_at','deleted_at'
          ])
          OR COALESCE((v_record ->> 'schema_version')::integer, 0) <> 1
          OR (v_record ->> 'policy_id')::uuid <> v_entity_id
          OR (v_record ->> 'revision')::bigint <> v_revision
          OR COALESCE(v_record ->> 'capability', '') NOT IN (
            'calendar', 'reminders', 'contacts', 'notifications', 'location', 'routes',
            'photos', 'capture', 'focus', 'spotlight', 'health_context', 'weather_context'
          )
          OR COALESCE(v_record ->> 'disclosure_level', '') NOT IN ('private', 'summary', 'full_proposal')
          OR jsonb_typeof(v_record -> 'is_offered') <> 'boolean'
          OR jsonb_typeof(v_record -> 'sync_enabled') <> 'boolean'
          OR (
            NOT (v_record ->> 'is_offered')::boolean
            AND (
              (v_record ->> 'sync_enabled')::boolean
              OR v_record ->> 'disclosure_level' <> 'private'
            )
          )
          OR (
            (v_record ->> 'is_offered')::boolean
            AND NOT (v_record ->> 'sync_enabled')::boolean
            AND v_record ->> 'disclosure_level' <> 'private'
          )
          OR (
            (v_record ->> 'is_offered')::boolean
            AND (v_record ->> 'sync_enabled')::boolean
            AND v_record ->> 'disclosure_level' NOT IN ('summary', 'full_proposal')
          )
          OR jsonb_typeof(v_record -> 'updated_at') <> 'string'
          OR NOT public.daypage_is_canonical_system_action_timestamp_v1(v_record ->> 'updated_at')
          OR (
            v_record ->> 'deleted_at' IS NOT NULL
            AND (
              jsonb_typeof(v_record -> 'deleted_at') <> 'string'
              OR NOT public.daypage_is_canonical_system_action_timestamp_v1(v_record ->> 'deleted_at')
            )
          ) THEN
          RAISE EXCEPTION 'invalid policy';
        END IF;
        SELECT revision INTO v_current_revision
        FROM public.system_action_capability_policies
        WHERE user_id = p_user_id AND policy_id = v_entity_id
        FOR UPDATE;
        IF (FOUND AND v_revision <> v_current_revision + 1)
          OR (NOT FOUND AND v_revision <> 1) THEN
          v_rejected := v_rejected || jsonb_build_array(jsonb_build_object(
            'operation_id', v_operation_id, 'entity_type', v_entity_type,
            'entity_id', v_entity_id, 'reason', 'stale_revision'
          ));
          CONTINUE;
        END IF;
        IF v_operation_kind = 'delete' THEN
          IF v_current_revision IS NULL THEN
            v_rejected := v_rejected || jsonb_build_array(jsonb_build_object(
              'operation_id', v_operation_id, 'entity_type', v_entity_type,
              'entity_id', v_entity_id, 'reason', 'stale_revision'
            ));
            CONTINUE;
          END IF;
          v_deleted_at := COALESCE(NULLIF(v_record ->> 'deleted_at', '')::timestamptz, now());
        ELSE
          v_deleted_at := NULL;
        END IF;

        INSERT INTO public.system_action_capability_policies (
          user_id, policy_id, schema_version, capability, revision,
          is_offered, sync_enabled, disclosure_level, deleted_at, updated_at,
          change_sequence
        ) VALUES (
          p_user_id, v_entity_id, 1, v_record ->> 'capability', v_revision,
          (v_record ->> 'is_offered')::boolean,
          (v_record ->> 'sync_enabled')::boolean,
          v_record ->> 'disclosure_level', v_deleted_at,
          COALESCE(NULLIF(v_record ->> 'updated_at', '')::timestamptz, now()),
          nextval('public.daypage_system_action_change_sequence')
        )
        ON CONFLICT (user_id, policy_id) DO UPDATE SET
          schema_version = EXCLUDED.schema_version,
          capability = EXCLUDED.capability,
          revision = EXCLUDED.revision,
          is_offered = EXCLUDED.is_offered,
          sync_enabled = EXCLUDED.sync_enabled,
          disclosure_level = EXCLUDED.disclosure_level,
          deleted_at = EXCLUDED.deleted_at,
          updated_at = EXCLUDED.updated_at,
          change_sequence = EXCLUDED.change_sequence
        RETURNING change_sequence INTO v_change_sequence;
        v_record := v_record || jsonb_build_object(
          'deleted_at', public.daypage_system_action_timestamp_text_v1(v_deleted_at)
        );
      END IF;

      v_result := jsonb_build_object(
        'operation_id', v_operation_id,
        'entity_type', v_entity_type,
        'entity_id', v_entity_id,
        'revision', v_revision,
        'status', 'applied',
        'change_sequence', v_change_sequence,
        'record', v_record
      );
      INSERT INTO public.system_action_sync_operations (
        user_id, operation_id, entity_type, entity_id, operation_kind,
        revision, request_fingerprint, result
      ) VALUES (
        p_user_id, v_operation_id, v_entity_type, v_entity_id,
        v_operation_kind, v_revision, v_fingerprint, v_result
      );
      v_accepted := v_accepted || jsonb_build_array(v_result);
    EXCEPTION WHEN OTHERS THEN
      IF SQLSTATE = 'P8801' THEN
        v_reason := 'operation_id_reuse_mismatch';
      ELSIF SQLSTATE = 'P8802' THEN
        v_reason := 'stale_revision';
      ELSIF SQLSTATE = 'P8803' THEN
        v_reason := 'approval_mismatch';
      ELSIF SQLSTATE = 'P8804' THEN
        v_reason := 'lease_required';
      ELSIF SQLSTATE = '23505' THEN
        v_reason := 'conflict';
      ELSE
        v_reason := 'invalid_operation';
      END IF;
      v_rejected := v_rejected || jsonb_build_array(jsonb_build_object(
        'operation_id', v_operation ->> 'operation_id',
        'entity_type', v_operation ->> 'entity_type',
        'entity_id', v_operation ->> 'entity_id',
        'reason', v_reason
      ));
    END;
  END LOOP;

  RETURN jsonb_build_object('accepted', v_accepted, 'rejected', v_rejected);
END;
$$;--> statement-breakpoint
REVOKE ALL ON FUNCTION public.daypage_apply_system_action_operations_for_user_v1(uuid, jsonb)
  FROM PUBLIC, anon, authenticated, service_role;--> statement-breakpoint

CREATE OR REPLACE FUNCTION public.daypage_apply_system_action_operations_v1(p_operations jsonb)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'authentication required' USING ERRCODE = '42501';
  END IF;
  IF COALESCE(auth.jwt() ->> 'client_id', '') <> '' THEN
    RAISE EXCEPTION 'OAuth clients must use the proposal-only RPC' USING ERRCODE = '42501';
  END IF;
  RETURN public.daypage_apply_system_action_operations_for_user_v1(auth.uid(), p_operations);
END;
$$;--> statement-breakpoint
REVOKE ALL ON FUNCTION public.daypage_apply_system_action_operations_v1(jsonb)
  FROM PUBLIC, anon;--> statement-breakpoint
GRANT EXECUTE ON FUNCTION public.daypage_apply_system_action_operations_v1(jsonb)
  TO authenticated;--> statement-breakpoint

CREATE OR REPLACE FUNCTION public.daypage_mcp_propose_system_action_v1(
  p_operation_id uuid,
  p_proposal jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_client_id text := auth.jwt() ->> 'client_id';
BEGIN
  IF v_user_id IS NULL OR btrim(COALESCE(v_client_id, '')) = '' THEN
    RAISE EXCEPTION 'OAuth client credential required' USING ERRCODE = '42501';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.mcp_client_grants grant_row
    WHERE grant_row.user_id = v_user_id
      AND grant_row.client_id = v_client_id
      AND grant_row.revoked_at IS NULL
      AND grant_row.can_propose_actions
  ) THEN
    RAISE EXCEPTION 'OAuth client lacks action proposal grant' USING ERRCODE = '42501';
  END IF;
  IF jsonb_typeof(p_proposal) <> 'object'
    OR p_proposal ->> 'creator_source' IS DISTINCT FROM 'mcp'
    OR p_proposal ->> 'creator_device_id_hash' IS NOT NULL
    OR p_proposal ->> 'target_device_preference' IS DISTINCT FROM 'any'
    OR p_proposal ->> 'target_device_id_hash' IS NOT NULL
    OR p_proposal ->> 'redaction_level' IS DISTINCT FROM 'private'
    OR p_proposal ->> 'state' IS DISTINCT FROM 'pending'
    OR p_proposal ->> 'deleted_at' IS NOT NULL THEN
    RAISE EXCEPTION 'invalid MCP action proposal metadata' USING ERRCODE = '22023';
  END IF;
  RETURN public.daypage_apply_system_action_operations_for_user_v1(
    v_user_id,
    jsonb_build_array(jsonb_build_object(
      'protocol_version', 1,
      'operation_id', p_operation_id,
      'entity_type', 'proposal',
      'entity_id', p_proposal ->> 'proposal_id',
      'operation_kind', 'upsert',
      'revision', p_proposal ->> 'revision',
      'record', p_proposal
    ))
  );
END;
$$;--> statement-breakpoint
REVOKE ALL ON FUNCTION public.daypage_mcp_propose_system_action_v1(uuid, jsonb)
  FROM PUBLIC, anon;--> statement-breakpoint
GRANT EXECUTE ON FUNCTION public.daypage_mcp_propose_system_action_v1(uuid, jsonb)
  TO authenticated;--> statement-breakpoint

CREATE OR REPLACE FUNCTION public.daypage_mcp_list_system_action_proposals_v1(
  p_limit integer DEFAULT 20,
  p_state text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_client_id text := auth.jwt() ->> 'client_id';
  v_limit integer;
  v_result jsonb;
BEGIN
  IF v_user_id IS NULL OR btrim(COALESCE(v_client_id, '')) = '' THEN
    RAISE EXCEPTION 'OAuth client credential required' USING ERRCODE = '42501';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.mcp_client_grants grant_row
    WHERE grant_row.user_id = v_user_id
      AND grant_row.client_id = v_client_id
      AND grant_row.revoked_at IS NULL
      AND grant_row.can_read_actions
  ) THEN
    RAISE EXCEPTION 'OAuth client lacks action read grant' USING ERRCODE = '42501';
  END IF;
  IF p_state IS NOT NULL AND p_state NOT IN (
    'pending', 'approved', 'rejected', 'executing', 'completed', 'failed',
    'cancelled', 'needs_review'
  ) THEN
    RAISE EXCEPTION 'invalid proposal state' USING ERRCODE = '22023';
  END IF;
  v_limit := LEAST(GREATEST(COALESCE(p_limit, 20), 1), 50);
  SELECT COALESCE(jsonb_agg(
    (to_jsonb(proposal_row) - ARRAY['created_at','expires_at','deleted_at'])
      || jsonb_build_object(
        'created_at', public.daypage_system_action_timestamp_text_v1(proposal_row.created_at),
        'expires_at', public.daypage_system_action_timestamp_text_v1(proposal_row.expires_at),
        'deleted_at', public.daypage_system_action_timestamp_text_v1(proposal_row.deleted_at)
      )
    ORDER BY proposal_row.created_at DESC
  ), '[]'::jsonb)
  INTO v_result
  FROM (
    SELECT proposal_id, schema_version, revision, kind, payload, payload_hash,
      title, rationale, source_refs, redaction_level, target_device_preference,
      state, created_at, expires_at, deleted_at
    FROM public.system_action_proposals
    WHERE user_id = v_user_id
      AND deleted_at IS NULL
      AND (p_state IS NULL OR state = p_state)
    ORDER BY created_at DESC LIMIT v_limit
  ) proposal_row;
  RETURN v_result;
END;
$$;--> statement-breakpoint
REVOKE ALL ON FUNCTION public.daypage_mcp_list_system_action_proposals_v1(integer, text)
  FROM PUBLIC, anon;--> statement-breakpoint
GRANT EXECUTE ON FUNCTION public.daypage_mcp_list_system_action_proposals_v1(integer, text)
  TO authenticated;--> statement-breakpoint

CREATE OR REPLACE FUNCTION public.daypage_mcp_list_system_action_receipts_v1(
  p_limit integer DEFAULT 20
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_client_id text := auth.jwt() ->> 'client_id';
  v_limit integer;
  v_result jsonb;
BEGIN
  IF v_user_id IS NULL OR btrim(COALESCE(v_client_id, '')) = '' THEN
    RAISE EXCEPTION 'OAuth client credential required' USING ERRCODE = '42501';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.mcp_client_grants grant_row
    WHERE grant_row.user_id = v_user_id
      AND grant_row.client_id = v_client_id
      AND grant_row.revoked_at IS NULL
      AND grant_row.can_read_actions
  ) THEN
    RAISE EXCEPTION 'OAuth client lacks action read grant' USING ERRCODE = '42501';
  END IF;
  v_limit := LEAST(GREATEST(COALESCE(p_limit, 20), 1), 50);
  SELECT COALESCE(jsonb_agg(
    (to_jsonb(receipt_row) - ARRAY['started_at','completed_at'])
      || jsonb_build_object(
        'started_at', public.daypage_system_action_timestamp_text_v1(receipt_row.started_at),
        'completed_at', public.daypage_system_action_timestamp_text_v1(receipt_row.completed_at)
      )
    ORDER BY receipt_row.completed_at DESC
  ), '[]'::jsonb)
  INTO v_result
  FROM (
    SELECT receipt_id, proposal_id, schema_version, phase, proposal_revision,
      payload_hash, attempt, outcome, result, error_code, reconciliation_state,
      undo_capability, started_at, completed_at
    FROM public.system_action_receipts
    WHERE user_id = v_user_id
    ORDER BY completed_at DESC LIMIT v_limit
  ) receipt_row;
  RETURN v_result;
END;
$$;--> statement-breakpoint
REVOKE ALL ON FUNCTION public.daypage_mcp_list_system_action_receipts_v1(integer)
  FROM PUBLIC, anon;--> statement-breakpoint
GRANT EXECUTE ON FUNCTION public.daypage_mcp_list_system_action_receipts_v1(integer)
  TO authenticated;--> statement-breakpoint

CREATE OR REPLACE FUNCTION public.daypage_pull_system_action_changes_v1(
  p_after_sequence bigint DEFAULT 0,
  p_limit integer DEFAULT 100
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_limit integer;
  v_changes jsonb;
  v_next_cursor bigint;
  v_has_more boolean;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'authentication required' USING ERRCODE = '42501';
  END IF;
  IF COALESCE(auth.jwt() ->> 'client_id', '') <> '' THEN
    RAISE EXCEPTION 'OAuth clients cannot use the native action pull RPC' USING ERRCODE = '42501';
  END IF;
  IF p_after_sequence IS NULL OR p_after_sequence < 0 THEN
    RAISE EXCEPTION 'p_after_sequence must be non-negative' USING ERRCODE = '22023';
  END IF;
  v_limit := LEAST(GREATEST(COALESCE(p_limit, 100), 1), 200);

  WITH all_changes AS (
    SELECT proposal.change_sequence, 'proposal'::text AS entity_type,
      proposal.proposal_id AS entity_id,
      (to_jsonb(proposal) - ARRAY['user_id','change_sequence','updated_at','created_at','expires_at','deleted_at'])
        || jsonb_build_object(
          'created_at', public.daypage_system_action_timestamp_text_v1(proposal.created_at),
          'expires_at', public.daypage_system_action_timestamp_text_v1(proposal.expires_at),
          'deleted_at', public.daypage_system_action_timestamp_text_v1(proposal.deleted_at)
        ) AS record
    FROM public.system_action_proposals proposal
    WHERE proposal.user_id = v_user_id AND proposal.change_sequence > p_after_sequence
    UNION ALL
    SELECT approval.change_sequence, 'approval', approval.approval_id,
      (to_jsonb(approval) - ARRAY['user_id','change_sequence','created_at','decided_at','replacement_proposal_id'])
        || jsonb_build_object(
          'decided_at', public.daypage_system_action_timestamp_text_v1(approval.decided_at),
          'has_replacement', approval.replacement_proposal_id IS NOT NULL
        )
    FROM public.system_action_approvals approval
    WHERE approval.user_id = v_user_id AND approval.change_sequence > p_after_sequence
    UNION ALL
    SELECT receipt.change_sequence, 'receipt', receipt.receipt_id,
      (to_jsonb(receipt) - ARRAY['user_id','change_sequence','created_at','started_at','completed_at'])
        || jsonb_build_object(
          'started_at', public.daypage_system_action_timestamp_text_v1(receipt.started_at),
          'completed_at', public.daypage_system_action_timestamp_text_v1(receipt.completed_at)
        )
    FROM public.system_action_receipts receipt
    WHERE receipt.user_id = v_user_id AND receipt.change_sequence > p_after_sequence
    UNION ALL
    SELECT policy.change_sequence, 'policy', policy.policy_id,
      (to_jsonb(policy) - ARRAY['user_id','change_sequence','created_at','updated_at','deleted_at'])
        || jsonb_build_object(
          'updated_at', public.daypage_system_action_timestamp_text_v1(policy.updated_at),
          'deleted_at', public.daypage_system_action_timestamp_text_v1(policy.deleted_at)
        )
    FROM public.system_action_capability_policies policy
    WHERE policy.user_id = v_user_id AND policy.change_sequence > p_after_sequence
  ), page AS (
    SELECT * FROM all_changes ORDER BY change_sequence, entity_type, entity_id LIMIT v_limit
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'change_sequence', page.change_sequence,
      'entity_type', page.entity_type,
      'entity_id', page.entity_id,
      'record', page.record
    ) ORDER BY page.change_sequence, page.entity_type, page.entity_id), '[]'::jsonb),
    COALESCE(max(page.change_sequence), p_after_sequence)
  INTO v_changes, v_next_cursor
  FROM page;

  SELECT EXISTS (
    SELECT 1 FROM (
      SELECT change_sequence FROM public.system_action_proposals WHERE user_id = v_user_id
      UNION ALL SELECT change_sequence FROM public.system_action_approvals WHERE user_id = v_user_id
      UNION ALL SELECT change_sequence FROM public.system_action_receipts WHERE user_id = v_user_id
      UNION ALL SELECT change_sequence FROM public.system_action_capability_policies WHERE user_id = v_user_id
    ) remaining
    WHERE remaining.change_sequence > v_next_cursor
  ) INTO v_has_more;

  RETURN jsonb_build_object(
    'changes', v_changes,
    'next_cursor', v_next_cursor,
    'has_more', v_has_more
  );
END;
$$;--> statement-breakpoint
REVOKE ALL ON FUNCTION public.daypage_pull_system_action_changes_v1(bigint, integer)
  FROM PUBLIC, anon;--> statement-breakpoint
GRANT EXECUTE ON FUNCTION public.daypage_pull_system_action_changes_v1(bigint, integer)
  TO authenticated;--> statement-breakpoint

CREATE OR REPLACE FUNCTION public.daypage_claim_system_action_execution_v1(
  p_operation_id uuid,
  p_proposal_id uuid,
  p_phase text,
  p_proposal_revision bigint,
  p_payload_hash text,
  p_device_id_hash text,
  p_lease_seconds integer DEFAULT 120
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_seconds integer;
  v_fingerprint text;
  v_stored public.system_action_sync_operations%ROWTYPE;
  v_proposal public.system_action_proposals%ROWTYPE;
  v_existing public.system_action_execution_leases%ROWTYPE;
  v_lease_id uuid;
  v_issued_at timestamptz;
  v_expires_at timestamptz;
  v_receipt_id uuid;
  v_result jsonb;
  v_has_stored boolean := false;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'authentication required' USING ERRCODE = '42501';
  END IF;
  IF COALESCE(auth.jwt() ->> 'client_id', '') <> '' THEN
    RAISE EXCEPTION 'OAuth clients cannot claim native execution' USING ERRCODE = '42501';
  END IF;
  IF p_phase NOT IN ('execute', 'undo')
    OR p_proposal_revision < 1
    OR COALESCE(p_payload_hash, '') !~ '^[0-9a-f]{64}$'
    OR COALESCE(p_device_id_hash, '') !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'invalid execution claim' USING ERRCODE = '22023';
  END IF;
  v_seconds := LEAST(GREATEST(COALESCE(p_lease_seconds, 120), 30), 300);
  v_fingerprint := encode(extensions.digest(concat_ws(E'\x1f', '1', p_proposal_id::text,
    p_phase, p_proposal_revision::text, p_payload_hash, p_device_id_hash,
    v_seconds::text), 'sha256'), 'hex');

  PERFORM pg_advisory_xact_lock(hashtextextended(
    v_user_id::text || ':' || p_proposal_id::text || ':' || p_phase, 887
  ));

  SELECT * INTO v_stored
  FROM public.system_action_sync_operations
  WHERE user_id = v_user_id AND operation_id = p_operation_id;
  IF FOUND THEN
    v_has_stored := true;
    IF v_stored.entity_type <> 'lease'
      OR v_stored.entity_id <> p_proposal_id
      OR v_stored.operation_kind <> 'claim'
      OR v_stored.revision <> p_proposal_revision
      OR v_stored.request_fingerprint <> v_fingerprint THEN
      RAISE EXCEPTION 'operation id reuse mismatch' USING ERRCODE = '22023';
    END IF;
  END IF;

  SELECT * INTO v_proposal
  FROM public.system_action_proposals proposal
  WHERE proposal.user_id = v_user_id
    AND proposal.proposal_id = p_proposal_id
    AND proposal.revision = p_proposal_revision
    AND proposal.payload_hash = p_payload_hash
    AND proposal.deleted_at IS NULL
    AND (proposal.expires_at IS NULL OR proposal.expires_at > now())
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'exact proposal revision required' USING ERRCODE = '42501';
  END IF;
  IF NOT public.daypage_system_action_cloud_policy_allows_v1(
    v_user_id, v_proposal.kind, v_proposal.payload
  ) THEN
    RAISE EXCEPTION 'active full-proposal capability policy required' USING ERRCODE = '42501';
  END IF;
  IF NOT (
    v_proposal.target_device_preference = 'any'
    OR (
      v_proposal.target_device_preference = 'creating_device'
      AND v_proposal.creator_device_id_hash = p_device_id_hash
    )
    OR (
      v_proposal.target_device_preference = 'specific_device'
      AND v_proposal.target_device_id_hash = p_device_id_hash
    )
  ) THEN
    RAISE EXCEPTION 'target device is not eligible for this proposal' USING ERRCODE = '42501';
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM public.system_action_approvals approval
    WHERE approval.user_id = v_user_id
      AND approval.proposal_id = p_proposal_id
      AND approval.phase = p_phase
      AND approval.proposal_revision = p_proposal_revision
      AND approval.payload_hash = p_payload_hash
      AND approval.decision = 'approve'
  ) THEN
    RAISE EXCEPTION 'exact native approval required' USING ERRCODE = '42501';
  END IF;
  IF p_phase = 'undo' AND NOT EXISTS (
    SELECT 1 FROM public.system_action_receipts
    WHERE user_id = v_user_id AND proposal_id = p_proposal_id
      AND phase = 'execute' AND outcome = 'succeeded'
      AND proposal_revision = p_proposal_revision
      AND payload_hash = p_payload_hash
      AND device_id_hash = p_device_id_hash
  ) THEN
    RAISE EXCEPTION 'undo requires successful execution' USING ERRCODE = '22023';
  END IF;

  SELECT receipt_id INTO v_receipt_id
  FROM public.system_action_receipts
  WHERE user_id = v_user_id AND proposal_id = p_proposal_id
    AND phase = p_phase AND proposal_revision = p_proposal_revision
    AND payload_hash = p_payload_hash AND outcome = 'succeeded'
  ORDER BY attempt DESC LIMIT 1;
  IF v_receipt_id IS NOT NULL THEN
    v_result := jsonb_build_object(
      'operation_id', p_operation_id, 'proposal_id', p_proposal_id,
      'phase', p_phase, 'proposal_revision', p_proposal_revision,
      'payload_hash', p_payload_hash, 'device_id_hash', p_device_id_hash,
      'status', 'already_completed', 'lease_id', NULL,
      'issued_at', NULL, 'expires_at', NULL, 'receipt_id', v_receipt_id
    );
    IF v_has_stored THEN
      UPDATE public.system_action_sync_operations SET result = v_result
      WHERE user_id = v_user_id AND operation_id = p_operation_id;
    ELSE
      INSERT INTO public.system_action_sync_operations (
        user_id, operation_id, entity_type, entity_id, operation_kind,
        revision, request_fingerprint, result
      ) VALUES (v_user_id, p_operation_id, 'lease', p_proposal_id, 'claim',
        p_proposal_revision, v_fingerprint, v_result);
    END IF;
    RETURN v_result;
  END IF;

  SELECT receipt.receipt_id INTO v_receipt_id
  FROM public.system_action_execution_leases lease
  JOIN public.system_action_receipts receipt
    ON receipt.user_id = lease.user_id
   AND receipt.lease_id = lease.lease_id
  WHERE lease.user_id = v_user_id
    AND lease.claim_operation_id = p_operation_id
  ORDER BY receipt.attempt DESC
  LIMIT 1;
  IF v_receipt_id IS NOT NULL THEN
    v_result := jsonb_build_object(
      'operation_id', p_operation_id, 'proposal_id', p_proposal_id,
      'phase', p_phase, 'proposal_revision', p_proposal_revision,
      'payload_hash', p_payload_hash, 'device_id_hash', p_device_id_hash,
      'status', 'attempt_completed', 'lease_id', NULL,
      'issued_at', NULL, 'expires_at', NULL, 'receipt_id', v_receipt_id
    );
    IF v_has_stored THEN
      UPDATE public.system_action_sync_operations SET result = v_result
      WHERE user_id = v_user_id AND operation_id = p_operation_id;
    ELSE
      INSERT INTO public.system_action_sync_operations (
        user_id, operation_id, entity_type, entity_id, operation_kind,
        revision, request_fingerprint, result
      ) VALUES (v_user_id, p_operation_id, 'lease', p_proposal_id, 'claim',
        p_proposal_revision, v_fingerprint, v_result);
    END IF;
    RETURN v_result;
  END IF;

  SELECT * INTO v_existing
  FROM public.system_action_execution_leases
  WHERE user_id = v_user_id AND proposal_id = p_proposal_id
    AND phase = p_phase AND released_at IS NULL
  LIMIT 1 FOR UPDATE;
  IF FOUND THEN
    v_result := jsonb_build_object(
      'operation_id', p_operation_id, 'proposal_id', p_proposal_id,
      'phase', p_phase, 'proposal_revision', p_proposal_revision,
      'payload_hash', p_payload_hash, 'device_id_hash', p_device_id_hash,
      'status', CASE
        WHEN v_existing.claim_operation_id = p_operation_id
          AND v_existing.expires_at > now() THEN 'replayed'
        ELSE 'busy'
      END,
      'lease_id', v_existing.lease_id,
      'issued_at', public.daypage_system_action_timestamp_text_v1(v_existing.created_at),
      'expires_at', public.daypage_system_action_timestamp_text_v1(v_existing.expires_at),
      'receipt_id', NULL
    );
  ELSE
    v_expires_at := now() + make_interval(secs => v_seconds);
    SELECT * INTO v_existing
    FROM public.system_action_execution_leases lease
    WHERE lease.user_id = v_user_id
      AND lease.claim_operation_id = p_operation_id
      AND NOT EXISTS (
        SELECT 1 FROM public.system_action_receipts receipt
        WHERE receipt.user_id = lease.user_id AND receipt.lease_id = lease.lease_id
      )
    LIMIT 1 FOR UPDATE;
    IF FOUND THEN
      v_lease_id := v_existing.lease_id;
      v_issued_at := v_existing.created_at;
      v_expires_at := v_existing.expires_at;
    ELSIF v_has_stored AND v_stored.result ->> 'status' <> 'busy' THEN
      RETURN v_stored.result || jsonb_build_object('status', 'replayed');
    ELSE
      v_lease_id := gen_random_uuid();
      v_issued_at := date_trunc('milliseconds', now());
      v_expires_at := v_issued_at + make_interval(secs => v_seconds);
      INSERT INTO public.system_action_execution_leases (
        user_id, lease_id, claim_operation_id, proposal_id, phase,
        proposal_revision, payload_hash, device_id_hash, created_at, expires_at
      ) VALUES (
        v_user_id, v_lease_id, p_operation_id, p_proposal_id, p_phase,
        p_proposal_revision, p_payload_hash, p_device_id_hash, v_issued_at, v_expires_at
      );
    END IF;
    UPDATE public.system_action_proposals SET
      state = 'executing', updated_at = now(),
      change_sequence = nextval('public.daypage_system_action_change_sequence')
    WHERE user_id = v_user_id AND proposal_id = p_proposal_id;
    v_result := jsonb_build_object(
      'operation_id', p_operation_id, 'proposal_id', p_proposal_id,
      'phase', p_phase, 'proposal_revision', p_proposal_revision,
      'payload_hash', p_payload_hash, 'device_id_hash', p_device_id_hash,
      'status', 'claimed', 'lease_id', v_lease_id,
      'issued_at', public.daypage_system_action_timestamp_text_v1(v_issued_at),
      'expires_at', public.daypage_system_action_timestamp_text_v1(v_expires_at),
      'receipt_id', NULL
    );
  END IF;

  IF v_has_stored THEN
    UPDATE public.system_action_sync_operations SET result = v_result
    WHERE user_id = v_user_id AND operation_id = p_operation_id;
  ELSE
    INSERT INTO public.system_action_sync_operations (
      user_id, operation_id, entity_type, entity_id, operation_kind,
      revision, request_fingerprint, result
    ) VALUES (v_user_id, p_operation_id, 'lease', p_proposal_id, 'claim',
      p_proposal_revision, v_fingerprint, v_result);
  END IF;
  RETURN v_result;
END;
$$;--> statement-breakpoint
REVOKE ALL ON FUNCTION public.daypage_claim_system_action_execution_v1(uuid, uuid, text, bigint, text, text, integer)
  FROM PUBLIC, anon;--> statement-breakpoint
GRANT EXECUTE ON FUNCTION public.daypage_claim_system_action_execution_v1(uuid, uuid, text, bigint, text, text, integer)
  TO authenticated;--> statement-breakpoint

-- OAuth reconnection is deliberately separate from action authority. Every new
-- consent (including a reconnect after revocation) resets both action grants to
-- false; only the first-party settings RPC below may enable them afterwards.
CREATE OR REPLACE FUNCTION public.daypage_upsert_mcp_client_grant_v1(
  p_client_id text,
  p_can_write boolean
)
RETURNS void
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_user_id uuid := auth.uid();
BEGIN
  IF v_user_id IS NULL OR COALESCE(auth.jwt() ->> 'client_id', '') <> '' THEN
    RAISE EXCEPTION 'grant changes require a first-party account session' USING ERRCODE = '42501';
  END IF;
  IF btrim(COALESCE(p_client_id, '')) = '' OR octet_length(p_client_id) > 200 THEN
    RAISE EXCEPTION 'invalid client id' USING ERRCODE = '22023';
  END IF;
  INSERT INTO public.mcp_client_grants (
    user_id, client_id, can_read, can_write, can_read_actions,
    can_propose_actions, created_at, updated_at, revoked_at
  ) VALUES (
    v_user_id, p_client_id, true, COALESCE(p_can_write, false), false,
    false, now(), now(), NULL
  )
  ON CONFLICT (user_id, client_id) DO UPDATE SET
    can_read = true,
    can_write = EXCLUDED.can_write,
    can_read_actions = false,
    can_propose_actions = false,
    updated_at = now(),
    revoked_at = NULL;
END;
$$;--> statement-breakpoint
REVOKE ALL ON FUNCTION public.daypage_upsert_mcp_client_grant_v1(text, boolean)
  FROM PUBLIC, anon;--> statement-breakpoint
GRANT EXECUTE ON FUNCTION public.daypage_upsert_mcp_client_grant_v1(text, boolean)
  TO authenticated;--> statement-breakpoint

CREATE OR REPLACE FUNCTION public.daypage_revoke_mcp_client_grant_v1(p_client_id text)
RETURNS boolean
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_user_id uuid := auth.uid();
BEGIN
  IF v_user_id IS NULL OR COALESCE(auth.jwt() ->> 'client_id', '') <> '' THEN
    RAISE EXCEPTION 'grant changes require a first-party account session' USING ERRCODE = '42501';
  END IF;
  IF btrim(COALESCE(p_client_id, '')) = '' OR octet_length(p_client_id) > 200 THEN
    RAISE EXCEPTION 'invalid client id' USING ERRCODE = '22023';
  END IF;
  UPDATE public.mcp_client_grants SET
    can_read = false,
    can_write = false,
    can_read_actions = false,
    can_propose_actions = false,
    revoked_at = now(),
    updated_at = now()
  WHERE user_id = v_user_id AND client_id = p_client_id;
  RETURN FOUND;
END;
$$;--> statement-breakpoint
REVOKE ALL ON FUNCTION public.daypage_revoke_mcp_client_grant_v1(text)
  FROM PUBLIC, anon;--> statement-breakpoint
GRANT EXECUTE ON FUNCTION public.daypage_revoke_mcp_client_grant_v1(text)
  TO authenticated;--> statement-breakpoint

CREATE OR REPLACE FUNCTION public.daypage_set_mcp_action_grant_v1(
  p_client_id text,
  p_can_read_actions boolean,
  p_can_propose_actions boolean
)
RETURNS void
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_user_id uuid := auth.uid();
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'authentication required' USING ERRCODE = '42501';
  END IF;
  IF COALESCE(auth.jwt() ->> 'client_id', '') <> '' THEN
    RAISE EXCEPTION 'action grants require a first-party account session' USING ERRCODE = '42501';
  END IF;
  IF btrim(COALESCE(p_client_id, '')) = '' OR octet_length(p_client_id) > 200 THEN
    RAISE EXCEPTION 'invalid client id' USING ERRCODE = '22023';
  END IF;
  UPDATE public.mcp_client_grants SET
    can_read_actions = p_can_read_actions,
    can_propose_actions = p_can_propose_actions,
    updated_at = now()
  WHERE user_id = v_user_id AND client_id = p_client_id AND revoked_at IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'active MCP grant not found' USING ERRCODE = '22023';
  END IF;
END;
$$;--> statement-breakpoint
REVOKE ALL ON FUNCTION public.daypage_set_mcp_action_grant_v1(text, boolean, boolean)
  FROM PUBLIC, anon;--> statement-breakpoint
GRANT EXECUTE ON FUNCTION public.daypage_set_mcp_action_grant_v1(text, boolean, boolean)
  TO authenticated;--> statement-breakpoint

CREATE OR REPLACE FUNCTION public.daypage_mcp_action_api_key_request_v1(
  p_key_hash text,
  p_operation text,
  p_arguments jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_key_id uuid;
  v_user_id uuid;
  v_scopes jsonb;
  v_can_read_actions boolean;
  v_can_propose_actions boolean;
  v_limit integer;
  v_state text;
  v_result jsonb;
  v_proposal jsonb;
  v_operation_id uuid;
BEGIN
  IF p_key_hash IS NULL OR p_key_hash !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'invalid API key' USING ERRCODE = '28000';
  END IF;
  IF jsonb_typeof(p_arguments) <> 'object' THEN
    RAISE EXCEPTION 'p_arguments must be an object' USING ERRCODE = '22023';
  END IF;
  SELECT api_key.id, api_key.user_id, api_key.scopes
  INTO v_key_id, v_user_id, v_scopes
  FROM public.api_keys api_key
  WHERE api_key.key_hash = p_key_hash
    AND api_key.revoked_at IS NULL
    AND (api_key.expires_at IS NULL OR api_key.expires_at > now())
  LIMIT 1;
  IF v_key_id IS NULL THEN
    RAISE EXCEPTION 'invalid or expired API key' USING ERRCODE = '28000';
  END IF;
  -- Action authority is an independent, post-upgrade grant. Historical PATs
  -- may contain the legacy umbrella `admin` scope for memo APIs, but that must
  -- never silently opt them into reading or proposing system actions.
  v_can_read_actions := COALESCE(v_scopes ? 'actions:read', false);
  v_can_propose_actions := COALESCE(v_scopes ? 'actions:propose', false);
  UPDATE public.api_keys SET last_used_at = now() WHERE id = v_key_id;

  IF p_operation = 'resolve_grant' THEN
    RETURN jsonb_build_object(
      'can_read_actions', v_can_read_actions,
      'can_propose_actions', v_can_propose_actions
    );
  END IF;

  IF p_operation = 'propose_action' THEN
    IF NOT v_can_propose_actions THEN
      RAISE EXCEPTION 'API key lacks actions:propose scope' USING ERRCODE = '42501';
    END IF;
    v_proposal := p_arguments -> 'proposal';
    v_operation_id := (p_arguments ->> 'operation_id')::uuid;
    IF jsonb_typeof(v_proposal) <> 'object'
      OR v_proposal ->> 'creator_source' IS DISTINCT FROM 'mcp'
      OR v_proposal ->> 'creator_device_id_hash' IS NOT NULL
      OR v_proposal ->> 'target_device_preference' IS DISTINCT FROM 'any'
      OR v_proposal ->> 'target_device_id_hash' IS NOT NULL
      OR v_proposal ->> 'redaction_level' IS DISTINCT FROM 'private'
      OR v_proposal ->> 'state' IS DISTINCT FROM 'pending'
      OR v_proposal ->> 'deleted_at' IS NOT NULL THEN
      RAISE EXCEPTION 'invalid MCP action proposal metadata' USING ERRCODE = '22023';
    END IF;
    RETURN public.daypage_apply_system_action_operations_for_user_v1(
      v_user_id,
      jsonb_build_array(jsonb_build_object(
        'protocol_version', 1,
        'operation_id', v_operation_id,
        'entity_type', 'proposal',
        'entity_id', v_proposal ->> 'proposal_id',
        'operation_kind', 'upsert',
        'revision', v_proposal ->> 'revision',
        'record', v_proposal
      ))
    );
  END IF;

  IF NOT v_can_read_actions THEN
    RAISE EXCEPTION 'API key lacks actions:read scope' USING ERRCODE = '42501';
  END IF;
  v_limit := LEAST(GREATEST(COALESCE((p_arguments ->> 'limit')::integer, 20), 1), 50);

  IF p_operation = 'list_action_proposals' THEN
    v_state := NULLIF(p_arguments ->> 'state', '');
    IF v_state IS NOT NULL AND v_state NOT IN (
      'pending', 'approved', 'rejected', 'executing', 'completed', 'failed',
      'cancelled', 'needs_review'
    ) THEN
      RAISE EXCEPTION 'invalid proposal state' USING ERRCODE = '22023';
    END IF;
    SELECT COALESCE(jsonb_agg(
      (to_jsonb(proposal_row) - ARRAY['created_at','expires_at','deleted_at'])
        || jsonb_build_object(
          'created_at', public.daypage_system_action_timestamp_text_v1(proposal_row.created_at),
          'expires_at', public.daypage_system_action_timestamp_text_v1(proposal_row.expires_at),
          'deleted_at', public.daypage_system_action_timestamp_text_v1(proposal_row.deleted_at)
        )
      ORDER BY proposal_row.created_at DESC
    ), '[]'::jsonb)
    INTO v_result
    FROM (
      SELECT proposal_id, schema_version, revision, kind, payload, payload_hash,
        title, rationale, source_refs, redaction_level, target_device_preference,
        state, created_at, expires_at, deleted_at
      FROM public.system_action_proposals
      WHERE user_id = v_user_id
        AND deleted_at IS NULL
        AND (v_state IS NULL OR state = v_state)
      ORDER BY created_at DESC LIMIT v_limit
    ) proposal_row;
    RETURN v_result;
  END IF;

  IF p_operation = 'list_action_receipts' THEN
    SELECT COALESCE(jsonb_agg(
      (to_jsonb(receipt_row) - ARRAY['started_at','completed_at'])
        || jsonb_build_object(
          'started_at', public.daypage_system_action_timestamp_text_v1(receipt_row.started_at),
          'completed_at', public.daypage_system_action_timestamp_text_v1(receipt_row.completed_at)
        )
      ORDER BY receipt_row.completed_at DESC
    ), '[]'::jsonb)
    INTO v_result
    FROM (
      SELECT receipt_id, proposal_id, schema_version, phase, proposal_revision,
        payload_hash, attempt, outcome, result, error_code, reconciliation_state,
        undo_capability, started_at, completed_at
      FROM public.system_action_receipts
      WHERE user_id = v_user_id
      ORDER BY completed_at DESC LIMIT v_limit
    ) receipt_row;
    RETURN v_result;
  END IF;

  RAISE EXCEPTION 'unsupported action API key operation' USING ERRCODE = '22023';
END;
$$;--> statement-breakpoint
REVOKE ALL ON FUNCTION public.daypage_mcp_action_api_key_request_v1(text, text, jsonb)
  FROM PUBLIC, authenticated, service_role;--> statement-breakpoint
GRANT EXECUTE ON FUNCTION public.daypage_mcp_action_api_key_request_v1(text, text, jsonb)
  TO anon;--> statement-breakpoint
