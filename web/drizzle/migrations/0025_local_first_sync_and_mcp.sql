-- #873: local-first revisioned sync, tenant RLS, and OAuth MCP grants.
--
-- This migration is intentionally additive. Rollback disables the writers and leaves
-- receipts/tombstones in place; deleting them could resurrect stale client state.

ALTER TABLE "memos" ADD COLUMN IF NOT EXISTS "sync_revision" bigint NOT NULL DEFAULT 0;--> statement-breakpoint
ALTER TABLE "memos" ADD COLUMN IF NOT EXISTS "source_modified_at" timestamp with time zone;--> statement-breakpoint
ALTER TABLE "memos" ADD COLUMN IF NOT EXISTS "content_hash" text;--> statement-breakpoint
ALTER TABLE "memos" ADD COLUMN IF NOT EXISTS "deleted_at" timestamp with time zone;--> statement-breakpoint
ALTER TABLE "memos" ADD COLUMN IF NOT EXISTS "last_sync_device_id" text;--> statement-breakpoint

CREATE INDEX IF NOT EXISTS "memos_user_sync_cursor"
  ON "memos" ("user_id", "updated_at", "id");--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "memos_user_active_created"
  ON "memos" ("user_id", "created_at" DESC)
  WHERE "deleted_at" IS NULL;--> statement-breakpoint

-- MCP substring search uses ILIKE '%term%'. Trigram GIN indexes keep this
-- bounded as a Vault grows beyond the point where sequential scans feel instant.
CREATE SCHEMA IF NOT EXISTS extensions;--> statement-breakpoint
CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA extensions;--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "memos_body_trgm"
  ON "memos" USING gin ("body" extensions.gin_trgm_ops)
  WHERE "deleted_at" IS NULL;--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "pages_title_trgm"
  ON "pages" USING gin ("title" extensions.gin_trgm_ops);--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "pages_body_md_trgm"
  ON "pages" USING gin ("body_md" extensions.gin_trgm_ops);--> statement-breakpoint

CREATE TABLE IF NOT EXISTS "sync_operations" (
  "user_id" uuid NOT NULL REFERENCES "public"."users"("id") ON DELETE cascade,
  "operation_id" uuid NOT NULL,
  "memo_id" uuid NOT NULL,
  "kind" text NOT NULL CHECK ("kind" IN ('upsert', 'delete')),
  "revision" bigint NOT NULL CHECK ("revision" > 0),
  "status" text NOT NULL CHECK ("status" IN ('applied', 'stale')),
  "applied_at" timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "sync_operations_user_operation_pk" PRIMARY KEY ("user_id", "operation_id")
);--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "sync_operations_user_memo_revision"
  ON "sync_operations" ("user_id", "memo_id", "revision" DESC);--> statement-breakpoint

CREATE TABLE IF NOT EXISTS "mcp_client_grants" (
  "user_id" uuid NOT NULL REFERENCES "public"."users"("id") ON DELETE cascade,
  "client_id" text NOT NULL,
  "can_read" boolean NOT NULL DEFAULT true,
  "can_write" boolean NOT NULL DEFAULT false,
  "created_at" timestamp with time zone NOT NULL DEFAULT now(),
  "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
  "revoked_at" timestamp with time zone,
  CONSTRAINT "mcp_client_grants_user_client_pk" PRIMARY KEY ("user_id", "client_id")
);--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "mcp_client_grants_client_active"
  ON "mcp_client_grants" ("client_id", "user_id")
  WHERE "revoked_at" IS NULL;--> statement-breakpoint

-- Environment-owned values used by the Auth hook. No browser/API role receives table
-- access; only supabase_auth_admin can read it while issuing a token.
CREATE TABLE IF NOT EXISTS "daypage_runtime_config" (
  "key" text PRIMARY KEY,
  "value" text NOT NULL,
  "updated_at" timestamp with time zone NOT NULL DEFAULT now()
);--> statement-breakpoint
INSERT INTO "daypage_runtime_config" ("key", "value")
VALUES ('mcp_resource', '')
ON CONFLICT ("key") DO NOTHING;--> statement-breakpoint
REVOKE ALL ON public.daypage_runtime_config FROM PUBLIC, anon, authenticated;--> statement-breakpoint

-- RLS for the surfaces reached by iOS sync and Cloud MCP.
ALTER TABLE "users" ENABLE ROW LEVEL SECURITY;--> statement-breakpoint
ALTER TABLE "memos" ENABLE ROW LEVEL SECURITY;--> statement-breakpoint
ALTER TABLE "memo_attachments" ENABLE ROW LEVEL SECURITY;--> statement-breakpoint
ALTER TABLE "pages" ENABLE ROW LEVEL SECURITY;--> statement-breakpoint
ALTER TABLE "domains" ENABLE ROW LEVEL SECURITY;--> statement-breakpoint
ALTER TABLE "page_links" ENABLE ROW LEVEL SECURITY;--> statement-breakpoint
ALTER TABLE "page_sources" ENABLE ROW LEVEL SECURITY;--> statement-breakpoint
ALTER TABLE "annotations" ENABLE ROW LEVEL SECURITY;--> statement-breakpoint
ALTER TABLE "sync_operations" ENABLE ROW LEVEL SECURITY;--> statement-breakpoint
ALTER TABLE "mcp_client_grants" ENABLE ROW LEVEL SECURITY;--> statement-breakpoint
ALTER TABLE "daypage_runtime_config" ENABLE ROW LEVEL SECURITY;--> statement-breakpoint

