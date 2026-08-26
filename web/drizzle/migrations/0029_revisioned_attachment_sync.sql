-- #884: revisioned, receipt-gated attachment manifests and private media transfer.
--
-- The Vault remains authoritative. This migration is additive for protocol v1,
-- distinguishes legacy metadata rows from verified v2 manifests, and never removes
-- Storage objects synchronously.

CREATE SCHEMA IF NOT EXISTS extensions;--> statement-breakpoint
CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;--> statement-breakpoint

ALTER TABLE public.memos
  ADD COLUMN IF NOT EXISTS attachment_manifest_hash text;--> statement-breakpoint

ALTER TABLE public.sync_operations
  ADD COLUMN IF NOT EXISTS protocol_version integer NOT NULL DEFAULT 1;--> statement-breakpoint
ALTER TABLE public.sync_operations
  ADD COLUMN IF NOT EXISTS content_hash text;--> statement-breakpoint
ALTER TABLE public.sync_operations
  ADD COLUMN IF NOT EXISTS attachment_manifest_hash text;--> statement-breakpoint
ALTER TABLE public.sync_operations
  ADD COLUMN IF NOT EXISTS remote_revision bigint;--> statement-breakpoint

ALTER TABLE public.memo_attachments
  ADD COLUMN IF NOT EXISTS protocol_version integer;--> statement-breakpoint
ALTER TABLE public.memo_attachments
  ADD COLUMN IF NOT EXISTS position integer;--> statement-breakpoint
ALTER TABLE public.memo_attachments
  ADD COLUMN IF NOT EXISTS content_sha256 text;--> statement-breakpoint
ALTER TABLE public.memo_attachments
  ADD COLUMN IF NOT EXISTS duration_ms integer;--> statement-breakpoint
ALTER TABLE public.memo_attachments
  ADD COLUMN IF NOT EXISTS transcription_status text;--> statement-breakpoint
ALTER TABLE public.memo_attachments
  ADD COLUMN IF NOT EXISTS verified_at timestamptz;--> statement-breakpoint

CREATE UNIQUE INDEX IF NOT EXISTS memo_attachments_memo_position_v2
  ON public.memo_attachments (memo_id, position)
  WHERE content_sha256 IS NOT NULL;--> statement-breakpoint
CREATE UNIQUE INDEX IF NOT EXISTS memo_attachments_memo_storage_v2
  ON public.memo_attachments (memo_id, storage_key)
  WHERE content_sha256 IS NOT NULL;--> statement-breakpoint

CREATE TABLE IF NOT EXISTS public.attachment_upload_reservations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE cascade,
  memo_id uuid NOT NULL,
  object_key text NOT NULL,
  content_sha256 text NOT NULL,
  size_bytes bigint NOT NULL,
  mime_type text NOT NULL,
  status text NOT NULL DEFAULT 'prepared',
  expires_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  committed_at timestamptz,
  CONSTRAINT attachment_upload_reservations_user_object_unique
    UNIQUE (user_id, object_key),
  CONSTRAINT attachment_upload_reservations_hash_check
    CHECK (content_sha256 ~ '^[0-9a-f]{64}$'),
  CONSTRAINT attachment_upload_reservations_size_check
    CHECK (size_bytes BETWEEN 1 AND 52428800),
  CONSTRAINT attachment_upload_reservations_status_check
    CHECK (status IN ('prepared', 'committed', 'expired'))
);--> statement-breakpoint
CREATE INDEX IF NOT EXISTS attachment_upload_reservations_user_expiry
  ON public.attachment_upload_reservations (user_id, expires_at);--> statement-breakpoint
CREATE INDEX IF NOT EXISTS attachment_upload_reservations_user_created
  ON public.attachment_upload_reservations (user_id, created_at);--> statement-breakpoint

CREATE TABLE IF NOT EXISTS public.attachment_gc_queue (
  user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE cascade,
  object_key text NOT NULL,
  content_sha256 text NOT NULL,
  reason text NOT NULL,
  not_before timestamptz NOT NULL,
  attempts integer NOT NULL DEFAULT 0,
  status text NOT NULL DEFAULT 'pending',
  last_error text,
  claimed_at timestamptz,
  lease_token uuid,
  lease_expires_at timestamptz,
  deleted_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT attachment_gc_queue_pk PRIMARY KEY (user_id, object_key),
  CONSTRAINT attachment_gc_queue_hash_check
    CHECK (content_sha256 ~ '^[0-9a-f]{64}$'),
  CONSTRAINT attachment_gc_queue_reason_check
    CHECK (reason IN ('memo_deleted', 'manifest_removed', 'uncommitted_orphan')),
  CONSTRAINT attachment_gc_queue_status_check
    CHECK (status IN ('pending', 'processing', 'deleted'))
);--> statement-breakpoint
CREATE INDEX IF NOT EXISTS attachment_gc_queue_due
  ON public.attachment_gc_queue (not_before, lease_expires_at)
  WHERE status <> 'deleted';--> statement-breakpoint

ALTER TABLE public.attachment_upload_reservations ENABLE ROW LEVEL SECURITY;--> statement-breakpoint
ALTER TABLE public.attachment_gc_queue ENABLE ROW LEVEL SECURITY;--> statement-breakpoint

DROP POLICY IF EXISTS attachment_upload_reservations_select_own
  ON public.attachment_upload_reservations;--> statement-breakpoint
CREATE POLICY attachment_upload_reservations_select_own
  ON public.attachment_upload_reservations FOR SELECT TO authenticated
  USING (user_id = auth.uid());--> statement-breakpoint

REVOKE ALL ON public.attachment_upload_reservations FROM PUBLIC, anon, authenticated;--> statement-breakpoint
GRANT SELECT ON public.attachment_upload_reservations TO authenticated;--> statement-breakpoint
REVOKE ALL ON public.attachment_gc_queue FROM PUBLIC, anon, authenticated;--> statement-breakpoint

DROP POLICY IF EXISTS memo_attachments_insert_own ON public.memo_attachments;--> statement-breakpoint
DROP POLICY IF EXISTS memo_attachments_update_own ON public.memo_attachments;--> statement-breakpoint
DROP POLICY IF EXISTS memo_attachments_delete_own ON public.memo_attachments;--> statement-breakpoint
REVOKE INSERT, UPDATE, DELETE ON public.memo_attachments FROM authenticated;--> statement-breakpoint
GRANT SELECT ON public.memo_attachments TO authenticated;--> statement-breakpoint

