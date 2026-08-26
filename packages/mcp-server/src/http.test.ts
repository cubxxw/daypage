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
  DayPageRepository,
  McpClientGrant,
  MemoRecord,
  PageRecord,
  SearchResults,
} from "./repository.js";

const marker = "DAYPAGE_MCP_TEST_20260823: Codex can read real MCP data.";
const memoId = "0198aaaa-bbbb-7ccc-8ddd-eeeeeeeeeeee";

class FakeRepository implements DayPageRepository {
  grant: McpClientGrant = { canRead: true, canWrite: false };
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
    repository.grant = { canRead: true, canWrite: true };
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
