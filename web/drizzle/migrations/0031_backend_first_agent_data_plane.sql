-- Backend-first Agent Data Plane.
--
-- This migration is intentionally additive. Raw memos and attachment storage keep
-- their existing local-first contract; all new tables contain derived state,
-- runtime audit data, configuration, or proposal/execution receipts.

CREATE TYPE "public"."skill_version_status" AS ENUM('active', 'deprecated', 'disabled');--> statement-breakpoint
CREATE TYPE "public"."tool_effect" AS ENUM('read', 'internal_write', 'external_write', 'destructive');--> statement-breakpoint
CREATE TYPE "public"."approval_mode" AS ENUM('auto', 'confirm', 'forbidden');--> statement-breakpoint
CREATE TYPE "public"."automation_trigger_type" AS ENUM('event', 'schedule', 'manual');--> statement-breakpoint
CREATE TYPE "public"."agent_run_status" AS ENUM('queued', 'running', 'completed', 'failed', 'cancelled', 'needs_review');--> statement-breakpoint
CREATE TYPE "public"."agent_run_step_status" AS ENUM('pending', 'running', 'completed', 'failed', 'skipped');--> statement-breakpoint
CREATE TYPE "public"."artifact_status" AS ENUM('draft', 'live', 'superseded', 'archived', 'needs_review');--> statement-breakpoint
CREATE TYPE "public"."tool_execution_status" AS ENUM('pending', 'running', 'completed', 'failed', 'dead');--> statement-breakpoint
ALTER TYPE "public"."work_order_status" ADD VALUE IF NOT EXISTS 'approved' AFTER 'gated';--> statement-breakpoint
ALTER TYPE "public"."work_order_status" ADD VALUE IF NOT EXISTS 'rejected' AFTER 'approved';--> statement-breakpoint

ALTER TABLE "agents" ADD COLUMN IF NOT EXISTS "instructions" text NOT NULL DEFAULT '';--> statement-breakpoint
ALTER TABLE "agents" ADD COLUMN IF NOT EXISTS "model_policy" jsonb NOT NULL DEFAULT '{"preferredModel":"gpt-4o-mini"}'::jsonb;--> statement-breakpoint
ALTER TABLE "agents" ADD COLUMN IF NOT EXISTS "knowledge_scope" jsonb NOT NULL DEFAULT '{"topK":8}'::jsonb;--> statement-breakpoint
ALTER TABLE "agents" ADD COLUMN IF NOT EXISTS "budget_policy" jsonb NOT NULL DEFAULT '{"maxInputTokens":16000,"maxOutputTokens":2048,"maxToolCalls":4,"timeoutSeconds":120}'::jsonb;--> statement-breakpoint

ALTER TABLE "gateway_jobs" ADD COLUMN IF NOT EXISTS "available_at" timestamptz NOT NULL DEFAULT now();--> statement-breakpoint
ALTER TABLE "gateway_jobs" ADD COLUMN IF NOT EXISTS "lease_token" uuid;--> statement-breakpoint
ALTER TABLE "gateway_jobs" ADD COLUMN IF NOT EXISTS "lease_expires_at" timestamptz;--> statement-breakpoint
ALTER TABLE "gateway_jobs" ADD COLUMN IF NOT EXISTS "coalesce_key" text;--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "gateway_jobs_claimable" ON "gateway_jobs" ("status", "available_at", "lease_expires_at");--> statement-breakpoint

CREATE TABLE "skill_versions" (
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
  "key" text NOT NULL,
  "version" text NOT NULL,
  "description" text NOT NULL DEFAULT '',
  "manifest" jsonb NOT NULL DEFAULT '{}'::jsonb,
  "input_schema" jsonb NOT NULL DEFAULT '{}'::jsonb,
  "output_schema" jsonb NOT NULL DEFAULT '{}'::jsonb,
  "required_tools" jsonb NOT NULL DEFAULT '[]'::jsonb,
  "optional_tools" jsonb NOT NULL DEFAULT '[]'::jsonb,
  "default_risk" "tool_effect" NOT NULL DEFAULT 'read',
  "implementation_ref" text NOT NULL,
  "checksum" text NOT NULL,
  "status" "skill_version_status" NOT NULL DEFAULT 'active',
  "created_at" timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT "skill_versions_key_version_unique" UNIQUE("key", "version"),
  CONSTRAINT "skill_versions_checksum_unique" UNIQUE("checksum")
);--> statement-breakpoint
CREATE INDEX "skill_versions_key_status" ON "skill_versions" ("key", "status");--> statement-breakpoint