-- Storage objects are immutable. An authenticated upload is permitted only after the
-- owner-derived preparation RPC reserved that exact key. Clients cannot delete objects;
-- the delayed GC worker uses the Storage API with a server-only credential.
DROP POLICY IF EXISTS memo_attachments_insert ON storage.objects;--> statement-breakpoint
CREATE POLICY memo_attachments_insert
ON storage.objects FOR INSERT TO authenticated
WITH CHECK (
  bucket_id = 'memo-attachments'
  AND (storage.foldername(name))[1] = auth.uid()::text
  AND EXISTS (
    SELECT 1
    FROM public.attachment_upload_reservations reservation
    WHERE reservation.user_id = auth.uid()
      AND reservation.object_key = name
      AND reservation.status = 'prepared'
      AND reservation.expires_at > statement_timestamp()
  )
);--> statement-breakpoint
DROP POLICY IF EXISTS memo_attachments_delete ON storage.objects;--> statement-breakpoint

CREATE OR REPLACE FUNCTION public.daypage_length_prefix(p_value text)
RETURNS text
LANGUAGE sql
IMMUTABLE
STRICT
SET search_path = pg_catalog
AS $$
  SELECT octet_length(p_value)::text || ':' || p_value
$$;--> statement-breakpoint

CREATE OR REPLACE FUNCTION public.daypage_attachment_extension(p_mime_type text)
RETURNS text
LANGUAGE sql
IMMUTABLE
STRICT
SET search_path = pg_catalog
AS $$
  SELECT CASE lower(p_mime_type)
    WHEN 'audio/m4a' THEN 'm4a'
    WHEN 'audio/mp4' THEN 'mp4'
    WHEN 'image/jpeg' THEN 'jpg'
    WHEN 'image/png' THEN 'png'
    WHEN 'image/heic' THEN 'heic'
    WHEN 'image/heif' THEN 'heif'
    WHEN 'application/pdf' THEN 'pdf'
    ELSE NULL
  END
$$;--> statement-breakpoint

CREATE OR REPLACE FUNCTION public.daypage_attachment_manifest_hash(p_attachments jsonb)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog
AS $$
DECLARE
  v_records text;
BEGIN
  IF jsonb_typeof(p_attachments) <> 'array' THEN
    RAISE EXCEPTION 'attachments must be an array' USING ERRCODE = '22023';
  END IF;

  SELECT string_agg(
    public.daypage_length_prefix(
      public.daypage_length_prefix(COALESCE(attachment ->> 'position', '')) ||
      public.daypage_length_prefix(COALESCE(attachment ->> 'kind', '')) ||
      public.daypage_length_prefix(COALESCE(attachment ->> 'content_sha256', '')) ||
      public.daypage_length_prefix(COALESCE(attachment ->> 'size_bytes', '')) ||
      public.daypage_length_prefix(COALESCE(attachment ->> 'mime_type', '')) ||
      public.daypage_length_prefix(COALESCE(attachment ->> 'object_key', '')) ||
      public.daypage_length_prefix(COALESCE(attachment ->> 'original_filename', '')) ||
      public.daypage_length_prefix(COALESCE(attachment ->> 'duration_ms', '')) ||
      public.daypage_length_prefix(COALESCE(attachment ->> 'transcript', '')) ||
      public.daypage_length_prefix(COALESCE(attachment ->> 'transcription_status', ''))
    ),
    '' ORDER BY (attachment ->> 'position')::integer
  )
  INTO v_records
  FROM jsonb_array_elements(p_attachments) AS item(attachment);

  RETURN encode(
    extensions.digest(
      convert_to(public.daypage_length_prefix('2') || COALESCE(v_records, ''), 'UTF8'),
      'sha256'
    ),
    'hex'
  );
END;
$$;--> statement-breakpoint

REVOKE ALL ON FUNCTION public.daypage_length_prefix(text) FROM PUBLIC;--> statement-breakpoint
REVOKE ALL ON FUNCTION public.daypage_attachment_extension(text) FROM PUBLIC;--> statement-breakpoint
REVOKE ALL ON FUNCTION public.daypage_attachment_manifest_hash(jsonb) FROM PUBLIC;--> statement-breakpoint

