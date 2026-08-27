import assert from "node:assert/strict";
import { once } from "node:events";
import type { AddressInfo } from "node:net";
import test from "node:test";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
import type { DayPageAuthContext } from "./auth.js";
import type { DayPageMcpConfig } from "./config.js";
import { createDayPageHttpServer, metadataPath, parseBearerAuthorization } from "./http.js";
import type {
  ActionProposalInput,
  ActionProposalRecord,
  ActionReceiptView,
  DayPageRepository,
  McpClientGrant,
  MemoRecord,
  PageRecord,
  SearchResults,
} from "./repository.js";
import { systemActionPayloadHash } from "./repository.js";

const marker = "DAYPAGE_MCP_TEST_20260823: Codex can read real MCP data.";
const memoId = "0198aaaa-bbbb-7ccc-8ddd-eeeeeeeeeeee";

test("MCP canonical payload hashing matches the cross-platform contract fixture", async () => {
  const hash = await systemActionPayloadHash({
    kind: "calendar_event",
    title: "Design review",
    start_at: "2026-08-27T01:00:00.000Z",
    end_at: "2026-08-27T01:30:00.000Z",
    all_day: false,
    time_zone: "Asia/Shanghai",
    location_label: "Studio",
    notes: null,
  });
  assert.equal(hash, "025b6f8ab0826324bbcbc4d2d3d7e92a492735931c4543639bb96e043726475c");

  const coordinateHash = await systemActionPayloadHash({
    kind: "route",
    destination_label: "Tiny",
    destination_latitude: 0.000001,
    destination_longitude: -0.000001,
    transport: "walking",
  });
  assert.equal(
    coordinateHash,
    "0daab34946dd400a4389a48450bc75f500670c92983d722170361bc5119338df",
  );
});

class FakeRepository implements DayPageRepository {
  grant: McpClientGrant = {
    canRead: true,
    canWrite: false,
    canReadActions: false,
    canProposeActions: false,
  };
  readonly memo: MemoRecord = {
    id: memoId,
    body: marker,
    type: "text",
    origin: "ios",
    created_at: "2026-08-23T08:00:00.000Z",
    updated_at: "2026-08-23T08:00:00.000Z",
    deleted_at: null,
  };

  async getGrant(): Promise<McpClientGrant> { return this.grant; }
  async listRecent(): Promise<MemoRecord[]> { return [this.memo]; }
  async getMemo(id: string): Promise<MemoRecord | null> { return id === memoId ? this.memo : null; }
  async search(): Promise<SearchResults> { return { memos: [this.memo], pages: [] }; }
  async getPage(): Promise<PageRecord | null> { return null; }
  async addMemo(text: string): Promise<MemoRecord> {
    return { ...this.memo, id: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee", body: text };
  }
  async proposeAction(input: ActionProposalInput): Promise<ActionProposalRecord> {
    return {
      ...input,
      schema_version: 1,
      proposal_id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
      revision: 1,
      kind: input.payload.kind,
      payload_hash: "a".repeat(64),
      rationale: input.rationale ?? "",
      source_refs: input.source_refs ?? [],
      creator_source: "mcp",
      creator_device_id_hash: null,
      target_device_id_hash: input.target_device_id_hash ?? null,
      state: "pending",
      created_at: "2026-08-26T10:00:00.000Z",
      expires_at: input.expires_at ?? null,
      deleted_at: null,
    };
  }
  async listActionProposals(): Promise<ActionProposalRecord[]> {
    return [await this.proposeAction({
      payload: { kind: "focus_session", title: "Deep work", duration_seconds: 1500, schedule_end_alert: true, allow_live_activity: true },
      title: "Start Deep work",
      redaction_level: "private",
      target_device_preference: "any",
    })];
  }
  async listActionReceipts(): Promise<ActionReceiptView[]> {
    return [{
      receipt_id: "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
      proposal_id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
      phase: "execute",
      proposal_revision: 1,
      attempt: 2,
      outcome: "failed",
      result: { summary: "Retry failed safely" },
      error_code: "adapter_unavailable",
      reconciliation_state: "not_applicable",
      undo_capability: "none",
      completed_at: "2026-08-26T10:06:01.000Z",
    }];
  }
}

async function withServer(
  run: (baseUrl: URL, repository: FakeRepository, config: DayPageMcpConfig) => Promise<void>,
): Promise<void> {
  const repository = new FakeRepository();
  const config: DayPageMcpConfig = {
    host: "127.0.0.1",
    port: 0,
    supabaseUrl: "https://example.supabase.co",
    supabaseAnonKey: "anon",
    issuer: "https://example.supabase.co/auth/v1",
    authorizationServer: "https://example.supabase.co/auth/v1",
    resource: "http://127.0.0.1/mcp",
    appBaseUrl: "https://daypage.example",
    requestBodyLimitBytes: 1024 * 1024,
    requestsPerMinute: 100,
  };
  const auth: DayPageAuthContext = {
    token: "test-token",
    subject: "11111111-1111-1111-1111-111111111111",
    clientId: "codex-test-client",
    expiresAt: Math.floor(Date.now() / 1000) + 600,
    grantedScopes: ["openid", "email", "profile"],
    claims: {
      iss: config.issuer,
      sub: "11111111-1111-1111-1111-111111111111",
      aud: ["authenticated", config.resource],
      exp: Math.floor(Date.now() / 1000) + 600,
      iat: Math.floor(Date.now() / 1000),
      role: "authenticated",
      aal: "aal1",
      session_id: "22222222-2222-2222-2222-222222222222",
      client_id: "codex-test-client",
    },
    authType: "oauth",
  };
  const server = createDayPageHttpServer(config, {
    verifyToken: async (token) => {
      if (token !== "test-token") throw new Error("invalid");
      return auth;
    },
    createRepository: () => repository,
  });
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  const port = (server.address() as AddressInfo).port;
  const baseUrl = new URL(`http://127.0.0.1:${port}`);
  config.resource = new URL("/mcp", baseUrl).toString();
  auth.claims.aud = ["authenticated", config.resource];
  try {
    await run(baseUrl, repository, config);
  } finally {
    server.close();
    await once(server, "close");
  }
}

test("publishes protected-resource metadata and a discoverable 401 challenge", async () => {
  await withServer(async (baseUrl, _repository, config) => {
    const metadata = await fetch(new URL(metadataPath(config), baseUrl));
    assert.equal(metadata.status, 200);
    const document = await metadata.json() as { resource: string; authorization_servers: string[] };
    assert.equal(document.resource, config.resource);
    assert.deepEqual(document.authorization_servers, [config.authorizationServer]);

    const unauthorized = await fetch(new URL("/mcp", baseUrl), {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "initialize", params: {} }),
    });
    assert.equal(unauthorized.status, 401);
    assert.match(unauthorized.headers.get("www-authenticate") ?? "", /oauth-protected-resource/);
  });
});

