import { McpServer, ResourceTemplate } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod/v4";
import { canonicalSystemActionNumber } from "../../contracts/system-action-hash.mjs";
import type { DayPageAuthContext } from "./auth.js";
import type { DayPageMcpConfig } from "./config.js";
import type {
  ActionProposalInput,
  ActionProposalView,
  ActionReceiptView,
  DayPageRepository,
  McpClientGrant,
  MemoRecord,
  PageRecord,
} from "./repository.js";

const readAnnotations = {
  readOnlyHint: true,
  destructiveHint: false,
  idempotentHint: true,
  openWorldHint: false,
} as const;

const canonicalTimestamp = z.string().regex(
  /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/,
).refine((value) => {
  const parsed = new Date(value);
  return !Number.isNaN(parsed.valueOf()) && parsed.toISOString() === value;
}, "timestamp must be a valid UTC millisecond instant");
const timestamp = canonicalTimestamp;
const nullableTimestamp = timestamp.nullable();
const utf8ByteLength = (value: string) => new TextEncoder().encode(value).byteLength;
const utf8Text = (maximum: number, required = false) => z.string().refine(
  (value) => utf8ByteLength(value) <= maximum
    && (!required || value.trim().length > 0),
  `text must ${required ? "be non-blank and " : ""}fit within ${maximum} UTF-8 bytes`,
);
const canonicalCoordinate = (minimum: number, maximum: number) => z.number()
  .min(minimum)
  .max(maximum)
  .refine((value) => {
    try {
      canonicalSystemActionNumber(value);
      return true;
    } catch {
      return false;
    }
  }, "coordinates require at most six decimal places");
const sourceReference = z.object({
  kind: z.enum(["memo", "daily_page", "entity", "place", "system_entry"]),
  id: utf8Text(160, true),
}).strict();
const actionPayload = z.discriminatedUnion("kind", [
  z.object({
    kind: z.literal("calendar_event"),
    title: utf8Text(160, true),
    start_at: timestamp,
    end_at: timestamp,
    all_day: z.boolean(),
    time_zone: utf8Text(64, true),
    location_label: utf8Text(240).nullable(),
    notes: utf8Text(2_000).nullable(),
  }).strict().refine((value) => value.end_at > value.start_at, {
    message: "calendar end_at must be after start_at",
    path: ["end_at"],
  }),
  z.object({
    kind: z.literal("reminder"),
    title: utf8Text(160, true),
    due_at: nullableTimestamp,
    time_zone: utf8Text(64).nullable(),
    priority: z.number().int().min(0).max(9),
    notes: utf8Text(2_000).nullable(),
  }).strict(),
  z.object({
    kind: z.literal("contact_draft"),
    given_name: utf8Text(100),
    family_name: utf8Text(100),
    organization: utf8Text(160).nullable(),
    phones: z.array(utf8Text(40, true)).max(5),
    emails: z.array(utf8Text(254, true).refine((value) => utf8ByteLength(value) >= 3)).max(5),
  }).strict().refine((value) => Boolean(
    value.given_name.trim() || value.family_name.trim() || value.organization?.trim(),
  ), {
    message: "a contact draft requires a name or organization",
  }),
  z.object({
    kind: z.literal("notification"),
    title: utf8Text(160, true),
    body: utf8Text(500),
    fire_at: timestamp,
    time_zone: utf8Text(64, true),
    interruption_level: z.enum(["passive", "active", "time_sensitive"]),
  }).strict(),
  z.object({
    kind: z.literal("route"),
    destination_label: utf8Text(240, true),
    destination_address: utf8Text(500, true).optional(),
    destination_latitude: canonicalCoordinate(-90, 90).optional(),
    destination_longitude: canonicalCoordinate(-180, 180).optional(),
    transport: z.enum(["any", "walking", "driving", "transit", "cycling"]),
  }).strict().superRefine((value, context) => {
    const hasAddress = value.destination_address !== undefined;
    const hasLatitude = value.destination_latitude !== undefined;
    const hasLongitude = value.destination_longitude !== undefined;
    if (hasLatitude !== hasLongitude) {
      context.addIssue({
        code: "custom",
        message: "a route requires both destination coordinates",
      });
    }
    if (hasAddress === (hasLatitude && hasLongitude)) {
      context.addIssue({
        code: "custom",
        message: "a route requires either an address or a coordinate pair",
      });
    }
  }),
  z.object({
    kind: z.literal("capture"),
    mode: z.enum(["text", "photo", "camera", "file", "scan", "ocr", "ink", "voice"]),
    destination: z.enum(["new_memo", "current_draft"]),
    suggested_title: utf8Text(200).nullable(),
  }).strict(),
  z.object({
    kind: z.literal("focus_session"),
    title: utf8Text(160, true),
    duration_seconds: z.number().int().min(60).max(86_400),
    schedule_end_alert: z.boolean(),
    allow_live_activity: z.boolean(),
  }).strict(),
  z.object({
    kind: z.literal("moment"),
    captured_at: timestamp,
    title: utf8Text(160).nullable(),
    place_label: utf8Text(240, true).nullable(),
    people_refs: z.array(utf8Text(160, true)).max(20),
    include_one_shot_location: z.boolean(),
  }).strict().refine(
    (value) => value.include_one_shot_location === (value.place_label !== null),
    { message: "place_label must be present exactly when one-shot location is requested" },
  ),
  z.object({
    kind: z.literal("local_context_attachment"),
    context_kind: z.enum(["photo", "health_summary", "weather_summary", "location_summary", "contact_selection"]),
    local_reference: z.string().uuid(),
    observed_at: timestamp,
    disclosure: z.literal("summary_only"),
  }).strict(),
]);
const actionProposalInput = z.object({
  payload: actionPayload,
  title: utf8Text(160, true),
  rationale: utf8Text(500).optional(),
  source_refs: z.array(sourceReference).max(20).refine(
    (references) => new Set(references.map((reference) => `${reference.kind}\u0000${reference.id}`)).size === references.length,
    { message: "source_refs must be unique" },
  ).optional(),
  redaction_level: z.literal("private").default("private"),
  target_device_preference: z.literal("any").default("any"),
  expires_at: nullableTimestamp.optional(),
}).strict();

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