CREATE OR REPLACE FUNCTION public.daypage_prepare_attachment_upload(
  p_memo_id uuid,
  p_content_sha256 text,
  p_size_bytes bigint,
  p_mime_type text,
  p_extension text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_expected_extension text;
  v_object_key text;
  v_reservation public.attachment_upload_reservations%ROWTYPE;
  v_existing public.attachment_upload_reservations%ROWTYPE;
  v_committed_bytes bigint := 0;
  v_reserved_bytes bigint := 0;
  v_memo_bytes bigint := 0;
  v_memo_objects integer := 0;
  v_live_reservations integer := 0;
  v_recent_reservations integer := 0;
  v_object_size bigint;
  v_already_exists boolean := false;
  v_is_new_reservation boolean := false;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'authentication required' USING ERRCODE = '42501';
  END IF;
  IF p_content_sha256 !~ '^[0-9a-f]{64}$'
    OR p_size_bytes NOT BETWEEN 1 AND 52428800 THEN
    RAISE EXCEPTION 'invalid attachment hash or size' USING ERRCODE = '22023';
  END IF;

  v_expected_extension := public.daypage_attachment_extension(p_mime_type);
  IF v_expected_extension IS NULL OR lower(p_extension) <> v_expected_extension THEN
    RAISE EXCEPTION 'unsupported MIME and extension pair' USING ERRCODE = '22023';
  END IF;

  v_object_key := v_user_id::text || '/' || p_memo_id::text || '/' ||
    p_content_sha256 || '.' || v_expected_extension;

  PERFORM pg_advisory_xact_lock(hashtextextended(v_user_id::text, 884));

  SELECT * INTO v_existing
  FROM public.attachment_upload_reservations
  WHERE user_id = v_user_id AND object_key = v_object_key;
  v_is_new_reservation := NOT FOUND;
  IF NOT v_is_new_reservation AND ROW(
    v_existing.memo_id,
    v_existing.content_sha256,
    v_existing.size_bytes,
    v_existing.mime_type
  ) IS DISTINCT FROM ROW(
    p_memo_id,
    p_content_sha256,
    p_size_bytes,
    lower(p_mime_type)
  ) THEN
    RAISE EXCEPTION 'object reservation tuple mismatch' USING ERRCODE = '23505';
  END IF;

  -- Bound both live reservation cardinality and short bursts. The account
  -- byte quota alone is insufficient for many tiny files, while retries for
  -- the same immutable key remain idempotent and do not consume a new slot.
  IF v_is_new_reservation THEN
    SELECT COUNT(*)::integer INTO v_live_reservations
    FROM public.attachment_upload_reservations reservation
    WHERE reservation.user_id = v_user_id
      AND reservation.status = 'prepared'
      AND reservation.expires_at > statement_timestamp();
    IF v_live_reservations >= 100 THEN
      RAISE EXCEPTION 'live attachment reservation limit exceeded' USING ERRCODE = '54000';
    END IF;

    SELECT COUNT(*)::integer INTO v_recent_reservations
    FROM public.attachment_upload_reservations reservation
    WHERE reservation.user_id = v_user_id
      AND reservation.created_at >= statement_timestamp() - interval '1 minute';
    IF v_recent_reservations >= 60 THEN
      RAISE EXCEPTION 'attachment reservation rate limit exceeded' USING ERRCODE = '54000';
    END IF;
  END IF;

  -- Serialize restore/re-upload against the worker's short deletion lease.
  -- A processing object finishes deletion first; the client then prepares
  -- the same immutable key again and uploads fresh bytes.
  PERFORM 1
  FROM public.attachment_gc_queue queue
  WHERE queue.user_id = v_user_id AND queue.object_key = v_object_key
  FOR UPDATE;
  IF EXISTS (
    SELECT 1 FROM public.attachment_gc_queue queue
    WHERE queue.user_id = v_user_id
      AND queue.object_key = v_object_key
      AND queue.status = 'processing'
      AND queue.lease_expires_at > statement_timestamp()
  ) THEN
    RAISE EXCEPTION 'attachment is being garbage-collected' USING ERRCODE = '55000';
  END IF;
  DELETE FROM public.attachment_gc_queue queue
  WHERE queue.user_id = v_user_id AND queue.object_key = v_object_key;

  SELECT (object.metadata ->> 'size')::bigint
  INTO v_object_size
  FROM storage.objects object
  WHERE object.bucket_id = 'memo-attachments'
    AND object.name = v_object_key
    AND object.owner_id = v_user_id::text;
  IF FOUND THEN
    IF v_object_size IS DISTINCT FROM p_size_bytes THEN
      RAISE EXCEPTION 'existing object size mismatch' USING ERRCODE = '22023';
    END IF;
    v_already_exists := true;
  END IF;

  SELECT COUNT(*)::integer INTO v_memo_objects
  FROM (
    SELECT attachment.storage_key
    FROM public.memo_attachments attachment
    JOIN public.memos memo ON memo.id = attachment.memo_id
    WHERE memo.user_id = v_user_id
      AND memo.deleted_at IS NULL
      AND attachment.memo_id = p_memo_id
      AND attachment.content_sha256 IS NOT NULL
    UNION
    SELECT reservation.object_key
    FROM public.attachment_upload_reservations reservation
    WHERE reservation.user_id = v_user_id
      AND reservation.memo_id = p_memo_id
      AND reservation.status = 'prepared'
      AND reservation.expires_at > statement_timestamp()
      AND reservation.object_key <> v_object_key
  ) objects;
  IF v_memo_objects >= 20 AND NOT EXISTS (
    SELECT 1 FROM public.memo_attachments
    WHERE memo_id = p_memo_id AND storage_key = v_object_key
      AND content_sha256 IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'attachment count quota exceeded' USING ERRCODE = '54000';
  END IF;

  SELECT COALESCE(SUM(object.size_bytes), 0)::bigint INTO v_memo_bytes
  FROM (
    SELECT attachment.storage_key, attachment.size_bytes::bigint
    FROM public.memo_attachments attachment
    JOIN public.memos memo ON memo.id = attachment.memo_id
    WHERE memo.user_id = v_user_id
      AND memo.deleted_at IS NULL
      AND attachment.memo_id = p_memo_id
      AND attachment.content_sha256 IS NOT NULL
      AND attachment.storage_key <> v_object_key
    UNION ALL
    SELECT reservation.object_key, reservation.size_bytes
    FROM public.attachment_upload_reservations reservation
    WHERE reservation.user_id = v_user_id
      AND reservation.memo_id = p_memo_id
      AND reservation.status = 'prepared'
      AND reservation.expires_at > statement_timestamp()
      AND reservation.object_key <> v_object_key
      AND NOT EXISTS (
        SELECT 1
        FROM public.memo_attachments attachment
        WHERE attachment.memo_id = p_memo_id
          AND attachment.storage_key = reservation.object_key
          AND attachment.content_sha256 IS NOT NULL
      )
  ) object;
  IF v_memo_bytes + p_size_bytes > 262144000 THEN
    RAISE EXCEPTION 'memo attachment byte quota exceeded' USING ERRCODE = '54000';
  END IF;

  SELECT COALESCE(SUM(attachment.size_bytes), 0)::bigint INTO v_committed_bytes
  FROM public.memo_attachments attachment
  JOIN public.memos memo ON memo.id = attachment.memo_id
  WHERE memo.user_id = v_user_id
    AND memo.deleted_at IS NULL
    AND attachment.content_sha256 IS NOT NULL;

  SELECT COALESCE(SUM(reservation.size_bytes), 0)::bigint INTO v_reserved_bytes
  FROM public.attachment_upload_reservations reservation
  WHERE reservation.user_id = v_user_id
    AND reservation.status = 'prepared'
    AND reservation.expires_at > statement_timestamp()
    AND reservation.object_key <> v_object_key
    AND NOT EXISTS (
      SELECT 1
      FROM public.memo_attachments attachment
      JOIN public.memos memo ON memo.id = attachment.memo_id
      WHERE memo.user_id = v_user_id
        AND memo.deleted_at IS NULL
        AND attachment.content_sha256 IS NOT NULL
        AND attachment.storage_key = reservation.object_key
    );

  IF v_committed_bytes + v_reserved_bytes +
    (CASE WHEN v_already_exists THEN 0 ELSE p_size_bytes END) > 2147483648 THEN
    RAISE EXCEPTION 'account attachment quota exceeded' USING ERRCODE = '54000';
  END IF;

  INSERT INTO public.attachment_upload_reservations (
    user_id, memo_id, object_key, content_sha256, size_bytes, mime_type,
    status, expires_at, committed_at
  ) VALUES (
    v_user_id, p_memo_id, v_object_key, p_content_sha256, p_size_bytes,
    lower(p_mime_type), CASE WHEN v_already_exists THEN 'committed' ELSE 'prepared' END,
    statement_timestamp() + interval '26 hours',
    CASE WHEN v_already_exists THEN statement_timestamp() ELSE NULL END
  )
  ON CONFLICT ON CONSTRAINT attachment_upload_reservations_user_object_unique
  DO UPDATE SET
    expires_at = EXCLUDED.expires_at,
    status = CASE
      WHEN v_already_exists THEN 'committed' ELSE 'prepared'
    END,
    committed_at = CASE
      WHEN v_already_exists THEN statement_timestamp() ELSE NULL
    END
  RETURNING * INTO v_reservation;

  RETURN jsonb_build_object(
    'reservation_id', v_reservation.id,
    'object_key', v_reservation.object_key,
    'expires_at', v_reservation.expires_at,
    'already_exists', v_already_exists
  );
END;
$$;--> statement-breakpoint

REVOKE ALL ON FUNCTION public.daypage_prepare_attachment_upload(uuid, text, bigint, text, text)
  FROM PUBLIC;--> statement-breakpoint
GRANT EXECUTE ON FUNCTION public.daypage_prepare_attachment_upload(uuid, text, bigint, text, text)
  TO authenticated;--> statement-breakpoint

-- Any tombstone path, including protocol v1, queues verified media for delayed cleanup.
-- Physical memo deletes are also recoverably queued before cascade removes descriptors.
CREATE OR REPLACE FUNCTION public.daypage_queue_memo_attachment_gc()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_memo_id uuid;
  v_user_id uuid;
  v_reason text;
BEGIN
  IF TG_OP = 'DELETE' THEN
    v_memo_id := OLD.id;
    v_user_id := OLD.user_id;
    v_reason := 'memo_deleted';
  ELSIF OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL THEN
    v_memo_id := NEW.id;
    v_user_id := NEW.user_id;
    v_reason := 'memo_deleted';
  ELSE
    RETURN NEW;
  END IF;

  INSERT INTO public.attachment_gc_queue (
    user_id, object_key, content_sha256, reason, not_before
  )
  SELECT v_user_id, attachment.storage_key, attachment.content_sha256,
    v_reason, statement_timestamp() + interval '30 days'
  FROM public.memo_attachments attachment
  WHERE attachment.memo_id = v_memo_id
    AND attachment.content_sha256 IS NOT NULL
  ON CONFLICT (user_id, object_key) DO UPDATE SET
    reason = EXCLUDED.reason,
    not_before = GREATEST(attachment_gc_queue.not_before, EXCLUDED.not_before),
    claimed_at = NULL,
    status = 'pending',
    lease_token = NULL,
    lease_expires_at = NULL,
    deleted_at = NULL,
    last_error = NULL;

  IF TG_OP = 'UPDATE' THEN
    DELETE FROM public.memo_attachments WHERE memo_id = v_memo_id;
    RETURN NEW;
  END IF;
  RETURN OLD;
END;
$$;--> statement-breakpoint

DROP TRIGGER IF EXISTS daypage_memo_attachment_gc_on_tombstone ON public.memos;--> statement-breakpoint
CREATE TRIGGER daypage_memo_attachment_gc_on_tombstone
AFTER UPDATE OF deleted_at ON public.memos
FOR EACH ROW EXECUTE FUNCTION public.daypage_queue_memo_attachment_gc();--> statement-breakpoint
DROP TRIGGER IF EXISTS daypage_memo_attachment_gc_on_delete ON public.memos;--> statement-breakpoint
CREATE TRIGGER daypage_memo_attachment_gc_on_delete
BEFORE DELETE ON public.memos
FOR EACH ROW EXECUTE FUNCTION public.daypage_queue_memo_attachment_gc();--> statement-breakpoint

CREATE OR REPLACE FUNCTION public.daypage_bump_memo_change_sequence()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF NEW.deleted_at IS NOT NULL THEN
    NEW.attachment_manifest_hash := NULL;
  END IF;
  IF TG_OP = 'INSERT' THEN
    IF NEW.sync_change_sequence IS NULL THEN
      NEW.sync_change_sequence := nextval('public.daypage_memo_change_sequence');
    END IF;
  ELSIF ROW(
    NEW.type, NEW.body, NEW.created_at, NEW.pinned_at, NEW.location, NEW.weather,
    NEW.device, NEW.source, NEW.vault_path, NEW.mood, NEW.source_modified_at,
    NEW.content_hash, NEW.attachment_manifest_hash, NEW.sync_revision,
    NEW.last_sync_device_id, NEW.deleted_at
  ) IS DISTINCT FROM ROW(
    OLD.type, OLD.body, OLD.created_at, OLD.pinned_at, OLD.location, OLD.weather,
    OLD.device, OLD.source, OLD.vault_path, OLD.mood, OLD.source_modified_at,
    OLD.content_hash, OLD.attachment_manifest_hash, OLD.sync_revision,
    OLD.last_sync_device_id, OLD.deleted_at
  ) THEN
    NEW.sync_change_sequence := nextval('public.daypage_memo_change_sequence');
  END IF;
  RETURN NEW;
END;
$$;--> statement-breakpoint

CREATE OR REPLACE FUNCTION public.daypage_apply_sync_operations_v2(p_operations jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
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
  v_attachments jsonb;
  v_content_hash text;
  v_manifest_hash text;
  v_device_id text;
  v_remote_revision bigint;
  v_current_revision bigint;
  v_status text;
  v_stored public.sync_operations%ROWTYPE;
  v_total_bytes bigint;
  v_other_committed_bytes bigint;
  v_accepted jsonb := '[]'::jsonb;
  v_rejected jsonb := '[]'::jsonb;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'authentication required' USING ERRCODE = '42501';
  END IF;
  IF jsonb_typeof(p_operations) <> 'array' THEN
    RAISE EXCEPTION 'p_operations must be an array' USING ERRCODE = '22023';
  END IF;
  IF jsonb_array_length(p_operations) NOT BETWEEN 1 AND 100 THEN
    RAISE EXCEPTION 'between 1 and 100 operations are required' USING ERRCODE = '22023';
  END IF;

  FOR v_operation IN SELECT value FROM jsonb_array_elements(p_operations)
  LOOP
    BEGIN
      v_operation_id := (v_operation ->> 'operation_id')::uuid;
      v_memo_id := (v_operation ->> 'memo_id')::uuid;
      v_kind := v_operation ->> 'kind';
      v_revision := (v_operation ->> 'revision')::bigint;
      v_modified_at := (v_operation ->> 'modified_at')::timestamptz;
      v_payload := v_operation -> 'payload';
      v_content_hash := v_operation ->> 'content_hash';
      v_manifest_hash := v_operation ->> 'attachment_manifest_hash';
      v_device_id := v_operation ->> 'device_id';
      v_remote_revision := NULL;
      v_current_revision := NULL;
      v_status := NULL;
      v_stored := NULL;

      IF (v_operation ->> 'protocol_version')::integer <> 2
        OR v_kind NOT IN ('upsert', 'delete')
        OR v_revision < 1 THEN
        RAISE EXCEPTION 'invalid v2 operation';
      END IF;

      SELECT * INTO v_stored
      FROM public.sync_operations receipt
      WHERE receipt.user_id = v_user_id
        AND receipt.operation_id = v_operation_id;
      IF FOUND THEN
        IF v_stored.memo_id <> v_memo_id
          OR v_stored.kind <> v_kind
          OR v_stored.revision <> v_revision
          OR v_stored.protocol_version <> 2
          OR v_stored.content_hash IS DISTINCT FROM v_content_hash
          OR v_stored.attachment_manifest_hash IS DISTINCT FROM v_manifest_hash THEN
          RAISE EXCEPTION 'operation id reuse mismatch';
        END IF;
        v_status := v_stored.status;
        v_remote_revision := v_stored.remote_revision;
      ELSE
        IF v_kind = 'upsert' THEN
          IF v_content_hash !~ '^[0-9a-f]{64}$'
            OR v_manifest_hash !~ '^[0-9a-f]{64}$'
            OR jsonb_typeof(v_payload) <> 'object'
            OR NULLIF(v_payload ->> 'body', '') IS NULL THEN
            RAISE EXCEPTION 'invalid upsert hashes or payload';
          END IF;
          v_attachments := COALESCE(v_payload -> 'attachments', '[]'::jsonb);
          IF jsonb_typeof(v_attachments) <> 'array'
            OR jsonb_array_length(v_attachments) > 20
            OR public.daypage_attachment_manifest_hash(v_attachments) <> v_manifest_hash THEN
            RAISE EXCEPTION 'invalid attachment manifest';
          END IF;

          IF EXISTS (
            SELECT 1
            FROM jsonb_array_elements(v_attachments) WITH ORDINALITY item(attachment, ordinal)
            WHERE (attachment ->> 'position')::integer <> ordinal - 1
              OR attachment ->> 'kind' NOT IN ('audio', 'photo', 'file')
              OR attachment ->> 'content_sha256' !~ '^[0-9a-f]{64}$'
              OR (attachment ->> 'size_bytes')::bigint NOT BETWEEN 1 AND 52428800
              OR public.daypage_attachment_extension(attachment ->> 'mime_type') IS NULL
              OR attachment ->> 'object_key' <>
                v_user_id::text || '/' || v_memo_id::text || '/' ||
                (attachment ->> 'content_sha256') || '.' ||
                public.daypage_attachment_extension(attachment ->> 'mime_type')
              OR NULLIF(attachment ->> 'original_filename', '') IS NULL
              OR octet_length(attachment ->> 'original_filename') > 255
              OR position('/' IN attachment ->> 'original_filename') > 0
              OR position(chr(92) IN attachment ->> 'original_filename') > 0
              OR attachment ->> 'original_filename' ~ '[[:cntrl:]]'
              OR ((attachment ->> 'duration_ms') IS NOT NULL
                AND (attachment ->> 'duration_ms')::bigint < 0)
              OR octet_length(COALESCE(attachment ->> 'transcript', '')) > 200000
              OR COALESCE(attachment ->> 'transcription_status', '')
                NOT IN ('', 'pending', 'done', 'failed')
          ) THEN
            RAISE EXCEPTION 'invalid attachment descriptor';
          END IF;

          SELECT COALESCE(SUM((attachment ->> 'size_bytes')::bigint), 0)
          INTO v_total_bytes
          FROM jsonb_array_elements(v_attachments) item(attachment);
          IF v_total_bytes > 262144000 THEN
            RAISE EXCEPTION 'memo attachment quota exceeded';
          END IF;
        ELSE
          v_attachments := '[]'::jsonb;
          IF v_payload IS NOT NULL OR v_content_hash IS NOT NULL OR v_manifest_hash IS NOT NULL THEN
            RAISE EXCEPTION 'delete cannot contain payload or hashes';
          END IF;
        END IF;

        SELECT memo.sync_revision INTO v_current_revision
        FROM public.memos memo
        WHERE memo.id = v_memo_id AND memo.user_id = v_user_id;
        IF FOUND AND v_current_revision >= v_revision THEN
          v_status := 'stale';
          v_remote_revision := v_current_revision;
        ELSIF v_kind = 'upsert' THEN
          IF EXISTS (
            SELECT 1
            FROM jsonb_array_elements(v_attachments) item(attachment)
            WHERE NOT EXISTS (
              SELECT 1
              FROM storage.objects object
              WHERE object.bucket_id = 'memo-attachments'
                AND object.name = attachment ->> 'object_key'
                AND object.owner_id = v_user_id::text
                AND (object.metadata ->> 'size')::bigint =
                  (attachment ->> 'size_bytes')::bigint
                AND lower(COALESCE(
                  object.metadata ->> 'mimetype',
                  object.metadata ->> 'content-type',
                  ''
                )) = lower(attachment ->> 'mime_type')
            )
          ) THEN
            RAISE EXCEPTION 'missing or mismatched Storage object';
          END IF;

          IF EXISTS (
            SELECT 1
            FROM jsonb_array_elements(v_attachments) item(attachment)
            WHERE NOT EXISTS (
              SELECT 1
              FROM public.attachment_upload_reservations reservation
              WHERE reservation.user_id = v_user_id
                AND reservation.memo_id = v_memo_id
                AND reservation.object_key = attachment ->> 'object_key'
                AND reservation.content_sha256 = attachment ->> 'content_sha256'
                AND reservation.size_bytes = (attachment ->> 'size_bytes')::bigint
                AND reservation.mime_type = lower(attachment ->> 'mime_type')
                AND reservation.status IN ('prepared', 'committed')
                AND (reservation.status = 'committed'
                  OR reservation.expires_at > statement_timestamp())
            )
            AND NOT EXISTS (
              SELECT 1
              FROM public.memo_attachments prior
              JOIN public.memos memo ON memo.id = prior.memo_id
              WHERE memo.user_id = v_user_id
                AND prior.memo_id = v_memo_id
                AND prior.storage_key = attachment ->> 'object_key'
                AND prior.content_sha256 = attachment ->> 'content_sha256'
            )
          ) THEN
            RAISE EXCEPTION 'missing upload reservation';
          END IF;


          -- Row locks close the restore-vs-worker race across Postgres and
          -- the Storage API. A leased object cannot be re-committed until
          -- the worker finishes or its lease expires.
          PERFORM 1
          FROM public.attachment_gc_queue queue
          WHERE queue.user_id = v_user_id
            AND EXISTS (
              SELECT 1 FROM jsonb_array_elements(v_attachments) item(attachment)
              WHERE attachment ->> 'object_key' = queue.object_key
            )
          FOR UPDATE;
          IF EXISTS (
            SELECT 1
            FROM public.attachment_gc_queue queue
            WHERE queue.user_id = v_user_id
              AND queue.status = 'processing'
              AND queue.lease_expires_at > statement_timestamp()
              AND EXISTS (
                SELECT 1 FROM jsonb_array_elements(v_attachments) item(attachment)
                WHERE attachment ->> 'object_key' = queue.object_key
              )
          ) THEN
            RAISE EXCEPTION 'attachment is being garbage-collected';
          END IF;

          PERFORM pg_advisory_xact_lock(hashtextextended(v_user_id::text, 884));
          SELECT COALESCE(SUM(attachment.size_bytes), 0)::bigint
          INTO v_other_committed_bytes
          FROM public.memo_attachments attachment
          JOIN public.memos memo ON memo.id = attachment.memo_id
          WHERE memo.user_id = v_user_id
            AND memo.deleted_at IS NULL
            AND attachment.content_sha256 IS NOT NULL
            AND attachment.memo_id <> v_memo_id;
          IF v_other_committed_bytes + v_total_bytes > 2147483648 THEN
            RAISE EXCEPTION 'account attachment quota exceeded';
          END IF;

          INSERT INTO public.memos (
            id, user_id, type, body, created_at, pinned_at, location, weather,
            device, origin, source, vault_path, updated_at, source_modified_at,
            content_hash, attachment_manifest_hash, sync_revision,
            last_sync_device_id, deleted_at
          ) VALUES (
            v_memo_id,
            v_user_id,
            CASE WHEN v_payload ->> 'type' IN ('text','url','voice','photo','file')
              THEN (v_payload ->> 'type')::public.memo_type
              ELSE 'text'::public.memo_type END,
            v_payload ->> 'body',
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
            v_content_hash,
            v_manifest_hash,
            v_revision,
            NULLIF(v_device_id, ''),
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
            attachment_manifest_hash = EXCLUDED.attachment_manifest_hash,
            sync_revision = EXCLUDED.sync_revision,
            last_sync_device_id = EXCLUDED.last_sync_device_id,
            deleted_at = NULL
          WHERE memos.user_id = v_user_id
            AND memos.sync_revision < EXCLUDED.sync_revision
          RETURNING sync_revision INTO v_remote_revision;
          IF v_remote_revision IS NULL THEN
            RAISE EXCEPTION 'memo id conflicts with another tenant';
          END IF;

          INSERT INTO public.attachment_gc_queue (
            user_id, object_key, content_sha256, reason, not_before
          )
          SELECT v_user_id, prior.storage_key, prior.content_sha256,
            'manifest_removed', statement_timestamp() + interval '30 days'
          FROM public.memo_attachments prior
          WHERE prior.memo_id = v_memo_id
            AND prior.content_sha256 IS NOT NULL
            AND NOT EXISTS (
              SELECT 1 FROM jsonb_array_elements(v_attachments) item(attachment)
              WHERE attachment ->> 'object_key' = prior.storage_key
            )
          ON CONFLICT (user_id, object_key) DO UPDATE SET
            reason = EXCLUDED.reason,
            not_before = GREATEST(attachment_gc_queue.not_before, EXCLUDED.not_before),
            claimed_at = NULL,
            status = 'pending',
            lease_token = NULL,
            lease_expires_at = NULL,
            deleted_at = NULL,
            last_error = NULL;

          DELETE FROM public.memo_attachments WHERE memo_id = v_memo_id;
          INSERT INTO public.memo_attachments (
            memo_id, kind, storage_key, filename, mime_type, size_bytes,
            duration_sec, transcript, protocol_version, position, content_sha256,
            duration_ms, transcription_status, verified_at
          )
          SELECT
            v_memo_id,
            (attachment ->> 'kind')::public.attachment_kind,
            attachment ->> 'object_key',
            attachment ->> 'original_filename',
            attachment ->> 'mime_type',
            (attachment ->> 'size_bytes')::integer,
            CASE WHEN attachment ->> 'duration_ms' IS NULL THEN NULL
              ELSE (attachment ->> 'duration_ms')::real / 1000 END,
            attachment ->> 'transcript',
            2,
            (attachment ->> 'position')::integer,
            attachment ->> 'content_sha256',
            (attachment ->> 'duration_ms')::integer,
            attachment ->> 'transcription_status',
            statement_timestamp()
          FROM jsonb_array_elements(v_attachments) item(attachment);

          UPDATE public.attachment_upload_reservations reservation
          SET status = 'committed', committed_at = statement_timestamp()
          WHERE reservation.user_id = v_user_id
            AND EXISTS (
              SELECT 1 FROM jsonb_array_elements(v_attachments) item(attachment)
              WHERE attachment ->> 'object_key' = reservation.object_key
            );
          DELETE FROM public.attachment_gc_queue queue
          WHERE queue.user_id = v_user_id
            AND EXISTS (
              SELECT 1 FROM jsonb_array_elements(v_attachments) item(attachment)
              WHERE attachment ->> 'object_key' = queue.object_key
            );
          v_status := 'applied';
        ELSE
          INSERT INTO public.memos (
            id, user_id, type, body, created_at, origin, source, updated_at,
            source_modified_at, attachment_manifest_hash, sync_revision,
            last_sync_device_id, deleted_at
          ) VALUES (
            v_memo_id, v_user_id, 'text'::public.memo_type, '', v_modified_at,
            'ios'::public.origin, 'ios', v_modified_at, v_modified_at, NULL,
            v_revision, NULLIF(v_device_id, ''), v_modified_at
          )
          ON CONFLICT (id) DO UPDATE SET
            updated_at = EXCLUDED.updated_at,
            source_modified_at = EXCLUDED.source_modified_at,
            attachment_manifest_hash = NULL,
            sync_revision = EXCLUDED.sync_revision,
            last_sync_device_id = EXCLUDED.last_sync_device_id,
            deleted_at = EXCLUDED.deleted_at
          WHERE memos.user_id = v_user_id
            AND memos.sync_revision < EXCLUDED.sync_revision
          RETURNING sync_revision INTO v_remote_revision;
          IF v_remote_revision IS NULL THEN
            RAISE EXCEPTION 'memo id conflicts with another tenant';
          END IF;
          v_status := 'applied';
        END IF;

        INSERT INTO public.sync_operations (
          user_id, operation_id, memo_id, kind, revision, status,
          protocol_version, content_hash, attachment_manifest_hash, remote_revision
        ) VALUES (
          v_user_id, v_operation_id, v_memo_id, v_kind, v_revision, v_status,
          2, v_content_hash, v_manifest_hash, v_remote_revision
        );
      END IF;

      v_accepted := v_accepted || jsonb_build_array(jsonb_build_object(
        'operation_id', v_operation_id,
        'memo_id', v_memo_id,
        'revision', v_revision,
        'remote_revision', COALESCE(v_remote_revision, 0),
        'status', v_status,
        'attachment_manifest_hash', v_manifest_hash
      ));
    EXCEPTION WHEN OTHERS THEN
      v_rejected := v_rejected || jsonb_build_array(jsonb_build_object(
        'operation_id', v_operation ->> 'operation_id',
        'memo_id', v_operation ->> 'memo_id',
        'reason', 'invalid_or_conflicting_attachment_operation'
      ));
    END;
  END LOOP;

  RETURN jsonb_build_object('accepted', v_accepted, 'rejected', v_rejected);
END;
$$;--> statement-breakpoint

REVOKE ALL ON FUNCTION public.daypage_apply_sync_operations_v2(jsonb) FROM PUBLIC;--> statement-breakpoint
GRANT EXECUTE ON FUNCTION public.daypage_apply_sync_operations_v2(jsonb) TO authenticated;--> statement-breakpoint

CREATE OR REPLACE FUNCTION public.daypage_pull_sync_changes_v2(
  p_after_sequence bigint DEFAULT 0,
  p_limit integer DEFAULT 200
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = pg_catalog
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_after bigint := GREATEST(COALESCE(p_after_sequence, 0), 0);
  v_limit integer := LEAST(GREATEST(COALESCE(p_limit, 200), 1), 500);
  v_changes jsonb;
  v_next_cursor bigint;
  v_has_more boolean;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'authentication required' USING ERRCODE = '42501';
  END IF;

  SELECT
    COALESCE(jsonb_agg(change.payload ORDER BY change.change_sequence), '[]'::jsonb),
    COALESCE(max(change.change_sequence), v_after)
  INTO v_changes, v_next_cursor
  FROM (
    SELECT memo.sync_change_sequence AS change_sequence,
      jsonb_build_object(
        'id', memo.id,
        'type', memo.type::text,
        'body', memo.body,
        'created_at', memo.created_at,
        'pinned_at', memo.pinned_at,
        'location', memo.location,
        'weather', memo.weather,
        'device', memo.device,
        'source', memo.source,
        'vault_path', memo.vault_path,
        'source_modified_at', memo.source_modified_at,
        'content_hash', memo.content_hash,
        'sync_revision', memo.sync_revision,
        'last_sync_device_id', memo.last_sync_device_id,
        'deleted_at', memo.deleted_at,
        'change_sequence', memo.sync_change_sequence,
        'attachment_manifest_hash', CASE
          WHEN memo.deleted_at IS NULL THEN memo.attachment_manifest_hash
          ELSE NULL END,
        'attachments', CASE
          WHEN memo.deleted_at IS NOT NULL OR memo.attachment_manifest_hash IS NULL
            THEN '[]'::jsonb
          ELSE COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
              'position', attachment.position,
              'kind', attachment.kind::text,
              'content_sha256', attachment.content_sha256,
              'size_bytes', attachment.size_bytes,
              'mime_type', attachment.mime_type,
              'object_key', attachment.storage_key,
              'original_filename', attachment.filename,
              'duration_ms', attachment.duration_ms,
              'transcript', attachment.transcript,
              'transcription_status', attachment.transcription_status
            ) ORDER BY attachment.position)
            FROM public.memo_attachments attachment
            WHERE attachment.memo_id = memo.id
              AND attachment.protocol_version = 2
              AND attachment.content_sha256 IS NOT NULL
          ), '[]'::jsonb)
        END
      ) AS payload
    FROM public.memos memo
    WHERE memo.user_id = v_user_id
      AND memo.sync_change_sequence > v_after
    ORDER BY memo.sync_change_sequence ASC
    LIMIT v_limit
  ) change;

  SELECT EXISTS (
    SELECT 1 FROM public.memos memo
    WHERE memo.user_id = v_user_id
      AND memo.sync_change_sequence > v_next_cursor
  ) INTO v_has_more;

  RETURN jsonb_build_object(
    'changes', v_changes,
    'next_cursor', v_next_cursor,
    'has_more', v_has_more
  );
END;
$$;--> statement-breakpoint

REVOKE ALL ON FUNCTION public.daypage_pull_sync_changes_v2(bigint, integer) FROM PUBLIC;--> statement-breakpoint
GRANT EXECUTE ON FUNCTION public.daypage_pull_sync_changes_v2(bigint, integer) TO authenticated;--> statement-breakpoint

-- Server-only orphan inventory. It may inspect Storage metadata but never
-- mutates storage.objects; actual deletion is performed by the Edge worker
-- through the supported Storage API.
CREATE OR REPLACE FUNCTION public.daypage_inventory_attachment_orphans()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_queued integer := 0;
BEGIN
  IF auth.role() <> 'service_role' THEN
    RAISE EXCEPTION 'service role required' USING ERRCODE = '42501';
  END IF;

  UPDATE public.attachment_upload_reservations reservation
  SET status = 'expired'
  WHERE reservation.status = 'prepared'
    AND reservation.expires_at <= statement_timestamp();

  -- Storage creates its row before RLS can observe final bytes (and TUS does
  -- so before the first chunk), so actual size/MIME are verified here and at
  -- manifest commit. Mismatches get a short forensic window, then lose their
  -- live reservation and become immediately collectable.
  UPDATE public.attachment_upload_reservations reservation
  SET status = 'expired'
  WHERE reservation.status = 'prepared'
    AND EXISTS (
      SELECT 1
      FROM storage.objects object
      WHERE object.bucket_id = 'memo-attachments'
        AND object.name = reservation.object_key
        AND object.owner_id = reservation.user_id::text
        AND object.created_at < statement_timestamp() - interval '10 minutes'
        AND (
          (object.metadata ->> 'size')::bigint IS DISTINCT FROM reservation.size_bytes
          OR lower(COALESCE(
            object.metadata ->> 'mimetype',
            object.metadata ->> 'content-type',
            ''
          )) IS DISTINCT FROM reservation.mime_type
        )
    );

  WITH inserted AS (
    INSERT INTO public.attachment_gc_queue (
      user_id, object_key, content_sha256, reason, not_before, status
    )
    SELECT
      users.id,
      object.name,
      substring(split_part(object.name, '/', 3) FROM '^[0-9a-f]{64}'),
      'uncommitted_orphan',
      statement_timestamp(),
      'pending'
    FROM storage.objects object
    JOIN public.users users
      ON users.id::text = split_part(object.name, '/', 1)
    WHERE object.bucket_id = 'memo-attachments'
      AND (
        object.created_at < statement_timestamp() - interval '26 hours'
        OR EXISTS (
          SELECT 1
          FROM public.attachment_upload_reservations mismatch
          WHERE mismatch.user_id = users.id
            AND mismatch.object_key = object.name
            AND mismatch.status = 'expired'
            AND mismatch.expires_at > statement_timestamp()
        )
      )
      AND split_part(object.name, '/', 3) ~ '^[0-9a-f]{64}\.[a-z0-9]+$'
      AND NOT EXISTS (
        SELECT 1
        FROM public.memo_attachments attachment
        JOIN public.memos memo ON memo.id = attachment.memo_id
        WHERE memo.user_id = users.id
          AND memo.deleted_at IS NULL
          AND attachment.storage_key = object.name
          AND attachment.content_sha256 IS NOT NULL
      )
      AND NOT EXISTS (
        SELECT 1
        FROM public.attachment_upload_reservations reservation
        WHERE reservation.user_id = users.id
          AND reservation.object_key = object.name
          AND reservation.status = 'prepared'
          AND reservation.expires_at > statement_timestamp()
      )
    ON CONFLICT (user_id, object_key) DO UPDATE SET
      reason = 'uncommitted_orphan',
      not_before = LEAST(attachment_gc_queue.not_before, statement_timestamp()),
      status = CASE
        WHEN attachment_gc_queue.status = 'processing'
          AND attachment_gc_queue.lease_expires_at > statement_timestamp()
          THEN 'processing'
        ELSE 'pending'
      END,
      lease_token = CASE
        WHEN attachment_gc_queue.status = 'processing'
          AND attachment_gc_queue.lease_expires_at > statement_timestamp()
          THEN attachment_gc_queue.lease_token
        ELSE NULL
      END,
      lease_expires_at = CASE
        WHEN attachment_gc_queue.status = 'processing'
          AND attachment_gc_queue.lease_expires_at > statement_timestamp()
          THEN attachment_gc_queue.lease_expires_at
        ELSE NULL
      END,
      deleted_at = NULL
    RETURNING 1
  )
  SELECT count(*)::integer INTO v_queued FROM inserted;

  RETURN jsonb_build_object('queued', v_queued);
END;
$$;--> statement-breakpoint

REVOKE ALL ON FUNCTION public.daypage_inventory_attachment_orphans() FROM PUBLIC;--> statement-breakpoint
GRANT EXECUTE ON FUNCTION public.daypage_inventory_attachment_orphans() TO service_role;--> statement-breakpoint

CREATE OR REPLACE FUNCTION public.daypage_claim_attachment_gc(p_limit integer DEFAULT 25)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_items jsonb;
BEGIN
  IF auth.role() <> 'service_role' THEN
    RAISE EXCEPTION 'service role required' USING ERRCODE = '42501';
  END IF;

  WITH candidates AS (
    SELECT queue.user_id, queue.object_key
    FROM public.attachment_gc_queue queue
    WHERE queue.not_before <= statement_timestamp()
      AND (
        queue.status = 'pending'
        OR (
          queue.status = 'processing'
          AND queue.lease_expires_at <= statement_timestamp()
        )
      )
      AND NOT EXISTS (
        SELECT 1
        FROM public.memo_attachments attachment
        JOIN public.memos memo ON memo.id = attachment.memo_id
        WHERE memo.user_id = queue.user_id
          AND memo.deleted_at IS NULL
          AND attachment.storage_key = queue.object_key
          AND attachment.content_sha256 IS NOT NULL
      )
      AND NOT EXISTS (
        SELECT 1
        FROM public.attachment_upload_reservations reservation
        WHERE reservation.user_id = queue.user_id
          AND reservation.object_key = queue.object_key
          AND reservation.status = 'prepared'
          AND reservation.expires_at > statement_timestamp()
      )
    ORDER BY queue.not_before, queue.attempts, queue.object_key
    FOR UPDATE SKIP LOCKED
    LIMIT LEAST(GREATEST(COALESCE(p_limit, 25), 1), 100)
  ), claimed AS (
    UPDATE public.attachment_gc_queue queue
    SET status = 'processing',
        attempts = queue.attempts + 1,
        claimed_at = statement_timestamp(),
        lease_token = gen_random_uuid(),
        lease_expires_at = statement_timestamp() + interval '15 minutes',
        last_error = NULL
    FROM candidates
    WHERE queue.user_id = candidates.user_id
      AND queue.object_key = candidates.object_key
    RETURNING queue.user_id, queue.object_key, queue.lease_token, queue.attempts
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'user_id', claimed.user_id,
    'object_key', claimed.object_key,
    'lease_token', claimed.lease_token,
    'attempt', claimed.attempts
  ) ORDER BY claimed.object_key), '[]'::jsonb)
  INTO v_items
  FROM claimed;

  RETURN jsonb_build_object('items', v_items);
