import { McpServer, ResourceTemplate } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod/v4";
import type { DayPageAuthContext } from "./auth.js";
import type { DayPageMcpConfig } from "./config.js";
import type { DayPageRepository, McpClientGrant, MemoRecord, PageRecord } from "./repository.js";

const readAnnotations = {
  readOnlyHint: true,
  destructiveHint: false,
  idempotentHint: true,
  openWorldHint: false,
} as const;

function memoSummary(memo: MemoRecord) {
  return {
    id: memo.id,
    body: memo.body,
    type: memo.type,
    origin: memo.origin,
    created_at: memo.created_at,
    updated_at: memo.updated_at,
  };
}

function pageSummary(page: PageRecord, config: DayPageMcpConfig) {
  return {
    ...page,
    body_md: page.body_md ?? "",
    url: `${config.appBaseUrl}/wiki/${encodeURIComponent(page.slug)}`,
  };
}

function preview(text: string, max = 180): string {
  const compact = text.replace(/\s+/g, " ").trim();
  return compact.length > max ? `${compact.slice(0, max)}…` : compact;
}

function textResult(text: string, structuredContent: Record<string, unknown>) {
  return { content: [{ type: "text" as const, text }], structuredContent };
}

export function createDayPageMcpServer(
  config: DayPageMcpConfig,
  auth: DayPageAuthContext,
  grant: McpClientGrant,
  repository: DayPageRepository,
): McpServer {
  const server = new McpServer(
    { name: "daypage-cloud", version: "0.2.0" },
    {
      instructions:
        "DayPage is the user's private local-first memory. Read only the minimum needed, preserve chronology, and distinguish user-authored memo text from compiled wiki pages. Never imply that a write succeeded unless the tool returns the saved memo ID.",
    },
  );

  if (!grant.canRead) return server;

  server.registerTool(
    "daypage_list_recent",
    {
      title: "List recent DayPage memos",
      description: "List the user's most recent non-deleted memos in reverse chronological order.",
      inputSchema: {
        limit: z.number().int().min(1).max(50).default(10),
        before: z.string().datetime({ offset: true }).optional(),
      },
      annotations: readAnnotations,
    },
    async ({ limit, before }) => {
      const memos = (await repository.listRecent(limit, before)).map(memoSummary);
      const nextCursor = memos.length === limit ? memos[memos.length - 1]?.created_at ?? null : null;
      const text = memos.length
        ? memos.map((memo) => `${memo.created_at} · ${memo.id}\n${preview(memo.body)}`).join("\n\n")
        : "No memos found.";
      return textResult(text, { memos, next_cursor: nextCursor });
    },
  );

  server.registerTool(
    "daypage_search",
    {
      title: "Search DayPage",
      description: "Search the user's non-deleted memos and compiled wiki pages by text.",
      inputSchema: {
        query: z.string().trim().min(1).max(200),
        limit: z.number().int().min(1).max(20).default(8),
      },
      annotations: readAnnotations,
    },
    async ({ query, limit }) => {
      const result = await repository.search(query, limit);
      const memos = result.memos.map(memoSummary);
      const pages = result.pages.map((page) => pageSummary(page, config));
      const lines = [
        ...memos.map((memo) => `Memo ${memo.id}: ${preview(memo.body)}`),
        ...pages.map((page) => `Page ${page.title} (${page.slug}): ${preview(page.body_md)}`),
      ];
      return textResult(lines.join("\n") || `No DayPage results matched “${query}”.`, { query, memos, pages });
    },
  );

  server.registerTool(
    "daypage_get_memo",
    {
      title: "Get a DayPage memo",
      description: "Get one non-deleted memo by UUID.",
      inputSchema: { id: z.string().uuid() },
      annotations: readAnnotations,
    },
    async ({ id }) => {
      const memo = await repository.getMemo(id);
      if (!memo) return { content: [{ type: "text" as const, text: `Memo not found: ${id}` }], isError: true };
      const structured = memoSummary(memo);
      return textResult(`${structured.created_at} · ${structured.id}\n\n${structured.body}`, { memo: structured });
    },
  );

  server.registerTool(
    "daypage_get_page",
    {
      title: "Get a DayPage wiki page",
      description: "Get one compiled DayPage wiki page by slug.",
      inputSchema: { slug: z.string().trim().min(1).max(200) },
      annotations: readAnnotations,
    },
    async ({ slug }) => {
      const page = await repository.getPage(slug);
      if (!page) return { content: [{ type: "text" as const, text: `Page not found: ${slug}` }], isError: true };
      const structured = pageSummary(page, config);
      return textResult(`# ${structured.title}\n\n${structured.body_md}\n\n${structured.url}`, { page: structured });
    },
  );

  server.registerResource(
    "daypage-memo",
    new ResourceTemplate("daypage://memos/{id}", { list: undefined }),
    { title: "DayPage memo", description: "A private memo owned by the authenticated user", mimeType: "text/markdown" },
    async (uri, variables) => {
      const idValue = variables.id;
      const id = Array.isArray(idValue) ? idValue[0] : idValue;
      if (!id) throw new Error("Memo id is required");
      const memo = await repository.getMemo(id);
      if (!memo) throw new Error("Memo not found");
      return { contents: [{ uri: uri.href, mimeType: "text/markdown", text: memo.body }] };
    },
  );

  if (grant.canWrite) {
    server.registerTool(
      "daypage_add_memo",
      {
        title: "Add a DayPage memo",
        description: "Create a new memo in the authenticated user's DayPage cloud account.",
        inputSchema: { text: z.string().trim().min(1).max(10_000) },
        annotations: {
          readOnlyHint: false,
          destructiveHint: false,
          idempotentHint: false,
          openWorldHint: false,
        },
      },
      async ({ text }) => {
        const memo = memoSummary(await repository.addMemo(text));
        return textResult(`Saved DayPage memo ${memo.id}.`, { memo });
      },
    );
  }

  void auth;
  return server;
}
