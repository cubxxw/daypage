import { randomUUID } from "node:crypto";
import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import type { DayPageAuthContext } from "./auth.js";
import type { DayPageMcpConfig } from "./config.js";

export interface McpClientGrant {
  canRead: boolean;
  canWrite: boolean;
}

export interface MemoRecord {
  id: string;
  body: string;
  type: string;
  origin: string;
  created_at: string;
  updated_at: string;
  deleted_at: string | null;
}

export interface PageRecord {
  id: string;
  slug: string;
  title: string;
  type: string;
  status: string;
  body_md: string | null;
  updated_at: string;
}

export interface SearchResults {
  memos: MemoRecord[];
  pages: PageRecord[];
}

export interface DayPageRepository {
  getGrant(clientId: string): Promise<McpClientGrant>;
  listRecent(limit: number, before?: string): Promise<MemoRecord[]>;
  getMemo(id: string): Promise<MemoRecord | null>;
  search(query: string, limit: number): Promise<SearchResults>;
  getPage(slug: string): Promise<PageRecord | null>;
  addMemo(text: string): Promise<MemoRecord>;
}

export class RepositoryError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "RepositoryError";
  }
}

function assertData<T>(data: T | null, error: { message: string } | null, operation: string): T {
  if (error) throw new RepositoryError(`${operation} failed: ${error.message}`);
  if (data === null) throw new RepositoryError(`${operation} returned no data`);
  return data;
}

function escapeLike(value: string): string {
  return value.replace(/[\\%_]/g, (match) => `\\${match}`);
}

class SupabaseDayPageRepository implements DayPageRepository {
  constructor(
    private readonly client: SupabaseClient,
    private readonly auth: DayPageAuthContext,
  ) {}

  async getGrant(clientId: string): Promise<McpClientGrant> {
    const { data, error } = await this.client
      .from("mcp_client_grants")
      .select("can_read,can_write")
      .eq("client_id", clientId)
      .is("revoked_at", null)
      .maybeSingle();
    if (error) throw new RepositoryError(`grant lookup failed: ${error.message}`);
    return { canRead: data?.can_read === true, canWrite: data?.can_write === true };
  }

  async listRecent(limit: number, before?: string): Promise<MemoRecord[]> {
    let query = this.client
      .from("memos")
      .select("id,body,type,origin,created_at,updated_at,deleted_at")
      .is("deleted_at", null)
      .order("created_at", { ascending: false })
      .limit(limit);
    if (before) query = query.lt("created_at", before);
    const { data, error } = await query;
    return assertData(data as MemoRecord[] | null, error, "list recent memos");
  }

  async getMemo(id: string): Promise<MemoRecord | null> {
    const { data, error } = await this.client
      .from("memos")
      .select("id,body,type,origin,created_at,updated_at,deleted_at")
      .eq("id", id)
      .is("deleted_at", null)
      .maybeSingle();
    if (error) throw new RepositoryError(`get memo failed: ${error.message}`);
    return data as MemoRecord | null;
  }

  async search(queryText: string, limit: number): Promise<SearchResults> {
    const pattern = `%${escapeLike(queryText)}%`;
    const [memoResponse, pageTitleResponse, pageBodyResponse] = await Promise.all([
      this.client
        .from("memos")
        .select("id,body,type,origin,created_at,updated_at,deleted_at")
        .is("deleted_at", null)
        .ilike("body", pattern)
        .order("created_at", { ascending: false })
        .limit(limit),
      this.client
        .from("pages")
        .select("id,slug,title,type,status,body_md,updated_at")
        .ilike("title", pattern)
        .order("updated_at", { ascending: false })
        .limit(limit),
      this.client
        .from("pages")
        .select("id,slug,title,type,status,body_md,updated_at")
        .ilike("body_md", pattern)
        .order("updated_at", { ascending: false })
        .limit(limit),
    ]);
    const titlePages = assertData(
      pageTitleResponse.data as PageRecord[] | null,
      pageTitleResponse.error,
      "search page titles",
    );
    const bodyPages = assertData(
      pageBodyResponse.data as PageRecord[] | null,
      pageBodyResponse.error,
      "search page bodies",
    );
    const pages = [...titlePages, ...bodyPages]
      .filter((page, index, all) => all.findIndex((candidate) => candidate.id === page.id) === index)
      .sort((a, b) => b.updated_at.localeCompare(a.updated_at))
      .slice(0, limit);
    return {
      memos: assertData(memoResponse.data as MemoRecord[] | null, memoResponse.error, "search memos"),
      pages,
    };
  }

  async getPage(slug: string): Promise<PageRecord | null> {
    const { data, error } = await this.client
      .from("pages")
      .select("id,slug,title,type,status,body_md,updated_at")
      .eq("slug", slug)
      .maybeSingle();
    if (error) throw new RepositoryError(`get page failed: ${error.message}`);
    return data as PageRecord | null;
  }

  async addMemo(text: string): Promise<MemoRecord> {
    const now = new Date().toISOString();
    const { data, error } = await this.client
      .from("memos")
      .insert({
        user_id: this.auth.subject,
        type: "text",
        body: text,
        origin: "api",
        source: "mcp",
        ingest_mode: "light",
        compile_status: "pending",
        idempotency_key: `mcp:${this.auth.clientId}:${randomUUID()}`,
        created_at: now,
        updated_at: now,
      })
      .select("id,body,type,origin,created_at,updated_at,deleted_at")
      .single();
    return assertData(data as MemoRecord | null, error, "add memo");
  }
}

export function createSupabaseRepository(
  config: DayPageMcpConfig,
  auth: DayPageAuthContext,
): DayPageRepository {
  const client = createClient(config.supabaseUrl, config.supabaseAnonKey, {
    auth: { autoRefreshToken: false, detectSessionInUrl: false, persistSession: false },
    global: { headers: { Authorization: `Bearer ${auth.token}` } },
  });
  return new SupabaseDayPageRepository(client, auth);
}