CREATE TABLE "tool_definitions" (
  "key" text PRIMARY KEY NOT NULL,
  "source" text NOT NULL,
  "effect" "tool_effect" NOT NULL,
  "input_schema" jsonb NOT NULL DEFAULT '{}'::jsonb,
  "output_schema" jsonb NOT NULL DEFAULT '{}'::jsonb,
  "default_approval" "approval_mode" NOT NULL DEFAULT 'forbidden',
  "required_scopes" jsonb NOT NULL DEFAULT '[]'::jsonb,
  "timeout_seconds" integer NOT NULL DEFAULT 30,
  "max_result_bytes" integer NOT NULL DEFAULT 65536,
  "enabled" boolean NOT NULL DEFAULT true,
  "created_at" timestamptz NOT NULL DEFAULT now(),
  "updated_at" timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT "tool_definitions_timeout_check" CHECK (timeout_seconds BETWEEN 1 AND 300),
  CONSTRAINT "tool_definitions_result_size_check" CHECK (max_result_bytes BETWEEN 1 AND 1048576)
);--> statement-breakpoint

CREATE TABLE "tool_connections" (
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
  "user_id" uuid NOT NULL REFERENCES "users"("id") ON DELETE cascade,
  "provider" text NOT NULL,
  "auth_ref" text NOT NULL,
  "scopes" jsonb NOT NULL DEFAULT '[]'::jsonb,
  "status" text NOT NULL DEFAULT 'active',
  "metadata" jsonb NOT NULL DEFAULT '{}'::jsonb,
  "revoked_at" timestamptz,
  "created_at" timestamptz NOT NULL DEFAULT now(),
  "updated_at" timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT "tool_connections_user_provider_auth_unique" UNIQUE("user_id", "provider", "auth_ref"),
  CONSTRAINT "tool_connections_status_check" CHECK (status IN ('active', 'expired', 'revoked', 'error'))
);--> statement-breakpoint
CREATE INDEX "tool_connections_user_status" ON "tool_connections" ("user_id", "status");--> statement-breakpoint

CREATE TABLE "agent_skill_bindings" (
  "agent_id" uuid NOT NULL REFERENCES "agents"("id") ON DELETE cascade,
  "skill_version_id" uuid NOT NULL REFERENCES "skill_versions"("id") ON DELETE cascade,
  "enabled" boolean NOT NULL DEFAULT true,
  "priority" integer NOT NULL DEFAULT 0,
  "config" jsonb NOT NULL DEFAULT '{}'::jsonb,
  CONSTRAINT "agent_skill_bindings_pk" PRIMARY KEY("agent_id", "skill_version_id")
);--> statement-breakpoint

CREATE TABLE "agent_tool_bindings" (
  "agent_id" uuid NOT NULL REFERENCES "agents"("id") ON DELETE cascade,
  "tool_key" text NOT NULL REFERENCES "tool_definitions"("key") ON DELETE cascade,
  "connection_id" uuid REFERENCES "tool_connections"("id") ON DELETE set null,
  "approval_override" "approval_mode",
  "enabled" boolean NOT NULL DEFAULT true,
  CONSTRAINT "agent_tool_bindings_pk" PRIMARY KEY("agent_id", "tool_key")
);--> statement-breakpoint

CREATE TABLE "automations" (
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
  "user_id" uuid NOT NULL REFERENCES "users"("id") ON DELETE cascade,
  "name" text NOT NULL,
  "trigger_type" "automation_trigger_type" NOT NULL,
  "trigger" jsonb NOT NULL DEFAULT '{}'::jsonb,
  "timezone" text NOT NULL DEFAULT 'UTC',
  "agent_id" uuid REFERENCES "agents"("id") ON DELETE set null,
  "skill_version_id" uuid NOT NULL REFERENCES "skill_versions"("id") ON DELETE restrict,
  "input_selector" jsonb NOT NULL DEFAULT '{}'::jsonb,
  "coalesce_policy" jsonb NOT NULL DEFAULT '{}'::jsonb,
  "enabled" boolean NOT NULL DEFAULT true,
  "next_due_at" timestamptz,
  "last_enqueued_at" timestamptz,
  "created_at" timestamptz NOT NULL DEFAULT now(),
  "updated_at" timestamptz NOT NULL DEFAULT now()
);--> statement-breakpoint
CREATE INDEX "automations_due" ON "automations" ("enabled", "next_due_at");--> statement-breakpoint