test("parses bearer authorization with a bounded linear scan", () => {
  assert.equal(parseBearerAuthorization("Bearer test-token"), "test-token");
  assert.equal(parseBearerAuthorization("bEaReR\t  test-token  "), "test-token");
  assert.equal(parseBearerAuthorization(`Bearer ${" ".repeat(100_000)}test-token`), "test-token");

  assert.equal(parseBearerAuthorization(undefined), null);
  assert.equal(parseBearerAuthorization(""), null);
  assert.equal(parseBearerAuthorization("Bearer"), null);
  assert.equal(parseBearerAuthorization("Bearer    "), null);
  assert.equal(parseBearerAuthorization("BearerX test-token"), null);
  assert.equal(parseBearerAuthorization("Basic test-token"), null);
});

test("official MCP client lists tools and reads the synthetic memo", async () => {
  await withServer(async (baseUrl) => {
    const client = new Client({ name: "daypage-test", version: "1.0.0" }, { capabilities: {} });
    const transport = new StreamableHTTPClientTransport(new URL("/mcp", baseUrl), {
      requestInit: { headers: { Authorization: "Bearer test-token" } },
    });
    await client.connect(transport);
    try {
      const tools = await client.listTools();
      assert.ok(tools.tools.some((tool) => tool.name === "daypage_list_recent"));
      assert.ok(!tools.tools.some((tool) => tool.name === "daypage_add_memo"));

      const result = await client.callTool({ name: "daypage_list_recent", arguments: { limit: 1 } });
      assert.match(JSON.stringify(result), new RegExp(marker));

      const resource = await client.readResource({ uri: `daypage://memos/${memoId}` });
      const content = resource.contents[0];
      assert.ok(content && "text" in content);
      assert.equal(content.text, marker);
    } finally {
      await client.close();
    }
  });
});

test("write tool is advertised only after a user grant", async () => {
  await withServer(async (baseUrl, repository) => {
    repository.grant = {
      canRead: true,
      canWrite: true,
      canReadActions: false,
      canProposeActions: false,
    };
    const client = new Client({ name: "daypage-write-test", version: "1.0.0" }, { capabilities: {} });
    const transport = new StreamableHTTPClientTransport(new URL("/mcp", baseUrl), {
      requestInit: { headers: { Authorization: "Bearer test-token" } },
    });
    await client.connect(transport);
    try {
      const tools = await client.listTools();
      assert.ok(tools.tools.some((tool) => tool.name === "daypage_add_memo"));
      const result = await client.callTool({ name: "daypage_add_memo", arguments: { text: "from agent" } });
      assert.match(JSON.stringify(result), /from agent/);
    } finally {
      await client.close();
    }
  });
});