END;
$$;--> statement-breakpoint

REVOKE ALL ON FUNCTION public.daypage_claim_attachment_gc(integer) FROM PUBLIC;--> statement-breakpoint
GRANT EXECUTE ON FUNCTION public.daypage_claim_attachment_gc(integer) TO service_role;--> statement-breakpoint

CREATE OR REPLACE FUNCTION public.daypage_finish_attachment_gc(
  p_user_id uuid,
  p_object_key text,
  p_lease_token uuid,
  p_deleted boolean,
  p_error_code text DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_updated integer;
BEGIN
  IF auth.role() <> 'service_role' THEN
    RAISE EXCEPTION 'service role required' USING ERRCODE = '42501';
  END IF;

  UPDATE public.attachment_gc_queue queue
  SET status = CASE WHEN p_deleted THEN 'deleted' ELSE 'pending' END,
      deleted_at = CASE WHEN p_deleted THEN statement_timestamp() ELSE NULL END,
      not_before = CASE
        WHEN p_deleted THEN queue.not_before
        ELSE statement_timestamp() +
          make_interval(secs => LEAST(3600, 30 * (1 << LEAST(queue.attempts, 7))))
      END,
      last_error = CASE
        WHEN p_deleted THEN NULL
        ELSE left(COALESCE(NULLIF(p_error_code, ''), 'storage_api_error'), 80)
      END,
      lease_token = NULL,
      lease_expires_at = NULL
  WHERE queue.user_id = p_user_id
    AND queue.object_key = p_object_key
    AND queue.status = 'processing'
    AND queue.lease_token = p_lease_token;
  GET DIAGNOSTICS v_updated = ROW_COUNT;
  IF v_updated = 1 AND p_deleted THEN
    UPDATE public.attachment_upload_reservations reservation
    SET status = 'expired',
        expires_at = LEAST(reservation.expires_at, statement_timestamp())
    WHERE reservation.user_id = p_user_id
      AND reservation.object_key = p_object_key;
  END IF;
  RETURN v_updated = 1;
END;
$$;--> statement-breakpoint

REVOKE ALL ON FUNCTION public.daypage_finish_attachment_gc(uuid, text, uuid, boolean, text)
  FROM PUBLIC;--> statement-breakpoint
GRANT EXECUTE ON FUNCTION public.daypage_finish_attachment_gc(uuid, text, uuid, boolean, text)
  TO service_role;--> statement-breakpoint
