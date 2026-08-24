-- #873: monotonic, account-scoped incremental pull for native multi-device sync.
--
-- `updated_at` is not a safe cursor: client clocks can move backwards and a
-- page boundary can split rows with the same timestamp. This server-owned
-- sequence changes on every user-visible memo mutation and gives each device a
-- durable integer cursor. RLS remains the tenant boundary.

CREATE SEQUENCE IF NOT EXISTS public.daypage_memo_change_sequence AS bigint;--> statement-breakpoint
GRANT USAGE, SELECT ON SEQUENCE public.daypage_memo_change_sequence TO authenticated;--> statement-breakpoint

ALTER TABLE public.memos
  ADD COLUMN IF NOT EXISTS sync_change_sequence bigint;--> statement-breakpoint
ALTER TABLE public.memos
  ALTER COLUMN sync_change_sequence SET DEFAULT nextval('public.daypage_memo_change_sequence');--> statement-breakpoint
UPDATE public.memos
SET sync_change_sequence = nextval('public.daypage_memo_change_sequence')
WHERE sync_change_sequence IS NULL;--> statement-breakpoint
ALTER TABLE public.memos
  ALTER COLUMN sync_change_sequence SET NOT NULL;--> statement-breakpoint

CREATE INDEX IF NOT EXISTS memos_user_sync_change_sequence
  ON public.memos (user_id, sync_change_sequence);--> statement-breakpoint

CREATE OR REPLACE FUNCTION public.daypage_bump_memo_change_sequence()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.sync_change_sequence IS NULL THEN
      NEW.sync_change_sequence := nextval('public.daypage_memo_change_sequence');
    END IF;
  ELSIF ROW(
    NEW.type, NEW.body, NEW.created_at, NEW.pinned_at, NEW.location, NEW.weather,
    NEW.device, NEW.source, NEW.vault_path, NEW.mood, NEW.source_modified_at,
    NEW.content_hash, NEW.sync_revision, NEW.last_sync_device_id, NEW.deleted_at
  ) IS DISTINCT FROM ROW(
    OLD.type, OLD.body, OLD.created_at, OLD.pinned_at, OLD.location, OLD.weather,
    OLD.device, OLD.source, OLD.vault_path, OLD.mood, OLD.source_modified_at,
    OLD.content_hash, OLD.sync_revision, OLD.last_sync_device_id, OLD.deleted_at
  ) THEN
    NEW.sync_change_sequence := nextval('public.daypage_memo_change_sequence');
  END IF;
  RETURN NEW;
END;
$$;--> statement-breakpoint

DROP TRIGGER IF EXISTS daypage_memos_change_sequence ON public.memos;--> statement-breakpoint
CREATE TRIGGER daypage_memos_change_sequence
BEFORE INSERT OR UPDATE ON public.memos
FOR EACH ROW EXECUTE FUNCTION public.daypage_bump_memo_change_sequence();--> statement-breakpoint

CREATE OR REPLACE FUNCTION public.daypage_pull_sync_changes(
  p_after_sequence bigint DEFAULT 0,
  p_limit integer DEFAULT 200
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = public
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
    COALESCE(jsonb_agg(to_jsonb(change_row) ORDER BY change_row.change_sequence), '[]'::jsonb),
    COALESCE(max(change_row.change_sequence), v_after)
  INTO v_changes, v_next_cursor
  FROM (
    SELECT
      id,
      type::text AS type,
      body,
      created_at,
      pinned_at,
      location,
      weather,
      device,
      source,
      vault_path,
      source_modified_at,
      content_hash,
      sync_revision,
      last_sync_device_id,
      deleted_at,
      sync_change_sequence AS change_sequence
    FROM public.memos
    WHERE user_id = v_user_id
      AND sync_change_sequence > v_after
    ORDER BY sync_change_sequence ASC
    LIMIT v_limit
  ) AS change_row;

  SELECT EXISTS (
    SELECT 1
    FROM public.memos
    WHERE user_id = v_user_id
      AND sync_change_sequence > v_next_cursor
  ) INTO v_has_more;

  RETURN jsonb_build_object(
    'changes', v_changes,
    'next_cursor', v_next_cursor,
    'has_more', v_has_more
  );
END;
$$;--> statement-breakpoint

REVOKE ALL ON FUNCTION public.daypage_pull_sync_changes(bigint, integer) FROM PUBLIC;--> statement-breakpoint
GRANT EXECUTE ON FUNCTION public.daypage_pull_sync_changes(bigint, integer) TO authenticated;--> statement-breakpoint
