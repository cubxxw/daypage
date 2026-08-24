import assert from "node:assert/strict";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";

const endpoint = process.env.DAYPAGE_MCP_E2E_URL;
const apiKey = process.env.DAYPAGE_MCP_E2E_KEY;
const macMarker = process.env.DAYPAGE_MCP_E2E_MAC_MARKER;
const agentMarker = process.env.DAYPAGE_MCP_E2E_AGENT_MARKER
  ?? `DAYPAGE_AGENT_MCP_WRITE_E2E_${new Date().toISOString()}`;

assert.ok(endpoint, "DAYPAGE_MCP_E2E_URL is required");
assert.ok(apiKey, "DAYPAGE_MCP_E2E_KEY is required");
assert.ok(macMarker, "DAYPAGE_MCP_E2E_MAC_MARKER is required");

const client = new Client(
  { name: "daypage-live-write-acceptance", version: "1.0.0" },
  { capabilities: {} },
);
const transport = new StreamableHTTPClientTransport(new URL(endpoint), {
  requestInit: { headers: { Authorization: `Bearer ${apiKey}` } },
});

await client.connect(transport);
try {
  const listed = await client.listTools();
  const toolNames = listed.tools.map((tool) => tool.name).sort();
  assert.ok(toolNames.includes("daypage_add_memo"), "read/write key did not advertise daypage_add_memo");

  const macSearch = await client.callTool({
    name: "daypage_search",
    arguments: { query: macMarker, limit: 5 },
  });
  assert.match(JSON.stringify(macSearch), new RegExp(macMarker));

  const created = await client.callTool({
    name: "daypage_add_memo",
    arguments: { text: agentMarker },
  });
  assert.equal(created.isError, undefined);
  const memo = created.structuredContent?.memo;
  assert.equal(typeof memo?.id, "string", "write result did not return a memo ID");
  assert.equal(memo?.body, agentMarker);

  const agentSearch = await client.callTool({
    name: "daypage_search",
    arguments: { query: agentMarker, limit: 5 },
  });
  assert.match(JSON.stringify(agentSearch), new RegExp(memo.id));
  assert.match(JSON.stringify(agentSearch), new RegExp(agentMarker));

  process.stdout.write(`${JSON.stringify({
    tools: toolNames,
    mac_sync_marker_read: true,
    agent_memo_id: memo.id,
    agent_marker: agentMarker,
    agent_write_read_back: true,
  }, null, 2)}\n`);
} finally {
  await client.close();
}