CREATE TABLE "agent_runs" (
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
  "user_id" uuid NOT NULL REFERENCES "users"("id") ON DELETE cascade,
  "trigger_type" text NOT NULL,
  "trigger_ref" text,
  "trigger_snapshot" jsonb NOT NULL DEFAULT '{}'::jsonb,
  "memo_id" uuid REFERENCES "memos"("id") ON DELETE set null,
  "memo_revision" bigint,
  "agent_id" uuid REFERENCES "agents"("id") ON DELETE set null,
  "skill_version_id" uuid NOT NULL REFERENCES "skill_versions"("id") ON DELETE restrict,
  "agent_snapshot" jsonb NOT NULL DEFAULT '{}'::jsonb,
  "skill_snapshot" jsonb NOT NULL DEFAULT '{}'::jsonb,
  "tool_policy_snapshot" jsonb NOT NULL DEFAULT '{}'::jsonb,
  "skill_checksum" text NOT NULL,
  "idempotency_key" text NOT NULL,
  "attempt" integer NOT NULL DEFAULT 1,
  "is_canonical" boolean NOT NULL DEFAULT true,
  "shadow" boolean NOT NULL DEFAULT false,
  "status" "agent_run_status" NOT NULL DEFAULT 'queued',
  "summary" text,
  "budget" jsonb NOT NULL DEFAULT '{}'::jsonb,
  "error" jsonb,
  "started_at" timestamptz,
  "completed_at" timestamptz,
  "created_at" timestamptz NOT NULL DEFAULT now(),
  "updated_at" timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT "agent_runs_user_key_attempt_unique" UNIQUE("user_id", "idempotency_key", "attempt"),
  CONSTRAINT "agent_runs_attempt_check" CHECK (attempt >= 1),
  CONSTRAINT "agent_runs_revision_check" CHECK (memo_revision IS NULL OR memo_revision >= 0)
);--> statement-breakpoint
CREATE UNIQUE INDEX "agent_runs_one_canonical" ON "agent_runs" ("user_id", "idempotency_key") WHERE "is_canonical" = true;--> statement-breakpoint
CREATE INDEX "agent_runs_user_status_created" ON "agent_runs" ("user_id", "status", "created_at");--> statement-breakpoint
CREATE INDEX "agent_runs_memo" ON "agent_runs" ("user_id", "memo_id", "created_at");--> statement-breakpoint

CREATE TABLE "agent_run_steps" (
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
  "run_id" uuid NOT NULL REFERENCES "agent_runs"("id") ON DELETE cascade,
  "ordinal" integer NOT NULL,
  "step_key" text NOT NULL,
  "tool_key" text REFERENCES "tool_definitions"("key") ON DELETE set null,
  "status" "agent_run_step_status" NOT NULL DEFAULT 'pending',
  "input_hash" text,
  "output_hash" text,
  "tokens_in" integer NOT NULL DEFAULT 0,
  "tokens_out" integer NOT NULL DEFAULT 0,
  "duration_ms" integer NOT NULL DEFAULT 0,
  "receipt" jsonb NOT NULL DEFAULT '{}'::jsonb,
  "error" jsonb,
  "started_at" timestamptz,
  "completed_at" timestamptz,
  "created_at" timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT "agent_run_steps_run_ordinal_unique" UNIQUE("run_id", "ordinal"),
  CONSTRAINT "agent_run_steps_run_key_unique" UNIQUE("run_id", "step_key"),
  CONSTRAINT "agent_run_steps_usage_check" CHECK (ordinal >= 0 AND tokens_in >= 0 AND tokens_out >= 0 AND duration_ms >= 0)
);--> statement-breakpoint