DROP POLICY IF EXISTS "users_select_own" ON "users";--> statement-breakpoint
CREATE POLICY "users_select_own" ON "users" FOR SELECT TO authenticated
  USING (id = auth.uid());--> statement-breakpoint
DROP POLICY IF EXISTS "users_update_own" ON "users";--> statement-breakpoint
CREATE POLICY "users_update_own" ON "users" FOR UPDATE TO authenticated
  USING (id = auth.uid()) WITH CHECK (id = auth.uid());--> statement-breakpoint

DROP POLICY IF EXISTS "memos_select_own" ON "memos";--> statement-breakpoint
CREATE POLICY "memos_select_own" ON "memos" FOR SELECT TO authenticated
  USING (user_id = auth.uid());--> statement-breakpoint
DROP POLICY IF EXISTS "memos_insert_own" ON "memos";--> statement-breakpoint
CREATE POLICY "memos_insert_own" ON "memos" FOR INSERT TO authenticated
  WITH CHECK (user_id = auth.uid());--> statement-breakpoint
DROP POLICY IF EXISTS "memos_update_own" ON "memos";--> statement-breakpoint
CREATE POLICY "memos_update_own" ON "memos" FOR UPDATE TO authenticated
  USING (user_id = auth.uid()) WITH CHECK (user_id = auth.uid());--> statement-breakpoint
DROP POLICY IF EXISTS "memos_delete_own" ON "memos";--> statement-breakpoint
CREATE POLICY "memos_delete_own" ON "memos" FOR DELETE TO authenticated
  USING (user_id = auth.uid());--> statement-breakpoint

DROP POLICY IF EXISTS "memo_attachments_select_own" ON "memo_attachments";--> statement-breakpoint
CREATE POLICY "memo_attachments_select_own" ON "memo_attachments" FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.memos
    WHERE memos.id = memo_attachments.memo_id AND memos.user_id = auth.uid()
  ));--> statement-breakpoint
DROP POLICY IF EXISTS "memo_attachments_insert_own" ON "memo_attachments";--> statement-breakpoint
CREATE POLICY "memo_attachments_insert_own" ON "memo_attachments" FOR INSERT TO authenticated
  WITH CHECK (EXISTS (
    SELECT 1 FROM public.memos
    WHERE memos.id = memo_attachments.memo_id AND memos.user_id = auth.uid()
  ));--> statement-breakpoint
DROP POLICY IF EXISTS "memo_attachments_update_own" ON "memo_attachments";--> statement-breakpoint
CREATE POLICY "memo_attachments_update_own" ON "memo_attachments" FOR UPDATE TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.memos
    WHERE memos.id = memo_attachments.memo_id AND memos.user_id = auth.uid()
  )) WITH CHECK (EXISTS (
    SELECT 1 FROM public.memos
    WHERE memos.id = memo_attachments.memo_id AND memos.user_id = auth.uid()
  ));--> statement-breakpoint
DROP POLICY IF EXISTS "memo_attachments_delete_own" ON "memo_attachments";--> statement-breakpoint
CREATE POLICY "memo_attachments_delete_own" ON "memo_attachments" FOR DELETE TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.memos
    WHERE memos.id = memo_attachments.memo_id AND memos.user_id = auth.uid()
  ));--> statement-breakpoint

DROP POLICY IF EXISTS "pages_owner_all" ON "pages";--> statement-breakpoint
CREATE POLICY "pages_owner_all" ON "pages" FOR ALL TO authenticated
  USING (user_id = auth.uid()) WITH CHECK (user_id = auth.uid());--> statement-breakpoint
DROP POLICY IF EXISTS "domains_owner_all" ON "domains";--> statement-breakpoint
CREATE POLICY "domains_owner_all" ON "domains" FOR ALL TO authenticated
  USING (user_id = auth.uid()) WITH CHECK (user_id = auth.uid());--> statement-breakpoint
DROP POLICY IF EXISTS "page_links_owner_all" ON "page_links";--> statement-breakpoint
CREATE POLICY "page_links_owner_all" ON "page_links" FOR ALL TO authenticated
  USING (user_id = auth.uid()) WITH CHECK (user_id = auth.uid());--> statement-breakpoint
DROP POLICY IF EXISTS "annotations_owner_all" ON "annotations";--> statement-breakpoint
CREATE POLICY "annotations_owner_all" ON "annotations" FOR ALL TO authenticated
  USING (user_id = auth.uid()) WITH CHECK (user_id = auth.uid());--> statement-breakpoint

DROP POLICY IF EXISTS "page_sources_select_own" ON "page_sources";--> statement-breakpoint
CREATE POLICY "page_sources_select_own" ON "page_sources" FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.pages
    WHERE pages.id = page_sources.page_id AND pages.user_id = auth.uid()
  ));--> statement-breakpoint
