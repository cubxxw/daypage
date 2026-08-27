import { randomUUID } from "node:crypto";
import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { canonicalSystemActionJson } from "../../contracts/system-action-hash.mjs";
import type { DayPageAuthContext } from "./auth.js";
import type { DayPageMcpConfig } from "./config.js";

export interface McpClientGrant {
  canRead: boolean;
  canWrite: boolean;
  canReadActions: boolean;
  canProposeActions: boolean;
}

export type SystemActionState =
  | "pending" | "approved" | "rejected" | "executing" | "completed"
  | "failed" | "cancelled" | "needs_review";

export interface ActionSourceReference {
  kind: "memo" | "daily_page" | "entity" | "place" | "system_entry";
  id: string;
}

export interface ActionProposalInput {
  payload: Record<string, unknown> & { kind: string };
  title: string;
  rationale?: string;
  source_refs?: ActionSourceReference[];
  redaction_level: "private" | "sensitive" | "summary";
  target_device_preference: "any";
  target_device_id_hash?: null;
  expires_at?: string | null;
}

export interface ActionProposalRecord extends ActionProposalInput {
  schema_version: 1;
  proposal_id: string;
  revision: number;
  kind: string;
  payload_hash: string;
  rationale: string;
  source_refs: ActionSourceReference[];
  creator_source: "mcp";
  creator_device_id_hash: null;
  state: SystemActionState;
  target_device_id_hash: null;
  created_at: string;
  expires_at: string | null;
  deleted_at: string | null;
}

export type ActionProposalView = Pick<
  ActionProposalRecord,
  | "proposal_id" | "revision" | "kind" | "payload" | "payload_hash"
  | "title" | "rationale" | "source_refs" | "redaction_level"
  | "target_device_preference" | "state" | "created_at" | "expires_at"
>;

export interface ActionReceiptRecord {
  receipt_id: string;
  proposal_id: string;
  schema_version: 1;
  phase: "execute" | "undo";
  proposal_revision: number;
  payload_hash: string;
  attempt: number;
  outcome: "succeeded" | "failed" | "cancelled" | "ambiguous";
  device_id_hash: string;
  execution_mode: "online_lease" | "offline_owner";
  lease_id: string | null;
  result: Record<string, unknown>;
  error_code: string | null;
  reconciliation_state: "confirmed" | "pending" | "needs_review" | "not_applicable";
  undo_capability: "reversible" | "compensating" | "manual" | "none";
  external_id_hash: string | null;
  started_at: string;
  completed_at: string;
}

export type ActionReceiptView = Pick<
  ActionReceiptRecord,
  | "receipt_id" | "proposal_id" | "phase" | "proposal_revision" | "attempt" | "outcome"
  | "result" | "error_code" | "reconciliation_state" | "undo_capability"
  | "completed_at"
>;

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
  proposeAction(input: ActionProposalInput): Promise<ActionProposalRecord>;
  listActionProposals(limit: number, state?: SystemActionState): Promise<ActionProposalView[]>;
  listActionReceipts(limit: number): Promise<ActionReceiptView[]>;
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