CREATE TABLE "agent_artifacts" (
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
  "user_id" uuid NOT NULL REFERENCES "users"("id") ON DELETE cascade,
  "run_id" uuid NOT NULL REFERENCES "agent_runs"("id") ON DELETE cascade,
  "kind" text NOT NULL,
  "schema_version" integer NOT NULL DEFAULT 1,
  "logical_key" text NOT NULL,
  "payload" jsonb NOT NULL DEFAULT '{}'::jsonb,
  "body_md" text,
  "status" "artifact_status" NOT NULL DEFAULT 'draft',
  "revision" integer NOT NULL DEFAULT 1,
  "source_set_hash" text,
  "local_date" text,
  "timezone" text,
  "perspective_key" text NOT NULL DEFAULT 'canonical',
  "supersedes_id" uuid REFERENCES "agent_artifacts"("id") ON DELETE set null,
  "finalized_at" timestamptz,
  "created_at" timestamptz NOT NULL DEFAULT now(),
  "updated_at" timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT "agent_artifacts_logical_revision_unique" UNIQUE("user_id", "logical_key", "perspective_key", "revision"),
  CONSTRAINT "agent_artifacts_revision_check" CHECK (schema_version >= 1 AND revision >= 1),
  CONSTRAINT "agent_artifacts_local_date_check" CHECK (local_date IS NULL OR local_date ~ '^\\d{4}-\\d{2}-\\d{2}$')
);--> statement-breakpoint
CREATE INDEX "agent_artifacts_user_kind_status" ON "agent_artifacts" ("user_id", "kind", "status");--> statement-breakpoint
CREATE INDEX "agent_artifacts_local_date" ON "agent_artifacts" ("user_id", "local_date", "kind");--> statement-breakpoint

CREATE TABLE "artifact_sources" (
  "artifact_id" uuid NOT NULL REFERENCES "agent_artifacts"("id") ON DELETE cascade,
  "memo_id" uuid REFERENCES "memos"("id") ON DELETE set null,
  "page_id" uuid REFERENCES "pages"("id") ON DELETE set null,
  "source_artifact_id" uuid REFERENCES "agent_artifacts"("id") ON DELETE set null,
  "span_start" integer,
  "span_end" integer,
  "provenance" text NOT NULL DEFAULT 'direct',
  "weight" real NOT NULL DEFAULT 1,
  "created_at" timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT "artifact_sources_has_source_check" CHECK (num_nonnulls(memo_id, page_id, source_artifact_id) = 1),
  CONSTRAINT "artifact_sources_span_check" CHECK ((span_start IS NULL AND span_end IS NULL) OR (span_start >= 0 AND span_end > span_start)),
  CONSTRAINT "artifact_sources_unique" UNIQUE NULLS NOT DISTINCT ("artifact_id", "memo_id", "page_id", "source_artifact_id", "span_start", "span_end")
);--> statement-breakpoint
CREATE INDEX "artifact_sources_memo" ON "artifact_sources" ("memo_id", "artifact_id");--> statement-breakpoint

ALTER TABLE "work_orders" ADD COLUMN IF NOT EXISTS "run_id" uuid;--> statement-breakpoint
ALTER TABLE "work_orders" ADD COLUMN IF NOT EXISTS "tool_key" text;--> statement-breakpoint
ALTER TABLE "work_orders" ADD COLUMN IF NOT EXISTS "arguments" jsonb;--> statement-breakpoint
ALTER TABLE "work_orders" ADD COLUMN IF NOT EXISTS "effect" "tool_effect";--> statement-breakpoint
ALTER TABLE "work_orders" ADD COLUMN IF NOT EXISTS "approval_required" boolean NOT NULL DEFAULT true;--> statement-breakpoint
ALTER TABLE "work_orders" ADD COLUMN IF NOT EXISTS "approved_at" timestamptz;--> statement-breakpoint
ALTER TABLE "work_orders" ADD COLUMN IF NOT EXISTS "approved_by" uuid;--> statement-breakpoint
ALTER TABLE "work_orders" ADD COLUMN IF NOT EXISTS "rejected_at" timestamptz;--> statement-breakpoint
ALTER TABLE "work_orders" ADD COLUMN IF NOT EXISTS "rejection_reason" text;--> statement-breakpoint
ALTER TABLE "work_orders" ADD COLUMN IF NOT EXISTS "provider_idempotency_key" text;--> statement-breakpoint
ALTER TABLE "work_orders" ADD COLUMN IF NOT EXISTS "provider_receipt" jsonb;--> statement-breakpoint
ALTER TABLE "work_orders" ADD COLUMN IF NOT EXISTS "updated_at" timestamptz NOT NULL DEFAULT now();--> statement-breakpoint
ALTER TABLE "work_orders" ADD CONSTRAINT "work_orders_run_id_agent_runs_id_fk" FOREIGN KEY ("run_id") REFERENCES "agent_runs"("id") ON DELETE set null;--> statement-breakpoint
ALTER TABLE "work_orders" ADD CONSTRAINT "work_orders_tool_key_tool_definitions_key_fk" FOREIGN KEY ("tool_key") REFERENCES "tool_definitions"("key") ON DELETE restrict;--> statement-breakpoint
ALTER TABLE "work_orders" ADD CONSTRAINT "work_orders_approved_by_users_id_fk" FOREIGN KEY ("approved_by") REFERENCES "users"("id") ON DELETE set null;--> statement-breakpoint
CREATE UNIQUE INDEX "work_orders_provider_idempotency_unique" ON "work_orders" ("provider_idempotency_key") WHERE "provider_idempotency_key" IS NOT NULL;--> statement-breakpoint