DROP POLICY IF EXISTS "page_sources_insert_own" ON "page_sources";--> statement-breakpoint
CREATE POLICY "page_sources_insert_own" ON "page_sources" FOR INSERT TO authenticated
  WITH CHECK (
    EXISTS (SELECT 1 FROM public.pages WHERE pages.id = page_sources.page_id AND pages.user_id = auth.uid())
    AND EXISTS (SELECT 1 FROM public.memos WHERE memos.id = page_sources.memo_id AND memos.user_id = auth.uid())
  );--> statement-breakpoint
DROP POLICY IF EXISTS "page_sources_delete_own" ON "page_sources";--> statement-breakpoint
CREATE POLICY "page_sources_delete_own" ON "page_sources" FOR DELETE TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.pages
    WHERE pages.id = page_sources.page_id AND pages.user_id = auth.uid()
  ));--> statement-breakpoint

DROP POLICY IF EXISTS "sync_operations_owner_all" ON "sync_operations";--> statement-breakpoint
CREATE POLICY "sync_operations_owner_all" ON "sync_operations" FOR ALL TO authenticated
  USING (user_id = auth.uid()) WITH CHECK (user_id = auth.uid());--> statement-breakpoint
DROP POLICY IF EXISTS "mcp_client_grants_owner_all" ON "mcp_client_grants";--> statement-breakpoint
CREATE POLICY "mcp_client_grants_owner_all" ON "mcp_client_grants" FOR ALL TO authenticated
  USING (user_id = auth.uid()) WITH CHECK (user_id = auth.uid());--> statement-breakpoint

GRANT SELECT, INSERT, UPDATE, DELETE ON public.memos TO authenticated;--> statement-breakpoint
GRANT SELECT, INSERT, UPDATE, DELETE ON public.memo_attachments TO authenticated;--> statement-breakpoint
GRANT SELECT ON public.pages, public.domains, public.page_links, public.page_sources TO authenticated;--> statement-breakpoint
GRANT SELECT, INSERT, UPDATE, DELETE ON public.sync_operations TO authenticated;--> statement-breakpoint
GRANT SELECT, INSERT, UPDATE, DELETE ON public.mcp_client_grants TO authenticated;--> statement-breakpoint

-- Applies at most 100 outbox operations under the caller's RLS identity. A receipt is
-- written for applied and stale operations so client retries can be acknowledged exactly.
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

      SELECT status INTO v_status
      FROM public.sync_operations
      WHERE user_id = v_user_id AND operation_id = v_operation_id;

      IF FOUND THEN
        SELECT sync_revision INTO v_remote_revision
        FROM public.memos WHERE id = v_memo_id AND user_id = v_user_id;
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

CREATE OR REPLACE FUNCTION public.daypage_pull_memo_changes(
  p_after timestamptz DEFAULT '1970-01-01T00:00:00Z'::timestamptz,
  p_limit integer DEFAULT 200
)
RETURNS SETOF public.memos
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
  SELECT memos.*
  FROM public.memos
  WHERE memos.user_id = auth.uid() AND memos.updated_at > p_after
  ORDER BY memos.updated_at ASC, memos.id ASC
  LIMIT LEAST(GREATEST(p_limit, 1), 500)
$$;--> statement-breakpoint
REVOKE ALL ON FUNCTION public.daypage_pull_memo_changes(timestamptz, integer) FROM PUBLIC;--> statement-breakpoint
GRANT EXECUTE ON FUNCTION public.daypage_pull_memo_changes(timestamptz, integer) TO authenticated;--> statement-breakpoint

-- The hook is inert until an operator sets daypage_runtime_config.mcp_resource and enables
-- it in Supabase Auth. Normal app sessions (no client_id) retain aud=authenticated.
CREATE OR REPLACE FUNCTION public.daypage_custom_access_token_hook(event jsonb)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  claims jsonb := event -> 'claims';
  resource text;
BEGIN
  IF COALESCE(claims ->> 'client_id', '') = '' THEN
    RETURN event;
  END IF;

  SELECT value INTO resource
  FROM public.daypage_runtime_config
  WHERE key = 'mcp_resource';

  IF COALESCE(resource, '') = '' THEN
    RETURN event;
  END IF;

  claims := jsonb_set(claims, '{aud}', jsonb_build_array('authenticated', resource), true);
  claims := jsonb_set(claims, '{daypage_mcp_resource}', to_jsonb(resource), true);
  RETURN jsonb_set(event, '{claims}', claims, true);
END;
$$;--> statement-breakpoint

REVOKE ALL ON FUNCTION public.daypage_custom_access_token_hook(jsonb) FROM PUBLIC, anon, authenticated;--> statement-breakpoint
GRANT USAGE ON SCHEMA public TO supabase_auth_admin;--> statement-breakpoint
GRANT SELECT ON public.daypage_runtime_config TO supabase_auth_admin;--> statement-breakpoint
GRANT EXECUTE ON FUNCTION public.daypage_custom_access_token_hook(jsonb) TO supabase_auth_admin;--> statement-breakpoint