test("independent action grants expose proposal/read tools but never approval or execution", async () => {
  await withServer(async (baseUrl, repository) => {
    repository.grant = {
      canRead: false,
      canWrite: false,
      canReadActions: true,
      canProposeActions: true,
    };
    const client = new Client({ name: "daypage-action-test", version: "1.0.0" }, { capabilities: {} });
    const transport = new StreamableHTTPClientTransport(new URL("/mcp", baseUrl), {
      requestInit: { headers: { Authorization: "Bearer test-token" } },
    });
    await client.connect(transport);
    try {
      const tools = await client.listTools();
      const names = tools.tools.map((tool) => tool.name);
      assert.ok(names.includes("daypage_propose_action"));
      assert.ok(names.includes("daypage_list_action_proposals"));
      assert.ok(names.includes("daypage_list_action_receipts"));
      assert.ok(!names.some((name) => /approve|execute|undo|permission/.test(name)));
      assert.ok(!names.some((name) => ["daypage_list_recent", "daypage_search", "daypage_get_memo", "daypage_get_page"].includes(name)));

      const receipts = await client.callTool({
        name: "daypage_list_action_receipts",
        arguments: { limit: 10 },
      });
      const receipt = (receipts.structuredContent as {
        receipts?: Array<{ proposal_revision?: unknown; attempt?: unknown }>;
      } | undefined)?.receipts?.[0];
      assert.equal(receipt?.proposal_revision, 1);
      assert.equal(receipt?.attempt, 2);

      const proposed = await client.callTool({
        name: "daypage_propose_action",
        arguments: {
          action: {
            payload: {
              kind: "focus_session",
              title: "Deep work",
              duration_seconds: 1500,
              schedule_end_alert: true,
              allow_live_activity: true,
            },
            title: "Start Deep work",
            target_device_preference: "any",
          },
        },
      });
      assert.match(JSON.stringify(proposed), /Pending native user review/);
      assert.equal((proposed.structuredContent as { executed?: unknown } | undefined)?.executed, false);
      assert.equal(
        (proposed.structuredContent as { proposal?: { redaction_level?: unknown } } | undefined)
          ?.proposal?.redaction_level,
        "private",
      );
      const nonPrivate = await client.callTool({
        name: "daypage_propose_action",
        arguments: {
          action: {
            payload: {
              kind: "focus_session",
              title: "Deep work",
              duration_seconds: 1500,
              schedule_end_alert: true,
              allow_live_activity: true,
            },
            title: "Sensitive before approval",
            redaction_level: "sensitive",
            target_device_preference: "any",
          },
        },
      });
      assert.equal(nonPrivate.isError, true);
      const invalidTarget = await client.callTool({
        name: "daypage_propose_action",
        arguments: {
          action: {
            payload: {
              kind: "focus_session",
              title: "Deep work",
              duration_seconds: 1500,
              schedule_end_alert: true,
              allow_live_activity: true,
            },
            title: "Start on the nonexistent cloud creator device",
            redaction_level: "private",
            target_device_preference: "creating_device",
          },
        },
      });
      assert.equal(invalidTarget.isError, true);
      assert.match(JSON.stringify(invalidTarget), /invalid.*input/i);

      const invalidCalendar = await client.callTool({
        name: "daypage_propose_action",
        arguments: {
          action: {
            payload: {
              kind: "calendar_event",
              title: "Invalid interval",
              start_at: "2026-08-27T09:00:00+08:00",
              end_at: "2026-08-27T09:00:00+08:00",
              all_day: false,
              time_zone: "Asia/Shanghai",
              location_label: null,
              notes: null,
            },
            title: "Invalid interval",
            redaction_level: "private",
            target_device_preference: "any",
          },
        },
      });
      assert.equal(invalidCalendar.isError, true);

      const overPreciseRoute = await client.callTool({
        name: "daypage_propose_action",
        arguments: {
          action: {
            payload: {
              kind: "route",
              destination_label: "Too precise",
              destination_latitude: 12.1234567,
              destination_longitude: 31.123456,
              transport: "walking",
            },
            title: "Invalid route precision",
            redaction_level: "private",
            target_device_preference: "any",
          },
        },
      });
      assert.equal(overPreciseRoute.isError, true);
      assert.match(JSON.stringify(overPreciseRoute), /six decimal places/i);

      const oversizedUtf8 = await client.callTool({
        name: "daypage_propose_action",
        arguments: {
          action: {
            payload: {
              kind: "focus_session",
              title: "Deep work",
              duration_seconds: 1500,
              schedule_end_alert: true,
              allow_live_activity: true,
            },
            title: "🙂".repeat(41),
            redaction_level: "private",
            target_device_preference: "any",
          },
        },
      });
      assert.equal(oversizedUtf8.isError, true);
    } finally {
      await client.close();
    }
  });
});