CREATE TABLE "tool_execution_outbox" (
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
  "user_id" uuid NOT NULL REFERENCES "users"("id") ON DELETE cascade,
  "work_order_id" uuid NOT NULL REFERENCES "work_orders"("id") ON DELETE cascade,
  "tool_key" text NOT NULL REFERENCES "tool_definitions"("key") ON DELETE restrict,
  "connection_id" uuid REFERENCES "tool_connections"("id") ON DELETE set null,
  "arguments" jsonb NOT NULL DEFAULT '{}'::jsonb,
  "idempotency_key" text NOT NULL,
  "status" "tool_execution_status" NOT NULL DEFAULT 'pending',
  "attempts" integer NOT NULL DEFAULT 0,
  "available_at" timestamptz NOT NULL DEFAULT now(),
  "lease_token" uuid,
  "lease_expires_at" timestamptz,
  "provider_receipt" jsonb,
  "last_error" text,
  "created_at" timestamptz NOT NULL DEFAULT now(),
  "updated_at" timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT "tool_execution_outbox_idempotency_unique" UNIQUE("idempotency_key"),
  CONSTRAINT "tool_execution_outbox_attempts_check" CHECK (attempts >= 0)
);--> statement-breakpoint
CREATE INDEX "tool_execution_outbox_due" ON "tool_execution_outbox" ("status", "available_at", "lease_expires_at");--> statement-breakpoint

-- Direct clients may read only their own derived data/configuration. Writes are
-- normally made by the backend runtime, but owner policies preserve safe API/RPC use.
ALTER TABLE "agents" ENABLE ROW LEVEL SECURITY;--> statement-breakpoint
ALTER TABLE "gateway_jobs" ENABLE ROW LEVEL SECURITY;--> statement-breakpoint
ALTER TABLE "work_orders" ENABLE ROW LEVEL SECURITY;--> statement-breakpoint
ALTER TABLE "agent_sessions" ENABLE ROW LEVEL SECURITY;--> statement-breakpoint
ALTER TABLE "skill_versions" ENABLE ROW LEVEL SECURITY;--> statement-breakpoint
ALTER TABLE "tool_definitions" ENABLE ROW LEVEL SECURITY;--> statement-breakpoint
ALTER TABLE "tool_connections" ENABLE ROW LEVEL SECURITY;--> statement-breakpoint
ALTER TABLE "agent_skill_bindings" ENABLE ROW LEVEL SECURITY;--> statement-breakpoint
ALTER TABLE "agent_tool_bindings" ENABLE ROW LEVEL SECURITY;--> statement-breakpoint
ALTER TABLE "automations" ENABLE ROW LEVEL SECURITY;--> statement-breakpoint
ALTER TABLE "agent_runs" ENABLE ROW LEVEL SECURITY;--> statement-breakpoint
ALTER TABLE "agent_run_steps" ENABLE ROW LEVEL SECURITY;--> statement-breakpoint
ALTER TABLE "agent_artifacts" ENABLE ROW LEVEL SECURITY;--> statement-breakpoint
ALTER TABLE "artifact_sources" ENABLE ROW LEVEL SECURITY;--> statement-breakpoint
ALTER TABLE "tool_execution_outbox" ENABLE ROW LEVEL SECURITY;--> statement-breakpoint