async function sha256Hex(value: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

export function systemActionPayloadHash(payload: Record<string, unknown>): Promise<string> {
  return sha256Hex(canonicalSystemActionJson(payload));
}

async function makeMcpProposal(input: ActionProposalInput): Promise<ActionProposalRecord> {
  const now = new Date().toISOString();
  return {
    ...input,
    schema_version: 1,
    proposal_id: randomUUID(),
    revision: 1,
    kind: input.payload.kind,
    payload_hash: await systemActionPayloadHash(input.payload),
    rationale: input.rationale ?? "",
    source_refs: input.source_refs ?? [],
    creator_source: "mcp",
    creator_device_id_hash: null,
    state: "pending",
    target_device_id_hash: input.target_device_id_hash ?? null,
    created_at: now,
    expires_at: input.expires_at ?? null,
    deleted_at: null,
  };
}

interface ActionApplyResult {
  accepted: Array<{ record: ActionProposalRecord }>;
  rejected: Array<{ reason: string }>;
}

class SupabaseDayPageRepository implements DayPageRepository {
  constructor(
    private readonly client: SupabaseClient,
    private readonly auth: DayPageAuthContext,
  ) {}

  async getGrant(clientId: string): Promise<McpClientGrant> {
    const { data, error } = await this.client
      .from("mcp_client_grants")
      .select("can_read,can_write,can_read_actions,can_propose_actions")
      .eq("client_id", clientId)
      .is("revoked_at", null)
      .maybeSingle();
    if (error) throw new RepositoryError(`grant lookup failed: ${error.message}`);
    return {
      canRead: data?.can_read === true,
      canWrite: data?.can_write === true,
      canReadActions: data?.can_read_actions === true,
      canProposeActions: data?.can_propose_actions === true,
    };
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

  async proposeAction(input: ActionProposalInput): Promise<ActionProposalRecord> {
    const proposal = await makeMcpProposal(input);
    const { data, error } = await this.client.rpc("daypage_mcp_propose_system_action_v1", {
      p_operation_id: randomUUID(),
      p_proposal: proposal,
    });
    const result = assertData(data as ActionApplyResult | null, error, "propose action");
    const accepted = result.accepted[0]?.record;
    if (!accepted || result.rejected.length > 0) {
      throw new RepositoryError(`propose action rejected: ${result.rejected[0]?.reason ?? "unknown"}`);
    }
    return accepted;
  }

  async listActionProposals(limit: number, state?: SystemActionState): Promise<ActionProposalView[]> {
    const { data, error } = await this.client.rpc("daypage_mcp_list_system_action_proposals_v1", {
      p_limit: limit,
      p_state: state ?? null,
    });
    return assertData(data as ActionProposalView[] | null, error, "list action proposals");
  }

  async listActionReceipts(limit: number): Promise<ActionReceiptView[]> {
    const { data, error } = await this.client.rpc("daypage_mcp_list_system_action_receipts_v1", {
      p_limit: limit,
    });
    return assertData(data as ActionReceiptView[] | null, error, "list action receipts");
  }
}

class ApiKeyDayPageRepository implements DayPageRepository {
  private readonly client: SupabaseClient;
  private readonly keyHash: string;

  constructor(config: DayPageMcpConfig, private readonly auth: DayPageAuthContext) {
    if (auth.authType !== "api_key" || !auth.apiKey) {
      throw new RepositoryError("API key repository requires API key authentication");
    }
    this.keyHash = auth.apiKey.hash;
    this.client = createClient(config.supabaseUrl, config.supabaseAnonKey, {
      auth: { autoRefreshToken: false, detectSessionInUrl: false, persistSession: false },
    });
  }

  private async execute<T>(operation: string, args: Record<string, unknown> = {}): Promise<T> {
    const { data, error } = await this.client.rpc("daypage_mcp_api_key_request", {
      p_key_hash: this.keyHash,
      p_operation: operation,
      p_arguments: args,
    });
    if (error) throw new RepositoryError(`${operation} failed: ${error.message}`);
    return data as T;
  }

  async getGrant(): Promise<McpClientGrant> {
    const actionGrant = await this.executeAction<{ can_read_actions: boolean; can_propose_actions: boolean }>(
      "resolve_grant",
    );
    return {
      canRead: this.auth.apiKey?.canRead === true,
      canWrite: this.auth.apiKey?.canWrite === true,
      canReadActions: actionGrant.can_read_actions === true,
      canProposeActions: actionGrant.can_propose_actions === true,
    };
  }

  private async executeAction<T>(operation: string, args: Record<string, unknown> = {}): Promise<T> {
    const { data, error } = await this.client.rpc("daypage_mcp_action_api_key_request_v1", {
      p_key_hash: this.keyHash,
      p_operation: operation,
      p_arguments: args,
    });
    if (error) throw new RepositoryError(`${operation} failed: ${error.message}`);
    return data as T;
  }

  async listRecent(limit: number, before?: string): Promise<MemoRecord[]> {
    return this.execute<MemoRecord[]>("list_recent", { limit, before: before ?? null });
  }

  async getMemo(id: string): Promise<MemoRecord | null> {
    return this.execute<MemoRecord | null>("get_memo", { id });
  }

  async search(query: string, limit: number): Promise<SearchResults> {
    return this.execute<SearchResults>("search", { query, limit });
  }

  async getPage(slug: string): Promise<PageRecord | null> {
    return this.execute<PageRecord | null>("get_page", { slug });
  }

  async addMemo(text: string): Promise<MemoRecord> {
    return this.execute<MemoRecord>("add_memo", { text });
  }

  async proposeAction(input: ActionProposalInput): Promise<ActionProposalRecord> {
    const proposal = await makeMcpProposal(input);
    const result = await this.executeAction<ActionApplyResult>("propose_action", {
      operation_id: randomUUID(),
      proposal,
    });
    const accepted = result.accepted[0]?.record;
    if (!accepted || result.rejected.length > 0) {
      throw new RepositoryError(`propose action rejected: ${result.rejected[0]?.reason ?? "unknown"}`);
    }
    return accepted;
  }

  async listActionProposals(limit: number, state?: SystemActionState): Promise<ActionProposalView[]> {
    return this.executeAction<ActionProposalView[]>("list_action_proposals", { limit, state: state ?? null });
  }

  async listActionReceipts(limit: number): Promise<ActionReceiptView[]> {
    return this.executeAction<ActionReceiptView[]>("list_action_receipts", { limit });
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

export function createDayPageRepository(
  config: DayPageMcpConfig,
  auth: DayPageAuthContext,
): DayPageRepository {
  return auth.authType === "api_key"
    ? new ApiKeyDayPageRepository(config, auth)
    : createSupabaseRepository(config, auth);
}