function actionProposalSummary(proposal: ActionProposalView) {
  return {
    proposal_id: proposal.proposal_id,
    revision: proposal.revision,
    kind: proposal.kind,
    title: proposal.title,
    rationale: proposal.rationale,
    payload: proposal.payload,
    payload_hash: proposal.payload_hash,
    source_refs: proposal.source_refs,
    redaction_level: proposal.redaction_level,
    target_device_preference: proposal.target_device_preference,
    state: proposal.state,
    created_at: proposal.created_at,
    expires_at: proposal.expires_at,
  };
}

function actionReceiptSummary(receipt: ActionReceiptView) {
  return {
    receipt_id: receipt.receipt_id,
    proposal_id: receipt.proposal_id,
    phase: receipt.phase,
    proposal_revision: receipt.proposal_revision,
    attempt: receipt.attempt,
    outcome: receipt.outcome,
    result: receipt.result,
    error_code: receipt.error_code,
    reconciliation_state: receipt.reconciliation_state,
    undo_capability: receipt.undo_capability,
    completed_at: receipt.completed_at,
  };
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
        "DayPage is the user's private local-first memory. Read only the minimum needed, preserve chronology, and distinguish user-authored memo text from compiled wiki pages. System actions are proposals only: never claim approval, OS permission, Apple Framework execution, or success until a native immutable receipt exists.",
    },
  );

  if (grant.canRead) {
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
  }

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

  if (grant.canProposeActions) {
    server.registerTool(
      "daypage_propose_action",
      {
        title: "Propose a DayPage system action",
        description:
          "Create a bounded proposal for native user review. This does not approve or execute an Apple system action.",
        inputSchema: { action: actionProposalInput },
        annotations: {
          readOnlyHint: false,
          destructiveHint: false,
          idempotentHint: false,
          openWorldHint: false,
        },
      },
      async ({ action }) => {
        const proposal = actionProposalSummary(
          await repository.proposeAction(action as ActionProposalInput),
        );
        return textResult(
          `Proposed ${proposal.title}. Pending native user review; no Apple action has executed.`,
          { proposal, requires_native_review: true, executed: false },
        );
      },
    );
  }

  if (grant.canReadActions) {
    server.registerTool(
      "daypage_list_action_proposals",
      {
        title: "List DayPage system action proposals",
        description: "List bounded proposal records. A pending or approved proposal is not proof of execution.",
        inputSchema: {
          limit: z.number().int().min(1).max(50).default(20),
          state: z.enum(["pending", "approved", "rejected", "executing", "completed", "failed", "cancelled", "needs_review"]).optional(),
        },
        annotations: readAnnotations,
      },
      async ({ limit, state }) => {
        const proposals = (await repository.listActionProposals(limit, state)).map(actionProposalSummary);
        return textResult(
          proposals.length ? proposals.map((proposal) => `${proposal.state} · ${proposal.kind} · ${proposal.title}`).join("\n") : "No system action proposals found.",
          { proposals },
        );
      },
    );

    server.registerTool(
      "daypage_list_action_receipts",
      {
        title: "List DayPage system action receipts",
        description: "List immutable, privacy-bounded native execution or undo receipts.",
        inputSchema: { limit: z.number().int().min(1).max(50).default(20) },
        annotations: readAnnotations,
      },
      async ({ limit }) => {
        const receipts = (await repository.listActionReceipts(limit)).map(actionReceiptSummary);
        return textResult(
          receipts.length ? receipts.map((receipt) => `${receipt.outcome} · ${receipt.phase} · ${receipt.proposal_id}`).join("\n") : "No system action receipts found.",
          { receipts },
        );
      },
    );
  }

  void auth;
  return server;
}