CREATE POLICY "skill_versions_authenticated_read" ON "skill_versions" FOR SELECT TO authenticated USING (true);--> statement-breakpoint
CREATE POLICY "tool_definitions_authenticated_read" ON "tool_definitions" FOR SELECT TO authenticated USING (enabled);--> statement-breakpoint
CREATE POLICY "agents_owner_all" ON "agents" FOR ALL TO authenticated USING (user_id = auth.uid()) WITH CHECK (user_id = auth.uid());--> statement-breakpoint
CREATE POLICY "gateway_jobs_owner_read" ON "gateway_jobs" FOR SELECT TO authenticated USING (user_id = auth.uid());--> statement-breakpoint
CREATE POLICY "work_orders_owner_read" ON "work_orders" FOR SELECT TO authenticated USING (user_id = auth.uid());--> statement-breakpoint
CREATE POLICY "agent_sessions_owner_read" ON "agent_sessions" FOR SELECT TO authenticated USING (user_id = auth.uid());--> statement-breakpoint
CREATE POLICY "tool_connections_owner_read" ON "tool_connections" FOR SELECT TO authenticated USING (user_id = auth.uid());--> statement-breakpoint
CREATE POLICY "agent_skill_bindings_owner_read" ON "agent_skill_bindings" FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM agents WHERE agents.id = agent_skill_bindings.agent_id AND agents.user_id = auth.uid()));--> statement-breakpoint
CREATE POLICY "agent_tool_bindings_owner_read" ON "agent_tool_bindings" FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM agents WHERE agents.id = agent_tool_bindings.agent_id AND agents.user_id = auth.uid()));--> statement-breakpoint
CREATE POLICY "automations_owner_read" ON "automations" FOR SELECT TO authenticated USING (user_id = auth.uid());--> statement-breakpoint
CREATE POLICY "agent_runs_owner_read" ON "agent_runs" FOR SELECT TO authenticated USING (user_id = auth.uid());--> statement-breakpoint
CREATE POLICY "agent_run_steps_owner_read" ON "agent_run_steps" FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM agent_runs WHERE agent_runs.id = agent_run_steps.run_id AND agent_runs.user_id = auth.uid()));--> statement-breakpoint
CREATE POLICY "agent_artifacts_owner_read" ON "agent_artifacts" FOR SELECT TO authenticated USING (user_id = auth.uid());--> statement-breakpoint
CREATE POLICY "artifact_sources_owner_read" ON "artifact_sources" FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM agent_artifacts WHERE agent_artifacts.id = artifact_sources.artifact_id AND agent_artifacts.user_id = auth.uid()));--> statement-breakpoint
CREATE POLICY "tool_execution_outbox_owner_read" ON "tool_execution_outbox" FOR SELECT TO authenticated USING (user_id = auth.uid());--> statement-breakpoint

REVOKE ALL ON skill_versions, tool_definitions, tool_connections, agent_skill_bindings,
  agent_tool_bindings, automations, agent_runs, agent_run_steps, agent_artifacts,
  artifact_sources, tool_execution_outbox FROM PUBLIC, anon;--> statement-breakpoint
GRANT SELECT ON skill_versions, tool_definitions, agent_runs, agent_run_steps,
  agent_artifacts, artifact_sources, tool_execution_outbox TO authenticated;--> statement-breakpoint
GRANT SELECT ON tool_connections, agent_skill_bindings, agent_tool_bindings,
  automations, work_orders TO authenticated;--> statement-breakpoint

-- Every raw revision, regardless of ingress path, emits the same durable event.
-- The trigger is narrowly scoped so compiler metadata/embedding updates do not loop.
CREATE OR REPLACE FUNCTION public.daypage_enqueue_memo_revision()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
  v_hash text;
  v_revision bigint;
  v_type text;
  v_key text;
