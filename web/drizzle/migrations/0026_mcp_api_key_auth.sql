-- #873: revocable DayPage personal access tokens for Cloud MCP.
--
-- The Edge Function receives a raw PAT, hashes it with SHA-256, and sends only
-- the hash to this function. This function is the sole anon-accessible path to
-- PAT-owned data. It uses fixed queries, rechecks expiry/revocation/scopes on
-- every operation, and never exposes api_keys or a service-role credential.

ALTER TABLE public.api_keys
  ADD COLUMN IF NOT EXISTS revoked_at timestamp with time zone;--> statement-breakpoint

ALTER TABLE public.api_keys ENABLE ROW LEVEL SECURITY;--> statement-breakpoint
REVOKE ALL ON public.api_keys FROM PUBLIC, anon, authenticated;--> statement-breakpoint

CREATE OR REPLACE FUNCTION public.daypage_mcp_api_key_request(
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
  v_expires_at timestamptz;
  v_can_read boolean;
  v_can_write boolean;
  v_limit integer;
  v_before timestamptz;
  v_query text;
  v_pattern text;
  v_slug text;
  v_text text;
  v_result jsonb;
  v_memos jsonb;
  v_pages jsonb;
BEGIN
  IF p_key_hash IS NULL OR p_key_hash !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'invalid API key' USING ERRCODE = '28000';
  END IF;
  IF p_arguments IS NULL OR jsonb_typeof(p_arguments) <> 'object' THEN
    RAISE EXCEPTION 'p_arguments must be an object' USING ERRCODE = '22023';
  END IF;

  SELECT api_keys.id, api_keys.user_id, api_keys.scopes, api_keys.expires_at
  INTO v_key_id, v_user_id, v_scopes, v_expires_at
  FROM public.api_keys
  WHERE api_keys.key_hash = p_key_hash
    AND api_keys.revoked_at IS NULL
    AND (api_keys.expires_at IS NULL OR api_keys.expires_at > now())
  LIMIT 1;

  IF v_key_id IS NULL THEN
    RAISE EXCEPTION 'invalid or expired API key' USING ERRCODE = '28000';
  END IF;

  v_can_read := COALESCE(v_scopes ? 'read' OR v_scopes ? 'admin', false);
  v_can_write := COALESCE(v_scopes ? 'write' OR v_scopes ? 'admin', false);

  UPDATE public.api_keys SET last_used_at = now() WHERE id = v_key_id;

  IF p_operation = 'resolve' THEN
    RETURN jsonb_build_object(
      'key_id', v_key_id,
      'user_id', v_user_id,
      'scopes', v_scopes,
      'can_read', v_can_read,
      'can_write', v_can_write,
      'expires_at', v_expires_at
    );
  END IF;

  IF NOT v_can_read THEN
    RAISE EXCEPTION 'API key lacks read scope' USING ERRCODE = '42501';
  END IF;

  IF p_operation = 'list_recent' THEN
    v_limit := LEAST(GREATEST(COALESCE((p_arguments ->> 'limit')::integer, 10), 1), 50);
    v_before := NULLIF(p_arguments ->> 'before', '')::timestamptz;
    SELECT COALESCE(jsonb_agg(to_jsonb(memo_row) ORDER BY memo_row.created_at DESC), '[]'::jsonb)
    INTO v_result
    FROM (
      SELECT id, body, type::text AS type, origin::text AS origin,
             created_at, updated_at, deleted_at
      FROM public.memos
      WHERE user_id = v_user_id
        AND deleted_at IS NULL
        AND (v_before IS NULL OR created_at < v_before)
      ORDER BY created_at DESC
      LIMIT v_limit
    ) AS memo_row;
    RETURN v_result;
  END IF;

  IF p_operation = 'get_memo' THEN
    SELECT to_jsonb(memo_row)
    INTO v_result
    FROM (
      SELECT id, body, type::text AS type, origin::text AS origin,
             created_at, updated_at, deleted_at
      FROM public.memos
      WHERE user_id = v_user_id
        AND id = (p_arguments ->> 'id')::uuid
        AND deleted_at IS NULL
      LIMIT 1
    ) AS memo_row;
    RETURN COALESCE(v_result, 'null'::jsonb);
  END IF;

  IF p_operation = 'search' THEN
    v_query := btrim(COALESCE(p_arguments ->> 'query', ''));
    IF v_query = '' OR length(v_query) > 200 THEN
      RAISE EXCEPTION 'query must contain 1 to 200 characters' USING ERRCODE = '22023';
    END IF;
    v_limit := LEAST(GREATEST(COALESCE((p_arguments ->> 'limit')::integer, 8), 1), 20);
    v_pattern := '%' || replace(replace(replace(v_query, E'\\', E'\\\\'), '%', E'\\%'), '_', E'\\_') || '%';

    SELECT COALESCE(jsonb_agg(to_jsonb(memo_row) ORDER BY memo_row.created_at DESC), '[]'::jsonb)
    INTO v_memos
    FROM (
      SELECT id, body, type::text AS type, origin::text AS origin,
             created_at, updated_at, deleted_at
      FROM public.memos
      WHERE user_id = v_user_id
        AND deleted_at IS NULL
        AND body ILIKE v_pattern ESCAPE E'\\'
      ORDER BY created_at DESC
      LIMIT v_limit
    ) AS memo_row;

    SELECT COALESCE(jsonb_agg(to_jsonb(page_row) ORDER BY page_row.updated_at DESC), '[]'::jsonb)
    INTO v_pages
    FROM (
      SELECT id, slug, title, type::text AS type, status::text AS status,
             body_md, updated_at
      FROM public.pages
      WHERE user_id = v_user_id
        AND (title ILIKE v_pattern ESCAPE E'\\' OR COALESCE(body_md, '') ILIKE v_pattern ESCAPE E'\\')
      ORDER BY updated_at DESC
      LIMIT v_limit
    ) AS page_row;

    RETURN jsonb_build_object('memos', v_memos, 'pages', v_pages);
  END IF;

  IF p_operation = 'get_page' THEN
    v_slug := btrim(COALESCE(p_arguments ->> 'slug', ''));
    SELECT to_jsonb(page_row)
    INTO v_result
    FROM (
      SELECT id, slug, title, type::text AS type, status::text AS status,
             body_md, updated_at
      FROM public.pages
      WHERE user_id = v_user_id AND slug = v_slug
      LIMIT 1
    ) AS page_row;
    RETURN COALESCE(v_result, 'null'::jsonb);
  END IF;

  IF p_operation = 'add_memo' THEN
    IF NOT v_can_write THEN
      RAISE EXCEPTION 'API key lacks write scope' USING ERRCODE = '42501';
    END IF;
    v_text := btrim(COALESCE(p_arguments ->> 'text', ''));
    IF v_text = '' OR length(v_text) > 10000 THEN
      RAISE EXCEPTION 'memo text must contain 1 to 10000 characters' USING ERRCODE = '22023';
    END IF;

    INSERT INTO public.memos (
      user_id, type, body, origin, source, ingest_mode, compile_status,
      idempotency_key, created_at, updated_at
    ) VALUES (
      v_user_id, 'text'::public.memo_type, v_text, 'api'::public.origin,
      'mcp', 'light'::public.ingest_mode, 'pending'::public.compile_status,
      format('mcp-pat:%s:%s', v_key_id, gen_random_uuid()), now(), now()
    )
    RETURNING jsonb_build_object(
      'id', id,
      'body', body,
      'type', type::text,
      'origin', origin::text,
      'created_at', created_at,
      'updated_at', updated_at,
      'deleted_at', deleted_at
    ) INTO v_result;
    RETURN v_result;
  END IF;

  RAISE EXCEPTION 'unsupported API key operation' USING ERRCODE = '22023';
END;
$$;--> statement-breakpoint

REVOKE ALL ON FUNCTION public.daypage_mcp_api_key_request(text, text, jsonb)
  FROM PUBLIC, authenticated;--> statement-breakpoint
GRANT EXECUTE ON FUNCTION public.daypage_mcp_api_key_request(text, text, jsonb)
  TO anon;--> statement-breakpoint
