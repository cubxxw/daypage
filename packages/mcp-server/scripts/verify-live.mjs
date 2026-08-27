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
  assert.ok(toolNames.includes("daypage_propose_action"), "action-scoped key did not advertise daypage_propose_action");
  assert.ok(toolNames.includes("daypage_list_action_proposals"), "action-scoped key did not advertise proposal reads");
  assert.ok(toolNames.includes("daypage_list_action_receipts"), "action-scoped key did not advertise receipt reads");
  assert.ok(!toolNames.some((name) => /approve|execute|undo|permission/.test(name)), "MCP exposed native authority");

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

  const actionTitle = `DAYPAGE_LOCAL_MCP_ACTION_${new Date().toISOString()}`;
  const proposed = await client.callTool({
    name: "daypage_propose_action",
    arguments: {
      action: {
        payload: {
          kind: "focus_session",
          title: actionTitle,
          duration_seconds: 1200,
          schedule_end_alert: true,
          allow_live_activity: true,
        },
        title: `Start ${actionTitle}`,
        rationale: "Synthetic local backend acceptance",
        redaction_level: "private",
        target_device_preference: "any",
      },
    },
  });
  assert.equal(proposed.isError, undefined);
  assert.equal(proposed.structuredContent?.executed, false);
  assert.equal(proposed.structuredContent?.requires_native_review, true);
  const proposalId = proposed.structuredContent?.proposal?.proposal_id;
  assert.equal(typeof proposalId, "string", "proposal did not return its durable ID");

  const proposals = await client.callTool({
    name: "daypage_list_action_proposals",
    arguments: { limit: 5, state: "pending" },
  });
  assert.match(JSON.stringify(proposals), new RegExp(proposalId));

  process.stdout.write(`${JSON.stringify({
    tools: toolNames,
    mac_sync_marker_read: true,
    agent_memo_id: memo.id,
    agent_marker: agentMarker,
    agent_write_read_back: true,
    action_proposal_id: proposalId,
    action_pending_native_review: true,
  }, null, 2)}\n`);
} finally {
  await client.close();
}