BEGIN
  IF TG_OP = 'UPDATE'
    AND OLD.body IS NOT DISTINCT FROM NEW.body
    AND OLD.content_hash IS NOT DISTINCT FROM NEW.content_hash
    AND OLD.sync_revision IS NOT DISTINCT FROM NEW.sync_revision
    AND OLD.deleted_at IS NOT DISTINCT FROM NEW.deleted_at THEN
    RETURN NEW;
  END IF;

  v_hash := COALESCE(
    NEW.content_hash,
    encode(extensions.digest(convert_to(COALESCE(NEW.body, ''), 'UTF8'), 'sha256'), 'hex')
  );
  v_revision := CASE WHEN NEW.sync_revision > 0 THEN NEW.sync_revision ELSE NEW.sync_change_sequence END;
  v_type := CASE WHEN NEW.deleted_at IS NULL THEN 'memo.synced' ELSE 'memo.deleted' END;
  v_key := v_type || ':' || NEW.user_id::text || ':' || NEW.id::text || ':' || v_revision::text || ':' || v_hash;

  INSERT INTO gateway_jobs (
    user_id, type, payload, status, idempotency_key, available_at,
    coalesce_key, attempts, created_at, updated_at
  ) VALUES (
    NEW.user_id,
    v_type,
    jsonb_build_object(
      'memo_id', NEW.id,
      'accepted_revision', v_revision,
      'content_hash', v_hash,
      'deleted', NEW.deleted_at IS NOT NULL
    ),
    'queued',
    v_key,
    now(),
    'memo:' || NEW.user_id::text || ':' || NEW.id::text,
    0,
    now(),
    now()
  ) ON CONFLICT (idempotency_key) DO NOTHING;

  RETURN NEW;
END;
$$;--> statement-breakpoint
REVOKE ALL ON FUNCTION public.daypage_enqueue_memo_revision() FROM PUBLIC;--> statement-breakpoint
DROP TRIGGER IF EXISTS daypage_memo_revision_event ON public.memos;--> statement-breakpoint
CREATE TRIGGER daypage_memo_revision_event
AFTER INSERT OR UPDATE OF body, content_hash, sync_revision, deleted_at ON public.memos
FOR EACH ROW
EXECUTE FUNCTION public.daypage_enqueue_memo_revision();--> statement-breakpoint

-- Client-safe optimistic page mutation. Backend workers use the same predicate
-- directly so a missing auth context cannot accidentally widen access.
CREATE OR REPLACE FUNCTION public.daypage_apply_page_patch(
  p_page_id uuid,
  p_expected_version integer,
  p_title text,
  p_body_md text,
  p_metadata jsonb DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
  v_row pages%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'authentication required' USING ERRCODE = '42501';
  END IF;

  UPDATE pages
  SET title = COALESCE(p_title, title),
      body_md = p_body_md,
      metadata = COALESCE(p_metadata, metadata),
      version = version + 1,
      last_compiled_at = now(),
      updated_at = now()
  WHERE id = p_page_id
    AND user_id = auth.uid()
    AND version = p_expected_version
  RETURNING * INTO v_row;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('applied', false, 'reason', 'version_conflict');
  END IF;

  RETURN jsonb_build_object('applied', true, 'page_id', v_row.id, 'version', v_row.version);
END;
$$;--> statement-breakpoint
REVOKE ALL ON FUNCTION public.daypage_apply_page_patch(uuid, integer, text, text, jsonb) FROM PUBLIC, anon;--> statement-breakpoint
GRANT EXECUTE ON FUNCTION public.daypage_apply_page_patch(uuid, integer, text, text, jsonb) TO authenticated;
--> statement-breakpoint

-- Authenticated clients may request reducer work without being allowed to
-- insert or mutate Agent Runs directly. The durable queue remains the only
-- execution ingress and the worker remains the only writer of run/artifact
-- state. Explicit retries receive a fresh key; ordinary requests coalesce.
CREATE OR REPLACE FUNCTION public.daypage_request_daily_run(
  p_local_date text,
  p_timezone text,
  p_finalize boolean DEFAULT false,
  p_explicit_retry boolean DEFAULT false
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_job_id uuid;
  v_kind text := CASE WHEN p_finalize THEN 'daily.finalize' ELSE 'daily.synthesize' END;
  v_key text;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'authentication required' USING ERRCODE = '42501';
  END IF;
  IF p_local_date !~ '^\d{4}-\d{2}-\d{2}$' OR p_local_date::date::text <> p_local_date THEN
    RAISE EXCEPTION 'invalid local date' USING ERRCODE = '22007';
  END IF;
  IF p_timezone IS NULL OR length(p_timezone) NOT BETWEEN 1 AND 100 THEN
    RAISE EXCEPTION 'invalid timezone' USING ERRCODE = '22023';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_timezone_names WHERE name = p_timezone) THEN
    RAISE EXCEPTION 'unknown IANA timezone' USING ERRCODE = '22023';
  END IF;

  v_key := v_kind || ':client:' || v_user_id::text || ':' || p_local_date || ':' || p_timezone ||
    CASE WHEN p_explicit_retry THEN ':' || gen_random_uuid()::text ELSE '' END;
  INSERT INTO gateway_jobs (
    user_id, type, payload, status, idempotency_key, available_at,
    coalesce_key, attempts, created_at, updated_at
  ) VALUES (
    v_user_id,
    v_kind,
    jsonb_build_object(
      'local_date', p_local_date,
      'timezone', p_timezone,
      'finalize', p_finalize,
      'explicit_retry', p_explicit_retry,
      'requested_by', 'authenticated_client'
    ),
    'queued',
    v_key,
    CASE WHEN p_finalize THEN now() ELSE now() + interval '2 minutes' END,
    'daily:' || v_user_id::text || ':' || p_local_date || ':' || p_finalize::text,
    0,
    now(),
    now()
  )
  ON CONFLICT (idempotency_key) DO UPDATE
    SET available_at = LEAST(gateway_jobs.available_at, EXCLUDED.available_at),
        updated_at = now()
  RETURNING id INTO v_job_id;

  RETURN v_job_id;
END;
$$;
--> statement-breakpoint
REVOKE ALL ON FUNCTION public.daypage_request_daily_run(text, text, boolean, boolean) FROM PUBLIC, anon;
--> statement-breakpoint
GRANT EXECUTE ON FUNCTION public.daypage_request_daily_run(text, text, boolean, boolean) TO authenticated;
--> statement-breakpoint

CREATE OR REPLACE FUNCTION public.daypage_request_weekly_run(
  p_week_start text,
  p_timezone text,
  p_explicit_retry boolean DEFAULT false
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_job_id uuid;
  v_key text;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'authentication required' USING ERRCODE = '42501';
  END IF;
  IF p_week_start !~ '^\d{4}-\d{2}-\d{2}$' OR p_week_start::date::text <> p_week_start THEN
    RAISE EXCEPTION 'invalid week start' USING ERRCODE = '22007';
  END IF;
  IF p_timezone IS NULL OR length(p_timezone) NOT BETWEEN 1 AND 100 THEN
    RAISE EXCEPTION 'invalid timezone' USING ERRCODE = '22023';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_timezone_names WHERE name = p_timezone) THEN
    RAISE EXCEPTION 'unknown IANA timezone' USING ERRCODE = '22023';
  END IF;

  v_key := 'weekly.review:client:' || v_user_id::text || ':' || p_week_start || ':' || p_timezone ||
    CASE WHEN p_explicit_retry THEN ':' || gen_random_uuid()::text ELSE '' END;
  INSERT INTO gateway_jobs (
    user_id, type, payload, status, idempotency_key, available_at,
    coalesce_key, attempts, created_at, updated_at
  ) VALUES (
    v_user_id,
    'weekly.review',
    jsonb_build_object(
      'week_start', p_week_start,
      'timezone', p_timezone,
      'explicit_retry', p_explicit_retry,
      'requested_by', 'authenticated_client'
    ),
    'queued',
    v_key,
    now(),
    'weekly:' || v_user_id::text || ':' || p_week_start,
    0,
    now(),
    now()
  )
  ON CONFLICT (idempotency_key) DO UPDATE
    SET available_at = LEAST(gateway_jobs.available_at, EXCLUDED.available_at),
        updated_at = now()
  RETURNING id INTO v_job_id;

  RETURN v_job_id;
END;
$$;
--> statement-breakpoint
REVOKE ALL ON FUNCTION public.daypage_request_weekly_run(text, text, boolean) FROM PUBLIC, anon;
--> statement-breakpoint
GRANT EXECUTE ON FUNCTION public.daypage_request_weekly_run(text, text, boolean) TO authenticated;
